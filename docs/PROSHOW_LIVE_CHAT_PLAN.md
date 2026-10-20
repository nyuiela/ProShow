# ProShow Live Chat Ingest Plan

Status: Phase 1 (YouTube) in progress behind `proshow.liveChatIngestV1` (off by default).
Owner: Kaleel. Last updated: 2026-10-20 (GMT).

## 1. Goals

1. Pull audience chat from every destination we stream to into one operator inbox.
2. Nothing reaches the program output unless the operator puts it there.
3. Zero cost or near zero cost per show. No background polling that bills.
4. Auto-discover the chat for the destination on Go Live. No copy/paste on show day.
5. Read only. ProShow never posts into platform chat in v1.
6. Every connector fails soft: a dead chat never blocks Go Live, Take, or the encoder.

Non-goals for v1: posting replies, platform moderation actions (ban, timeout), analytics, chat archive export.

## 2. Destinations we use today

From `device-settings.json` (names only, no secrets): YouTube, X, LinkedIn, Custom RTMP (instrm, pscp). No Facebook, Twitch, TikTok, Instagram, or Kick accounts are configured.

Existing code we build on:

| File | What it does today |
| --- | --- |
| `ProShow/Services/LiveChatEngine.swift` | Studio chat model, overlay card, `ingestWebhook` |
| `ProShow/Services/LiveChatIngestService.swift` | Normalizes webhook JSON (Zoom, Meet, YouTube, Twitch) into `LiveChatMessage` |
| `ProShow/Services/LiveChatStreamManager.swift` | Operator inbox, star, feature on screen, auto-clear |
| `ProShow/Features/Operator/BackstageControlPanelView.swift` | "Live chat stream" inbox UI |
| `ProShow/Services/StreamAccountManager.swift` | PKCE OAuth, token refresh |
| `ProShow/Services/KeychainStreamVault.swift` | Token storage |
| `ProShow/Services/PlatformLiveApiService.swift` | YouTube broadcast provisioning (`broadcastID`), X broadcast listing |

## 3. Platform matrix

| Platform | Official read API | Method | Auth | Latency | Cost / limits | Effort | Plan |
| --- | --- | --- | --- | --- | --- | --- | --- |
| YouTube | Yes | `liveChatMessages.streamList` (server push), `liveChatMessages.list` (poll) | OAuth `youtube.readonly` (already granted) | ~1 s push, poll at `pollingIntervalMillis` | 5 units per stream connect, 5 per list call, 10,000 units/day default | Low | Phase 1 |
| X | Yes | Activity API `broadcast.chat` event (push), `GET /2/broadcasts/{id}/chat` (history) | OAuth 2.0 user token, `broadcast.read` (missing today) | Real time push | Pay per use. Push events not billed at time of writing. Broadcast start/end about $0.005 each, about $0.01 per show. Poll price unpublished, do not poll | Medium | Phase 2 |
| LinkedIn | No live chat API | Comments on the live post via Social Actions Comments API | Partner-only `r_member_social` / Community Management | Poll only | Partner approval | High | Restream bridge or later |
| Facebook | Yes | Poll `/{live-video-id}/comments`. SSE `streaming-graph.facebook.com` is unreliable | `pages_read_engagement`, `pages_read_user_content`, Meta App Review | 2 to 5 s poll | Graph rate limits | Medium + review | Later, needs Meta App Review |
| Instagram | Yes (Business/Creator only) | Webhook `live_comments` | Instagram Graph, Meta App Review, public webhook URL | Push | Needs public HTTPS endpoint | High | Later, needs Meta App Review |
| Twitch | Yes | EventSub WebSocket `channel.chat.message` | `user:read:chat` | Push | Free | Low | Later (no account today) |
| Kick | Yes | Webhook `chat.message.sent` | `events:subscribe` | Push | Needs public HTTPS endpoint | Medium | Later (no account today) |
| TikTok | No public live chat API | None | None | n/a | n/a | n/a | Not viable |

Sources (read 2026-10-20):

- YouTube streamList: https://developers.google.com/youtube/v3/live/docs/liveChatMessages/streamList
- YouTube list: https://developers.google.com/youtube/v3/live/docs/liveChatMessages/list
- YouTube liveBroadcasts.list: https://developers.google.com/youtube/v3/live/docs/liveBroadcasts/list
- YouTube videos `liveStreamingDetails.activeLiveChatId`: https://developers.google.com/youtube/v3/docs/videos#liveStreamingDetails
- YouTube quota costs: https://developers.google.com/youtube/v3/determine_quota_cost
- X API broadcasts and Activity API: https://docs.x.com/x-api/introduction
- X pricing: https://docs.x.com/x-api/getting-started/pricing
- Twitch EventSub `channel.chat.message`: https://dev.twitch.tv/docs/eventsub/eventsub-subscription-types/#channelchatmessage
- Kick events: https://docs.kick.com/events/event-types
- Facebook live comments: https://developers.facebook.com/docs/live-video-api/guides/comments
- Instagram webhooks (`live_comments`): https://developers.facebook.com/docs/instagram-platform/webhooks
- LinkedIn comments API: https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/comments-api
- LinkedIn live events: https://learn.microsoft.com/en-us/linkedin/marketing/live-events
- Restream chat API (aggregator fallback): https://developers.restream.io/docs

## 4. Architecture

```
 Go Live / manual target
          |
          v
   ChatIngestHub (@MainActor, one per controller)
     |-- YouTubeChatConnector  (Phase 1)
     |-- XChatConnector        (Phase 2)
     |-- RestreamChatConnector (later, LinkedIn bridge)
          |
          v  LiveChatMessage (normalized, deduped by platform + externalID)
   LiveChatStreamManager.ingest  -> operator inbox (Backstage panel)
          |
          v  operator action only (Feature)
   LiveChatEngine.pushOverlay -> compositor chat card / lower third text fields
```

### 4.1 ChatConnector interface

```swift
enum ChatConnectorState: Equatable, Sendable {
    case idle
    case resolving              // finding the chat id
    case streaming              // push connection open
    case polling                // list fallback
    case retrying(seconds: Int) // backoff
    case ended                  // chat closed by platform
    case failed(String)         // terse reason, shown as is
}

@MainActor
protocol ChatConnector: AnyObject {
    var platform: ChatPlatform { get }
    var state: ChatConnectorState { get }
    func start(target: ChatTarget)
    func stop()
}

enum ChatTarget: Equatable, Sendable {
    case chatID(String)       // platform chat id
    case video(String)        // YouTube video id or URL, X broadcast id
    case broadcast(String)    // id from our own provisioning
    case autoActive           // find my active broadcast
}
```

Connectors own their network loop, reconnect, and backoff. They emit through two closures: `onMessages([LiveChatMessage])` and `onRemoved([String])` (platform message ids removed upstream). They never touch the compositor.

### 4.2 Normalized message model

Extend `LiveChatMessage` with optional fields (Codable stays backward compatible):

| Field | Type | Notes |
| --- | --- | --- |
| `externalID` | `String?` | Platform message id |
| `authorID` | `String?` | Platform author id, used for block author |
| `authorRole` | `String?` | `owner`, `moderator`, `member`, `verified` |
| `kind` | `String?` | `text`, `superChat`, `superSticker`, `membership`, `other` |
| `amountDisplay` | `String?` | Super Chat amount as YouTube formats it |

Dedupe key: `"\(platform.rawValue):\(externalID)"`. The inbox keeps a bounded set (last 2,000 keys) so a resumed stream or a reconnect replay never doubles a message. Messages without `externalID` (webhooks) are never deduped.

### 4.3 Chat id discovery on Go Live

- YouTube: we already create the broadcast in `PlatformLiveApiService` and hold `ResolvedIngest.broadcastID`. After the encoder is live, call `liveBroadcasts.list?part=snippet&id=<broadcastID>` and read `snippet.liveChatId`. If we have no broadcast id (manual stream key), fall back to `liveBroadcasts.list?part=snippet&broadcastStatus=active&broadcastType=all` (my active broadcasts) and take the first `liveChatId`. Retry for up to 60 s since the chat can appear a few seconds after transition to live.
- YouTube manual: operator pastes a watch URL, `youtu.be` link, `/live/<id>` link, or an 11 character video id. We resolve with `videos.list?part=liveStreamingDetails&id=<id>` and read `liveStreamingDetails.activeLiveChatId`. This also works for public streams we do not own (read only).
- X: use the broadcast id from our `broadcast.start` call (`prepareXBroadcasts`). If missing, `list_broadcasts` for the signed in user and take the one in `running` state. Subscribe to `broadcast.chat` filtered on that id.

### 4.4 Auth

- Tokens stay in `KeychainStreamVault` through `StreamAccountManager.ensureValidAccessToken`. Connectors get a token provider closure, never raw storage.
- YouTube: current scopes (`youtube`, `youtube.readonly`) already cover chat read. No re-consent.
- X: add `broadcast.read` and `broadcast.write` to `xUserScopes` in `StreamAccountModel.swift`. Existing tokens do not carry them, so the X account must re-consent once (Kaleel). Until then the X connector reports `failed("Reconnect X for chat")`.
- 401 handling: force one refresh, then fail with `Sign-in expired`.
- No client secrets or tokens in the repo, fixtures, or logs.

### 4.5 Moderation queue

- Every ingested message lands in the inbox as pending. Only an explicit operator action (Feature) puts it on screen. No auto-feature in any phase.
- Actions: Feature, Hide (removes from inbox, keeps key so it never comes back), Block author (hides all current and future messages from that `authorID` for this session, optional persist per project later), Star.
- Word filter: case-insensitive list in device settings. Matching messages are dropped before the inbox (counted, not shown).
- Upstream removal: YouTube `messageDeletedEvent` and `userBannedEvent`, X `broadcast.chat.remove`. If the removed message is on screen, clear the overlay immediately.

### 4.6 On screen

- Chat card: existing `ChatOverlayCard` through `LiveChatEngine.pushOverlay` and `compositor.setChatOverlay`.
- Lower third text fields: add placeholders `chat.name` and `chat.text` to the dynamic text resolver so any lower third prop can show the featured message. Empty when nothing is featured.
- Cooldown and auto-clear: keep `autoClearSeconds` (default 10). Add a 3 s cooldown so a double click cannot swap the card mid-animation.

## 5. Costs and quotas

- YouTube: 10,000 units/day default. streamList is 5 units per connect. A 2 hour show with a few reconnects is under 100 units. List polling at the server `pollingIntervalMillis` (often 3 to 10 s) is about 5 units per call; 1 hour of polling at 5 s is about 3,600 units, so polling is fallback only and the connector stops polling when quota errors appear. Discovery calls cost 1 unit each.
- X: push only. About $0.01 per show for broadcast start/end. Do not poll `/2/broadcasts/{id}/chat` until the price is published. Budget stays under $0.50/day per account and $1/day combined.
- The connector keeps a running `quotaUnitsUsed` estimate, shown in the panel tooltip and in `GET /v1/chat/youtube`.

## 6. Feature flag

`proshow.liveChatIngestV1` (UserDefaults bool, off by default).

```
defaults write com.kaleel.proshow proshow.liveChatIngestV1 -bool YES
```

Off: no connector code runs, no new UI, Go Live behaves exactly as today. On: YouTube row in the chat panel, auto-connect after Go Live, control route `/v1/chat/youtube`.

## 7. Phases

### Phase 1: YouTube (now)

Scope:
- `YouTubeChatConnector` with streamList first, list polling fallback, page token resume, exponential backoff with jitter (1 s to 60 s), quota awareness, 401 refresh.
- Auto-connect after Go Live using `broadcastID`, else my active broadcast.
- Manual target: paste URL or video id in the chat panel.
- Feeds `LiveChatStreamManager` inbox with dedupe. Upstream deletes remove inbox rows.
- Control API: `GET /v1/chat/youtube` (state), `POST /v1/chat/youtube` `{"input": "<url or id>"}` connect, `{"stop": "1"}` stop.

Test plan:
- Unit (recorded fixtures, swift-testing): URL/id parsing, list response parse (text, Super Chat, deleted, ended, offlineAt), error reason mapping (`liveChatEnded`, `liveChatNotFound`, `quotaExceeded`, `rateLimitExceeded`), stream chunk framing (array and newline framed), connector loop with fake transport (resolve, page token resume, dedupe, 401 refresh, stream to poll fallback, backoff sequence).
- Live: connect to a public YouTube live stream with active chat, read only, using the existing YouTube OAuth. Never arm or stream to real destinations. Screenshot of messages in the inbox.

Acceptance:
- Messages show in the inbox within 3 s of posting (stream mode).
- Kill network for 30 s: connector shows Retrying, then resumes with no duplicates and no gap beyond what YouTube keeps.
- Chat ends: state Ended, no further calls.
- Flag off: zero network calls, UI unchanged.
- Under 100 quota units per hour in stream mode.

### Phase 2: X

Scope: add `broadcast.read`, `broadcast.write` scopes (re-consent by Kaleel), `XChatConnector` via Activity API subscription to `broadcast.chat` and `broadcast.chat.remove` for the running broadcast id, history backfill once at connect with `/2/broadcasts/{id}/chat` only if the price is confirmed free or trivial.

Test plan: unit tests with recorded event fixtures; live test on a private test broadcast after re-consent.

Acceptance: messages within 2 s; removals clear inbox and overlay; spend per show under $0.02 in the X usage dashboard.

### Phase 3: Moderation and on screen

Scope: Hide, Block author, word filter, `chat.name` / `chat.text` placeholders, cooldown.

Acceptance: blocked author never reappears in session; filtered words never reach inbox; lower third shows featured message and clears on auto-clear.

### Phase 4: LinkedIn and others

- LinkedIn: Restream chat WebSocket bridge (needs a Restream account) or wait for partner access to comments.
- Facebook and Instagram: only after Meta App Review, and Instagram needs a public webhook endpoint.
- Twitch and Kick: when an account is added. Twitch EventSub WebSocket needs no public endpoint, so it comes first.
- TikTok: not viable without a public API. Revisit if TikTok publishes one.

## 8. Risks

- streamList over HTTP framing is not documented in detail. The parser accepts JSON array framing and newline framing, and the connector falls back to list polling on any framing failure.
- YouTube `rateLimitExceeded` if we poll faster than `pollingIntervalMillis`. The connector always waits at least the server interval.
- X Activity API terms and pricing can change. Re-check pricing before Phase 2 ships.
- Chat is untrusted input. It is rendered as plain text only; never parsed as markup or links on screen.
