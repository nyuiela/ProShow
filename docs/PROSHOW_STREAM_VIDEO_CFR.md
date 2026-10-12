# ProShow stream video CFR (ingest `avg_frame_rate`)

## Problem

Ingest gates use **packet timing in the H.264 bytestream**, not RTMP `onMetaData` alone. When ProShow skips program composites under load, video tags can be **missing or irregular** while the CFR clock still advances → ffprobe `avg_frame_rate=0/0` → server **re-encode** → loading, low cadence, HLS rebuffer.

Audio flutter is a **separate** path (AAC / mix / silence AUs). CFR hold frames target **video ingest copy**, not chop.

## Intended CFR model (unchanged)

- Integer `framerate` in RTMP metadata
- VideoToolbox PTS = frame index × 1/fps (`StreamVideoCFRClock`)
- B-frames off; audio on `MediaClockAnchor`

## Shipped: CFR hold duplicates

When a program tick **cannot** run a full composite (`programOutputInFlight`):

1. **Live:** emit a **hold frame** on the stream CFR schedule (~target fps), not PTS-only advance.
2. **Hold source (in order):**
   - Cheap **video-layer blit** when `eligibleForVideoOnlyStreamEncode` (screen share, no slide/props).
   - Else **duplicate last full program frame** from `ProgramOutputStore` / cached snapshot.
3. Hold frames go through **`ProgramOutputBus`** → `HardwareVideoEncoder.encode` → same CFR index step as a normal frame.
4. **Recording:** same hold path when composite is skipped; PTS-only advance remains fallback if no frame exists yet.

Telemetry: `StreamTelemetryMonitor.streamCFRHoldFrameCount`, desk probe **CFR holds**.

Encode source tag: `StreamEncodeSource.cfrHoldDuplicate`.

## Verify after deploy

1. Live with heavy slide/props; force composite backlog (desk **composite skips** > 0).
2. Confirm **CFR holds** rise while **enc fps ≈ target** and measured Kbps stays plausible.
3. Capture publisher chunk; ffprobe `avg_frame_rate` and `r_frame_rate` should be **non-zero and aligned** (e.g. `30/1`).
4. Re-run ingest gate: prefer **conformant copy** vs prior `avg=0/0` + re-encode.

## Shipped: decouple holds from composite backlog

- Full composite runs on `programCompositeQueue`; CFR holds no longer queue behind a slow composite on `programClockQueue`.
- Tick holds duplicate the last frame **synchronously** when slides/props need the full snapshot; screen-share-only holds blit on `metalRenderQueue`.
- `StreamVideoCFRPacer` fires at target fps while live; if no VideoToolbox AU arrived that interval, re-encode `StreamHoldFrameCache` (wall-clock CFR backstop).

## Follow-ups (not in this change)

- Wall-clock scheduler independent of program tick jitter (Metal/display link) — partially addressed by `StreamVideoCFRPacer`.
- Duplicate **keyframe** policy on long hold streaks (GOP alignment for seek).
- Emit hold from `StreamAudioPipelineDiagnostics` / Console alongside `StreamAudio` logs.
