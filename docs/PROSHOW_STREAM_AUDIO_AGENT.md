# ProShow stream audio / buffering — agent brief

**Symptom:** Desk meters look fine. Viewers hear audio on/off. Player may keep loading. Uplink may be fine.

**Stack:** macOS SwiftUI. RTMP/RTMPS. AAC-LC 48 kHz. H.264 VideoToolbox.  
**Repo:** `/Users/kaleel/Documents/projects/tools/ProShow`

---

## Shipped (verify on device)

| Fix | What changed | Where |
|-----|----------------|-------|
| **1 Per-lane mix** | Full 1024-frame stereo AU; each role consumes up to AU size independently; short lanes zero-padded in mix (no `min(lane depth)` starvation) | `ProgramAACEncoder.dequeueMixedFrame` in `RTMPStreamTransport.swift` |
| **2 Mic peaks + PCM drops** | Live mic peak from decoded PCM → `onCaptureAudioPeak`; `monoPCM` nil counted (no crash) | `VideoIngestEngine.swift`, `VideoSampleDecoder` |
| **3 Composite skip PTS** | Skipped composite advances CFR `frameCount` without encoding | `HardwareVideoEncoder.advanceScheduledFrames`, `ShowController.submitProgramOutput` |
| **4 Telemetry** | 1 Hz `os_log`, desk probe line: silence vs real AU %, lane depths, monoPCM nil, gate reject, AAC fail | `StreamAudioPipelineDiagnostics.swift`, `DeskSignalProbe.swift` |

**Isolation checklist (run first):** [PROSHOW_STREAM_AUDIO_ISOLATION.md](./PROSHOW_STREAM_AUDIO_ISOLATION.md)

**Console while live:** filter `subsystem:com.kaleel.proshow category:StreamAudio`

---

## Why meters can lie

| Desk meter | What it shows | What RTMP sends |
|------------|---------------|-----------------|
| Compositor L/R bars | Matrix peaks + slide `outputLevel` + desktop `injectPeak` | Gates → PCM lanes → AAC → RTMP |
| Program-mix monitor | Same PCM mix as AAC input | Same as stream (**trust this**) |
| Mic peaks | **Now updated from AVF PCM** when capture works; still wrong if `monoPCM` nil | AVF `monoPCM` → gates |

**Rule:** Compare **program-mix headphones** to **viewer**. Compositor bars alone are not proof.

---

## Pipeline (one glance)

Capture (AVF / ScreenCaptureKit / slide tap) → `ProgramStreamAudioGates` → `ProgramPCMBridge` → AAC lanes → mix 1024 stereo → AAC → `ProgramAudioBus` (~48) → RTMP pump (~21.33 ms) → `RTMPEndpointQueue` (max 120) → network.

Video: `tickProgram` → composite → `HardwareVideoEncoder` (CFR index; skips advance index) → RTMP video tags → same queue.

Audio PTS: `MediaClockAnchor` (host). Video PTS: CFR frame index. Still dual clocks; skip advance reduces lag only.

---

## Still investigate if symptom persists

1. **`monoPCM` nil** — desk may show nil count + silence AU % spike.
2. **Empty bus → `AACSilenceEncoder`** — high `% silence` in probe / log = pump starved despite Fix 1.
3. **Mute / flush / reconcile** — lane clears during live edits.
4. **RTMP queue overflow** — `outboundNetworkAudioDropCount`, keyframe gap after flush.
5. **Slide tap vs `ProgramAudioPuller`** (420 ms stale).
6. **Loading:** composite skips + bitrate + A/V skew (no full audio-master video clock yet).

---

## Repro

1. Which meter? (compositor vs program-mix vs channel)
2. Bisect: camera+mic only → full rundown.
3. While choppy: desk probe + Console `StreamAudio` + `captureLanePressureRatio`, RTMP drops, encode FPS, `skippedCompositeFrameCount`.
4. Headphones cut + viewer cut → mix/encode. Headphones clean, viewer bad → RTMP/network.

---

## Instrumentation (in app)

`StreamAudioPipelineDiagnostics` — per session reset on `StreamingEngine.start`:

- Cumulative `monoPCM` nil (mic/desktop)
- Window (1 s): real vs silence AU, gate rejects
- Cumulative AAC encode failures
- Lane depth summary (`mic 512/1024` …)

Also: `DeskSignalProbe`, `outboundNetworkAudioDropCount`, `StreamTelemetryMonitor`.

---

## Files (read order)

| Pri | File | Why |
|-----|------|-----|
| P0 | `Services/RTMPStreamTransport.swift` | Gates, AAC mix, bus, pump |
| P0 | `Services/StreamAudioPipelineDiagnostics.swift` | Live counters / desk rollup |
| P0 | `Services/VideoIngestEngine.swift` | Capture PCM, peaks, monoPCM |
| P0 | `Services/ShowController.swift` | tickProgram, composite skip → PTS |
| P1 | `Services/RTMPEndpointQueue.swift` | Network drops |
| P1 | `Services/HardwareVideoEncoder.swift` | CFR + skip advance |
| P1 | `Services/MediaClockAnchor.swift` | Audio PTS |
| P1 | `Services/AudioMatrixEngine.swift`, `AudioMatrixReconciler.swift` | Mute / flush |
| P2 | `Services/MediaPlaybackEngine.swift` | Slide tap + puller |
| P2 | `Services/DeskSignalProbe.swift` | Health UI |

---

## Fix bar (release)

- Viewer audio continuous on same setup (no rhythmic silence).
- Program-mix monitor matches viewer.
- Probe/log shows pressure **before** operator hears it.
- Mute still mutes stream. No capture restart that blanks video.

---

## Ask operator

1. Destination? Single or multi RTMP?
2. Content when it fails: camera only, slide+audio, browser/rundown, NDI?
3. Program-mix headphones vs viewer?
4. Desk: silence AU %, monoPCM nil, RTMP drop advisories?
5. Video smooth + fluttery audio, or both stutter?

---

## Pasteable prompt (follow-up agent)

> ProShow stream audio: Fixes 1–4 are in tree (per-lane AAC mix, mic PCM peaks, composite-skip video PTS advance, StreamAudioPipelineDiagnostics). Validate with docs/PROSHOW_STREAM_AUDIO_ISOLATION.md. If viewers still flutter: confirm silence AU % and monoPCM nil in desk probe and Console `StreamAudio`; then check RTMPEndpointQueue drops, ProgramAudioPuller handoff, and whether video needs audio-anchored PTS beyond skip advance. P0: RTMPStreamTransport, StreamAudioPipelineDiagnostics, VideoIngestEngine, ShowController. Keep UI copy short.
