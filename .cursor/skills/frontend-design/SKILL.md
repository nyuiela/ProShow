---
name: frontend-design
description: Create distinctive, production-grade frontend interfaces with high design quality. Use when building or restyling UI, landing pages, dashboards, or any visual interface so the result avoids generic AI aesthetics.
---

# Frontend Design

Approach this as the design lead at a design studio known for giving every client a distinct visual identity. Make deliberate, opinionated choices about palette, typography, and layout that are specific to this brief.

## Ground designs in the subject matter

Identify the product, audience, and primary job before designing. Industry, materials, and vernacular drive distinctive visual choices. Build with real content, not lorem.

## Design principles

- The hero is the first thing viewers see. Open with the most characteristic thing in the subject's world.
- Typography carries personality. Use one family or two clearly distinct families. Choose typefaces deliberately, not Inter/Roboto/system defaults unless the brief asks for them.
- Default to line lengths under 80 characters. Serif body text gets slightly more line-height.
- Avoid: accenting a single word in a headline; all-caps labels; unnecessary eyebrows above content.
- Structural devices (outlines, numbering, dividers) encode information, they do not decorate. Numbered markers only if the content is actually a sequence.
- Non-user-triggered motion is rare. One orchestrated moment beats fade-and-slide on every section.
- Copy is design content. Name things by what users understand. Active voice. CTAs say what happens: "Save changes," not "Submit." Errors explain how to fix. Empty states invite action.

## Avoid generic AI defaults

Do not default to:

1. Warm cream (#F4F1EA) + terracotta accent (#D97757)
2. Near-black + acid-green or vermilion
3. Broadsheet hairlines and dense newspaper columns
4. Identical rounded SaaS cards with the same soft grey shadow
5. Tracked ALL-CAPS eyebrows, middle-dot meta strings, `WORD — fragment` labels, tinted near-black, monospace data labels, `→` on every link

The brief always wins if it asks for one of these looks. If an axis is free, do not spend it on a default.

## Process

1. Write a short design plan: 4–6 named hex colors, type roles, one-sentence layout + ASCII wireframe, principles.
2. Review the plan against the brief. If it reads like the generic default for any similar page, revise and say why.
3. Only then write code. Keep CSS specificities from cancelling each other.
4. Spend boldness in one place. Keep everything else quiet. Responsive, keyboard-visible focus, reduced motion, accessible contrast.
5. Critique as you build. Remove one accessory before shipping.
