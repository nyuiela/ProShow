# Multi-destination routing (locked before implementation)

Status: decisions only. Not in the 1.0.0 build. Ship behind a flag as 1.1. Flag off runs today’s `StreamingEngine.start()` and ignores screen and fit fields.

1.0.0 is ad-hoc signed. Notarization is a separate release task. Routing does not wait on Developer ID, and the 1.0.0 DMG is not Gatekeeper-clean on other Macs.

## Lane key

A lane is one `HardwareVideoEncoder` plus the RTMP senders that share its access units.

Group by:

- width
- height
- frameRate
- codec (`H264` only in v1)
- profile (`usesHighProfile`, derived from height ≥ 720)
- keyframeIntervalSeconds

30 fps and 60 fps at the same size are two lanes.

Bitrate is not part of the key. Destinations that match the key share one encode. Inside that lane, `StreamEncoderConfig.clamped(to:)` still lowers target, ceiling, and keyframe to the strictest ingest in that lane only. YouTube and Twitch at 1080p30 stay one encode. A Phone cap must not lower the Stream lane, and Twitch’s cap must not lower the Phone lane.

Audio bitrate is not a video lane key. One AAC session for the show. Its bitrate is the minimum of the project audio bitrate and every live destination’s audio cap.

## Screen source on a slide

Three states. v1 routing implements the pixel paths for absent and present. Linked overrides are named so they are not invented later as a third encoder.

| State | Data | Pixels |
| --- | --- | --- |
| Absent | No board for the destination’s screen | Fit the Stream composite into the lane size. Badge: From Stream. |
| Linked | Reserved. Not stored in v1. | Same pixels as absent until an override composer exists. |
| Present | Operator added that canvas. It has its own objects. | Compose that board. This is what Add Canvas already stores. |

An added canvas with no objects is present. Compose its background. That is an authored frame. Only a missing board uses From Stream.

Fallback when the board is absent:

- Always Fit, even if the destination is set to Fill.
- Keep the same encoder session, resolution, frame rate, and audio.
- Cut with the slide. Do not hold the previous Phone frame. Do not send black. Do not create a board on the slide.

Fill on a present Phone canvas center-crops. Fit letterboxes.

## Encode size versus canvas size

The lane’s VideoToolbox size is the encode preset, not the canvas size, and it does not change mid-session.

- Stream lane uses the existing project `StreamEncoderConfig`.
- Phone lane uses a fixed vertical template: 1080×1920, 30 fps, 2 second keyframe, bitrate in the vertical social range. v1 has no second preset picker.
- Fit or Fill scales the screen texture into that encode size.
- Downscale is normal.
- Upscale is allowed and labeled on the destination (720p canvas into a 1080p preset). Do not refuse Go Live. Do not retarget the session to the canvas size.
- SPS, PPS, and `onMetaData` width and height belong to that lane. A Phone sender never receives Stream access units. Each lane has its own encoder and its own fan-out. `MultiRTMPTransport` stays inside one lane.

## Who owns the preset

The screen owns geometry and the default rate. The platform owns the clamp for destinations in that lane. The operator’s existing preset picker remains the Stream lane. Custom bitrate override stays on Stream in v1.

## Go Live

The program picture, program monitor, and local record stay on the Stream composite.

Encode lanes are separate from that composite.

- At least one Stream destination: start the Stream encoder as today.
- Phone destinations: start the Phone lane only while one is live.
- Phone-only: composite Stream for the desk and for recording. Do not open a Stream RTMP encoder. Recording reads the Stream composite, not the RTMP encoder’s sample callback.

## Preview and rundown

Program Live and Preview stay Stream.

v1 Phone preview is the destination-row thumbnail of the last Phone frame. It shows From Stream while the on-air slide is derived. The upcoming slide shows a soft “No Phone” flag when it has no Phone board. Take is allowed. No modal, no silent fit.

## Transitions

Stream keeps the current program transition.

A present Phone canvas hard-cuts on the take. No second transition engine.

From Stream is a scale of the Stream composite, so the vertical output shows that transition letterboxed.

## Lyrics

Fitted 16:9 text on 9:16 is acceptable in v1. Readable vertical lyrics mean the operator adds a Phone canvas. The badge and the rundown flag are the warning.

## Cost and failure

- Maximum two encode lanes in v1. A third size is refused with a message to share a size.
- Display-only outputs (audience, NDI, IMAG) do not open an encode lane.
- The Phone compose and Phone encoder never run on the program clock ahead of Stream. If the Phone lane is late, it repeats its last frame. Stream’s CFR hold path stays as it is.
- Arming a Phone destination before Go Live creates that session with Go Live, off the program clock. Toggling a new size on mid-show keeps sending From Stream or the last Phone frame until that session’s first keyframe. No black frame. Stream is not stalled on `VTCompressionSessionCreate`.
- One `MasterClock`. Phone video PTS comes from that clock at the Phone frame rate. No second `MediaClockAnchor`.
- One Phone sender dying marks that destination failed. Other lanes stay live. Reconnect is that lane only.

## Migration

New destination fields decode as Stream and Fit when missing. Old shows Go Live on one lane. Flag off preserves that path even if the fields are present.

## v1 tests

- Same size, different platforms: one encode, strictest clamp inside the lane.
- 30 fps and 60 fps at the same size: two lanes.
- Stream plus Phone: two encoders, one AAC.
- Missing Phone board: Fit From Stream, session unchanged, no hold, no blank.
- Present Phone board: composed, including an empty board.
- Phone-only: no Stream RTMP encoder, desk still shows Stream.
- Toggle a destination off: that lane tears down, the other stays.
- Congestion on one sender: non-keyframe video drops on that queue only.
- Clamp does not cross lanes.
- Flag off: today’s single encode.

## Implementation notes

Stream destinations share the project encode preset. A saved account resolution does not open a second lane. An explicit frame rate on a lane member does. That keeps old shows on one Stream encode.

A present Phone board is drawn by the program composer right after the Stream frame, in the same work item: same `renderNow`, same text context, same captured frames (one snapshot per source buffer, shared by both canvases). Board objects go through `resolvedCanvasObjects` (placeholders and image bindings) like the editor preview. Slide builds use `broadcastPlayback` computed from the Phone objects; props drawn on Phone get their own prop playback. Media slots on the board play the program media; the 16:9 media backdrop and video layer stay off the Phone frame. Live tiles are scaled on the GPU and static layers around them are cached per output size. The Phone encoder ticker repeats the latest composed Phone frame. An absent board letterboxes the Stream frame. Neither path runs on the program encoder queue.

One AAC pump. When Stream is live, Phone taps those access units. When only Phone is live, Phone is the pump.

## Out of this slice

Detach editor, linked overrides, a vertical preset picker, a second program monitor, per-lane transitions, and notarization.
