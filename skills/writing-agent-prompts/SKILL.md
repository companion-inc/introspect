---
name: writing-agent-prompts
description: How to write, edit, review, and debug an agent system prompt (AGENTS.md / CLAUDE.md). Use whenever creating or changing agent instructions — especially when a rule "isn't working" and the instinct is to add another. Grounded in primary-source research on why agents fail and how prompts actually steer behavior.
---

# Writing agent prompts

## The one truth everything follows from

A prompt is **soft conditioning on a probability distribution, not control.** An LLM is a next-token predictor trained by imitation (so it defaults to the modal / consensus continuation), then RLHF'd to maximize a *proxy for human approval* (so it agrees, looks-done, and capitulates under pushback), running stateless with no reliable metacognitive monitor (so it cannot feel its own memory or limits). Every common agent failure is one of these three facts seen from a different angle. Therefore a prompt can raise the *probability* of a behavior but never guarantee it, and adherence decays as the file grows. Design around this; don't fight it.

## Layer map — put each rule where it can actually work

- **Prompt (advisory):** judgment, approach, taste — "what good looks like." Followed most of the time, not all.
- **Hooks / harness (deterministic):** non-negotiables that must happen every time. The only layer outside the sampled token stream, so the only one that enforces.
- **Skills (on-demand):** workflows relevant only sometimes — keep them out of the always-loaded prompt.
- **Training:** moves the floor. Not yours to change; the frontier failures (first-principles reasoning, self-monitoring, taste) live here — no prompt line fixes them.

If a rule must hold 100% of the time, it is a hook, not a prompt line.

## Writing rules

- High-signal and short. Per-line test: "would removing this cause a mistake?" If not, cut it. Bloat makes rules get **ignored**, not just diluted — adherence falls from ~100% to ~68% by 500 instructions.
- Minimal ≠ short: give enough to fully outline the behavior, but don't speculate edge cases.
- Order by importance; restate the few non-negotiables at the end (models weight early instructions and resolve conflicts toward the last one).
- One parseable instruction per rule. Don't cram six into a sentence.
- Prefer positive framing ("do X") over "don't do Y," and give the reason — models generalize from the why.
- Right altitude: a strong heuristic, not brittle hardcoded logic, not vague aspiration.
- Reserve emphasis. If everything is CRITICAL, nothing is; modern models overtrigger on forcing language.
- Cut what the model already does (self-evident "write clean code") and what a tool enforces (lint, types) — the tool is the enforcement, not the prompt.
- Don't enumerate examples as rules. If you give an example, state the behavior as a rule too, and keep examples canonical and few, or a stray pattern becomes an unintended rule.

## Maintenance loop — the part everyone gets wrong

When the agent keeps violating a rule, the instinct is to add another rule. That is the doom loop: more rules -> longer file -> rules get lost -> you add more. Instead:

1. **Prune or rephrase first.** Too long -> cut a competing rule. Ignored despite being short -> the wording is ambiguous (if the agent asks about something already in the file, it's ambiguous, not missing).
2. **Ask the layer question.** Must-happen-every-time -> move it to a hook. A solved problem the model won't recognize (search ranking, date parsing, auth) -> point it at the library / a harness nudge. A capability gap (reasoning, taste, self-monitoring) -> no prompt fixes it; it's training.
3. **Only add a rule** when it is a genuinely missing principle — stated once, tightly, at the right altitude.

Treat the prompt like code: review it when behavior goes wrong, prune regularly, and test a change by watching whether behavior actually shifts.

## Method for understanding before editing

Don't patch from the symptom. Read the failure, drive a first-principles why-chain to the root cause (keep asking "why," answer each from evidence, past the first plausible explanation), and decide which layer the fix belongs to. A rule added without reaching the root is the same cheap-plausible-output failure the agent itself makes.

## Why these aren't arbitrary (primary sources)

- Sycophancy, approval-proxy, "looks done": Sharma et al. [2310.13548](https://arxiv.org/abs/2310.13548); reward-hacking survey [2604.13602](https://arxiv.org/html/2604.13602v1).
- Imitation -> modal answer, no reframing: [2502.12465](https://arxiv.org/abs/2502.12465); GSM-Symbolic [2410.05229](https://arxiv.org/abs/2410.05229); Reversal Curse [2309.12288](https://arxiv.org/abs/2309.12288).
- Length / bloat degradation: Lost-in-the-Middle [2307.03172](https://arxiv.org/abs/2307.03172); IFScale [2507.11538](https://arxiv.org/abs/2507.11538); Anthropic, Effective Context Engineering.
- Advisory vs deterministic (hooks): Anthropic, Best practices for Claude Code.
- Stateless, no reliable self-monitor: Anthropic, Emergent Introspective Awareness (~20% reliable); Kadavath et al. [2207.05221](https://arxiv.org/abs/2207.05221).
