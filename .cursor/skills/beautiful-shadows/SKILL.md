---
name: beautiful-shadows
description: Apply refined layered elevation instead of muddy or generic shadows. Use when a UI needs depth, cards, panels, popovers, or when default Tailwind shadows look blunt.
---

# Beautiful Shadows

Use when a surface needs polished, layered elevation without colored glow.

## Tailwind utilities

### Beautiful sm

Compact cards, form controls, pills, quieter surfaces.

```txt
shadow-[0px_2px_3px_-1px_rgba(0,0,0,0.1),0px_1px_0px_0px_rgba(25,28,33,0.02),0px_0px_0px_1px_rgba(25,28,33,0.08)]
```

### Beautiful md

Cards, panels, popovers, default elevated surface.

```txt
shadow-[0px_0px_0px_1px_rgba(0,0,0,0.06),0px_1px_1px_-0.5px_rgba(0,0,0,0.06),0px_3px_3px_-1.5px_rgba(0,0,0,0.06),_0px_6px_6px_-3px_rgba(0,0,0,0.06),0px_12px_12px_-6px_rgba(0,0,0,0.06),0px_24px_24px_-12px_rgba(0,0,0,0.06)]
```

### Beautiful lg

Hero media, feature callouts, modal-like containers, strongest lift.

```txt
shadow-[0_2.8px_2.2px_rgba(0,_0,_0,_0.034),_0_6.7px_5.3px_rgba(0,_0,_0,_0.048),_0_12.5px_10px_rgba(0,_0,_0,_0.06),_0_22.3px_17.9px_rgba(0,_0,_0,_0.072),_0_41.8px_33.4px_rgba(0,_0,_0,_0.086),_0_100px_80px_rgba(0,_0,_0,_0.12)]
```

## Native / CSS equivalent

Keep shadows **neutral** and stacked (hairline ring + short contact + long ambient). One strength per component state.

```css
/* sm */
box-shadow: 0 2px 3px -1px rgba(0,0,0,0.1), 0 1px 0 rgba(25,28,33,0.02), 0 0 0 1px rgba(25,28,33,0.08);

/* md */
box-shadow: 0 0 0 1px rgba(0,0,0,0.06), 0 1px 1px -0.5px rgba(0,0,0,0.06), 0 3px 3px -1.5px rgba(0,0,0,0.06), 0 6px 6px -3px rgba(0,0,0,0.06), 0 12px 12px -6px rgba(0,0,0,0.06), 0 24px 24px -12px rgba(0,0,0,0.06);
```

## Rules

- Pair with a clean surface fill and a consistent radius.
- Do not mix with default Tailwind `shadow-sm/md/lg` on the same element.
- Do not tint with strong color.
- Do not apply `lg` to dense lists or tiny controls.
- Do not stack multiple shadow utilities on one element.
- Shadows are not a substitute for a real border in very low-contrast layouts.
