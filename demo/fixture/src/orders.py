from decimal import Decimal

from fees import apply_fee


def order_total(lines: list[tuple[Decimal, int]]) -> Decimal:
    return apply_fee(sum(price * qty for price, qty in lines))
