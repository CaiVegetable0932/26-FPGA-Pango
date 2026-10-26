"""Independent integer image-control oracle; no live PC video processing."""
import math


def gamma_curve(exponent):
    """Round a monotonic offline shared RGB curve to eight bits."""
    return tuple(math.floor(255 * (x / 255) ** exponent + 0.5) for x in range(256))


def colour_pixel(rgb12, matrix_q14):
    """Apply all nine linear coefficients before RGB888 rounding/clamping."""
    return tuple(max(0, min(255, (sum(matrix_q14[r*3+c] * rgb12[c]
                 for c in range(3)) + 131072) >> 18)) for r in range(3))


def next_curve(curve, total, count, low, high, hysteresis, allowed_mask):
    """Single-rung completed-frame policy, independent of table-copy timing."""
    if count and total < max(0, low-hysteresis)*count and curve > 0:
        return next((x for x in range(curve-1, -1, -1) if allowed_mask & (1 << x)), curve)
    if count and total > (high+hysteresis)*count and curve < 2:
        return next((x for x in range(curve+1, 3) if allowed_mask & (1 << x)), curve)
    return curve
