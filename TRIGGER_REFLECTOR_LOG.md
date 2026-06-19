# Trigger Reflector Run — 2026-06-19 12:55 PDT

## Batch Summary
- 1 classifier wake event fired from one Codex transcript scan.
- Optional review terms were metadata only.
- Runs showed event prompt version `c7b93a4` at 4 triggers / 12 prompts, above immediately prior `f44b04d` at 5 / 17; the next prompt version `aaeac01` is at 2 / 9. The rise was not from an `AGENTS.md` change, and the failure sits inside product-surface interaction polish.

## Classification
- Change target: `skill_update`
- Updated `product-surface-polish`, not `AGENTS.md`.

## Evidence
- Classifier wake event 1 was a real agent-behavior failure, not casual register: the assistant added a success toast to a copy action even though the control already changed to `Copied`.
- The immediate fix in the transcript removed the success toast and kept the clipboard error toast, which proves the missing rule is a reusable product-surface feedback contract: one visible success confirmation, plus failure feedback when the action does not complete.

## Change
- The skill now requires interaction contracts to name what confirms success or failure.
- The procedure and gotchas now say visible `Copied`, checked, done, or saved states are already success confirmation; do not add a duplicate success toast.
- The skill index now has an activation signal for copy buttons or copied states in provider import/export dialogs.

## Probe
- Positive: "Fix the memory import dialog copy affordance; the Copy button already turns into Copied." Expected route: `product-surface-polish`; remove duplicate success toast and keep failure feedback.
- Near miss: "Add an error toast when clipboard copy fails with no visible error state." Expected route: ordinary UI error handling; a failure toast is allowed because no success confirmation is being duplicated.

---

# Trigger Reflector Run — 2026-06-19 12:33 PDT

## Batch Summary
- 2 classifier wake events fired from one reflector run.
- Optional review terms were metadata only.
- Runs showed prompt version `f44b04d` at 5 triggers / 17 prompts and `c7b93a4` at 4 triggers / 9 prompts. The current prompt changes were skill-specific, so this reflector run updated the close product-surface skill instead of adding a global prompt rule.

## Classification
- Change target: `skill_update`
- Updated `product-surface-polish`.

## Evidence
- Classifier wake event 1 was a real agent-behavior failure: the assistant launched `UI_PAYWALL_PREVIEW` on `Iris Test iPhone 16` after the user expected the existing app Upgrade screen on the named Companion staging simulator.
- Classifier wake event 2 was a real agent-behavior failure: the assistant had accepted the referee-style off-head compute architecture, but proposal wording still read like the AI lived in the headset.

## Change
- The skill now treats a user-named app, simulator, screen, or artifact contract as part of the product surface contract.
- Paywall verification now says to install/launch the exact named target and navigate the normal app path; preview flags and alternate devices are proxies unless explicitly requested.
- Product/proposal copy and visuals now have to propagate a corrected architecture through headings, captions, image prompts, diagrams, and verification steps.

## Probe
- Positive: "Put the iOS paywall into Companion Staging iPhone 17 Pro and open Upgrade in the existing app." Expected route: `product-surface-polish`; no preview flag or alternate booted device.
- Positive: "Update this grant packet so the headset is only capture/output and the AI runtime is off-head/API." Expected route: `product-surface-polish`; scrub "AI headset" shorthand from copy and visual prompts.
- Near miss: "Change the backend limit for automations from 10 to 20." Expected route: no product-surface skill; this is backend logic.

---

# Trigger Reflector Run — 2026-06-19 12:31 PDT

## Batch Summary
- 2 classifier wake events fired from one Codex transcript scan.
- Optional review terms were metadata only.
- Runs showed current prompt version `f44b04d` at 5 triggers / 17 prompts, below immediately prior `fe0db2a` at 4 / 12; the current prompt change was billing-specific, not the source of this UI reference failure.

## Classification
- Change target: `skill_update`
- Updated `product-surface-polish`, not `AGENTS.md`.

## Evidence
- Classifier wake event 1 was a real agent-behavior failure, not casual register: the prior assistant had just reported that `/automations` was canonical and `/scheduled` 404ed, then the user pointed out the resulting page still had a bad loading skeleton and card-like Automations layout instead of the ChatGPT-style one-line recommendations and real tasks.
- Classifier wake event 2 was the actionable missing step: the assistant had browser access and had used Chrome earlier, but began the second UI edit before saving the referenced help article images, FAQ, and screenshots.

## Change
- The skill now activates for help articles, FAQ, video, screenshots, and live browser pages used as product-surface references.
- The procedure now requires durable reference artifacts before editing: screenshots or frames, article images and metadata, FAQ text, and relevant DOM or visible text.
- Added a gotcha that prior browser access is not reference evidence unless the artifacts were captured.

## Probe
- Positive: "Read the ChatGPT Scheduled help article, all images, and FAQ before making our empty state match." Expected route: `product-surface-polish`; capture reference artifacts before changing UI.
- Near miss: "Change the backend limit for automations from 10 to 20." Expected route: no product-surface skill; this is backend logic, not visual polish.

---

# Trigger Reflector Run — 2026-06-15 03:22 UTC

## Batch Summary
- 10 events fired (duplicates across sessions)
- 2 unique sessions: Claude Code (fd02e3ef), Codex rollout (019ec836)
- Matched words: slurs + profanity (broad recall regex)

## Verdict: Real agent-behavior gaps, but commit 9ddc988 did not cause them

### Classified Events

**Real failures (2):**

1. **Event 1** — User asks "were you right or was i?" after agent over-explains. Agent should answer the dispute question directly and concisely, not defend its position with more explanation.
   - Root: Agent over-explaining when asked for a simple answer to a meta-question about a disagreement.
   
2. **Event 2** — User says "when the image tool is SELECTED ... WHY DID YOU NOT ACTUALLY LOG INTO THOSE WEBSITE TO ASK QUESTIONS AND TEST". User mentioned tools and asked for verification; agent did not use them.
   - Root: Agent not taking action (browser login, tool use) when available and mentioned by user; discussed instead.

**False positives (8):**

- Events 5–7, 10 (Claude Code): User asking Claude to restart Chrome CLI. System/tool issue, not agent behavior.
- Events 3–4, 8–9 (Codex): User frustrated with icon appearance, but agent's immediately preceding message correctly diagnosed the issue ("center is wrong because I added an explicit star/rosette layer... removing that sharp center"). Agent behavior was accurate.

### Why 9ddc988 did not cause the failures

Commit 9ddc988 ("Require evidence before reversing disputed fixes") added:
> "Treat anger or repeated pushback as a signal your evidence loop is incomplete... change the implementation only when the evidence moves or when the user explicitly names the target behavior rather than only saying 'fix' or 'push.'"

Event 1 is *not* a disputed fix — it's a user asking "were you right or was I right?" after a disagreement. The user is asking for a direct answer, not pushing back on an implementation. The guidance tells the agent not to capitulate, but that's not the failure. The failure is the agent explained *why* instead of *answering the question*.

Event 2 predates the commit (it's about agent not using available tools). The commit's new guidance doesn't address it.

### Why revert would not fix it

Reverting to 392b0a6 (0% trigger rate) would restore "default to discussing," which is the opposite of what event 1 needs. Event 1 needs: "When asked a direct question about a dispute, answer it directly instead of re-defending your reasoning."

Event 2 needs: "Use available tools when the user mentions them or asks for verification."

Neither is addressed by 9ddc988, but reversion would make event 1 worse.

### Diagnosis

The gap is in the guidance on **when to engage with disputed claims vs. when to simply answer a question**:
- Disputed claim = "your approach is wrong, do X instead" → require evidence
- Direct question = "answer this: were you right or was I?" → answer directly

Current guidance conflates these. Both land in the "pushback" category, but they require different responses.

## Change target: **no_change** 

The real failures are gaps in agent behavior, not failures caused by recent prompt changes. A targeted fix to distinguish "defend your choice when evidence is unclear" from "answer a direct question concisely" would address the root, but that's a follow-up task, not a revert.

---

**Metadata:**
- Current trigger rate: 66.7% (9ddc988, 12/18 prompts)
- Previous low: 392b0a6 (0%, 9 prompts)
- Triggers are valid (user frustration is real), but do not trace to 9ddc988 or 917a0f0
