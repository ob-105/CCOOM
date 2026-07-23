"""Orchestrates the offline asset pipeline: reads freedoom1.wad, converts
E1M1's walls/flats/textures/palette, and writes everything into dist/.

Storage is a hard constraint: CC:Tweaked computers are capped at 1MB total,
so every format here is chosen to be as compact as the engine can still read
cheaply -- textures are downsampled to what a ~51x19 terminal can actually
show, quantized to 4-bit palette indices packed two-per-byte, and level
geometry is a flat packed-binary layout rather than a Lua table (the
straightforward pretty-printed Lua source form of the same data was ~25x
larger for no runtime benefit).

Stage 2 scope: wall textures + floor/ceiling flats, sharing one texture-id
space (a texture is keyed by (kind, name) since flat and wall namespaces can
in principle collide) so the engine's texture loader/format doesn't need to
care which kind a given id came from.
"""
from __future__ import annotations

import os
import shutil
import struct

from .wad import Wad
from .textures import TextureBank
from .doom_format import read_playpal
from .palette import median_cut, nearest_index
from .downsample import target_size, indices_to_rgb, box_downsample
from .convert_level import convert_level, level_to_binary
from .luaser import to_lua

MAP_NAME = "E1M1"
WAD_PATH = "freedoom/freedoom1.wad"
DIST = "dist"


def pack_4bit(rows: list[list[int]], width: int) -> bytes:
    out = bytearray()
    row_bytes = (width + 1) // 2
    for row in rows:
        buf = bytearray(row_bytes)
        for x, v in enumerate(row):
            byte_i = x // 2
            if x % 2 == 0:
                buf[byte_i] |= v & 0x0F
            else:
                buf[byte_i] |= (v & 0x0F) << 4
        out += buf
    return bytes(out)


def main():
    wad = Wad(WAD_PATH)
    playpal = read_playpal(wad.read_name("PLAYPAL"))

    level = convert_level(wad, MAP_NAME)
    wall_tex_names = sorted({w.tex for w in level.walls})
    flat_names = sorted({s.floor_flat for s in level.sectors} | {s.ceiling_flat for s in level.sectors})
    print(f"Level {MAP_NAME}: {len(level.walls)} solid walls, {len(level.sectors)} sectors, "
          f"{len(wall_tex_names)} distinct wall textures, {len(flat_names)} distinct flats")

    bank = TextureBank(wad)
    downsampled = {}  # (kind, name) -> (w, h, rgb grid)
    missing = []

    for name in wall_tex_names:
        if name not in bank.texture_defs:
            missing.append(("wall", name))
            continue
        tw, th, idx_grid = bank.composite_texture(name)
        rgb_grid = indices_to_rgb(idx_grid, playpal)
        target_w, target_h = target_size(tw, th)
        small = box_downsample(rgb_grid, target_w, target_h)
        downsampled[("wall", name)] = (target_w, target_h, small)

    for name in flat_names:
        if name not in bank._flat_index:
            missing.append(("flat", name))
            continue
        idx_grid = bank.flat_pixels(name)
        rgb_grid = indices_to_rgb(idx_grid, playpal)
        target_w, target_h = target_size(64, 64)
        small = box_downsample(rgb_grid, target_w, target_h)
        downsampled[("flat", name)] = (target_w, target_h, small)

    if missing:
        print(f"WARNING: {len(missing)} textures not found, will render untextured: {missing}")

    all_pixels = [px for _, _, grid in downsampled.values() for row in grid for px in row]
    print(f"Quantizing {len(all_pixels)} downsampled pixels to 16 colors...")
    palette = median_cut(all_pixels, 16)

    quant_cache: dict[tuple[int, int, int], int] = {}

    def quant(color):
        if color not in quant_cache:
            quant_cache[color] = nearest_index(color, palette)
        return quant_cache[color]

    tex_dir = f"{DIST}/assets/textures"
    if os.path.exists(tex_dir):
        shutil.rmtree(tex_dir)
    os.makedirs(tex_dir, exist_ok=True)

    tex_id = {key: i for i, key in enumerate(sorted(downsampled))}
    total_tex_bytes = 0
    for key, tid in tex_id.items():
        tw, th, grid = downsampled[key]
        idx_rows = [[quant(px) for px in row] for row in grid]
        packed = pack_4bit(idx_rows, tw)
        header = struct.pack("<BB", tw, th)
        with open(f"{tex_dir}/{tid}.tex", "wb") as f:
            f.write(header + packed)
        total_tex_bytes += len(header) + len(packed)

    with open(f"{DIST}/assets/palette.lua", "w", newline="\n") as f:
        f.write(to_lua([list(c) for c in palette]))

    level_bin = level_to_binary(level, tex_id)
    with open(f"{DIST}/assets/level1.dat", "wb") as f:
        f.write(level_bin)

    print(f"Wrote {len(tex_id)} texture files ({total_tex_bytes} bytes), "
          f"palette.lua, level1.dat ({len(level_bin)} bytes)")


if __name__ == "__main__":
    main()
