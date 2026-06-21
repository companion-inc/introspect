---
name: visual-asset-remaster
description: Remaster, upscale, or rebuild visual assets and sprite packs with image/upscale/edit APIs. Use when improving pixelated images, choosing GPT/Gemini/Fal/Flux/Topaz/Aura/ESRGAN-style providers, preserving transparent backgrounds, building contact-sheet batches, or generating a production asset pack. Not for ordinary UI component styling or one-off standalone image generation.
---

# Visual Asset Remaster

## When This Fires

Use this for image or animation asset work where quality depends on model choice, prompt strategy, alpha handling, or batch generation: pixelated mascots, sprite sheets, app icons, logo cleanup, transparent PNGs, upscaling, image edits, background removal, contact-sheet batching, and repacking assets into a runtime format.

Near misses: use `ui-component-polish` for UI layout/styling, `product-surface-polish` for store/pricing/marketing surfaces, and the built-in image generation flow for a single new image that does not need preservation, batching, or runtime integration.

## Procedure

1. Pin the asset contract before touching pixels: source files, renderer/consumer, expected dimensions, frame count, transparency rules, animation names/timing, and the exact visual qualities that must not change.
2. Find the best source first. Search local files, repo history, archives, and public originals when the user asks for provenance; compare per-frame detail, not just total canvas size.
3. Retrieve and validate provider credentials through `local-secret-retrieval` when API calls are needed. A key's presence is not enough; run the smallest provider call that proves it works, without printing secret values.
4. Build a hard-case pilot matrix before a full batch. Infer acceptance criteria from the asset contract and the visible failure instead of asking the user to define obvious quality metrics. Use representative difficult assets: tiny eyes, thin lines, overlapping props, hands/wires/text, edge transparency, and any animation frames where drift is obvious. Include local baselines, true upscalers, image-edit/generative models, background-removal/matte options, and prompt/control variants.
5. Treat "upscale" and "image edit/generation" as different hypotheses. True upscalers preserve identity but may smooth detail; edit/generation models can sharpen or beautify while moving geometry. Test both when quality demands it, then pick from evidence.
6. Handle transparency deterministically. Inspect actual alpha channels; PNG output alone does not prove transparency. Do not send white matte into the final pipeline. Use filled RGB under transparent pixels, green/blue/chroma backgrounds, background removal, or original masks as experiments, then choose the final alpha source from measured/visual evidence.
7. Judge with visual boards, not vibes. Make before/after boards, focused crops for the failure feature, alpha/checker previews, and per-animation review sheets. Metrics such as alpha IoU or pixel diff are secondary; reject outputs that preserve a number while moving eyes, silhouette, props, or timing.
8. Scale only after the pilot passes. Checkpoint provider outputs, record provider/model/settings/prompt in the manifest, and prefer one-by-one generation when quality review matters more than throughput.
9. Verify in the real runtime. Repack into the actual asset format, run structural tests/builds, launch or render through the consumer, inspect snapshots on transparent and real backgrounds, and review every animation or a per-animation board before calling the asset done.

## Gotchas

- A single pretty pose is a trap; animation quality fails on hard frames and frame-to-frame drift.
- "Which model is best?" means run the evidence matrix; it is not a reason to hand metric selection back to the user.
- Checkerboards are preview surfaces, not asset backgrounds.
- Background removal fixes alpha, not line quality. Line quality comes from the chosen enhancer/edit path.
- A structural verify proves references and dimensions, not visual quality.
- Provider/model names, schemas, and options turn over quickly. Read current docs or live schemas before naming a winner.
- Do not overwrite the known-good production asset until the replacement has passed the pilot and runtime preview, unless the user explicitly asks for a loud failing state.

## Verification

- Positive trigger: "This sprite is pixelated; use GPT/Gemini/Fal/Flux/Topaz and rebuild the HD pack."
- Positive trigger: "Make this transparent PNG cleaner without changing the character."
- Positive trigger: "Compare image generation/edit APIs for remastering these animation frames."
- Near miss: "Restyle this settings dropdown to look less ugly" with no image asset generation or preservation requirement.

## Sources

- Internal failure pattern: a one-frame remaster looked promising, but full batches exposed alpha/style failures; prompt/provider matrices on hard frames made the later model choice reliable.
- Skill format and placement: `skills/skill-creator/references/source-map.md`.
- Agent Skills specification: https://agentskills.io/specification
- OpenAI Codex Skills docs: https://developers.openai.com/codex/skills
