"""Box-filter downsampling for texture RGB grids.

The CC terminal only ever samples a wall texture at a handful of screen
rows/columns (roughly the terminal's own height/width, ~19x51 on a basic
Advanced Computer) -- storing textures at Doom's native 64-256px resolution
wastes enormous amounts of the 1MB computer storage budget for detail that
can never actually be displayed. We downsample every texture to a small,
fixed-cap resolution before quantizing/packing it.
"""
from __future__ import annotations

MAX_DIM = 32


def target_size(width: int, height: int) -> tuple[int, int]:
    scale = min(1.0, MAX_DIM / width, MAX_DIM / height)
    return max(1, round(width * scale)), max(1, round(height * scale))


def indices_to_rgb(grid: list[list[int | None]], playpal: list[tuple[int, int, int]]) -> list[list[tuple[int, int, int]]]:
    return [[playpal[v] if v is not None else (0, 0, 0) for v in row] for row in grid]


def box_downsample(grid: list[list[tuple[int, int, int]]], target_w: int, target_h: int) -> list[list[tuple[int, int, int]]]:
    height = len(grid)
    width = len(grid[0])
    out = [[(0, 0, 0)] * target_w for _ in range(target_h)]
    for oy in range(target_h):
        sy0 = (oy * height) // target_h
        sy1 = max(sy0 + 1, ((oy + 1) * height) // target_h)
        for ox in range(target_w):
            sx0 = (ox * width) // target_w
            sx1 = max(sx0 + 1, ((ox + 1) * width) // target_w)
            rs = gs = bs = cnt = 0
            for yy in range(sy0, sy1):
                row = grid[yy]
                for xx in range(sx0, sx1):
                    r, g, b = row[xx]
                    rs += r
                    gs += g
                    bs += b
                    cnt += 1
            out[oy][ox] = (rs // cnt, gs // cnt, bs // cnt)
    return out
