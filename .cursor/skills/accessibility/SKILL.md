---
name: accessibility
description: Audit and improve accessibility to WCAG 2.2 AA. Use when asked to improve a11y, run an accessibility audit, add keyboard or screen-reader support, fix contrast, or make a UI accessible.
---

# Accessibility

Goal: content usable by everyone. Target **WCAG 2.2 AA**. Automated scores are evidence, not conformance.

## Audit workflow

1. Prefer a live Lighthouse / axe pass on the rendered page.
2. Localize failing nodes to source.
3. Inspect the accessibility tree: names, roles, states, landmarks, headings.
4. Exercise the flow with the keyboard only.
5. Fix source, re-run the same audit.

## POUR

Perceivable · Operable · Understandable · Robust

## Must-fix

- Every image: descriptive `alt`, or `alt=""` + `role="presentation"` if decorative
- Icon-only controls: `aria-label` or visually hidden text; hide the SVG with `aria-hidden`
- Contrast: 4.5:1 normal text, 3:1 large text and UI chrome (1.4.3 / 1.4.11)
- Never color-only errors — add icon + text + `aria-invalid` + `aria-describedby`
- Native `<button>`, `<a>`, inputs first. No click-only `div`s
- Visible `:focus-visible` (2px+, 3:1). Never `outline: none` without a replacement
- Focus not fully covered by sticky chrome (`scroll-margin-top`)
- Skip link to main content
- Targets ≥ 24×24 CSS px (prefer 44×44)
- Dragging has a non-drag alternative
- `prefers-reduced-motion` respected
- `<html lang>` set
- Every input has a programmatic label
- Errors: `role="alert"` / `aria-live`, focus first error, say how to recover
- Allow paste / autofill on auth fields; offer passkey or magic link
- Help, nav, and landmarks stay in the same relative order

## Patterns

```html
<button aria-label="Open menu"><svg aria-hidden="true">...</svg></button>
<label for="email">Email</label>
<input id="email" aria-invalid="true" aria-describedby="email-error">
<p id="email-error" role="alert">Enter a valid email.</p>
```

```css
:focus-visible { outline: 2px solid currentColor; outline-offset: 2px; }
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0.01ms !important;
    transition-duration: 0.01ms !important;
  }
}
```

## Severity

- **Critical now:** unlabeled controls, missing alt, contrast fails, keyboard traps, no focus ring
- **Before launch:** no `lang`, broken heading order, "click here" links, autoplay, no skip link
- **Soon:** icon names, inconsistent nav, weak errors, missing landmarks
