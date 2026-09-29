---
name: fee-calc
description: How fees are computed in shopcalc. Use when changing fee rates, rounding, or anything that calls apply_fee.
---

# fee-calc

Fees are applied by `apply_fee` in the fees module. Money is `Decimal`, never float,
and rounds to cents with `ROUND_HALF_EVEN` (banker's rounding). Changing the rounding
mode changes every order total — call it out explicitly.
