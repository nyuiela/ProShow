# Changelog

## 0.5.2 build 10 (2026-10-21)

- Previews show each well's own source, the same as the stream. The editor, slide thumbnails, the right pane (Preview, Live and Phone view) and the ProShow Phone window resolve every well's placeholder or device first. Before, one input per slide was painted into every well, so a camera window could show the screen share.
- Camera windows in previews show the live camera. Camera frames arrive as YUV and are converted to BGRA for preview views only. Before, they showed black in the editor, the Phone board and the idle Encoded program window.
- Stream and Phone output, audio and the mixer are unchanged.

## 0.5.2 build 9 (2026-10-21)

- Settings > About ("Installed") shows the running app's version and build, read from the bundle at launch, for example "ProShow 0.5.2 (9)". Before, it showed the project file format version (1.0.0).
- GET /v1/status and the remote telemetry include app_version and app_build. The OpenAPI document carries x-proshow-app-version next to the Control API version.

## 0.5.2 build 8 (2026-10-21)

- Props play their enter and exit builds on Stream and Phone, the same as in the editor. Before, they switched on and off at once on both outputs.
- Prop exits run for the authored build-out time, whether the prop is toggled off or clears on its own timer.
- Prop images fade with the build, not only prop text.
- On Phone, grouped prop elements (the chat card's avatar, name and message) are fitted together, so the avatar no longer covers the first letter of the name.

## 0.5.1 build 5 (2026-10-21)

- Stream (16:9) and Phone (9:16) go out together with the Phone canvas drawn by the same program renderer: cameras, screen share, video and media slots, images, text fields, timers, props with their own Phone layout (including the chat template) and enter/exit builds. Placeholders resolve the same way as in the editor preview.
- Both canvases use the same frame clock and the same captured camera and screen frames. Nothing is captured twice.
- Camera and screen tiles are scaled on the GPU. Design images are scaled once per output size instead of every frame.
- The Phone output follows every slide take. Before, it stayed on the slide that was live when the stream started. Clearing the slide clears the Phone too.
- A missing Phone canvas still sends the Stream picture fitted into 9:16.

## 0.5.0 build 4 (2026-10-21)

- Chat connects from the live broadcast when a stream starts (YouTube and X), with an Auto-connect chat toggle and a refresh in the chat More menu. Link paste stays as a fallback.
- The reply box no longer asks for YouTube chat when X or no chat is in use.

## 0.5.0 (2026-10-21)

Versioning restarts at 0.5.0 and counts up toward v1. The older `v1.0` / `v1.0.0` tags stay as they are. Build numbers keep increasing (this is build 3), so macOS keeps the camera, microphone and screen recording grants.

- Camera and screen share stay live together on one slide, with no stop/start loop.
- Screen share updates at the show frame rate while the camera is live.
