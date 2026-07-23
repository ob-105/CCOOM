"""Median-cut quantizer: picks the best-fit N RGB colors for a set of pixels.

Used to build one shared 16-color palette (CC Advanced Computer's
term.setPaletteColor supports exactly 16 slots) from every pixel actually
used by the textures/flats/sprites the level references.
"""
from __future__ import annotations


def median_cut(pixels: list[tuple[int, int, int]], num_colors: int = 16) -> list[tuple[int, int, int]]:
    if not pixels:
        raise ValueError("no pixels to quantize")

    buckets = [pixels]
    while len(buckets) < num_colors:
        # split the bucket with the largest range on its widest channel
        buckets.sort(key=lambda b: _widest_range(b))
        bucket = buckets.pop()
        if len(bucket) < 2:
            buckets.append(bucket)
            break
        channel = _widest_channel(bucket)
        bucket_sorted = sorted(bucket, key=lambda p: p[channel])
        mid = len(bucket_sorted) // 2
        buckets.append(bucket_sorted[:mid])
        buckets.append(bucket_sorted[mid:])

    palette = [_average(b) for b in buckets]
    while len(palette) < num_colors:
        palette.append(palette[-1])
    return palette[:num_colors]


def _widest_channel(bucket: list[tuple[int, int, int]]) -> int:
    ranges = []
    for c in range(3):
        vals = [p[c] for p in bucket]
        ranges.append(max(vals) - min(vals))
    return max(range(3), key=lambda c: ranges[c])


def _widest_range(bucket: list[tuple[int, int, int]]) -> int:
    c = _widest_channel(bucket)
    vals = [p[c] for p in bucket]
    return max(vals) - min(vals)


def _average(bucket: list[tuple[int, int, int]]) -> tuple[int, int, int]:
    n = len(bucket)
    r = sum(p[0] for p in bucket) // n
    g = sum(p[1] for p in bucket) // n
    b = sum(p[2] for p in bucket) // n
    return (r, g, b)


def nearest_index(color: tuple[int, int, int], palette: list[tuple[int, int, int]]) -> int:
    best_i, best_d = 0, None
    for i, p in enumerate(palette):
        d = (color[0] - p[0]) ** 2 + (color[1] - p[1]) ** 2 + (color[2] - p[2]) ** 2
        if best_d is None or d < best_d:
            best_d, best_i = d, i
    return best_i
