---
name: design-review
description: Prioritized design critique of a URL, screenshot, or component. Use when the user asks to review, critique, or check craft or accessibility of a UI before shipping.
---

# Design Review

Senior craft critique. Opinionated and specific. Not a generic checklist dump.

## 1. Acquire the artifact

- Screenshot / image → read it (best for hierarchy, type, spacing, color)
- Component / code → read it and tokens (`file:line` + optional apply)
- URL → fetch markup; also ask for a screenshot for visual judgment
- If neither screenshot nor code exists, ask before guessing

## 2. Evaluate

Check with numbers where possible: contrast ratios, line-height, measure in `ch`, tap-target px, animation ms.

Dimensions: hierarchy & layout · typography · spacing & rhythm · color & contrast · motion · component states · accessibility · responsiveness · content & copy · consistency & brand.

## 3. Report

Lead with the few that matter. For each finding:

- **What** — specific issue, quote the element / `file:line`
- **Why** — one-line craft or usability reason
- **Fix** — exact value, not "increase spacing"

Severity:

- 🔴 Blocking — broken, inaccessible, fails WCAG AA, or unusable on a target device
- 🟠 Important — hurts hierarchy, readability, usability, or consistency
- 🟡 Polish — craft refinement

End with **Strengths** (2–4) and the single highest-leverage change.

## 4. Apply

Only edit when the user asks. Apply clear, safe fixes (contrast, spacing tokens, focus, reduced-motion, semantics, alt). Leave subjective restructuring as recommendations unless confirmed. Re-check values after edits.

## Tone

Direct and respectful. Precise about problems, always paired with the fix. Marketing heroes get type/motion scrutiny; forms get states/accessibility scrutiny.
