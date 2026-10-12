---
name: emil-design-eng
description: Emil Kowalski design-engineering craft for UI polish, animation decisions, and production frontend detail. Use when reviewing or polishing components, motion, buttons, popovers, toasts, or drawers.
---

# Emil Design Eng

Taste is trained. Unseen details compound. Beauty is leverage.

## Review format (required)

When reviewing UI, use one markdown table — never Before/After lists:

| Before | After | Why |
| --- | --- | --- |
| `transition: all 300ms` | `transition: transform 200ms ease-out` | Specify properties; avoid `all` |
| `transform: scale(0)` | `transform: scale(0.95); opacity: 0` | Nothing appears from nothing |
| `ease-in` on dropdown | `ease-out` custom curve | `ease-in` feels sluggish |
| No `:active` on button | `transform: scale(0.97)` | Press must feel heard |
| Center origin on popover | Origin at the trigger | Popovers grow from their source |

## Should this animate?

| Frequency | Decision |
| --- | --- |
| 100+/day (shortcuts, command palette) | No animation |
| Tens/day (hover, list nav) | Remove or cut hard |
| Occasional (modals, toasts) | Standard |
| Rare (onboarding) | Delight is allowed |

Never animate keyboard-initiated actions.

Purpose must be spatial consistency, state, explanation, feedback, or preventing a jarring snap — not "it looks cool."

## Easing and speed

```css
--ease-out: cubic-bezier(0.23, 1, 0.32, 1);
--ease-in-out: cubic-bezier(0.77, 0, 0.175, 1);
--ease-drawer: cubic-bezier(0.32, 0.72, 0, 1);
```

Never `ease-in` for UI. Stay under 300ms for UI. Button press 100–160ms. Tooltips 125–200ms. Dropdowns 150–250ms. Modals 200–500ms.

## Hard rules

- `scale(0.97)` on `:active` for pressable controls
- Never enter from `scale(0)` — start ≥ `0.9` + opacity
- Popovers origin-aware; **modals stay centered**
- Subsequent tooltips: skip delay and animation
- CSS transitions over keyframes for interruptible UI
- Subtle `blur(2px)` can hide a bad crossfade; keep blur under 20px
- Prefer `@starting-style` for enter animations
- `translateY(100%)` is relative to the element — use it for drawers/toasts
- `clip-path: inset()` for reveals, tab color morphs, hold-to-delete
- Dismiss on velocity (~0.11) or distance, not distance alone
- Damp past boundaries
- `transition: all` is forbidden

## Springs

Use for drag, interruptible gestures, and "alive" objects. `{ type: "spring", duration: 0.5, bounce: 0.2 }` or mass/stiffness/damping. Keep bounce 0.1–0.3 and rare.

## Perceived speed

A faster spinner and a 180ms select feel faster than a 400ms one at the same load time. Instant subsequent tooltips make a toolbar feel faster.
