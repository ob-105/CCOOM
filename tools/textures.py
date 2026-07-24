"""Resolves TEXTURE1/TEXTURE2 composite wall textures and namespaced
patch/flat/sprite lumps into RGB pixel grids, using PNAMES + the WAD's
P_START/P_END, F_START/F_END, and S_START/S_END namespaces.
"""
from __future__ import annotations

from .doom_format import (
    read_pnames, read_texture_lump, read_patch, read_flat, TextureDef,
)
from .wad import Wad


class TextureBank:
    def __init__(self, wad: Wad):
        self.wad = wad
        self.pnames = read_pnames(wad.read_name("PNAMES"))

        self.texture_defs: dict[str, TextureDef] = {}
        for lump_name in ("TEXTURE1", "TEXTURE2"):
            try:
                idx = wad.find(lump_name)
            except KeyError:
                continue
            self.texture_defs.update(read_texture_lump(wad.read(idx), self.pnames))

        p_start = wad.find("P_START")
        p_end = wad.find("P_END")
        self._patch_index: dict[str, int] = {}
        for i in range(p_start + 1, p_end):
            name = wad.lumps[i].name
            if name not in self._patch_index:
                self._patch_index[name] = i

        f_start = wad.find("F_START")
        f_end = wad.find("F_END")
        self._flat_index: dict[str, int] = {}
        for i in range(f_start + 1, f_end):
            name = wad.lumps[i].name
            if name not in self._flat_index:
                self._flat_index[name] = i

        s_start = wad.find("S_START")
        s_end = wad.find("S_END")
        self._sprite_names: list[str] = []
        self._sprite_index: dict[str, int] = {}
        for i in range(s_start + 1, s_end):
            name = wad.lumps[i].name
            self._sprite_names.append(name)
            if name not in self._sprite_index:
                self._sprite_index[name] = i

        self._patch_cache: dict[str, tuple[int, int, list[list[int | None]]]] = {}

    def _get_patch(self, name: str):
        if name not in self._patch_cache:
            idx = self._patch_index[name]
            self._patch_cache[name] = read_patch(self.wad.read(idx))
        return self._patch_cache[name]

    def composite_texture(self, name: str) -> tuple[int, int, list[list[int | None]]]:
        """Returns (width, height, grid[y][x] -> palette index or None)."""
        tdef = self.texture_defs[name]
        grid: list[list[int | None]] = [[None] * tdef.width for _ in range(tdef.height)]
        for patch in tdef.patches:
            patch_name = self.pnames[patch.patch_index]
            if patch_name not in self._patch_index:
                continue
            pw, ph, pgrid = self._get_patch(patch_name)
            for y in range(ph):
                dy = patch.origin_y + y
                if not (0 <= dy < tdef.height):
                    continue
                row = pgrid[y]
                dst_row = grid[dy]
                for x in range(pw):
                    val = row[x]
                    if val is None:
                        continue
                    dx = patch.origin_x + x
                    if 0 <= dx < tdef.width:
                        dst_row[dx] = val
        return tdef.width, tdef.height, grid

    def flat_pixels(self, name: str) -> list[list[int]]:
        idx = self._flat_index[name]
        return read_flat(self.wad.read(idx))

    def find_sprite_frame(self, prefix: str) -> str | None:
        """Finds one representative lump for a 4-letter sprite prefix.

        Sprite lumps are named <prefix><frame><rotation>, e.g. "TROOA1", or
        <prefix><frame><rotation><frame><rotation> when one lump covers two
        mirrored angles, e.g. "TROOA2A8". We only need a single static
        frame (no animation/rotation yet), so prefer the non-rotating "A0"
        frame (common for pickups), else "A1" (a front-facing rotation),
        else whatever frame A lump exists first.
        """
        for candidate in (f"{prefix}A0", f"{prefix}A1"):
            if candidate in self._sprite_index:
                return candidate
        for name in self._sprite_names:
            if name.startswith(prefix + "A"):
                return name
        return None

    def sprite_pixels(self, lump_name: str) -> tuple[int, int, list[list[int | None]]]:
        """Returns (width, height, grid[y][x] -> palette index or None).

        Doom's patch format also stores a left/top offset for precise
        anchoring, which we don't use -- sprites are assumed horizontally
        centered and floor-aligned at the bottom, true for the vast
        majority of pickup/decoration sprites.
        """
        idx = self._sprite_index[lump_name]
        return read_patch(self.wad.read(idx))
