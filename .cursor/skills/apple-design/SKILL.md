---
name: apple-design
description: Apple-style fluid interfaces — springs, gesture tracking, sheets, materials, and typography. Use when building or reviewing press/drag/swipe UI, interruptible motion, translucent chrome, or macOS/iOS-feeling web or native surfaces.
---

# Apple Design

Interfaces feel alive when motion starts from the **current on-screen value**, inherits velocity, projects momentum, and can be grabbed mid-flight. Springs are the tool.

## Response

- Feedback on **pointer-down**, not click/up
- Continuous 1:1 updates during drag — never animate only on release
- Audit debounce and ~300ms tap delay on the input path

```css
.button:active { transform: scale(0.97); transition: transform 100ms ease-out; }
```

## Direct manipulation

Touch and content move together. Respect grab offset. `setPointerCapture`. Keep a short velocity history.

## Interruptibility

Never lock input during a transition. Animate from the live presentation value. Avoid CSS keyframes for gesture-driven motion. Carry velocity through re-target. Independent X/Y springs.

## Springs

Designer params: **damping** (1.0 = no bounce) and **response** (seconds to settle, not duration).

| Interaction | Damping | Response |
| --- | --- | --- |
| Move / PiP | 1.0 | 0.4 |
| Rotation | 0.8 | 0.4 |
| Drawer / sheet | 0.8 | 0.3 |

Default critically damped. Bounce only after a flick. Hand off release velocity into the spring. Project landing: `current + (v/1000) * d / (1-d)` with `d ≈ 0.998`, then snap to nearest point.

## Spatial rules

- Enter and exit the same path
- Anchor popovers to the trigger (`transform-origin`)
- Rubber-band past edges instead of a hard stop
- Translucent chrome: `backdrop-filter` + content scrolling underneath; never stack light glass on light glass
- Dim + scrim for modal tasks; offset + glass for parallel panels

## Typography

Size-specific tracking (tighten large display, body near 0). Tight leading on big type, looser on body. Prefer the platform system font unless there is a reason not to. Scale layout in `rem`/`em`.

## Reduced motion

`prefers-reduced-motion`: cross-fade, drop springs/parallax. `prefers-reduced-transparency`: solid chrome. `prefers-contrast: more`: near-solid + defined border.

## Foundations

Purpose, agency (easy undo), responsibility, familiarity, flexibility, simplicity (not empty minimalism), craft, delight as the result of the other seven.

Feedback kinds: status, completion, warning, error. Every screen answers: where am I, where can I go, how do I get out.
