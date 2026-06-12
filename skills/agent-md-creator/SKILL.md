---
name: agent-md-creator
description: Create, edit, prune, review, and debug AGENTS.md or CLAUDE.md as the always-loaded agent prompt. Use for core_prompt decisions, global agent rules, prompt bloat, instruction failures, or placement decisions between AGENTS.md, hooks, and skills.
---

# Agent MD creator

## The one truth everything follows from

A prompt is **soft conditioning on a probability distribution, not control.** An LLM is a next-token predictor trained by imitation (so it defaults to the modal / consensus continuation), then RLHF'd to maximize a *proxy for human approval* (so it agrees, looks-done, and capitulates under pushback), running stateless with no reliable metacognitive monitor (so it cannot feel its own memory or limits). Every common agent failure is one of these three facts seen from a different angle. Therefore a prompt can raise the *probability* of a behavior but never guarantee it, and adherence decays as the file grows. Design around this; don't fight it.

## Layer map — put each rule where it can actually work

- **Prompt (advisory):** judgment, approach, taste — "what good looks like." Followed most of the time, not all.
- **Hooks / harness (deterministic):** non-negotiables that must happen every time. The only layer outside the sampled token stream, so the only one that enforces.
- **Skills (on-demand):** workflows relevant only sometimes — keep them out of the always-loaded prompt.
- **Training:** moves the floor. Not yours to change; the frontier failures (first-principles reasoning, self-monitoring, taste) live here — no prompt line fixes them.

If a rule must hold 100% of the time, it is a hook, not a prompt line.

## Scope map — global, project, override, local

- **Codex global:** `~/.codex/AGENTS.md`, or `~/.codex/AGENTS.override.md` when the entire global file must be replaced. Use only for cross-project invariants.
- **Codex project:** `AGENTS.md` in the repo root or nested directory. Codex concatenates global, repo, and nested files; later/closer files win on conflicts.
- **Codex override:** `AGENTS.override.md` replaces the regular `AGENTS.md` for that directory level. Use it only for a subtree that must not inherit that level's normal guidance.
- **Claude project:** Claude reads `CLAUDE.md`, not `AGENTS.md`; create `CLAUDE.md` with `@AGENTS.md` when shared repo guidance should load in Claude, then append Claude-only additions below it.
- **Claude local:** `CLAUDE.local.md` is private project-specific guidance and should be gitignored.
- **Project skills:** Codex repo skills live under `.agents/skills/<skill>/SKILL.md`; Claude project skills live under `.claude/skills/<skill>/SKILL.md`. Use them for codebase-specific workflows that should not follow the user everywhere.

## What content earns a line

Include only what the agent can't infer and will otherwise get wrong: commands it can't guess, conventions that differ from defaults, gotchas, behavioral rules learned from real failures. Exclude what's readable from the code, standard conventions the model already knows, fast-changing facts, and reference docs (link instead). The test for every candidate line is the same per-line test below.

## Writing rules

- High-signal and short. Per-line test: "would removing this cause a mistake?" If not, cut it. Bloat makes rules get **ignored**, not just diluted — adherence falls from ~100% to ~68% by 500 instructions.
- Minimal ≠ short: give enough to fully outline the behavior, but don't speculate edge cases.
- Order by importance; restate the few non-negotiables at the end (models weight early instructions and resolve conflicts toward the last one).
- One parseable instruction per rule, on its own line. Don't cram six into a sentence — a rule folded into a mega-bullet stops firing; un-burying it into a standalone line is a real fix.
- Prefer positive framing ("do X") over "don't do Y," and give the reason — models generalize from the why.
- Right altitude: a strong heuristic, not brittle hardcoded logic, not vague aspiration. Group rules under clear headers — structure is signal.
- Reserve emphasis. Emphasis ("IMPORTANT") measurably boosts adherence *because* it's scarce; modern models overtrigger on forcing language, so each use spends from a small budget. If everything is CRITICAL, nothing is.
- Cut what the model already does (self-evident "write clean code") and what a tool enforces (lint, types) — the tool is the enforcement, not the prompt.
- Don't enumerate examples as rules. If you give an example, state the behavior as a rule too, and keep examples canonical and few, or a stray pattern becomes an unintended rule.

## Editing discipline — every change is an experiment

- **Every edit traces to an observed failure.** A rule added speculatively ("while I'm here...") carries cost with no evidenced benefit — revert it. The failure (a real session, a real transcript) is the test case the edit must address.
- **One lesson per change**, named in behavioral terms (what was wrong, what's different now). Batched edits can't be evaluated or reverted independently.
- **Rules have side effects.** A line that fixes one failure can create another ("defend your position" → stubbornness against valid correction). After adding, watch for the over-rotation, not just the fix.
- **Compression is the riskiest edit.** Cuts must be restatement-only — never nuance. A keyword-level check misses semantic downgrades; after any compression pass, re-audit the new text against the old *by meaning*, rule by rule. Expect to restore things.
- **Rephrase before adding.** If the behavior is already covered but didn't fire, the rule is buried or ambiguous — sharpening the existing line is the fix, and it costs zero new length.

## Maintenance loop — the part everyone gets wrong

When the agent keeps violating a rule, the instinct is to add another rule. That is the doom loop: more rules -> longer file -> rules get lost -> you add more. Instead:

1. **Prune or rephrase first.** Too long -> cut a competing rule. Ignored despite being short -> the wording is ambiguous (if the agent asks about something already in the file, it's ambiguous, not missing).
2. **Ask the layer question.** Must-happen-every-time -> move it to a hook. A solved problem the model won't recognize (search ranking, date parsing, auth) -> point it at the library / a harness nudge. A capability gap (reasoning, taste, self-monitoring) -> no prompt fixes it; it's training.
3. **Only add a rule** when it is a genuinely missing principle — stated once, tightly, at the right altitude.

Treat the prompt like code: review it when behavior goes wrong, prune regularly, and test a change by watching whether behavior actually shifts.

## Method for understanding before editing

Don't patch from the symptom. Read the failure, drive a first-principles why-chain to the root cause (keep asking "why," answer each from evidence, past the first plausible explanation), and decide which layer the fix belongs to. Start shallow — the transcript and the file itself usually contain the answer; escalate to outside research only for a named gap. A rule added without reaching the root is the same cheap-plausible-output failure the agent itself makes.

## Why these aren't arbitrary (primary sources)

- Sycophancy, approval-proxy, "looks done": Sharma et al. [2310.13548](https://arxiv.org/abs/2310.13548); reward-hacking survey [2604.13602](https://arxiv.org/abs/2604.13602).
- Imitation -> modal answer, no reframing: [2502.12465](https://arxiv.org/abs/2502.12465); GSM-Symbolic [2410.05229](https://arxiv.org/abs/2410.05229); Reversal Curse [2309.12288](https://arxiv.org/abs/2309.12288).
- Length / bloat degradation: Lost-in-the-Middle [2307.03172](https://arxiv.org/abs/2307.03172); IFScale [2507.11538](https://arxiv.org/abs/2507.11538); Anthropic, [Effective Context Engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) (right altitude, canonical few-shot, section structure).
- Content include/exclude, per-line test, ambiguous-vs-missing, emphasis tuning, treat-like-code: Anthropic, [Claude Code best practices](https://code.claude.com/docs/en/best-practices) ("Bloated CLAUDE.md files cause Claude to ignore your actual instructions"; note it endorses sparing emphasis as an adherence lever).
- Advisory vs deterministic (hooks): same source — "Unlike CLAUDE.md instructions which are advisory, hooks are deterministic."
- Stateless, no reliable self-monitor: Anthropic, Emergent Introspective Awareness (~20% reliable); Kadavath et al. [2207.05221](https://arxiv.org/abs/2207.05221).
- Editing discipline: this repo's own history — compression-restores (c64f423→9f46c92), speculative-rule revert (511bd34), side-effect cut (3175b5a), un-burying (fee2575, c40b373).
