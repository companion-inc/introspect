---
name: product-surface-polish
description: Polish user-facing product surfaces such as pricing pages, plan cards, feature pages, grant/application packets, navigation rows, empty states, model/settings pickers, provider import/export prompts, provider logos, App Store/TestFlight metadata, icons, categories, onboarding, and marketing UI by reading real reference products and the product's enforced source of truth before writing copy, visuals, or interaction structure.
---

# Product Surface Polish

## Use When

- Editing pricing pages, plan cards, upgrade/paywall screens, feature lists, in-app feature pages, navigation rows, empty states, model pickers, settings copy, App Store metadata, TestFlight metadata, app icons, product categories, onboarding, or marketing UI.
- A product/settings surface names third-party providers or tools and needs their logos, brand marks, icons, or provider-choice affordances.
- A product/settings surface uses another AI's import/export prompt, dialog, or onboarding flow as a reference for the product's own prompt or flow.
- The user points at reference products and asks for the surface to feel similar, bigger, cleaner, more premium, simpler, or less awkward.
- Editing a grant, application, or submission packet where the funder's required materials, page limits, applicant type, budget rules, or optional award resources define the artifact.
- The reference arrives through a help article, FAQ, video, screenshot, or live browser page, and the product surface depends on its layout, copy, or interaction pattern.
- The user names a real app, device, screen, or artifact contract for a product surface, such as an existing app Upgrade screen or a specific simulator.
- Product or proposal copy/visuals need to preserve a user-corrected architecture, runtime split, or reference shape.
- Copy includes internal terms, vague feature claims, filler benefits, or numbers that may drift from enforced plan limits.

Near miss: do not load this for backend-only billing logic unless a user-visible product surface is being changed.

## Procedure

1. Name the exact surface and audience: store listing, home-screen app identity, pricing page, locked paywall, onboarding, model picker, grant packet, or in-app settings. If the user named a real app path, device, screen, or artifact contract, include that in the surface contract before acting.
2. For grant/application/submission packets, read the official application page and write the artifact contract before drafting: required attachments, page limits, budget requirements, applicant category, deadline, submission email/form, and selection criteria. Keep sidecar award resources such as credits, access, support, or provider APIs out of the proposal thesis and section structure unless the application asks for them or the user explicitly asks to feature them.
3. Read the real references the user named, plus the closest direct competitors when the user asks "how do others do it." For browser, help-article, FAQ, video, or screenshot references, save and read durable artifacts before editing: full-page screenshots or frames, article images and metadata, FAQ text, and the relevant DOM or visible text. Extract the pattern in concrete terms: naming formula, navigation placement, icon choice, subtitle placement, empty versus populated state, primary creation affordance, example prompts or rows, card/list hierarchy, feature taxonomy, spacing, and responsive behavior.
4. Classify each reference's role before implementing: verbatim source to copy, inspiration to synthesize from, or interaction/component behavior to match. For behavior to match, write the interaction contract before changing code: what the empty state invites, where input lives, which examples appear, how the layout changes once data exists, and what confirms success or failure. Use one success confirmation; when the pressed control visibly changes to `Copied`, a checkmark, or another done state, do not add a duplicate success toast. Copy provider prompt text verbatim only when the user asks for copying; when provider prompts are examples of how another app extracts/imports data, write one product-owned prompt shaped by the pattern instead. When the user corrects the product architecture, runtime location, or reference object, propagate that correction through headings, captions, image prompts, diagrams, and verification steps before generating more artifacts.
5. Read the product source of truth before writing copy: plan constants, enforced quotas, billing config, app metadata, bundle settings, feature gates, and current screenshots. A pricing claim must trace to code or config; store metadata must trace to App Store Connect or bundle settings.
6. For subscription or paywall work, prove the in-app purchase path before store-review artifacts: inspect the paywall code/config, product IDs, selected-plan params, StoreKit/Superwall wiring, and a real simulator/device screenshot or flow. If the user named an existing app, simulator, or screen, install/launch that exact target and navigate the normal app path; a preview flag, standalone fixture, or different booted device is a proxy unless the user explicitly asked for it. Do not upload App Store review screenshots or polish subscription metadata while the app only has static cards or an unproven trigger.
7. Translate internal capability into user language. Remove engineering phrases and filler such as "tool-heavy," "model context window," "standard usage," "switch anytime," or "add more credits anytime" unless the reference products and product truth make them genuinely meaningful.
8. For tiered pricing, make progression visible from low to high: more quota, broader capability, clearer support/access. Keep duplicated roll-up lines short, avoid unlimited claims unless the runtime actually enforces no limit, and align cards across desktop and medium-width layouts.
9. For provider import/export dialogs, use the app's existing standard dialog and controls first. Custom sizing, typography, or cloned competitor chrome needs a concrete reason from the reference pattern and the local design system.
10. For third-party provider logos, search current web, vendor, and public icon sources before inventing a mark. Prefer official brand kits or established public SVG icon packages; keep the resulting asset local in the app with its source recorded. Text initials or generated marks are temporary implementation scaffolds, not the final product surface, unless no real mark exists after search.
11. For app-owned icons and store metadata, choose the model/tool intentionally after checking available local/API options. Generate or edit the asset only after the reference pattern is clear, then verify the built app bundle uses the asset and the public metadata changed.
12. Verify on the actual surface, not a proxy: screenshot or inspect the live page, run typecheck/lint/build, verify responsive wrapping, and for referenced interaction models verify the relevant states that define the pattern, not only that the route renders. For App Store/TestFlight work confirm the processed uploaded build or current App Store Connect fields.

## Gotchas

- A reference list is not proof you read references. Summarize the pattern you observed before changing the product.
- Prior browser access is not durable reference evidence. If the UI decision depends on screenshots, FAQ text, article images, or a live page, capture those artifacts before the first edit.
- Copying a reference's labels, icon, or route is not enough. For feature pages, the creation path, empty-state examples, placement of the input, and transition to the populated state are part of the product pattern.
- Public names, subtitles, category labels, and pricing bullets are user psychology surfaces. They should not expose internal architecture, debugging shorthand, or implementation limits unless that is the sellable benefit.
- Model/tier picker labels and descriptions are product positioning copy. Read peer pickers first, then map internal model capability into short task-language; do not ship backend/provider metadata or vague filler like "needs more care."
- If the product has plan constants, copy should be generated from or checked against them so the page cannot promise more or less than the runtime enforces.
- Store review metadata is downstream of the in-app purchase path. A screenshot that matches pricing is not proof the app can select or buy that plan.
- Preview flags, generated concept renders, and proposal shorthand are proxies. Replace them with the named real surface or corrected architecture before claiming the product artifact is fixed.
- Award-side resources are not automatic proposal sections. A funder mentioning credits, model access, support, or an API in the award announcement does not mean the application asks for a credits plan, API plan, or provider-centered thesis.
- Provider-choice rows are brand-recognition surfaces. A `GPT` label, single letter, or hand-drawn approximation reads as unfinished next to real Claude, Gemini, ChatGPT, or Grok marks.
- Prompt references can be examples, not requested copy. When the user says another app's prompt is inspiration, preserve the product's own voice and data contract instead of either inventing an unrelated prompt or pasting the provider's exact wording.
- A provider import dialog is still an app dialog. Start from the repo's default dialog component; a custom wide modal or cloned competitor layout is scope creep unless the user asked for that surface.
- Success toasts are not free polish. If the control itself flips to `Copied`, checked, done, or saved, that is the confirmation; keep toast/banner feedback for errors or background outcomes that otherwise have no visible state.
- A generated visual can be worse than a clean existing glyph if the prompt is not grounded in the app identity and peer icon language.
- Labels such as "AI headset" can silently reintroduce the wrong architecture after a correction to off-head, phone, pocket, edge, cloud, or API runtime. Scrub titles and captions, not only body paragraphs.

## Verification

- Positive trigger: "Read ChatGPT, Claude, Manus, and Perplexity pricing and fix our pricing cards."
- Positive trigger: "Read Plaud/Granola/Pocket and fix our TestFlight name, category, and icon."
- Positive trigger: "Fix the model picker wording; how do Claude or ChatGPT describe these tiers?"
- Positive trigger: "The settings import row needs ChatGPT, Claude, Gemini, and Grok logos instead of placeholder text."
- Positive trigger: "Use Claude and Gemini's import prompts as inspiration for our memory import dialog."
- Positive trigger: "Fix the memory import dialog copy affordance; the Copy button already turns into Copied."
- Positive trigger: "Before uploading App Store subscription screenshots, check that the iOS paywall actually opens the selected plan."
- Positive trigger: "Put the iOS paywall into Companion Staging iPhone 17 Pro and open Upgrade in the existing app."
- Positive trigger: "Read the ChatGPT Scheduled help article, all images, and FAQ before making our empty state match."
- Positive trigger: "Update this grant packet so the headset is only capture/output and the AI runtime is off-head/API."
- Positive trigger: "Fix this Thinking Machines grant packet; Tinker credits are optional and the application wants the interactivity proposal materials."
- Near miss: "Change the backend limit for automations from 10 to 20" with no UI/store/pricing surface.

## Sources

- Failure transcript: `/Users/advaitpaliwal/.codex/attachments/5d18711c-7e59-4273-ab64-57108730cc2b/pasted-text.txt`.
- Failure transcript: `/Users/advaitpaliwal/.codex/attachments/2c7c786c-b08a-48ad-ac5e-e5b78c7b47c7/pasted-text.txt`.
- Failure transcript: `/Users/advaitpaliwal/.codex/sessions/2026/06/13/rollout-2026-06-13T12-54-35-019ec28c-eaa1-79d2-a821-aca87b3209e1.jsonl` lines 1207-1250 — agent changed model-tier copy from intuition, then the user pointed at Claude's model picker and asked why the product did not use that pattern.
- Classifier wake event transcript: `/Users/advaitpaliwal/.codex/sessions/2026/06/18/rollout-2026-06-18T09-49-03-019edba2-d988-7132-92c5-e48959f87980.jsonl` lines 3432-3468 — agent used text placeholders for ChatGPT/Grok in a settings provider row until the user pointed out it should search the internet for logos.
- Classifier wake event transcript: `/Users/advaitpaliwal/.codex/sessions/2026/06/18/rollout-2026-06-18T09-49-03-019edba2-d988-7132-92c5-e48959f87980.jsonl` lines 3767-3783 — agent overfit and underfit the Claude/Gemini prompt references before the user clarified that they were inspirations for a Companion-owned import prompt.
- Classifier wake event transcript: `/Users/advaitpaliwal/.codex/sessions/2026/06/18/rollout-2026-06-18T18-31-09-019edd80-d9c6-71d1-a99a-557fa117e0ee.jsonl` lines 4768-4857 — agent prepared App Store subscription review screenshots before proving the iOS paywall had a selected-plan purchase path.
- Classifier wake event transcript: `/Users/advaitpaliwal/.codex/sessions/2026/06/18/rollout-2026-06-18T23-29-19-019ede91-d20b-7ed3-a87a-76cd0f6178fa.jsonl` lines 424-425 and 3053-3072 — agent extracted and browser-tested ChatGPT Scheduled, then copied naming/routing while missing the empty-state composer, examples, and creation-first interaction model.
- Classifier wake event transcript: `/Users/advaitpaliwal/.codex/sessions/2026/06/18/rollout-2026-06-18T23-29-19-019ede91-d20b-7ed3-a87a-76cd0f6178fa.jsonl` lines 6363-6441 — agent shipped `/automations` and a card/list mismatch after prior ChatGPT Scheduled research, then began a second UI edit before saving the referenced help article images, FAQ, and Chrome screenshots.
- Classifier wake event transcript: `/Users/advaitpaliwal/.codex/sessions/2026/06/19/rollout-2026-06-19T08-57-14-019ee099-c668-7c00-91d9-adaf660ce6c1.jsonl` lines 3163-3214 — agent launched a paywall preview on the wrong booted simulator after the user expected the existing app Upgrade screen.
- Classifier wake event transcript: `/Users/advaitpaliwal/.codex/sessions/2026/06/19/rollout-2026-06-19T09-25-23-019ee0b3-8c6d-7df0-93c2-285ff22aacfe.jsonl` lines 1254-1298 — agent kept "AI headset" wording in proposal artifacts after the user corrected the architecture to off-head compute.
- Classifier wake event transcript: `/Users/advaitpaliwal/.codex/sessions/2026/06/19/rollout-2026-06-19T09-25-23-019ee0b3-8c6d-7df0-93c2-285ff22aacfe.jsonl` lines 1474-1508 — agent turned optional Tinker credits/API language into proposal scope before rereading the application requirements.
- Classifier wake event transcript: `/Users/advaitpaliwal/.codex/sessions/2026/06/19/rollout-2026-06-19T11-55-38-019ee13d-1a47-7fc3-9c7a-b6fae2e6b994.jsonl` lines 357-374 — agent added a success toast to a copy action even though the button already changed to `Copied`; the fix removed the redundant success toast and kept the clipboard error toast.
- Skill format and routing rules: `skills/skill-creator/references/source-map.md`.
