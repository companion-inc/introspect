---
name: billing-economics-source
description: Keep Companion credit economics, usage markup, ledger units, Autumn credit tracking, and usage UI display tied to one billing source of truth. Load when changing CREDIT_MARKUP, global 1.25x/1.5x markup, provider-cost-to-credit conversion, src/lib/billing/economics.ts, src/lib/billing/money.ts, usage_events costMicroCents, Autumn credits/top-ups, billing retry/reconcile scripts, or usage/credit display math. Not for per-plan quota or compute sizing; use tiered-plan-limits.
---

# Billing economics source

## Problem this handles

Companion bills users by deducting credits from a usage ledger. A real failure
mode is treating UI display math as a second billing model, or spreading markup
between worker rates, UI money helpers, Autumn config, and scripts. When the
user asks "global 1.25x" or "how does pricing work," answer the source-of-truth
model first, then edit.

## Activation boundary

Load when changing any of these:

- `CREDIT_MARKUP`, provider raw-cost to credit conversion, or "global 1.25x /
  1.5x" pricing behavior.
- `src/lib/billing/economics.ts`, `src/lib/billing/money.ts`, worker billing
  rates, usage ledger writes, billing retry/reconcile scripts, or Autumn credit
  item values.
- Usage UI, chat credit footer, billing usage tables, or any display that shows
  credits consumed from `usage_events.costMicroCents`.

Near-misses:

- Per-plan caps, quotas, storage, vCPU/RAM, or sandbox templates: use
  `tiered-plan-limits`.
- Pricing page copy or plan-card marketing without billing math: use
  `product-surface-polish`.

## Procedure

1. Before editing, state the current model with file evidence: raw provider
   cost is marked up into ledger micro-cents; ledger micro-cents are deducted
   as credits; UI displays ledger credits.
2. Read the live source path, not memory:
   - `src/lib/billing/economics.ts`
   - `workers/agent/lib/billing/rates.ts`
   - `workers/agent/lib/billing/usage-service.ts`
   - `autumn.config.ts`
   - `src/lib/billing/money.ts`
   - `workers/app/services/usage.ts`
   - any UI component or script touched by the requested change
3. Keep the source of truth narrow:
   - `CREDIT_MARKUP`, ledger unit constants, and credit price constants belong
     in `src/lib/billing/economics.ts`.
   - Worker billing code imports economics helpers and writes already-marked-up
     `usage_events.costMicroCents`.
   - Autumn tracking uses the same ledger value converted to credits.
   - UI money helpers format ledger values; they must not define markup or
     estimate raw provider cost unless the surface is explicitly internal and
     labeled as raw provider cost.
4. Delete duplicate economics constants instead of syncing them by comment.
   Prefer imports from `src/lib/billing/economics.ts` across server, scripts,
   Autumn config, tests, and UI.
5. If a raw-cost reporting surface is genuinely needed, name it as raw provider
   cost and keep it separate from user credit consumption.
6. Add focused guards for the drift you changed:
   - rate tests for markup and raw-dollar conversion;
   - money tests for ledger credit formatting;
   - usage tests for `costMicroCents` to Autumn credit value;
   - grep guard that no second `CREDIT_MARKUP` definition or raw-cost display
     helper remains in the UI layer.

## Gotchas

- `costMicroCents` is a deduction amount, not raw provider spend.
- `money.ts` is a formatter/converter for ledger values. Putting markup there
  makes UI code look like a billing engine.
- A displayed credit line item should come from the ledger or usage API. Do not
  recalculate what the user "probably" consumed in the UI.
- Top-up/subscription credit price and provider markup are different knobs:
  credit price says what a credit costs to buy; markup says how raw provider
  cost becomes credits consumed.

## Verification

- Run a source grep such as:

```bash
rg -n "CREDIT_MARKUP|estimateRawDollars|formatRawDollars|costMicroCents|microCentsToCredits" src workers scripts autumn.config.ts test
```

- Run focused billing/money tests, then the repo's normal validation for a
  shared billing change. Report any skipped external mutation explicitly, such
  as not pushing Autumn config or publishing provider templates.

## Sources

- Transcript `019ec299` (2026-06-13): user interrupted after a confusing
  "UI duplicated 1.25 for display math" explanation; follow-up clarified that
  markup belongs in billing economics and UI should format ledger values.
- Companion `src/lib/billing/economics.ts`: shared `CREDIT_MARKUP`, ledger unit
  constants, and credit price constants.
- Companion `workers/agent/lib/billing/rates.ts`: raw provider costs are
  converted to marked-up ledger micro-cents.
- Companion `workers/agent/lib/billing/usage-service.ts`: usage rows persist
  `costMicroCents` and track Autumn credits from that ledger amount.
- Companion `src/lib/billing/money.ts`: UI money helpers format already
  calculated ledger values.
