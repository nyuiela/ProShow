---
name: interaction-design
description: Design microinteractions, motion, transitions, and feedback. Use when adding hover/press states, loaders, toasts, gestures, page transitions, or any motion that should feel purposeful.
---

# Interaction Design

Motion communicates. It does not decorate.

## Purpose

- **Feedback** — confirm the action happened
- **Orientation** — show where things come from / go to
- **Focus** — point at the change
- **Continuity** — keep context during transitions

## Timing

| Duration | Use |
| --- | --- |
| 100–150ms | Micro-feedback (hover, press) |
| 200–300ms | Toggles, dropdowns |
| 300–500ms | Modals, page changes |
| 500ms+ | Rare choreographed moments only |

## Easing

```css
--ease-out: cubic-bezier(0.16, 1, 0.3, 1);      /* entering */
--ease-in: cubic-bezier(0.55, 0, 1, 0.45);       /* exiting (rarely for UI) */
--ease-in-out: cubic-bezier(0.65, 0, 0.35, 1);   /* moving between */
--spring: cubic-bezier(0.34, 1.56, 0.64, 1);     /* playful overshoot */
```

Prefer `ease-out` for UI. Never `ease-in` on open. Animate `transform` and `opacity` only.

## Patterns

- Buttons: `scale(0.97)` on press, 100–160ms
- Loading: skeleton that preserves layout; determinate progress when known
- Page enter: short opacity + small Y, `AnimatePresence mode="wait"` if using Motion
- Gestures: 1:1 drag, velocity-based dismiss, rubber-band at edges
- Feedback: toast / live region for outcomes; never block input during animation

## Accessibility

```css
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
  }
}
```

## Avoid

- Animating `width`, `height`, `top`, `left`
- Motion on actions used 100+ times/day
- Preventing input until an animation finishes
- Infinite decorative loops
