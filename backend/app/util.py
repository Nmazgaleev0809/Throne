from decimal import Decimal

# Mirrors the contract's fixed rules.
BPS = 10_000
MIN_INCREMENT_BPS = 1_000
USDC_DECIMALS = 6


def min_bid_for(price: int, starting_price: int) -> int:
    """Minimum next bid in token units (rounded up, same as the contract)."""
    if price == 0:
        return starting_price
    return (price * (BPS + MIN_INCREMENT_BPS) + BPS - 1) // BPS


def fmt_usdc(units: int) -> str:
    s = f"{Decimal(units) / Decimal(10 ** USDC_DECIMALS):.6f}".rstrip("0")
    whole, _, frac = s.partition(".")
    return f"{whole}.{frac.ljust(2, '0')}"


def short_addr(addr: str) -> str:
    return f"{addr[:6]}…{addr[-4:]}" if addr and len(addr) > 12 else addr
