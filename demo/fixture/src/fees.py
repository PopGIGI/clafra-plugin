from decimal import Decimal, ROUND_HALF_EVEN

DEFAULT_RATE = Decimal("0.025")


def apply_fee(amount: Decimal, rate: Decimal = DEFAULT_RATE) -> Decimal:
    """Return amount plus fee, rounded to cents with banker's rounding."""
    return (amount * (1 + rate)).quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)
