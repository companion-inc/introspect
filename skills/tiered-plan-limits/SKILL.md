---
name: tiered-plan-limits
description: Set per-plan caps, quotas, and limits in Companion's billing tiers by deriving the numbers from the existing price/credit ladder, not by inventing round numbers. Load when adding or changing a per-tier limit (automations cap, storage, rate limit, feature quota) or editing PLAN_TIERS in src/lib/billing/constants.ts. Not for one-off non-tiered constants.
---

# Tiered plan limits

## Problem this handles

When you add a per-tier quantity to a pricing system (a cap, quota, or limit
that differs by plan), the tiers already encode a ratio in their price and
credits. Inventing round numbers (10 / 25 / 100) that *look* reasonable but
break that ratio is a real, observed failure: shipping `maxAutomations` at
Plus 10 / Pro 25 / Max 100 drew "did u not see pricing for each plan why is the
multiple off" — because every other field scales 5× then 2×, but 25 is 2.5× of
10. The value was corrected to Pro 50 to restore the ladder.

## Activation boundary

Load when: adding or changing a field in `PLAN_TIERS`
(`src/lib/billing/constants.ts`); building a plan gate; picking a per-plan cap,
quota, storage size, rate limit, or feature count; reviewing such a change.

Near-misses (do not load): a single non-tiered constant; pricing copy with no
quantitative tier ladder; a flat limit that is identical across all plans.

## Procedure

1. Open `src/lib/billing/constants.ts` and read `PLAN_TIERS`. Add the new limit
   as a sibling field on `PlanTierSpec`, in the same source of truth as
   `monthlyDollars` / `includedCredits` — not a separate parallel constant.
2. Compute the existing ladder from the fields that already scale with value —
   `monthlyDollars` and `includedCredits`. As of writing: Plus $20 / 2000cr,
   Pro $100 / 10000cr, Max $200 / 20000cr → **Plus→Pro = 5×, Pro→Max = 2×**.
   Re-derive these from the file each time; don't trust this snapshot.
3. Set the new field to follow that ladder unless there is a stated product
   reason not to. If the limit should follow a *different* curve (flat cap,
   diminishing returns, a hard technical ceiling like Max's storage), say so
   explicitly and confirm the curve with the user before shipping — do not
   silently pick round numbers.
4. Enforce at the single choke point, mirroring `maxAutomationsForPlan` →
   `scheduleTaskForCurrentChat`, so both creation paths pass through one gate.
5. In your report, state the multiple you used (e.g. "5×/2×, matching price and
   credits") so the user can sanity-check the ratio at a glance.

## Gotchas

- Roundness is a trap. 10 / 25 / 100 reads as a clean ladder but isn't; anchor
  on the *ratio* the other fields use, not on numbers ending in 0 or 5.
- Paused / inactive items count toward caps — pausing must not free a slot
  (see the `maxAutomations` comment in `PlanTierSpec`).
- `emailStorageMb` does not scale uniformly (1000 / 25000 / 100000) — confirm
  which sibling fields actually share the ladder before copying a ratio; price
  and credits are the reliable anchor, storage is bespoke.

## Verification

- Assert the new field's adjacent-tier ratios equal the `monthlyDollars` /
  `includedCredits` ratios, or that any deviation was explicitly user-approved.
- Exercise the gate live where cheap; where the cap is too high to hit on
  staging, say the cap-exceeded branch is unverified rather than implying it.

## Sources

- `src/lib/billing/constants.ts:71-107` — `PlanTierSpec`, `PLAN_TIERS`,
  `maxAutomationsForPlan`, `baseTierFor`.
- Frustration transcript c11d13a6 (2026-06-11): shipped 10/25/100, user flagged
  the broken multiple; corrected to 10/50/100.
