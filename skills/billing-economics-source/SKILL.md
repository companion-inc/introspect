---
name: billing-economics-source
description: Keep Companion billing money values tied to source of truth: usage markup/credits in billing economics, and subscription plan prices across plan constants, Autumn/Stripe, RevenueCat, and App Store Connect when Apple IAP is in scope. Load when changing CREDIT_MARKUP, usage credit math, plan prices, top-ups, billing reconcile scripts, RevenueCat/App Store product prices, or paywall price displays. Not for per-plan quota or compute sizing; use tiered-plan-limits.
---

# Billing economics source

## Problem this handles

Companion bills users by deducting credits from a usage ledger. A real failure
mode is treating UI display math as a second billing model, or spreading markup
between worker rates, UI money helpers, Autumn config, and scripts. When the
user asks "global 1.25x" or "how does pricing work," answer the source-of-truth
model first, then edit.

Subscription price changes have a second failure mode: treating Autumn or the
repo constants as the only truth layer after native iOS billing is in scope. A
request like "fix all pricing" means web and Apple purchase rails, not only the
provider surfaced by the first stale CLI output.

## Activation boundary

Load when changing any of these:

- `CREDIT_MARKUP`, provider raw-cost to credit conversion, or "global 1.25x /
  1.5x" pricing behavior.
- `src/lib/billing/economics.ts`, `src/lib/billing/money.ts`, worker billing
  rates, usage ledger writes, billing retry/reconcile scripts, or Autumn credit
  item values.
- Plan subscription prices, monthly/annual plan amount changes, RevenueCat
  product/package/entitlement mapping, App Store Connect subscription price
  schedules, or paywall/store product price displays.
- Usage UI, chat credit footer, billing usage tables, or any display that shows
  credits consumed from `usage_events.costMicroCents`.

Near-misses:

- Per-plan caps, quotas, storage, vCPU/RAM, or sandbox templates: use
  `tiered-plan-limits`.
- Pricing page copy or plan-card marketing without changing billing facts: use
  `product-surface-polish`.

## Procedure

1. Before editing, state the current model with evidence. For usage economics:
   raw provider cost is marked up into ledger micro-cents; ledger micro-cents
   are deducted as credits; UI displays ledger credits. For subscription prices:
   preserve the user's term for the truth layer and list every rail you will
   verify before claiming the fix.
2. Read the live source path, not memory:
   - `src/lib/billing/economics.ts`
   - `src/lib/billing/constants.ts`
   - `workers/agent/lib/billing/rates.ts`
   - `workers/agent/lib/billing/usage-service.ts`
   - `autumn.config.ts`
   - `src/lib/billing/money.ts`
   - `workers/app/services/usage.ts`
   - iOS billing/paywall source and product ID mappings when Apple billing is in
     scope
   - any UI component or script touched by the requested change
3. Keep the source of truth narrow:
   - `CREDIT_MARKUP`, ledger unit constants, and credit price constants belong
     in `src/lib/billing/economics.ts`.
   - Subscription target prices start in plan constants/config, but live charge
     truth is provider-specific: Autumn/Stripe for web, App Store Connect for
     Apple subscriptions, and RevenueCat for product, entitlement, package, and
     webhook mapping.
   - For RevenueCat-backed mobile billing, Autumn receives RevenueCat updates;
     Autumn prices do not decide the mobile charge.
   - Worker billing code imports economics helpers and writes already-marked-up
     `usage_events.costMicroCents`.
   - Autumn tracking uses the same ledger value converted to credits.
   - UI money helpers format ledger values; they must not define markup or
     estimate raw provider cost unless the surface is explicitly internal and
     labeled as raw provider cost.
4. Resolve provider contradictions before mutating. Do not push a catalog or
   patch code from a summary table when detailed JSON, dashboard UI, or the
   charge provider disagrees.
5. Delete duplicate economics constants instead of syncing them by comment.
   Prefer imports from `src/lib/billing/economics.ts` across server, scripts,
   Autumn config, tests, and UI.
6. If a raw-cost reporting surface is genuinely needed, name it as raw provider
   cost and keep it separate from user credit consumption.
7. Add focused guards for the drift you changed:
   - rate tests for markup and raw-dollar conversion;
   - money tests for ledger credit formatting;
   - usage tests for `costMicroCents` to Autumn credit value;
   - grep guard that no second `CREDIT_MARKUP` definition or raw-cost display
     helper remains in the UI layer.
   - for subscription prices, capture the exact provider records checked:
     Autumn detailed product records, RevenueCat products/offerings/entitlements,
     and App Store Connect subscription status plus storefront price schedules.

## Gotchas

- `costMicroCents` is a deduction amount, not raw provider spend.
- `money.ts` is a formatter/converter for ledger values. Putting markup there
  makes UI code look like a billing engine.
- A displayed credit line item should come from the ledger or usage API. Do not
  recalculate what the user "probably" consumed in the UI.
- Top-up/subscription credit price and provider markup are different knobs:
  credit price says what a credit costs to buy; markup says how raw provider
  cost becomes credits consumed.
- App Store subscription prices are configured per country/region in App Store
  Connect. Check the storefront current price and product status, not only the
  product ID or RevenueCat offering label.
- RevenueCat entitlements decide access mapping after a purchase; offerings and
  packages decide what the SDK presents; App Store Connect still owns the Apple
  subscription price.

## Verification

- Run a source grep such as:

```bash
rg -n "CREDIT_MARKUP|estimateRawDollars|formatRawDollars|costMicroCents|microCentsToCredits" src workers scripts autumn.config.ts test
```

- Run focused billing/money tests, then the repo's normal validation for a
  shared billing change. Report any skipped external mutation explicitly, such
  as not pushing Autumn config or publishing provider templates.
- For plan-price changes, re-read the live provider records after the change:
  Autumn detailed product JSON/dashboard for web, RevenueCat product/offering
  and entitlement mapping for mobile, and App Store Connect subscription price
  schedules/status for Apple. Name any provider you did not check.

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
- Transcript `019ee099` (2026-06-19): user corrected a "fix all pricing" run
  because the agent narrowed to Autumn and failed to include Apple/App Store
  pricing in the named truth layer.
- Autumn RevenueCat docs: mobile billing is handled through RevenueCat; Autumn
  receives webhook updates and ignores Autumn prices for RevenueCat purchases.
- Apple App Store Connect docs: auto-renewable subscriptions are priced by
  country/region in App Store Connect and can be managed through its API.
- RevenueCat entitlements docs: products unlock entitlements, while offerings
  and packages control what the SDK presents.
