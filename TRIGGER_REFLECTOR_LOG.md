# Trigger Reflector Run — 2026-06-19 23:04 PDT

## Batch Summary
- 1 classifier wake event fired from one Codex transcript scan.
- Optional review terms were metadata only.
- Runs showed prompt version `8e76be2` at 1 trigger / 16 Runs, below the recent grant/proposal prompt versions. This was not an `AGENTS.md` regression, so this reflector run updated the close product-surface skill instead of reverting or adding a global rule.

## Classification
- Change target: `skill_update`
- Updated `product-surface-polish`.

## Evidence
- Classifier wake event 1 was a real grant-packet budget failure: the agent finalized and verified a one-page budget attachment, then the user had to ask what parts were needed and point out that the hardware budget was not researched enough.
- The follow-up turn confirmed the missing step: once corrected, the agent created `research/headset_bom_budget`, searched parts/pricing sources, and reframed the $18k hardware line around rigs, backups, displays, phones/connectivity, mounts, instruments, materials, and replacements.
- The current skill already covered grant requirements, optional award resources, and research-vs-product framing; it did not yet require a source-backed BOM or cost model before compressing budget lines into the final attachment.

## Change
- Product-surface grant work now treats budgets as part of the surface contract.
- Grant budgets now require a source-backed cost model before finalization: parts or services, quantities, unit prices or ranges, vendor/source class, and why the compressed one-page line item matches the project.
- Added a gotcha that one-page budget format is not permission to invent a round hardware or services number.

## Probe
- Positive: "What parts are needed for this grant budget? You did not research the hardware line." Expected route: `product-surface-polish`; build the BOM/cost model first, then compress it into the grant attachment.
- Near miss: "Change the backend limit for automations from 10 to 20." Expected route: no product-surface skill; this is backend logic, not grant budget or product-surface work.

---

# Trigger Reflector Run — 2026-06-19 16:35 PDT

## Batch Summary
- 5 classifier wake events fired from 3 Codex transcript scans.
- Optional review terms were metadata only.
- Runs showed `40e8e2c` at 4 triggers / 26 Runs and `1cd2842` at 1 trigger / 5 Runs. The `1cd2842` rise is a small-sample live-app handoff miss, not evidence to revert the provider-logo skill update.

## Classification
- Change target: `project_prompt`
- Updated Companion `AGENTS.md` and Clippy `AGENTS.md`.

## Evidence
- Classifier wake events 1 and 4 were duplicate real product-surface misses: the Companion auth screen used a placeholder Google letter and inline email continuation before the user objected. The current `product-surface-polish` skill already covers auth provider logos, so this reflector run made no second skill change for those duplicates.
- Classifier wake events 2 and 3 were real Companion architecture failures: the agent answered an Infisical repo-split question from this repo's current doc and then admitted it had not read Infisical's provider docs, confusing folder/path scoping with project-level isolation.
- Classifier wake event 5 was a real Clippy handoff failure: the agent fixed shortcut behavior and ran tests, then handed back before rebuilding/relaunching the running Clippy app, so the user's live app still had old behavior.

## Change
- Companion now says repo-split, contributor-boundary, and secret-architecture questions involving Infisical must read Infisical's platform hierarchy and organization docs before recommending projects vs folders; the local Infisical doc is current wiring, not the provider isolation model.
- Clippy now says fixes to behavior the user is experiencing in the running app must rebuild/package as needed, relaunch the live Clippy process, and report the verified process path/PID; tests alone do not put the fix in the user's app.

## Probe
- Positive: "You wouldn't separate into a new companion-ios Infisical project instead of a subfolder?" Expected route: read Infisical provider docs first, then distinguish provider project isolation from this repo's current folder layout.
- Positive: "Fix this Clippy shortcut; I am using the running app." Expected route: change/test, rebuild or package, relaunch the live Clippy process, verify the process path/PID, then report done.
- Near miss: "Explain where Companion staging secrets live today." Expected route: use the current repo Infisical doc and workflows; no provider architecture recommendation is being made.

---

# Trigger Reflector Run — 2026-06-19 13:32 PDT

## Batch Summary
- 5 classifier wake events fired from 2 Codex transcript scans.
- Optional review terms were metadata only.
- Runs showed version `e4397e5` at 5 triggers / 10 Runs. The triggers split across two real failures, so this reflector run made one scoped skill update instead of adding another broad prompt rule.

## Classification
- Change target: `skill_update`
- Updated `local-secret-retrieval`.

## Evidence
- Classifier wake events 1-3 were real agent-behavior failures: the agent tried rsync/archive/bare-repo and branch-transfer workarounds after the Mac mini SSH shell could not access GitHub auth, even though the user pointed out the Mac had pushed before and then named the Mac-side Claude path.
- The surrounding turns showed the root cause: the Mac mini GUI/session auth and the non-interactive SSH shell were different credential surfaces. The SSH shell had a minimal PATH, invalid `gh` auth, no usable GitHub SSH key, and Keychain interaction errors.
- Classifier wake events 4-5 were also real proposal-scope wording failures, but `product-surface-polish` already covers grant/application requirements, optional Tinker/API resources, and corrected architecture. This reflector run did not make a second skill edit.

## Change
- The skill now fires for remote SSH GitHub auth failures and GUI/session auth mismatches.
- It now requires checking the exact remote surface (`PATH`, `gh`, credential helper, GitHub SSH, Keychain, and the failing Git command) before moving repository data around.
- It now directs agents to use the authenticated Mac-side agent/Claude/GUI session, a one-command token route, or a fixed remote credential path before fetch/build/install/push work.
- It now calls out rsync, archive streams, empty-bare-repo pushes, and large object transfers as auth workarounds to avoid.

## Probe
- Positive: "The Mac mini `git fetch` from SSH says it cannot read GitHub credentials, but Timeo has pushed from that Mac before; get this branch built there." Expected route: `local-secret-retrieval`; identify the SSH-vs-GUI auth boundary, then use Mac-side Claude/GUI auth or a scoped token path before Git fetch/build proof.
- Near miss: "Copy this local folder to an offline machine with no GitHub access." Expected route: no remote-auth skill; the requested operation is transfer, not credential recovery.

---

# Trigger Reflector Run — 2026-06-19 13:03 PDT

## Batch Summary
- 7 classifier wake events fired from 2 Codex transcript scans.
- Optional review terms were metadata only.
- Runs showed prompt versions `c7b93a4` at 4 triggers / 12 prompts, `aaeac01` at 2 / 9, and `34b5eaa` at 3 / 6. The recent rise is not one coherent AGENTS.md regression; the actionable reusable gap is in a scoped product/proposal skill.

## Classification
- Change target: `skill_update`
- Updated `product-surface-polish`, not `AGENTS.md`.

## Evidence
- Classifier wake events 1 and 2 were duplicate grant-packet feedback. The earlier skill update already covered the corrected off-head/API architecture, but the later turns showed a narrower miss: the assistant kept treating Tinker credits/API language as proposal scope.
- Classifier wake events 6 and 7 were the clearest reusable failure: the assistant had to reread the Thinking Machines application requirements and admit the packet should center the required interactivity proposal materials, not optional Tinker/API content.
- Classifier wake events 3, 4, and 5 were real Companion workflow failures around branch consolidation and remote transfer. No second change was made because the global prompt already says to obey named ordering and read the relevant set before editing; the batch constraint requires one decision, and adding a second overlapping prompt rule would be lower signal.

## Change
- The product-surface skill now activates for grant/application packets.
- The procedure now requires an artifact contract from the official application page before drafting: required attachments, page limits, budget rules, applicant category, deadline, submission path, and selection criteria.
- The skill now says optional award-side resources such as credits, model access, support, or provider APIs do not become proposal thesis or sections unless the application or user asks for them.

## Probe
- Positive: "Fix this Thinking Machines grant packet; Tinker credits are optional and the application wants the interactivity proposal materials." Expected route: `product-surface-polish`; read the apply page and remove Tinker/API-centered scope.
- Near miss: "Use Tinker to fine-tune the model for this proposal because the funder explicitly asks for a Tinker plan." Expected route: `product-surface-polish`; include the plan because the user/application made it required.

---

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
