# ProShow v1.0 resource audit

Date: 2026-10-12. Host used for this pass: Apple M4 Max, 16 cores, 48 GB RAM (`sysctl hw.memsize` = 51539607552). ProShow was not running. No Instruments, `leaks`, `heap`, `vmmap`, or `footprint` sample of the app. No 30 minute encode. No 4 GB memory limit. Those rows are not measured.

## 1. Summary

v1.0 cannot be called safe on a 4 GB laptop today. The design can stay under 1.2 GB if caches stay cold and only one encode runs. The ceilings and the per frame copies do not enforce that.

Top problems:

1. `AssetCacheManager` allows a 2 GB image cache. That alone blows a 4 GB machine.
2. `ProgramOutputComposer` draws the program with `CGContext` into a new `CVPixelBuffer` every frame, then `snapshot` memcpy's another full frame.
3. A live show with guests and a Stream encode runs two encoders: VideoToolbox at the stream size (default 1080p30, 6000 kbps) and LiveKit at 720p24, each after another full frame copy.
4. `ProgramPageRaster` can hold 48 full page frames and will queue every remaining rundown URL into WebKit.
5. `ShowController` is one `@MainActor` `@Observable` object. The program timer hops to the main actor at the stream frame rate and mutates it.

Source size measured: 312 Swift files, 102999 lines. `ShowController.swift` is 7667 lines. Its extensions add 2973 lines. `ProgramOutputComposer.swift` is 2026 lines. `VideoIngestEngine.swift` is 1813 lines. `RTMPStreamTransport.swift` is 1927 lines.

## 2. Measured baseline

| Scenario | Resident memory | Peak memory | CPU % | GPU % | Threads | Disk writes / min | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Idle desk | not measured | not measured | not measured | not measured | not measured | not measured | App was not running. `footprint` not taken. |
| Edit 50 slides | not measured | not measured | not measured | not measured | not measured | not measured | No session. Undo cap is 40 snapshots in code. |
| Live Stream 1080p30, 30 min | not measured | not measured | not measured | not measured | not measured | not measured | No encode was started. |
| Stream plus Phone lane | not measured | not measured | not measured | not measured | not measured | not measured | Phone lane starts only when multi destination routing is on and a phone lane exists. |
| 4K background | not measured | not measured | not measured | not measured | not measured | not measured | Capture preset is `.high` in `VideoIngestEngine`. Output width field defaults to 1920. |
| Open and close 5 projects | not measured | not measured | not measured | not measured | not measured | not measured | No session. |
| One 1080p BGRA frame | 8294400 bytes | same | n/a | n/a | n/a | n/a | Estimated from 1920 x 1080 x 4. |
| 48 cached 1080p page frames | about 380 MB | about 380 MB | n/a | n/a | n/a | n/a | Estimated from `maxCachedFrames = 48` times one 1080p BGRA frame. |
| Image cache ceiling | 2 GB | 2 GB | n/a | n/a | n/a | n/a | Code limit, not a live sample. |
| Archive app bundle | 30 MB product, 187 MB xcarchive | n/a | n/a | n/a | n/a | n/a | Measured `du` on `build/ProShow.xcarchive`. Debug `ProShow.app` product was empty (0 B). |
| LiveKitWebRTC macOS binary | 29 MB file | n/a | n/a | n/a | n/a | n/a | Measured. Universal slice, not RSS. |

## 3. Findings

| ID | Area | File and type | Problem | Evidence | Impact | Severity | Effort | Suggested fix |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| F1 | Memory | `AssetCacheManager` in `ProShow/Services/AssetCacheManager.swift` | Default cache ceiling is 2 GB and 500 objects. | `init(totalCostLimit: Int = 2 * 1024 * 1024 * 1024, countLimit: Int = 500)`. `ResolvedCanvasMedia.imageCost` charges `width * height * 4`. `NSImage(contentsOfFile:)` stores the full decode. Pressure handler calls `removeAll` only on warning or critical. | RAM | Blocker | S | Cap at 128 MB. Decode a thumbnail with `CGImageSourceCreateThumbnailAtIndex`. |
| F2 | Video | `ProgramOutputComposer` | Every composite allocates a new BGRA buffer. `snapshot` memcpy's the whole frame on the CPU. | `ZeroCopyMetalPipeline.makeCompatiblePixelBuffer` calls `CVPixelBufferCreate` with no pool. `snapshot` locks both buffers and `copyMemory` per row (`ProgramOutputComposer.swift` lines 72 to 113). `drawVideoLayersOnly` builds a `CGContext` on that buffer (line 389). | CPU, RAM | Blocker | M | One `CVPixelBufferPool` of 3 buffers at the encode size. Composite on the GPU. Drop the extra memcpy when the pool buffer is already owned. |
| F3 | Video | `ShowController` plus `LiveKitDeskSession` | Stream encode and guest return each copy the frame again, then encode it again. | `rememberLastPublishedStreamFrame` calls `snapshot` again (line 2932). `LiveKitDeskSession.fit720` allocates 1280x720 and copies (`opaque720`, `fit720`). Publish uses `BufferCaptureOptions(dimensions: .h720_169, fps: 24)`. Stream default is `DisplayResolution.res1080p`, 6000 kbps, 30 fps (`SettingsModels`). `liveKitGuestReturnActive` keeps the program clock running. | CPU, GPU, RAM | Blocker | L | One scaled frame in the pool. Feed VideoToolbox and LiveKit from that buffer. Do not publish the guest return unless a guest is subscribed. |
| F4 | Media | `ProgramPageRaster` in `LayeredAudienceView.swift` | Prefetch walks every upcoming browser URL. Cache holds 48 `CVPixelBuffer`s. Two `WKWebView`s plus two offscreen `NSWindow`s stay up. | `maxCachedFrames = 48` (line 1466). `prefetchUpcomingRundownBrowserPages` appends every remaining page URL. `prefetch` queues them. One 1080p frame is about 8 MB, so 48 frames are about 380 MB. Not measured live. | RAM, CPU | High | S | Prefetch the next page only. Cap cache by bytes (64 MB), not by 48 slots. |
| F5 | App structure | `ShowController` | God object on the main actor. The program `Timer` schedules `Task { @MainActor in handleProgramClockTick() }` at 30 Hz, or at the stream fps while live. | Class starts line 102. File is 7667 lines. `programClockInterval` returns `1.0 / 30.0` unless offscreen composite is required, then the stream fps. `tickProgram` updates inspector, quotes, audio, compositor, and `programFrame`. | CPU | High | L | Move the clock off the main actor. Keep `@Observable` state for UI at 4 to 10 Hz. |
| F6 | Audio | `AudioDSP` called from `ShowAudioController` | FFT setup is created and destroyed on every spectrum update. | `vDSP_create_fftsetup` and `vDSP_destroy_fftsetup` inside `fftMagnitudes` (`AudioDSP.swift` lines 53 to 56). `ShowAudioController.tick` runs from `tickProgram`. | CPU | High | S | Keep one `FFTSetup` for size 512. Skip the FFT when the mixer and spectrum views are closed. |
| F7 | UI | SwiftUI `TimelineView` sites | Several views animate even when nothing on screen needs 30 or 60 fps. | `MarqueeTextLoopView` uses `1.0 / 60.0` with `paused: false`. `CanvasElementShimmer` uses 30 fps, `paused: false`. `PhoneCanvasMonitorView` uses 20 fps, `paused: false`. `MediaBinView` uses 0.08 s, `paused: false`. `PlayheadTimecodeView` uses 30 fps. | CPU, GPU | High | S | Pause when the view is off screen, the show is idle, or Reduce Motion is on. Meters at 15 fps are enough. |
| F8 | Video | `VideoIngestEngine` | Capture uses `AVCaptureSession.Preset.high`, which can be above 1080p on some cameras. Each live object is then `snapshot`'d at that size. | `session.sessionPreset = .high` near line 1092. `outputWidth = 1920` does not force the session preset. `ShowController` calls `ProgramOutputComposer.snapshot` on object pixels (around lines 2763 and 3076). | RAM, CPU | High | M | Set the session preset to 1080p (or 720p on a 4 GB machine) before `startRunning`. |
| F9 | Concurrency | `ShowController.ensureProgramClockRunning` | A main run loop `Timer` plus an unstructured `Task` per tick. Tasks are not cancelled when the clock stops. | Lines 2300 to 2306. `suspendProgramClock` only invalidates the timer. | CPU | Medium | S | Call the tick from the timer closure on the main actor directly, or use one long lived clock task. |
| F10 | Streaming | `RTMPEndpointQueue` | Pending cap is 120 tags. Audio and keyframes are kept, so a stuck socket can hold a long audio run. | `maxPending` default 120. `maxInFlight` is 8. One queue per endpoint. Drop path removes non keyframe video first. | RAM, network | Medium | S | Cap audio tags (for example 30) as well as video. |
| F11 | Memory | `EditorEngine` | Undo stores up to 40 full copies of `documents`. | `undoStack.append(snapshot())` and `if undoStack.count > 40`. `snapshot()` copies `documents`. | RAM | Medium | M | Snapshot the edited slide only. Lower the cap while a large program is open. |
| F12 | Disk | `AutoSaveEngine` in `ProjectStore.swift` | Default flush delay in the type is 0.5 s. User setting default is 2 s. Each flush writes the show and the studio manifest. | `delayNanoseconds` default `500_000_000`. `DeviceSettings.walFlushSeconds` default 2. `commitToDisk` writes the bundle. | Disk | Medium | S | Keep the 2 s user default. Do not call `commitNow` from frame paths. |
| F13 | Documents | `ProgramDocumentStore` | The whole `program.json` is read into `Data` then decoded. | `Data(contentsOf:)` in `load(from:)`. | RAM, disk | Low | M | Fine for a rundown JSON. Do not do this for media bytes. |
| F14 | Audio | `ProgramPCMBridge` and `ProgramMixInjector` | Rings are capped. This part is fine. | Guest ring cap `48_000 / 4` samples. Mix lane ceiling `48_000 * 2 * 120 / 1000` samples. LiveKit pending cap `48_000 * 2` (about 1 s of stereo). | RAM | Low | S | Leave the caps. Do not raise them. |
| F15 | UI | Materials | Almost no Liquid Glass. | `ultraThinMaterial` appears in `DeskGlass.swift` and `RundownTeleprompterView.swift` only (2 files). | GPU | Low | S | Leave it. Do not add full window blurs. |
| F16 | Dependencies | SwiftPM | AudioKit, AudioKitUI, Controls, and LiveKit are linked. Source checkouts are large. The WebRTC binary is in the app's runtime. | Checkout `du`: AudioKit 230 MB, Controls 151 MB, client-sdk-swift 26 MB, AudioKitUI 16 MB. `LiveKitWebRTC` macOS binary 29 MB. `import AudioKit` in `AudioIOEngine`, `AudioMixerView`, `FairlightChannelStrip`. `import AudioKitUI` in `FFTSpectrumView`. | Disk, RAM | Medium | M | Keep LiveKit. Confirm AudioKit is only the engine you use. Do not ship AudioKitUI if the spectrum view can use `Canvas`. |
| F17 | Dead code | `ProShowFeatureFlags` | `streamEngineV2Enabled` is hardcoded `true`. Comment still says legacy clocks stay until the flag is on. `RTMPStreamTransport.swift` is still 1927 lines and the audio pump is still called from `tickProgram`. | `StreamEngineV2.swift` lines 10 to 16. `publishProgramMediaAudioPuller` and `ProgramPCMBridge` from `tickProgram`. | CPU, RAM | Medium | L | Delete the unused clock after one profile shows v2 is the only sender. |
| F18 | Servers | `ControlAPIServer` | Loopback `NWListener` on port 55076. No connection cap. | `defaultPort` 55076. `newConnectionHandler` calls `accept` with no limit. | RAM, network | Low | S | Cap concurrent connections (for example 8). This is the desk, not a VPS. |
| F19 | Streaming | `HardwareVideoEncoder` | Settings are reasonable for a laptop: real time, no B frame reorder, H264 High or Main. | `kVTCompressionPropertyKey_RealTime` true. `AllowFrameReordering` false. Bitrate from `targetBitrateBps`. | CPU, GPU | Low | S | On a 4 GB machine default the preset to 720p30 and 2500 kbps. |
| F20 | Startup | `AppSession` | `ShowController.bootstrap()` runs in `init` before the desk is shown, including an empty studio install. | `ProjectStore.swift` `AppSession.init` assigns `ShowController.bootstrap()`. | RAM, CPU | Medium | M | Build the controller when a project opens, not at process start. |

`SlideCacheManager` is fine: image cache 50 MB and 100 items, texture cache 100 MB and 30 items.

`UnifiedCacheRegistry` is fine: 100 MB and 150 items.

`ProShowQueues` is fine: a fixed set of serial queues, `maxBuffersInFlight = 3`. Not one queue per object, except `RTMPEndpointQueue` which is one queue per destination.

Logging uses `Logger` (`StreamEngineV2`, `StreamAudioPipelineDiagnostics`). Telemetry log is about 1 Hz while live. No unbounded log file was found in the app. Not measured on disk.

No Docker image, ffmpeg process, or packager lives in this repo.

## 4. Architecture problems

**One main actor owns the show.** `ShowController` holds the compositor, stream session, editor, video inputs, audio matrix, ISO recorder, backstage, and LiveKit. The frame clock calls back onto that actor. Small cache fixes will not stop main thread hitches while this stays true. Better: a render graph on `programCompositeQueue` that publishes a small UI model a few times a second.

**The program picture is a CPU bitmap.** `ProgramOutputComposer` matches the audience view by redrawing with Core Graphics. `ZeroCopyMetalPipeline` still allocates with `CVPixelBufferCreate`. Better: a pool of IOSurface buffers at the encode size, a Metal or Core Image pass that samples the camera surface in place, and one consumer list (preview, VT, LiveKit, phone).

**Two full encoders for one picture.** RTMP uses VideoToolbox at the project size. Guests use a second WebRTC encode at 720p24 after `fit720` copies. Phone adds `PhoneEncodeLane.encoder`, a third `HardwareVideoEncoder`, only when that lane is started. Better: scale once, then share. Start the phone encoder only while a phone destination is connected. That part is already gated by `multiDestinationRoutingV1` and `phoneLane`.

**WebKit is a second compositor.** `ProgramPageRaster` snapshots pages into pixel buffers and keeps them. A long rundown of URLs will fill RAM even if the user is on one page. Better: one live web view, one prefetch view, and two cached frames.

## 5. v1.0 must fix

Do these before the commit. Order is cost on a 4 GB laptop.

1. **F1 image cache.** Done when `AssetCacheManager` total cost is at most 128 MB and a 4K still stored for a thumbnail is at most 512 px on the long side.
2. **F4 page cache.** Done when prefetch stores at most the next URL and `frameCache` stays under 64 MB.
3. **F6 FFT.** Done when `vDSP_create_fftsetup` is not called per tick. One setup lives for the process.
4. **F2 frame pool.** Done when a 60 second 1080p30 stream shows a flat `CVPixelBuffer` count in Allocations (pool of 3, not one alloc per frame).
5. **F8 capture size.** Done when the camera session preset is 1080p or smaller, not `.high`.
6. **F3 single scale.** The program frame from `ProgramFramePool` is the buffer RTMP encodes. Guest return scales that buffer into one pooled 1280x720 picture. A 16:9 show does not allocate a second full-frame copy.

F5 (splitting `ShowController`) is a Blocker for long term CPU, but it is not a cheap fix. Do not block the commit on the split if F2 and F3 land and a profile on an 8 GB machine stays under 50 percent CPU. Re measure on a 4 GB machine before calling it done.

## 6. After v1.0

**CPU and UI**

- F5. Split `ShowController`. Stop publishing `programFrame` through `@Observable` at 30 Hz.
- F7. Pause `TimelineView`s that are not visible.
- F9. Remove the per tick `Task`.

**Memory and disk**

- F11. Per slide undo.
- F12. Confirm autosave never runs from the frame clock.
- F17. Remove the legacy RTMP clock once v2 is the only path.

**Dependencies and startup**

- F16. Trim AudioKitUI if unused at runtime.
- F20. Lazy `ShowController` after the start menu.

**Network**

- F10. Cap audio tags in `RTMPEndpointQueue` at 30.
- F18. Cap `ControlAPIServer` connections at 8.
- F19. A 720p30, 2500 kbps preset is the default on machines with 8 GB or less when no preset is saved.

## 7. Server readiness

This repo is the macOS desk. There is no relay, ingest gate, or packager process to push to a VPS.

| Service | Where | Memory and CPU | Limits | Before push |
| --- | --- | --- | --- | --- |
| `ControlAPIServer` | In the desk, `127.0.0.1:55076` | Not measured. One `NWListener`. | No connection cap. | Add a cap. Not a VPS service. |
| `RemoteControlRuntime` | In the desk | Not measured. | Not measured. | Same process as the app. |
| LiveKit | Cloud. Client is `LiveKitDeskSession` and `client-sdk-swift`. | Client cost is F3. Server is not in this repo. | Not in this repo. | Do not ship a self hosted SFU from this tree. |
| Companion module | `Integrations/companion-module-proshow` | Not measured. Depends on `@companion-module/base`. | Talks to `127.0.0.1:55076`. | Optional. Not required for the desk to run. |
| Stream Deck plugin | `Integrations/com.proshow.streamdeck.sdPlugin` | Static HTML and JS. | n/a | No server. |
| Guest join (showroom) | Not in this repo. | Not measured here. | n/a | Audit that app separately before a VPS claim. |

No Dockerfile, no ffmpeg child process, no health check, no restart policy. Nothing here is ready as a 1 vCPU service because nothing here is that service.

## Package sizes

Measured 2026-10-12 from `build/DerivedData/ProShow/SourcePackages`. Pins are in `ProShow.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. `Package.resolved` at the repo root pins AudioKit only (the SPM library target). The app also pins LiveKit.

Checkout `du` includes a local `build/` folder inside AudioKit (222 MB), Controls (150 MB), and AudioKitUI (15 MB). Those are not upstream source. Source rows below exclude them.

| Package | Version | Needed for v1.0 | What it pulls in | Checkout source | Runtime binary |
| --- | --- | --- | --- | --- | --- |
| AudioKit | 5.7.2 | Yes. `AudioIOEngine`, mixer, channel strip. | No further packages. Target `AudioKit` only. | Sources 1.2 MB, tests 7.1 MB, 189 Swift files. | Static. Release `ProShow` arm64 slice is 70,814,432 bytes and `nm` shows 5973 AudioKit symbols. No separate framework. |
| Controls | 1.1.4 | Pulled by AudioKitUI. App target links the product. | No dependencies. 27 Swift files. | Sources 216 KB. The 151 MB checkout is a local `build/` dir. | Static inside the same arm64 slice. |
| AudioKitUI | 0.3.7 | Used by `FFTSpectrumView` and the mixer UI. | AudioKit and Controls. | Sources 836 KB. | Static inside the same arm64 slice. |
| client-sdk-swift (LiveKit) | 2.17.0 | Yes, for guest return. | LiveKitWebRTC 150.7871.2, LiveKitUniFFI 0.1.9, plus in-tree nanopb. `swift-protobuf` and `swift-docc-plugin` are declared for tests and docs and are not in `Package.resolved`. | Sources 3.0 MB, protocol 5.7 MB, tests 1.8 MB. Checkout `.git` is 14 MB. | Static inside the same arm64 slice. |
| webrtc-xcframework | 150.7871.2 | Yes. LiveKit dependency. | Prebuilt `LiveKitWebRTC`. Whole xcframework 147 MB (tvOS, iOS, xrOS, Mac). | Repo checkout 140 KB. | Copied into the app: `LiveKitWebRTC.framework` 29 MB fat. arm64 slice 13,411,904 bytes. |
| livekit-uniffi-xcframework | 0.1.9 | Yes. LiveKit dependency. | Prebuilt Rust UniFFI. Artifact tree 13 MB. | Checkout 360 KB. | Copied into the app: `RustLiveKitUniFFI.framework` 2.3 MB fat. arm64 slice 1,111,200 bytes. |

v1.0 needs AudioKit, LiveKit, and WebRTC. AudioKitUI and Controls are only for desk widgets. They are not needed for encode. Dropping them is an after v1.0 item (F16).

## 8. How to re-run

App was not running on this pass. After fixes, quit other heavy apps and run:

```bash
# Idle, 15 s after launch
open /Applications/ProShow.app
sleep 15
PID=$(pgrep -x ProShow)
footprint $PID
vmmap --summary $PID
ps -o pid,rss,%cpu,thcount -p $PID

# While live (start the encode in the app first)
sample $PID 5 -file /tmp/proshow-live.txt
footprint $PID

# Allocations, 60 s, then stop
xcrun xctrace record --template 'Allocations' --time-limit 60s --output /tmp/proshow-alloc.trace --attach $PID

# CPU
xcrun xctrace record --template 'Time Profiler' --time-limit 30s --output /tmp/proshow-cpu.trace --attach $PID

# GPU
xcrun xctrace record --template 'Metal System Trace' --time-limit 10s --output /tmp/proshow-metal.trace --attach $PID

# Leaks after closing 5 projects
leaks $PID
```

4 GB simulation (macOS memory limit is not a hard cgroup). Watch compression:

```bash
memory_pressure -l warn
# repeat footprint. Then:
memory_pressure -l critical
```

Do not leave the machine at critical. Run `memory_pressure -l normal` after.

Pass criteria for the live row: RSS under 1.2 GB, CPU under 50 percent on the target laptop, no growth across 30 minutes (`footprint` at 0, 10, 20, 30 min), swap used stays flat (`memory_pressure` output).

Package sizes:

```bash
du -sh build/DerivedData/ProShow/SourcePackages/checkouts/*
du -sh build/DerivedData/ProShow/SourcePackages/artifacts/webrtc-xcframework/LiveKitWebRTC/LiveKitWebRTC.xcframework
```
