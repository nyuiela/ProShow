---
name: adapt
description: Adapt interfaces across breakpoints, devices, and input methods. Use when making a design responsive, porting desktop to mobile (or reverse), or fitting a UI to a new platform context.
---

# Adapt

Adaptation is **rethinking the experience for the new context**, not scaling pixels.

## Assess

1. Source assumptions: screen size, pointer vs touch, connection, usage (glance vs focused).
2. Target: device, input, orientation, network, user expectations.
3. What will not fit, will not work (hover on touch), or is inappropriate.

## Strategies

### Desktop → mobile

- Single column, full-width, vertical stack
- Bottom nav or drawer instead of persistent side nav
- 44×44pt minimum targets; no hover-only actions
- Progressive disclosure; 16px minimum body text
- Bottom sheets instead of dense dropdowns
- Thumb reach: primary actions in the lower half

### Tablet

- Two-column / master-detail
- Support both touch and pointer
- Orientation-aware layout

### Mobile → desktop

- Multi-column with max-width (do not stretch to 4K)
- Persistent side nav, keyboard shortcuts, hover enrichment
- Show more information up front

### Print / email

- Print: drop chrome, page breaks, expanded URLs
- Email: 600px, single column, inline CSS, large CTAs, no hover

## Implementation

- Mobile-first `min-width` queries; breakpoints where the **design** breaks
- Detect input, not just width:

```css
@media (pointer: coarse) { .button { padding: 12px 20px; } }
@media (hover: hover) { .card:hover { transform: translateY(-2px); } }
```

- Safe areas: `env(safe-area-inset-*)` + `viewport-fit=cover`
- Responsive images: `srcset` / `picture` for art direction
- Container queries and `clamp()` for fluid type/spacing

## Verify

Test real devices when possible. Emulation checks layout, not gestures. Custom sliders/drag strips must complete a drag and not steal page scroll.

Do not hide core functionality on mobile. Do not assume desktop is powerful. Do not use a different IA per breakpoint.
