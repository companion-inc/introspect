---
name: product-surface-polish
description: Polish user-facing product surfaces such as pricing pages, plan cards, App Store/TestFlight metadata, icons, categories, onboarding, and marketing UI by reading real reference products and the product's enforced source of truth before writing copy or visuals.
---

# Product Surface Polish

## Use When

- Editing pricing pages, plan cards, upgrade/paywall screens, feature lists, App Store metadata, TestFlight metadata, app icons, product categories, onboarding, or marketing UI.
- The user points at reference products and asks for the surface to feel similar, bigger, cleaner, more premium, or less awkward.
- Copy includes internal terms, vague feature claims, filler benefits, or numbers that may drift from enforced plan limits.

Near miss: do not load this for backend-only billing logic unless a user-visible product surface is being changed.

## Procedure

1. Name the exact surface and audience: store listing, home-screen app identity, pricing page, locked paywall, onboarding, or in-app settings.
2. Read the real references the user named, plus the closest direct competitors when the user asks "how do others do it." Extract the pattern in concrete terms: naming formula, subtitle placement, category choice, icon style, card hierarchy, feature taxonomy, spacing, and responsive behavior.
3. Read the product source of truth before writing copy: plan constants, enforced quotas, billing config, app metadata, bundle settings, feature gates, and current screenshots. A pricing claim must trace to code or config; store metadata must trace to App Store Connect or bundle settings.
4. Translate internal capability into user language. Remove engineering phrases and filler such as "tool-heavy," "model context window," "standard usage," "switch anytime," or "add more credits anytime" unless the reference products and product truth make them genuinely meaningful.
5. For tiered pricing, make progression visible from low to high: more quota, broader capability, clearer support/access. Keep duplicated roll-up lines short, avoid unlimited claims unless the runtime actually enforces no limit, and align cards across desktop and medium-width layouts.
6. For icons and store metadata, choose the model/tool intentionally after checking available local/API options. Generate or edit the asset only after the reference pattern is clear, then verify the built app bundle uses the asset and the public metadata changed.
7. Verify on the actual surface, not a proxy: screenshot or inspect the live page, run typecheck/lint/build, verify responsive wrapping, and for App Store/TestFlight work confirm the processed uploaded build or current App Store Connect fields.

## Gotchas

- A reference list is not proof you read references. Summarize the pattern you observed before changing the product.
- Public names, subtitles, category labels, and pricing bullets are user psychology surfaces. They should not expose internal architecture, debugging shorthand, or implementation limits unless that is the sellable benefit.
- If the product has plan constants, copy should be generated from or checked against them so the page cannot promise more or less than the runtime enforces.
- A generated visual can be worse than a clean existing glyph if the prompt is not grounded in the app identity and peer icon language.

## Verification

- Positive trigger: "Read ChatGPT, Claude, Manus, and Perplexity pricing and fix our pricing cards."
- Positive trigger: "Read Plaud/Granola/Pocket and fix our TestFlight name, category, and icon."
- Near miss: "Change the backend limit for automations from 10 to 20" with no UI/store/pricing surface.

## Sources

- Failure transcript: `/Users/advaitpaliwal/.codex/attachments/5d18711c-7e59-4273-ab64-57108730cc2b/pasted-text.txt`.
- Failure transcript: `/Users/advaitpaliwal/.codex/attachments/2c7c786c-b08a-48ad-ac5e-e5b78c7b47c7/pasted-text.txt`.
- Skill format and routing rules: `skills/skill-creator/references/source-map.md`.
