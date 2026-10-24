# Changelog

## 0.5.5 build 14 (2026-10-24)

- Recording now also writes a 9:16 file beside the 16:9 file, named `<name>_Phone.mov`, while a Phone destination is live or the project has a Phone canvas. The Record menu and the record button show "Recording 16:9 + 9:16".
- While live, the 9:16 file starts on the same frame as the 16:9 file and carries the same AAC audio packets, so the two files line up sample for sample. Before this fix in testing, the 9:16 file could start up to one keyframe interval (about 0.4 s) early.
- Record-only (not live), the 9:16 file gets its own encode of the same program audio.
- The 9:16 file keeps going when the Phone stream drops, when the stream stops, and when Phone is removed or added by restarting the stream. Adding the Phone destination mid-recording opens the 9:16 file then.
- Closing the 9:16 file never waits on the main thread, and takes do not force a keyframe in it.
- Known, unchanged from 0.5.4: in a record-only 16:9 file the video runs at about 19 fps and slide changes land 1 to 2 s late, and after the stream stops mid-recording the 16:9 file has gaps of about 2 s every few seconds. The 9:16 file is not affected.
- Stream and Phone audio, the mixer and the AAC encoder are unchanged.

## 0.5.4 build 13 (2026-10-22)

- Takes no longer stall the app. After a program cut, Next or a slide take the main thread was busy for 0.6 to 1 s, so the stream held the old or a half-drawn slide and the slide completed late. Now the longest main-thread wait after a take is under 90 ms and the new slide starts on the stream within about 40 ms.
- Cause: every take rescanned cameras and rewrote the camera list and the main layer even when nothing changed, and each write redrew every live slide thumbnail and the on-air layer list. Those writes now happen only when something changed, warm thumbnails skip the scan, and the slide grid cells read their own selected and live state.
- The Active on-air layer list builds its rows once per redraw and only for visible rows. Before, it rebuilt the whole list for every row and reloaded layer thumbnails from disk.
- Because takes no longer stall, the program transition (0.5 s) now plays on the stream at every cut. Before, the stall swallowed it.
- The stream holds the last good camera picture of a source for up to 1.5 s while a new slide's camera window waits for its first frame, instead of showing the window's fill.
- Debug builds no longer copy themselves into /Applications. Pinning a Debug build now needs PROSHOW_PIN_DEBUG_APP=1, moves the old app to the Trash, and never replaces a signed Release app.
- Stream and Phone audio and the mixer are unchanged.

## 0.5.3 build 12 (2026-10-22)

- Program Auto: one Auto button in the program transport (workspace and float window), remembered on this Mac. With Auto on, the program cuts to the next item when its time runs out. If the prompter is still reading, the cut waits for the read to finish plus 0.75 s, and never more than 12 s past the item's time. Items with no script cut on time.
- Auto stops instead of cutting on: the first item when it is a waiting slate (Starting soon, Pre-show, Countdown), STANDBY or BRB items, an Outro, and the last item. Auto skips over STANDBY and BRB items. A per-item Stop here flag in the .program overrides this.
- Hold freezes the item clock and Auto; press Hold again or Space to resume. +30s adds 30 seconds to the live item. Next still cuts at once.
- The live row in the workspace and float window, and the stage display, count down the live item: 0:12, then +0:05 past the end, and HOLD while held.
- The prompter loads the next item's script on every program cut, from the workspace, the float window and the remote, and keeps rolling if it was rolling or Auto is on, in kinetic and scroll modes.
- Prompter pacing fits each item's script to its planned time (120 to 240 wpm) by default. Items can use the prompter's own speed instead.
- Kinetic prompter word timing no longer drifts: a read ends when its pacing says it will. Before, each word ran slightly long, about a second over a typical item.
- Stage cues use seconds before the end whatever their sign (older files stored -60) and fire once per item when the countdown crosses them, through holds, +30s and stalls. New programs default to 60, 30 and 0.
- A cut no longer rewrites the whole .program file when nothing in it changed. That save took about 85 ms per cut on the main thread.
- The next item's slide images are decoded ahead of its cut and released if it is skipped. Media and cameras are not preloaded.
- Remote: program next, previous, hold, extend, auto and status over REST (/v1/program/...), OSC (/proshow/program/...) and MIDI notes 62 to 65. slide/next is unchanged.
- Stream and Phone audio and the mixer are unchanged.

## 0.5.2 build 11 (2026-10-22)

- Camera rows in a .program keep the stream background they were designed with. Before, every reopen set the row's background off, so the stream dropped the full-frame background image and colour and showed the camera through the slide, while the editor and Phone canvas still looked right.
- Reopening a .program restores the background on rows an earlier reopen switched off and saves the repaired file.
- The .program show always goes on air from the repaired program file. Before, the project could open with an older saved copy of that show as the active show and send it to the stream.
- Stream and Phone audio and the mixer are unchanged.

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
