---
name: ui-component-polish
description: Restyle or build an in-app UI component (inputs, chips/tags, tabs, comboboxes, cards, dialogs, chat/message surfaces) by first identifying the right component archetype, reading real reference implementations, matching their concrete details and edge states, then verifying by viewing the rendered component. Use when the user calls a component ugly, off, or wants it to look like a real app or library. Not for marketing/pricing/store copy (use product-surface-polish) or component logic bugs.
---

# UI Component Polish

## Use When

- The user calls an in-app component ugly, awkward, broken, or "not like X," or asks to restyle one to feel like a real app or library.
- You are building or restyling a functional component: text/tags input, chips, tabs, combobox, select, card, dialog, list row.
- A component "looks wrong" in a specific way: detached boxes, lingering placeholder, wrong chip proportions, force-wrapping, bad spacing, an oversized input ringed by dead space, or message bubbles that don't grow with their content.

Near miss — do not load this for:
- Pricing cards, paywalls, App Store/onboarding/marketing copy and visuals → `product-surface-polish`.
- A component throwing or behaving wrong logically (empty-options crash, bad state) → that is a logic bug, not visual polish.

## Procedure

0. **Scope the change to exactly what was asked.** If the user names one dimension ("make it bigger", "more padding", "move it left"), change only that and keep the element's existing archetype, structure, and design tokens — its tabs, highlight/accent color, border, radius. "Make it bigger" is not license to restyle: do not swap a bordered tabs toggle for a circular rounded-pill, drop the highlight color, or re-vibe the control. When the target is an already-built element, its own current implementation is the first reference you read — match those tokens before any external library. Only do a full restyle when the user actually asks the component to look different.
1. **Identify the archetype before styling.** Match the use case to its canonical real-world pattern, not the user's loose word:
   - free-text, multiple arbitrary values → tags input (Gmail "To" field is canonical).
   - pick one from a known list → combobox / select.
   - switch between mutually-exclusive views → tabs.
   - back-and-forth conversation → chat/message UI (iMessage, ChatGPT, Claude are canonical): a compact input that grows with its content, the message and any thinking rendered inside the bubble, longer history behind an expand affordance — not a fixed oversized input box surrounded by empty space. Reason about the interaction (where the message goes, how the bubble grows, what the default state shows) before placing elements; shipping a default layout without that thinking is what reads as "why are you not thinking."
   If the user says "tabs" or "combobox" but the data doesn't fit, say so and name the right archetype with its reference.
2. **Read real reference implementations before writing any styles — never from memory.** Read at least two or three:
   - First the component library the repo already uses — open the installed component source (e.g. `src/components/ui/*.tsx` for shadcn), not just the docs.
   - Then polished public examples for that archetype (shadcn, diceui, emblor, originui, or the actual app the user named). Pull the GitHub source when docs are thin.
   Extract concrete values: chip height/radius/padding, container layout, where the input sits, and edge-state behavior.
3. **Match the concrete details, including edge states.** Common real-component behaviors the user notices when missing: placeholder hides once values exist; chips do not force-wrap to a second line; a locked/pinned value renders as a chip inside the field, not a detached gray box above it; remove targets are tappable.
4. **Verify by viewing the rendered component, not by lint/typecheck.** Run the app or the screen and look at it empty, with one value, with many, and overflowing. Lint and typecheck are necessary but prove nothing about how it looks. State that you actually viewed the render.

## Gotchas

- "Ugly" almost always points at a specific deviation from real components — find that exact mismatch (detached box, lingering placeholder, wrong proportions, wrap) instead of re-vibing the whole component.
- The repo's own component library is the first reference, not the last. Read the installed component before fetching external sites.
- Lint/typecheck passing is not visual verification. The user is looking at pixels; so must you before claiming it is fixed.
- A scoped request ("make it bigger") that comes back as a restyle reads as "you ignored me." Preserve the existing look and change only the named dimension; if you think a fuller restyle is warranted, say so and ask rather than shipping it.

## Verification

- Positive trigger: "this tags input is ugly, why doesn't it look like Gmail/tabs" → identify archetype, read references, match details, view the render.
- Near miss: "make the pricing card feel like ChatGPT's" → `product-surface-polish`.
- Near miss: "the combobox crashes when options is empty" → logic bug, not this skill.

## Sources

- Failure transcript: `/Users/advaitpaliwal/.claude/projects/-Users-advaitpaliwal-Companion-Code-companion/27cc8906-5c23-4031-a842-0148eba719f1.jsonl` — agent restyled a tags-input from memory (user: "DID YOU NOT READ EXAMPLES ONLINE"), then verified with lint/typecheck instead of viewing it ("I hadn't yet looked at it in the browser" → user: "fucking fix"). Same session later: "why are they fucking circular did you not read tabs and shit and how its done wheres the border and stuff" — agent reinvented an existing tabbed control as a borderless circular shape instead of matching the app's own tabs.
- Scope-overreach failure: `/Users/advaitpaliwal/.claude/projects/-Users-advaitpaliwal-Companion-Code-companion/1292b255-a0ce-469e-8700-8cfbfdeeb45d.jsonl` — user asked to make a billing-cycle toggle bigger; agent restyled it into an `h-12 rounded-full` pill, dropping the existing tabs pattern and highlight color (user: "why did you change styling i literally said make it bigger ... why did yo not use the highlight color and the fucking tabs").
- Chat-layout failure: `/Users/advaitpaliwal/.claude/projects/-Users-advaitpaliwal-Companion-Code-clippy/f2e329d4-ec2b-4967-b065-49cd7c1a9495.jsonl` (same message also in the `clawd` repo) — agent built a chat surface with a large fixed input and lots of empty space, two bubbles that didn't grow, instead of grounding it in real chat apps (user: "why do u have a large input instead of small ... so much empty space instead of letting the speech bubble grow ... why dont u ... show thinking in the same bubble ... why are you not thinking").
- AGENTS.md invariant this scopes: "When imitating any style or voice — visual, prose, tone, code idiom — fetch and actually take in the real material across several examples and match what you observe, never reconstruct it from memory."
- Reference component libraries observed in the transcript: shadcn/ui (installed `src/components/ui/input-tags.tsx`), diceui tags-input, emblor, originui.
