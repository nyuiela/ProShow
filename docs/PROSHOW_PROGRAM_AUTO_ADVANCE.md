# Program auto-advance (0.5.3)

The `.program` outline can run itself. Each item plays for its planned duration, then the next item is cut on air and its script loads in the prompter, still rolling.

## Controls

The outline transport (workspace footer and the stream outline window) has:

- **Auto**: on or off, kept across launches.
- **Hold**: freezes the item clock and auto-advance. Press again, or Space, to resume.
- **+30s**: adds 30 seconds to the live item.
- **Next**: skips to the next item now, held or not.

The live row and the stage display show the countdown. Past the end it shows the overrun as `+0:05`. While held it shows `HOLD`.

## When auto cuts

- At 0 remaining, if the item has no script or the prompter is not following it.
- If the prompter is still reading the item, auto waits for the end of the script plus 0.75 s, at most 12 s past the planned end.
- If the prompter finished early, auto cuts at 0 as planned.

## Stop items

Auto stops at the end of an item and waits for Next when the item's `stopHere` is true. When `stopHere` is not set, auto stops at:

- the first item, when its title is a waiting slate (Starting soon, Pre-show, Countdown, Waiting room, Stream starting)
- STANDBY or BRB items (title word STANDBY or BRB, or "be right back")
- an Outro (title starting with Outro or End slate)
- the last item

Auto never cuts into a STANDBY or BRB item unless `stopHere` is set on it; it goes to the next item instead. Next still takes it by hand.

## Prompter pacing

Each item's `promptPacing` is `fitDuration` (default) or `prompterSpeed`. `fitDuration` picks the words per minute that make the script fill the planned duration, from 120 to 240. Pauses and punctuation holds keep their own time.

## Stage cues

A cue offset is seconds before the end, whatever its sign (older files stored -60). A cue fires once per item, when the countdown crosses it, so Hold, +30s and slow frames neither repeat nor skip it. The defaults are 60, 30 and 0.

## Remote

| Action | REST | OSC | MIDI (note on) |
| --- | --- | --- | --- |
| Next | POST /v1/program/next | /proshow/program/next | 62 |
| Previous | POST /v1/program/prev | /proshow/program/prev | 63 |
| Hold toggle | POST /v1/program/hold | /proshow/program/hold | 64 |
| +30 s | POST /v1/program/extend | /proshow/program/extend | 65 |
| Auto | POST /v1/program/auto {"enabled": true} | /proshow/program/auto 1 | |
| State | GET /v1/program/status | /proshow/program/status | |

`/v1/slide/next` is unchanged and still moves the slide, not the outline.

## Preload

When an item starts, the next item's design images are decoded in the background and its page frames are prefetched. If a different item starts, the unused images are dropped from the cache. Media and cameras are not preloaded: that path starts capture and audio.

## Known issue

Any take to air (a program cut, Next, or a plain slide take) redraws the main window, and the main thread is busy for about 0.6 to 1 s afterwards. The cut itself is applied in under 40 ms, but on the stream the camera well can show blank and part of the new slide can complete up to about 1 s later. Build 11 behaves the same. The prompter catches up after the redraw, so reads still end on pace.
