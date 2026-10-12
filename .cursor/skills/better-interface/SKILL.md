---
name: better-interface
description: Orchestrate interface quality by combining personal UI skills. Use when building, restyling, reviewing, or shipping any user-facing interface so the work stays coordinated instead of one-skill-at-a-time.
---

# Better Interface

Coordinate the installed personal UI skills. Read the relevant skill files when a task matches.

## Route

| Task | Read |
| --- | --- |
| Distinct visual identity, avoid generic AI look | `frontend-design` |
| Apple / iOS / macOS feel, springs, sheets, materials | `apple-design` |
| Component polish, press, popovers, toasts, drawers | `emil-design-eng` |
| Motion, hover, loaders, gestures, page transitions | `interaction-design` |
| Elevation, cards, panels, popovers | `beautiful-shadows` |
| Responsive / breakpoint / input-method change | `adapt` |
| Keyboard, contrast, labels, WCAG | `accessibility` |
| Critique of a URL, screenshot, or component | `design-review` |
| Project uses `components.json` or user asked for shadcn | `shadcn` |

Read 1–2 skills that match the task. Do not load every skill on every turn.

## Non-negotiables

- Real content, not lorem
- Visible `:focus-visible`; never `outline: none` without a replacement
- `prefers-reduced-motion` respected
- Contrast AA (4.5:1 text, 3:1 chrome)
- Icon-only controls have an accessible name
- Animate `transform` and `opacity` only
- Never `transition: all` or enter from `scale(0)`
- Pressable controls have a press state (`scale(0.97)` or equivalent)
- Native controls first; no click-only `div`s
- Do not invent a new design system when the project already has one

## Loop

1. Plan: audience, one visual idea, type + color, motion budget.
2. Build against the project tokens and existing components.
3. Critique against `design-review` before calling the UI done.
4. Accessibility last-pass: keyboard, names, contrast, reduced motion.

Native SwiftUI / AppKit: apply the same craft (hierarchy, press, motion budget, contrast, labels). Map web tokens to system materials, SF Symbols, and platform type. Ignore `shadcn` unless the user asked for a web UI.
