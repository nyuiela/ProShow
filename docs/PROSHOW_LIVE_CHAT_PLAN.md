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
| X | Yes, own broadcasts only | `GET /2/broadcasts/{id}/chat` polling (built, Phase 2). Activity API push needs a public webhook | OAuth 2.0 user token, `broadcast.read` + `broadcast.write` (separate Connect X sign-in) | 10 s while active, 30 s quiet | Pay per use per unique resource per UTC day. No broadcast line on the pricing page; estimated at Posts read $0.005/message, User read $0.010/author | Medium | Phase 2 built |
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
- X (built): after Go Live, if an X destination (or a pscp/periscope RTMP ingest) is armed and Connect X is signed in, use the broadcast id from `prepareXBroadcasts` (`GET /2/broadcasts/{id}`). If it is missing or never turns live, fall back to `GET /2/broadcasts?max_results=5` (the signed in user's broadcasts) and take the first with state `running` (also accepts `live`, `started`; X does not enumerate `state`). Not live: status `Not live on X`, re-check at 60 s backing off to 180 s. Manual: paste an `x.com/i/broadcasts/<id>` link or id in More, or leave it empty for auto.

### 4.4 Auth

- Tokens stay in `KeychainStreamVault` through `StreamAccountManager.ensureValidAccessToken`. Connectors get a token provider closure, never raw storage.
- YouTube: current scopes (`youtube`, `youtube.readonly`) already cover chat read. No re-consent.
- X (built): a separate Connect X sign-in in the chat More menu, so the X destination account's working scopes (`tweet.read tweet.write users.read offline.access media.write`) are never changed. OAuth 2.0 PKCE with scopes `tweet.read users.read broadcast.read broadcast.write offline.access` (exact names from the X API v2 OpenAPI spec). Redirect `http://127.0.0.1:55079/`, the ProShow X port already registered on the X app. Tokens go to the keychain under the fixed id `XChatAuth.accountID` (`oauth.access/refresh/expires.<id>`); refresh through `ensureValidAccessToken`. If the X app is not allowed broadcast scopes, X returns `unauthorized_scope` and the menu shows `X app lacks broadcast access`.
- Loopback hijack guard (same class as the n8n bug): `OAuthLoopbackServer` now requires the bind for the family the redirect host names (127.0.0.1 needs IPv4, `[::1]` IPv6, `localhost` both). If that bind fails because something else holds the port, sign-in stops with `Port 55079 is in use` instead of opening the browser. ProShow binds the specific loopback address, so a Docker `*:port` listener cannot take the callback.
- 401 handling: force one refresh, then fail with `Sign-in expired`.
- No client secrets or tokens in the repo, fixtures, or logs.

### 4.5 Moderation queue

- Every ingested message lands in the inbox as pending. Only an explicit operator action (Feature) puts it on screen. No auto-feature in any phase.
- Actions: Feature, Hide (removes from inbox, keeps key so it never comes back), Block author (hides all current and future messages from that `authorID` for this session, optional persist per project later), Star.
- Word filter: case-insensitive list in device settings. Matching messages are dropped before the inbox (counted, not shown).
- Upstream removal: YouTube `messageDeletedEvent` and `userBannedEvent`. X polling has no removal events; X deletes are not mirrored yet (moderate in ProShow with Hide).

### 4.6 On screen

- Chat card: existing `ChatOverlayCard` through `LiveChatEngine.pushOverlay` and `compositor.setChatOverlay`.
- Lower third text fields: add placeholders `chat.name` and `chat.text` to the dynamic text resolver so any lower third prop can show the featured message. Empty when nothing is featured.
- Cooldown and auto-clear: keep `autoClearSeconds` (default 10). Add a 3 s cooldown so a double click cannot swap the card mid-animation.

## 5. Costs and quotas

- YouTube: 10,000 units/day default. streamList is 5 units per connect. Measured 2026-10-20: over HTTP the server holds each streamList connection about 10.5 s and then closes it (long poll), so the connector reconnects with the page token about 6 times a minute: about 30 units/min, 1,800 units/hour. That is about 3.9 hours of chat a day inside the 7,000 unit chat budget. Only gRPC keeps one connection open for the whole show (Phase 1b). List polling costs the same 5 units per call. Discovery calls cost 1 unit each.
- Guard: `YouTubeQuotaLedger` keeps a local per Pacific day estimate (quota resets at midnight Pacific) and the connector stops with `Daily quota budget reached` before it would pass 7,000 units, so Go Live provisioning (same quota) keeps working. `GET /v1/chat/youtube` reports `quota_units_today`, `stream_connects`, `last_hold_s`.
- X (checked 2026-10-21, docs.x.com/x-api/getting-started/pricing): pay per use, billed per resource returned, deduplicated per resource within a UTC day (X calls dedup a soft guarantee). The page has no broadcast or broadcast chat line. Activity API events are billed now too (for example `chat.received` $0.010) and need a public webhook, so ProShow polls instead.
  - Estimate used by `XChatSpendLedger`: $0.005 per unique chat message and per broadcast (Posts read rate), $0.010 per unique author with avatars (User read, `expansions=author_id`), $0.015 per reply sent (Post create rate). Kaleel's cap is under $1/day for all agents combined, so X chat gets $0.40 per UTC day (`proshow.liveChat.xDailyCapUSD`). The connector checks the worst case of the next page before each call and stops with `X daily cap reached`, so it never passes the cap by its own count.
  - Poll rate: 10 s while messages arrive, 30 s after 3 quiet polls, 10 messages per page while active and 3 when quiet. 360 requests per hour at most. Requests are not billed; returned resources are.
  - One hour of reading at that rate: about $0.25 for a quiet chat (30 messages, 10 people), about $1.60 for a busy one (200 messages, 60 people), so the $0.40 cap covers about 15 minutes of a busy chat. Avatars off (`defaults write com.kaleel.proshow proshow.liveChat.xAvatars -bool NO`) drops busy to $1.00 an hour. No chat: about $0.
  - Risk: chat reads are newest first with no since id, so every poll re-reads the newest page and relies on X dedup. If dedup missed, the worst case is 120 quiet polls x 3 messages x $0.005 = $1.80 an hour, which the local ledger would not see. Set a spending limit in the X Developer Console as the hard stop.
  - `GET /v1/chat/x` reports `requests`, `usd_today`, `usd_cap`. The X Developer Console usage page is the truth.
- The connector keeps a running `quotaUnitsUsed` estimate, shown in the panel tooltip and in `GET /v1/chat/youtube`.

## 6. Feature flag

`proshow.liveChatIngestV1` (UserDefaults bool, off by default).

```
defaults write com.kaleel.proshow proshow.liveChatIngestV1 -bool YES
```

Off: no connector code runs, no new UI, Go Live behaves exactly as today. On: YouTube and X rows in the chat More menu, auto-connect after Go Live, control routes `/v1/chat/youtube` and `/v1/chat/x`.

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
- Quota: about 1,800 units per hour over HTTP streamList (measured). Hard stop at 7,000 units per Pacific day. Phase 1b (gRPC streamList, one long-lived connection) targets under 100 units per hour.

### Phase 2: X

Status: built 2026-10-21. Sign-in pending (Kaleel).

Scope as built:
- `XChatConnector` (`ProShow/Services/XChatConnector.swift`): actor at utility priority, no shared locks with audio. Discovery (4.3), then polls `GET /2/broadcasts/{id}/chat` with `broadcast_chat_message.fields=id,text,author_name,author_username,created_at_ms,reply_to` and, when avatars are on, `expansions=author_id&user.fields=profile_image_url,username,name`. Newest first from X, delivered oldest first, deduped by message id. Re-checks the broadcast state every 5 min.
- Mapping: `LiveChatMessage` with id `x:<id>`, `@username`, avatar from the user expansion (initials otherwise), platform `X`, role `owner` for the host. Same inbox and moderation as YouTube: nothing reaches the screen without Display on screen.
- Errors: 401 refreshes once and retries, then `Sign in to X`. 429 waits for `x-rate-limit-reset` (capped at 15 min), else backs off 5, 10, 20 s up to 120 s. 403 is terminal `X app lacks broadcast access`. 404 or not running goes back to discovery. Ended broadcast stops.
- Replies: the reply box posts `POST /2/broadcasts/{id}/chat` `{"text", "reply_to"}` only on the operator's Send or Return. Text is flattened and capped at 140 characters (`SendBroadcastChatRequest.text` maxLength). `reply_to` is sent only when the target id is numeric (`^[0-9]{1,19}$`); otherwise the reply starts with `@username`. Needs a running broadcast.
- UI: chat More menu, X row under YouTube: `Connect X` before sign-in, then a link/ID field with Connect or Stop. Status line shows a terse X error only on failure.
- Control: `GET /v1/chat/x` state. `POST {"input": "auto" | id | link}`, `{"stop": "1"}`, `{"mock_base": "http://127.0.0.1:<port>/2"}` (loopback only, dummy token, tests). No send route.

Test plan as run:
- Unit (swift-testing `XChatIngestTests`, also run in `~/snap/lcharness/x`): parse and map, request fields, 140 cap and reply_to rules, link parsing, auto discovery and dedupe, not live backoff (60, 90, 135 s), 401 refresh, 401 twice, 429 reset header, 5xx backoff, quiet slowdown and page size, budget stop before cap, unique spend counting, send with refresh, ended, 403 terminal, hub reply routing.
- Mock X server `~/snap/lcharness/xmock/xmock.py` (127.0.0.1 only) with faults `401first,429third`: end to end over real HTTP through URLSession, read, refresh, rate limit wait, reply POST. Never posts to a real chat.

Acceptance: messages within about 10 s while active (30 s quiet); spend inside the $0.40 daily cap by the ledger, confirmed in the X usage dashboard after the first real show.

Limits found:
- Chat endpoints work only on broadcasts owned by the signed in user (`GET /2/broadcasts` returns "the authenticated user's live-video broadcasts"). Other people's broadcasts cannot be read.
- RTMP ingest: the broadcast object has `source_id` (Media Studio Producer source), so a broadcast fed from ProShow over RTMP should be an owned broadcast. Not yet confirmed on a real show; if it does not show up in `GET /2/broadcasts`, paste the broadcast link in More.
- Posting needs a running broadcast. Messages max 140 characters.
- `broadcast.*` scopes may need approval on the X app (the destination sign-in comment says requesting them broke consent). If so, Connect X shows `X app lacks broadcast access` and the X app needs those scopes enabled in the X Developer Console.

### Phase 3: Moderation and on screen

Scope: Hide, Block author, word filter, `chat.name` / `chat.text` placeholders, cooldown.

Acceptance: blocked author never reappears in session; filtered words never reach inbox; lower third shows featured message and clears on auto-clear.

### Phase 4: LinkedIn and others

- LinkedIn: Restream chat WebSocket bridge (needs a Restream account) or wait for partner access to comments.
- Facebook and Instagram: only after Meta App Review, and Instagram needs a public webhook endpoint.
- Twitch and Kick: when an account is added. Twitch EventSub WebSocket needs no public endpoint, so it comes first.
- TikTok: not viable without a public API. Revisit if TikTok publishes one.

## 8. Replies (YouTube and X built)

| Platform | Endpoint | Auth | Cost | Notes |
| --- | --- | --- | --- | --- |
| YouTube | `liveChatMessages.insert` (`POST /youtube/v3/liveChat/messages`, `snippet.type=textMessageEvent`) | `youtube` or `youtube.force-ssl`. ProShow already requests `youtube`, so no re-consent | 20 units per message | Posts as the signed in channel. `rateLimitExceeded` if sending too fast. Source: https://developers.google.com/youtube/v3/live/docs/liveChatMessages/insert |
| X (built) | `POST /2/broadcasts/{id}/chat` `{"text", "reply_to"}` | OAuth 2.0 user token with `broadcast.write` and `broadcast.read` (Connect X) | Pay per use, no published rate; ledger counts $0.015 per send | Broadcast must be running. 140 character cap (confirmed in the OpenAPI spec). Response `{success, timestamp}`. No MCP tool for it (MCP `send_chat_message` is encrypted X Chat DMs, not broadcast chat). Moderation exists: `DELETE /2/broadcasts/{id}/chat/{message_id}`, mute and unmute |
| LinkedIn, Facebook, Instagram | Comment replies need partner access or Meta App Review | | | Later |

Rules if built: operator types and confirms every reply, nothing automatic, posts as the signed in account, separate flag `proshow.liveChatReplyV1`.

## 8b. Display on screen through a project prop (built)

"Display on screen" in the chat panel uses a prop from the project when there is one, so the
show's own design is on air instead of the built-in card.

- **Template prop.** A prop marked **Use as Chat Template** (prop right-click menu). One prop
  at most; marking one clears the others; a duplicate starts unmarked. With none marked, a prop
  named `Chat highlight` is used. With neither, the built-in card draws as before.
  The flag saves as `isChatTemplate: true` and only when set, so other props save unchanged.
- **Values.** While a message is featured, `dynamicTextContext()` adds `chat.name`,
  `chat.message`, `chat.platform` (`YouTube`, `X`, ...) and `chat.avatar` (the avatar URL, or
  empty). They override the project's `chat.*` text fields for that moment only and are never
  saved. The project's sample text returns once the prop has finished leaving.
- **Show and hide.** A pick turns the prop on with `toggleInspectorProp`, so its own enter
  animation plays. A pick while it is up swaps the text in place, with no re-entry. Dismiss and
  the 10 s auto-clear (and an upstream delete or block of the featured message) turn it off
  through its own exit animation. The chat values stay on it until the exit finishes.
- **Already on.** If the template prop is on when a pick arrives (for example, its sample is
  showing), the pick fills it in place, and Dismiss turns it off.
- **Outputs.** The prop's own Show on setting applies. A Stream only prop stays off the Phone
  layout. A Phone lane that letterboxes the whole Stream picture still shows it, as it does any
  Stream prop.
- **Control API.** `POST /v1/chat/feature` with `id` or `index` (0 = newest), or `dismiss=1`;
  `GET` returns the template, whether it is on, and the live `chat.*` values. These are the same
  calls the panel makes.
- **Code.** `ShowController+Backstage.swift` (template lookup, show and hide, values),
  `LiveChatStreamManager` (`templatePresenter` / `templateDismisser`), `ProShowProp.isChatTemplate`.
  No audio code involved.

## 8c. Chat avatar on image layers (built)

- An image layer (image kind, or a shape with an image fill) can set **Live source: Chat avatar** in the prop editor. This is stored as `imageBinding = "chat.avatar"` on the canvas object and omitted when unset.
- For the chat template prop, right-click it and use **Chat Avatar Layer**, which lists its image layers (None or a layer name).
- When a message is featured, `ChatAvatarFileCache` downloads the sender's avatar off the main thread (utility priority, HTTPS only, 2 MB cap, must decode as an image).
  - It caches the file in Caches/ProShow/ChatAvatars.
  - It upgrades twimg `_normal` to `_400x400` and ggpht `=sNN` to `=s240`, falling back to the original URL.
- The render path only reads the cached file: `applyImageBinding` in `resolvedCanvasObjects` never fetches. Until the download lands, or if it fails, the layer keeps its own image. The props resync once the file is on disk.
- YouTube webhook ingest now reads `authorDetails.profileImageUrl`.
- `GET /v1/chat/feature` reports `avatar_cached` and `avatar_layers`.

## 9. Risks

- streamList over HTTP framing is not documented in detail. The parser accepts JSON array framing and newline framing, and the connector falls back to list polling on any framing failure.
- YouTube `rateLimitExceeded` if we poll faster than `pollingIntervalMillis`. The connector always waits at least the server interval.
- X pricing can change and has no broadcast line today. Re-check the pricing page and the X usage dashboard after the first real show. Keep a Developer Console spending limit as the hard stop.
- Chat is untrusted input. It is rendered as plain text only; never parsed as markup or links on screen.
