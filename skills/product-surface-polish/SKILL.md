---
name: product-surface-polish
description: Polish user-facing product surfaces such as pricing pages, plan cards, model/settings pickers, provider import/export prompts, provider logos, App Store/TestFlight metadata, icons, categories, onboarding, and marketing UI by reading real reference products and the product's enforced source of truth before writing copy or visuals.
---

# Product Surface Polish

## Use When

- Editing pricing pages, plan cards, upgrade/paywall screens, feature lists, model pickers, settings copy, App Store metadata, TestFlight metadata, app icons, product categories, onboarding, or marketing UI.
- A product/settings surface names third-party providers or tools and needs their logos, brand marks, icons, or provider-choice affordances.
- A product/settings surface uses another AI's import/export prompt, dialog, or onboarding flow as a reference for the product's own prompt or flow.
- The user points at reference products and asks for the surface to feel similar, bigger, cleaner, more premium, or less awkward.
- Copy includes internal terms, vague feature claims, filler benefits, or numbers that may drift from enforced plan limits.

Near miss: do not load this for backend-only billing logic unless a user-visible product surface is being changed.

## Procedure

1. Name the exact surface and audience: store listing, home-screen app identity, pricing page, locked paywall, onboarding, model picker, or in-app settings.
2. Read the real references the user named, plus the closest direct competitors when the user asks "how do others do it." Extract the pattern in concrete terms: naming formula, subtitle placement, category choice, icon style, card hierarchy, feature taxonomy, spacing, and responsive behavior.
3. Classify each reference's role before implementing: verbatim source to copy, inspiration to synthesize from, or component behavior to match. Copy provider prompt text verbatim only when the user asks for copying; when provider prompts are examples of how another app extracts/imports data, write one product-owned prompt shaped by the pattern instead.
4. Read the product source of truth before writing copy: plan constants, enforced quotas, billing config, app metadata, bundle settings, feature gates, and current screenshots. A pricing claim must trace to code or config; store metadata must trace to App Store Connect or bundle settings.
5. For subscription or paywall work, prove the in-app purchase path before store-review artifacts: inspect the paywall code/config, product IDs, selected-plan params, StoreKit/Superwall wiring, and a real simulator/device screenshot or flow. Do not upload App Store review screenshots or polish subscription metadata while the app only has static cards or an unproven trigger.
6. Translate internal capability into user language. Remove engineering phrases and filler such as "tool-heavy," "model context window," "standard usage," "switch anytime," or "add more credits anytime" unless the reference products and product truth make them genuinely meaningful.
7. For tiered pricing, make progression visible from low to high: more quota, broader capability, clearer support/access. Keep duplicated roll-up lines short, avoid unlimited claims unless the runtime actually enforces no limit, and align cards across desktop and medium-width layouts.
8. For provider import/export dialogs, use the app's existing standard dialog and controls first. Custom sizing, typography, or cloned competitor chrome needs a concrete reason from the reference pattern and the local design system.
9. For third-party provider logos, search current web, vendor, and public icon sources before inventing a mark. Prefer official brand kits or established public SVG icon packages; keep the resulting asset local in the app with its source recorded. Text initials or generated marks are temporary implementation scaffolds, not the final product surface, unless no real mark exists after search.
10. For app-owned icons and store metadata, choose the model/tool intentionally after checking available local/API options. Generate or edit the asset only after the reference pattern is clear, then verify the built app bundle uses the asset and the public metadata changed.
11. Verify on the actual surface, not a proxy: screenshot or inspect the live page, run typecheck/lint/build, verify responsive wrapping, and for App Store/TestFlight work confirm the processed uploaded build or current App Store Connect fields.

## Gotchas

- A reference list is not proof you read references. Summarize the pattern you observed before changing the product.
- Public names, subtitles, category labels, and pricing bullets are user psychology surfaces. They should not expose internal architecture, debugging shorthand, or implementation limits unless that is the sellable benefit.
- Model/tier picker labels and descriptions are product positioning copy. Read peer pickers first, then map internal model capability into short task-language; do not ship backend/provider metadata or vague filler like "needs more care."
- If the product has plan constants, copy should be generated from or checked against them so the page cannot promise more or less than the runtime enforces.
- Store review metadata is downstream of the in-app purchase path. A screenshot that matches pricing is not proof the app can select or buy that plan.
- Provider-choice rows are brand-recognition surfaces. A `GPT` label, single letter, or hand-drawn approximation reads as unfinished next to real Claude, Gemini, ChatGPT, or Grok marks.
- Prompt references can be examples, not requested copy. When the user says another app's prompt is inspiration, preserve the product's own voice and data contract instead of either inventing an unrelated prompt or pasting the provider's exact wording.
- A provider import dialog is still an app dialog. Start from the repo's default dialog component; a custom wide modal or cloned competitor layout is scope creep unless the user asked for that surface.
- A generated visual can be worse than a clean existing glyph if the prompt is not grounded in the app identity and peer icon language.

## Verification

- Positive trigger: "Read ChatGPT, Claude, Manus, and Perplexity pricing and fix our pricing cards."
- Positive trigger: "Read Plaud/Granola/Pocket and fix our TestFlight name, category, and icon."
- Positive trigger: "Fix the model picker wording; how do Claude or ChatGPT describe these tiers?"
- Positive trigger: "The settings import row needs ChatGPT, Claude, Gemini, and Grok logos instead of placeholder text."
- Positive trigger: "Use Claude and Gemini's import prompts as inspiration for our memory import dialog."
- Positive trigger: "Before uploading App Store subscription screenshots, check that the iOS paywall actually opens the selected plan."
- Near miss: "Change the backend limit for automations from 10 to 20" with no UI/store/pricing surface.

## Sources

- Failure transcript: `/Users/advaitpaliwal/.codex/attachments/5d18711c-7e59-4273-ab64-57108730cc2b/pasted-text.txt`.
- Failure transcript: `/Users/advaitpaliwal/.codex/attachments/2c7c786c-b08a-48ad-ac5e-e5b78c7b47c7/pasted-text.txt`.
- Failure transcript: `/Users/advaitpaliwal/.codex/sessions/2026/06/13/rollout-2026-06-13T12-54-35-019ec28c-eaa1-79d2-a821-aca87b3209e1.jsonl` lines 1207-1250 — agent changed model-tier copy from intuition, then the user pointed at Claude's model picker and asked why the product did not use that pattern.
- Classifier wake event transcript: `/Users/advaitpaliwal/.codex/sessions/2026/06/18/rollout-2026-06-18T09-49-03-019edba2-d988-7132-92c5-e48959f87980.jsonl` lines 3432-3468 — agent used text placeholders for ChatGPT/Grok in a settings provider row until the user pointed out it should search the internet for logos.
- Classifier wake event transcript: `/Users/advaitpaliwal/.codex/sessions/2026/06/18/rollout-2026-06-18T09-49-03-019edba2-d988-7132-92c5-e48959f87980.jsonl` lines 3767-3783 — agent overfit and underfit the Claude/Gemini prompt references before the user clarified that they were inspirations for a Companion-owned import prompt.
- Classifier wake event transcript: `/Users/advaitpaliwal/.codex/sessions/2026/06/18/rollout-2026-06-18T18-31-09-019edd80-d9c6-71d1-a99a-557fa117e0ee.jsonl` lines 4768-4857 — agent prepared App Store subscription review screenshots before proving the iOS paywall had a selected-plan purchase path.
- Skill format and routing rules: `skills/skill-creator/references/source-map.md`.
