"""Orchestrates the offline asset pipeline: reads freedoom1.wad, converts
E1M1's walls/textures/palette, and writes everything into dist/.

Storage is a hard constraint: CC:Tweaked computers are capped at 1MB total,
so every format here is chosen to be as compact as the engine can still read
cheaply -- textures are downsampled to what a ~51x19 terminal can actually
show, quantized to 4-bit palette indices packed two-per-byte, and level
geometry is a flat packed-binary layout rather than a Lua table (the
straightforward pretty-printed Lua source form of the same data was ~25x
larger for no runtime benefit).

Stage 1 scope: wall textures + level wall list only (no flats/sprites/
sounds yet -- those arrive in later build-order stages, and will need their
own bytes budgeted for out of what's left).
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
    tex_names = sorted({w.tex for w in level.walls})
    print(f"Level {MAP_NAME}: {len(level.walls)} solid walls, {len(tex_names)} distinct wall textures")

    bank = TextureBank(wad)
    downsampled = {}  # name -> (w, h, rgb grid)
    missing = []
    for name in tex_names:
        if name not in bank.texture_defs:
            missing.append(name)
            continue
        tw, th, idx_grid = bank.composite_texture(name)
        rgb_grid = indices_to_rgb(idx_grid, playpal)
        target_w, target_h = target_size(tw, th)
        small = box_downsample(rgb_grid, target_w, target_h)
        downsampled[name] = (target_w, target_h, small)
    if missing:
        print(f"WARNING: {len(missing)} textures not found, walls using them will be untextured: {missing}")

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

    tex_name_to_id = {name: i for i, name in enumerate(sorted(downsampled))}
    total_tex_bytes = 0
    for name, tex_id in tex_name_to_id.items():
        tw, th, grid = downsampled[name]
        idx_rows = [[quant(px) for px in row] for row in grid]
        packed = pack_4bit(idx_rows, tw)
        header = struct.pack("<BB", tw, th)
        with open(f"{tex_dir}/{tex_id}.tex", "wb") as f:
            f.write(header + packed)
        total_tex_bytes += len(header) + len(packed)

    with open(f"{DIST}/assets/palette.lua", "w", newline="\n") as f:
        f.write(to_lua([list(c) for c in palette]))

    level_bin = level_to_binary(level, tex_name_to_id)
    with open(f"{DIST}/assets/level1.dat", "wb") as f:
        f.write(level_bin)

    print(f"Wrote {len(tex_name_to_id)} texture files ({total_tex_bytes} bytes), "
          f"palette.lua, level1.dat ({len(level_bin)} bytes)")


if __name__ == "__main__":
    main()
