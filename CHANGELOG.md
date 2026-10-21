# Changelog

## 0.5.1 build 5 (2026-10-21)

- Stream (16:9) and Phone (9:16) go out together with the Phone canvas drawn by the same program renderer: cameras, screen share, video and media slots, images, text fields, timers, props with their own Phone layout (including the chat template) and enter/exit builds. Placeholders resolve the same way as in the editor preview.
- Both canvases use the same frame clock and the same captured camera and screen frames. Nothing is captured twice.
- Camera and screen tiles are scaled on the GPU. Design images are scaled once per output size instead of every frame.
- A missing Phone canvas still sends the Stream picture fitted into 9:16.

## 0.5.0 build 4 (2026-10-21)

- Chat connects from the live broadcast when a stream starts (YouTube and X), with an Auto-connect chat toggle and a refresh in the chat More menu. Link paste stays as a fallback.
- The reply box no longer asks for YouTube chat when X or no chat is in use.

## 0.5.0 (2026-10-21)

Versioning restarts at 0.5.0 and counts up toward v1. The older `v1.0` / `v1.0.0` tags stay as they are. Build numbers keep increasing (this is build 3), so macOS keeps the camera, microphone and screen recording grants.

- Camera and screen share stay live together on one slide, with no stop/start loop.
- Screen share updates at the show frame rate while the camera is live.
