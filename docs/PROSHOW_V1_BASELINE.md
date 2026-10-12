# ProShow v1.0 baseline (Phase 0)

Date: 2026-10-12. No app source changes. Package sizes were added to `docs/PROSHOW_V1_RESOURCE_AUDIT.md`.

Host: Apple M4 Max, 16 cores, 48 GB RAM (`hw.memsize` 51539607552). This is not a 4 GB laptop. Swap was 0 bytes used (`vm.swapusage`). System compressor was already in use by other processes (about 522303 pages). Do not treat these numbers as a 4 GB result.

Build: `xcodebuild -scheme ProShow -configuration Release -destination platform=macOS -derivedDataPath build/DerivedData/ProShowRelease build`. Exit 0. About 284 s.

Product: `build/DerivedData/ProShowRelease/Build/Products/Release/ProShow.app`. Bundle 168 MB. Main binary 135 MB universal. arm64 slice 70,814,432 bytes. Linked frameworks in the bundle: `LiveKitWebRTC.framework` 29 MB, `RustLiveKitUniFFI.framework` 2.3 MB.

The Release binary would not start. dyld rejected `LiveKitWebRTC` because the process and the framework had different Team IDs (hardened runtime). `codesign --force --deep --sign -` on the built app made it launch. That re-sign is not a source change. It dropped the original entitlements.

## What was measured

The desk was started with `launchctl bootstrap` and `WorkingDirectory` set to the repo. `open` of the same app hung and is not the idle row.

A saved show was open (`show_id` from `GET /v1/status`). `is_streaming` was false. `is_recording` was false. `audience_on` and `stage_on` were true. The program clock was already running: a 1 s sample sat in `ShowController.tickProgram` on the main thread.


| Scenario                                        | RSS                         | Peak footprint          | CPU                                        | GPU           | Threads                | Disk writes / min | CVPixelBuffer | Status   |
| ----------------------------------------------- | --------------------------- | ----------------------- | ------------------------------------------ | ------------- | ---------------------- | ----------------- | ------------- | -------- |
| Idle desk, about 18 s after a successful launch | 249 MB (`ps` rss 254720 KB) | 229 MB                  | 28% of one core (`ps` over the first 18 s) | not a percent | 34                     | not measured      | not measured  | Measured |
| Same process at 2 min                           | 314 MB (rss 321696 KB)      | 544 MB                  | 34% of one core, lifetime                  | not a percent | 33                     | not measured      | not measured  | Measured |
| Same process at 6 min 38 s                      | 302 MB (rss 309264 KB)      | 544 MB (unchanged peak) | 25.5% of one core, lifetime                | see note      | 33 at the 2 min sample | not measured      | not measured  | Measured |
| Edit a 50 slide show for 2 min                  | not measured                | not measured            | not measured                               | not measured  | not measured           | not measured      | not measured  | Not run  |
| Live Stream 1080p30, 30 min                     | not measured                | not measured            | not measured                               | not measured  | not measured           | not measured      | not measured  | Not run  |
| Stream plus guest return, 5 min                 | not measured                | not measured            | not measured                               | not measured  | not measured           | not measured      | not measured  | Not run  |
| Open and close 5 projects, then `leaks`         | not measured                | not measured            | not measured                               | not measured  | not measured           | not measured      | not measured  | Not run  |


Idle physical footprint (`footprint` / `vmmap`) was 159 MB at 18 s and 207 MB at 2 min. `footprint` also printed 274 MB at 2 min. IOSurface resident went from 31.6 MB (11 regions) to 38.4 MB (16 regions).

CPU is `ps` `%cpu`, which is one core = 100%. 28% of one core is about 1.8% of this 16 core machine. The v1.0 gate says under 50%. On this host the idle desk is under that if 50% means half the machine. It is not under 50% of one core. A 4 GB dual core laptop was not tested.

GPU percent was not produced. Metal System Trace (`/tmp/proshow-metal-idle.trace`, 8.9 s, template counter set null) exported 29550 `metal-gpu-execution-points`. That is activity, not a utilization percent.

Allocations did not finish. `xctrace record --template Allocations --time-limit 12s` stayed on "Starting recording" for over 3 minutes and was killed. `CVPixelBuffer` live count is not measured.

Disk writes per minute are not measured. `ps` inblk and oublk were blank. `fs_usage` needs root.

## Why the other rows were not run

1. `open ProShow.app` set cwd to `/`. The main thread blocked in `open` inside `LiveKitDeskConfig.parse` (`LiveKitDeskConfig.swift` line 57, called from `ShowController.bootstrapBackstageServices`). A 1 s sample an minute later was still in `__open`. Footprint of that wedged process was 12 MB and 3 threads. That is not a desk. The measured row used a launchd job whose working directory is the repo, so the first candidate path was not `/showroom/.env`.
2. MediaMTX is not installed. `POST /v1/stream/start` calls `streaming.start` for armed platform accounts (`ShowController.handleControl`). That can open a real YouTube or similar ingest. It was not called. There is no request in this pass that points the encoder at `127.0.0.1`.
3. System Events AppleScript did not return (Accessibility prompt or hang). Slides were not edited by hand.
4. Guest return needs a LiveKit room with a subscriber. Not started.
5. Five project open and close cycles were not driven, so `leaks` was not run.



## F17: which clock sends while live

Not logged once per second. No live encode was started, so `log stream` had nothing to count.

From the start path in source, both sides are armed, and they do not do the same job:

- Video clock that encodes is v2. `StreamingEngine.markLive` calls `StreamEngineV2Session.start`. `ProShowFeatureFlags.streamEngineV2Enabled` is hardcoded `true`. `OutputTicker` calls `HardwareVideoEncoder.encodeOnMasterClock`. Access units go to `PacketInterleaver`, then `transport.send`. The earlier `onEncoded` that sent straight to the socket is replaced, except sequence headers still call the original sender.
- Audio pump that sends AAC is the legacy one. `StreamingEngine.start` sets `RTMPStreamTransport.suppressAudioPump = false`. `connect` then calls `startAudioPump`, which timers `ProgramAACEncoder.nextTimedAccessUnit` and `sendAudioFrame`. v2 `AudioMixer.mixOnce` has no caller. `StreamEngineV2Session.start` sets `mixer.onBlock` and then sets `audioTimer` to nil. v2 audio block count should stay 0 while the legacy pump still fires.

So a live RTMP session runs one video clock (v2) and one audio pump (legacy). The v2 mixer is constructed and does not mix. This is not yet confirmed with a 1 Hz log from a live socket.

## Launch notes for the next profile

- Re-sign the Release app before `open`, or dyld will not load WebRTC.
- Do not `open` the app if cwd is `/` until `LiveKitDeskConfig` stops calling `String(contentsOf:)` on `cwd/showroom/.env` from the main thread. That call blocked this pass.
- `com.proshow.baseline` was booted out after the samples. ProShow is not left running.



## Pixel buffer count (still missing)

Tried again after the idle table. `CVPixelBuffer` live count is still not measured. Allocations was not started, because the desk never reached a window.

`open` of the Release app (pid 95248) sat at about 50 MB RSS and 0% CPU. `sample 95248 3` put every main-thread sample in `__open`, inside `LiveKitDeskConfig.parse` (`LiveKitDeskConfig.swift` line 57), called from `bootstrapBackstageServices` before `NSApplication` runs. The leaf is the kernel open, not a TCC or Gatekeeper frame. No window existed, so a permission prompt would have nothing to attach to. The file that call is opening, after two missing paths, is `~/Documents/projects/startups/foundry/showroom/.env`.

A later launch (pid 95633, working directory `/tmp`) also never opened port 55076. `sample` then stopped returning a file, which fits a Developer Tools prompt for the terminal that nobody answered. `lldb -p` hung the same way. UserNotificationCenter is running, but its window title could not be read, and screen capture was denied (`could not create image from display`).

The 60 second Allocations command was not run. There was no live PID with the desk on screen to attach to. Do not let `xctrace` launch the app. The temporary 1 Hz buffer counter stays for after Phase 3, as planned.

## Next phase

Phase 1 (image cache, page cache, one FFT setup) is in the source tree. The 30 minute soak was skipped. The matched 0/10/20/30 footprint series was not recorded.

Matched Phase 1 check, same steps both times: open `stellar-stream` (show `C0FFEE00-0000-4000-8000-0000000000B1`), wait 8 seconds, start a local recording, sample at 18 seconds. No live stream.

| | Before Phase 1 | After Phase 1 |
| --- | --- | --- |
| phys_footprint | 1027 MB (peak 1096 MB) | 915 MB (peak 983 MB) |
| RSS | 667 MB | 500 MB |
| IOSurface resident | 135.1 MB, 188 regions | 118.4 MB, 234 regions |

Phase 2 on the same project, local recording, this 48 GB Mac (4K stays available, capture follows the show size). At the start of the recording `phys_footprint` was 659 MB (peak 745 MB) and IOSurface was 88 regions, 60.5 MB resident. At 3 minutes footprint was 521 MB, peak still 745 MB, RSS 409 MB, CPU 1.6 percent of one core. IOSurface was 76 regions, 68.4 MB resident.

V2 check, same project, publish to `rtmp://127.0.0.1:1935/live/proshow-local` (ffmpeg listen, not a platform ingest). `is_streaming` stayed true for the 3 minutes. At the start `phys_footprint` was 511 MB (peak 542 MB), IOSurface 75 regions, 75.3 MB resident. At 3 minutes footprint was 575 MB (peak 826 MB), RSS 1.88 GB, CPU 0.8 percent of one core, IOSurface 184 regions, 97.2 MB resident. That build was before the frame pool. RSS is not used for the 4 GB call.

Phase 3 pool, same local RTMP publish, with a once per second log of send queue depth and encoder frames waiting. ffmpeg `-progress` counted frames. At the start `phys_footprint` was 598 MB (peak 601 MB), IOSurface 74 regions, 154.4 MB resident, and ffmpeg had 63 frames. At 3 minutes footprint was 599 MB (peak 602 MB), IOSurface 70 regions, 152.1 MB resident, ffmpeg frame 5477. At 6 minutes footprint was 600 MB (peak 606 MB), IOSurface still 70 regions and 152.1 MB resident, ffmpeg frame 10891. That is about 30 frames per second for the whole run. Send pending and unacked stayed 0. Encoder session backlog stayed 0 or 1. Frames held inside VideoToolbox stayed 0 or 1. Footprint and IOSurface leveled off, so the earlier climb was warm-up on the pre-pool build. CPU at the 6 minute sample was 1.6 percent of one core while frames were still arriving.

Phase 4 guest check, same local RTMP publish, with one guest subscribed to the program return. The desk reported guest return on and 1 guest in the room for the whole sample. At the start `phys_footprint` was 317 MB (peak 474 MB), IOSurface 48 regions, 98.0 MB resident. ffmpeg had 95 frames and the guest had 26. At 3 minutes footprint was 393 MB (peak 671 MB), IOSurface 73 regions, 106.4 MB resident. ffmpeg had 5067 frames, about 30 per second. The guest count climbed steadily, about 15 frames per second (26, then 427, 871, 1320, 1770, 2218 at each 30 second mark). Send queue depth stayed 0. The pool refused zero buffers that RTMP or the hold-frame cache still held, including while slides 0, 1, and 2 were triggered in a tight loop. Frames grabbed during that loop were a flat field with no torn edge. Index 3 is not in this show, so those triggers failed.

Phase 5 caps: an RTMP destination keeps at most 30 queued audio tags. The control API accepts at most 8 connections. A Mac with 8 GB or less, with no saved encoder preset, starts at 720p30 and 2500 kbps.

## Launch hang fix and recording pixel buffers

The launch stall was `LiveKitDeskConfig` reading `~/Documents/projects/startups/foundry/showroom/.env` from `bootstrapBackstageServices` before any window. That path is gone.

`LiveKitDeskConfig.load()` runs only when a guest action starts (`BackstageControlPanelView` on appear, or New room). Release builds read `~/Library/Application Support/ProShow/livekit.json` for the URL and token endpoint, and the API key and secret from the keychain (`livekit.apiKey`, `livekit.apiSecret`). Debug builds may still use `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, and `LIVEKIT_TOKEN_ENDPOINT`. If those are missing, status is `Guests off` and the desk still starts. No Documents or Desktop read happens at launch.

`open` of the re-signed Release app (pid 3282) reached `GET /v1/health` in under 20 seconds. A 1 second sample put the main thread in `NSApplication` run loop, not `__open`. RSS was about 160 MB before recording.

`POST /v1/stream/start` was not called. Armed accounts point at platform ingest hosts. `POST /v1/record/start` wrote a local `.mov` under `~/Movies/stream/` so the composite and file writer were running.

The first Allocations attach failed: `Failed to attach to target process`. The ad-hoc signature had dropped entitlements. Signing again with the app entitlements plus `com.apple.security.get-task-allow` (profiling only, not a source change) let the next attach succeed. Trace: `~/proshow-traces/alloc-live.trace`, pid 3623, 60 seconds, exit 0. `xctrace export --toc` lists signpost and kdebug tables only. It does not list an object-allocation table, and the trace bytes do not contain the string `CVPixelBuffer`. The live count below is from `heap -s`, not from that export.

During that recording, `heap -s` on pid 3623:

| Type | Live count | Bytes |
| --- | --- | --- |
| `CVPixelBuffer` | 21 | 3360 |
| `CVPixelBufferBacking` | 49 | 62720 |
| `CVPixelBufferPool` | 7 | 1792 |
| `IOSurface` | 209 | 3344 |

A second `heap -s` about 20 seconds later returned the same four counts. That is flat across those two snapshots. It is not a 30 minute stream, and it is a local recording, not an RTMP ingest. `heap` then left the process unable to answer port 55076 (0% CPU, health timed out). That process was stopped after the samples.

## Soak skipped, leaks, and Phase 1

The 30 minute series was stopped on request. One local recording of `stellar-stream` had already been started. At that moment `footprint` reported `phys_footprint` 596 MB (peak 1324 MB). `vmmap --summary` reported 201 IOSurface regions, 218.8 MB resident. RSS was about 3.1 GB. Those are not 0/10/20/30 minute points.

F17 for that recording: `is_streaming` was false, so the file writer path ran. `sink.program.recorder` calls `IsoRecorder.appendProgramFrame`, which appends the pixel buffer to `AVAssetWriter`. `StreamEngineV2` starts only from `StreamingEngine.markLive` after a stream transport connects. This recording did not use V2.

Five projects were opened and closed through `POST /v1/project/open` and `POST /v1/project/close` (stellar-stream, SecondTrial, FirstTrial1, and two copies). `leaks` on pid 5115 reported 589 leaks, 240 KB total. The largest root was `CMSimpleQueue` (287 leaks, 204 KB). The control port still answered after `leaks`.

The same five-project cycle after the close-path fix (pid 8210) reported 1 leak, 80 bytes, and 0 `CMSimpleQueue`. The allocation stack for that string is `AVCaptureHALDevice` device-list setup (`setUpMicrophoneModeStateOnce`), reached from `prepareSlidePreviewCapture` the first time a project discovers cameras. It is one process-lifetime CoreAudio preference key, not a sample-buffer queue. A project that never discovers cameras (FirstTrial1 alone) reports 0 leaks.

Phase 1, before the short remeasure:

| Item | Before |
| --- | --- |
| Image cache ceiling | 2 GB (`AssetCacheManager` default) |
| Page prefetch | every remaining rundown URL, 48 cached frames |
| FFT setup | `vDSP_create_fftsetup` and `vDSP_destroy_fftsetup` inside every `fftMagnitudes` call |

Phase 1 after:

| Item | After |
| --- | --- |
| Image cache ceiling | 128 MB. Poster and bin stills decode with `CGImageSourceCreateThumbnailAtIndex`, long side at most 512 px. Program fills still decode full size. |
| Page prefetch | the next URL only. `frameCache` drops oldest frames once the byte total exceeds 64 MB. |
| FFT setup | one `FFTSetup` for size 512, kept for the process |

A fresh Release launch, same project, about 18 seconds into a local recording: `phys_footprint` 1019 MB (peak 1067 MB), RSS 751 MB, IOSurface 243 regions and 171.5 MB resident. That is a different slide and a cold process, so it is not a before/after of the same session. `get-task-allow` was removed from the Release signature after that sample. The source entitlements file never had it.