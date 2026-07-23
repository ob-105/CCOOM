"""Struct-level decoders for Doom lump formats (vertexes, linedefs, sidedefs,
sectors, things, patches, flats, PLAYPAL, PNAMES/TEXTURE1).

All of this only ever runs offline on the desktop as part of the asset
pipeline -- never on the CC computer.
"""
from __future__ import annotations

import struct
from dataclasses import dataclass, field


def _cstr(raw: bytes) -> str:
    return raw.split(b"\0", 1)[0].decode("ascii", errors="replace").upper()


# ---------------------------------------------------------------- VERTEXES

def read_vertexes(data: bytes) -> list[tuple[int, int]]:
    n = len(data) // 4
    return [struct.unpack_from("<hh", data, i * 4) for i in range(n)]


# ---------------------------------------------------------------- LINEDEFS

@dataclass
class Linedef:
    v1: int
    v2: int
    flags: int
    special: int
    tag: int
    front_sidedef: int  # -1 if none
    back_sidedef: int   # -1 if none


def read_linedefs(data: bytes) -> list[Linedef]:
    n = len(data) // 14
    out = []
    for i in range(n):
        v1, v2, flags, special, tag, sd_front, sd_back = struct.unpack_from(
            "<hhhhhHH", data, i * 14
        )
        sd_front = -1 if sd_front == 0xFFFF else sd_front
        sd_back = -1 if sd_back == 0xFFFF else sd_back
        out.append(Linedef(v1, v2, flags, special, tag, sd_front, sd_back))
    return out


# ---------------------------------------------------------------- SIDEDEFS

@dataclass
class Sidedef:
    x_offset: int
    y_offset: int
    upper: str
    lower: str
    middle: str
    sector: int


def read_sidedefs(data: bytes) -> list[Sidedef]:
    n = len(data) // 30
    out = []
    for i in range(n):
        off = i * 30
        x_off, y_off = struct.unpack_from("<hh", data, off)
        upper = _cstr(data[off + 4: off + 12])
        lower = _cstr(data[off + 12: off + 20])
        middle = _cstr(data[off + 20: off + 28])
        (sector,) = struct.unpack_from("<h", data, off + 28)
        out.append(Sidedef(x_off, y_off, upper, lower, middle, sector))
    return out


# ---------------------------------------------------------------- SECTORS

@dataclass
class Sector:
    floor_height: int
    ceiling_height: int
    floor_flat: str
    ceiling_flat: str
    light_level: int
    special: int
    tag: int


def read_sectors(data: bytes) -> list[Sector]:
    n = len(data) // 26
    out = []
    for i in range(n):
        off = i * 26
        floor_h, ceil_h = struct.unpack_from("<hh", data, off)
        floor_flat = _cstr(data[off + 4: off + 12])
        ceil_flat = _cstr(data[off + 12: off + 20])
        light, special, tag = struct.unpack_from("<hhh", data, off + 20)
        out.append(Sector(floor_h, ceil_h, floor_flat, ceil_flat, light, special, tag))
    return out


# ------------------------------------------------------------------ THINGS

@dataclass
class Thing:
    x: int
    y: int
    angle: int
    type: int
    flags: int


def read_things(data: bytes) -> list[Thing]:
    n = len(data) // 10
    out = []
    for i in range(n):
        x, y, angle, ttype, flags = struct.unpack_from("<hhhhH", data, i * 10)
        out.append(Thing(x, y, angle, ttype, flags))
    return out


# ------------------------------------------------------------------ PLAYPAL

def read_playpal(data: bytes, palette_index: int = 0) -> list[tuple[int, int, int]]:
    """Each palette is 256 RGB triples (768 bytes). PLAYPAL has 14 palettes."""
    off = palette_index * 768
    return [tuple(data[off + i * 3: off + i * 3 + 3]) for i in range(256)]


# --------------------------------------------------------- PNAMES/TEXTURE1

def read_pnames(data: bytes) -> list[str]:
    (n,) = struct.unpack_from("<i", data, 0)
    return [_cstr(data[4 + i * 8: 4 + i * 8 + 8]) for i in range(n)]


@dataclass
class TexturePatch:
    origin_x: int
    origin_y: int
    patch_index: int


@dataclass
class TextureDef:
    name: str
    width: int
    height: int
    patches: list[TexturePatch] = field(default_factory=list)


def read_texture_lump(data: bytes, pnames: list[str]) -> dict[str, TextureDef]:
    """Parses TEXTURE1/TEXTURE2 lumps into a name -> TextureDef map."""
    (n,) = struct.unpack_from("<i", data, 0)
    offsets = struct.unpack_from(f"<{n}i", data, 4)
    out: dict[str, TextureDef] = {}
    for off in offsets:
        name = _cstr(data[off: off + 8])
        width, height = struct.unpack_from("<hh", data, off + 12)
        (patch_count,) = struct.unpack_from("<h", data, off + 20)
        patches = []
        p_off = off + 22
        for _ in range(patch_count):
            origin_x, origin_y, patch_num = struct.unpack_from("<hhh", data, p_off)
            patches.append(TexturePatch(origin_x, origin_y, patch_num))
            p_off += 10
        out[name] = TextureDef(name, width, height, patches)
    return out


# ----------------------------------------------------------------- PATCHES

def read_patch(data: bytes) -> tuple[int, int, list[list[int | None]]]:
    """Decode a 'patch' format graphic lump into a width x height grid of
    palette indices, with None for transparent pixels. Column-major on disk;
    returned grid is grid[y][x]."""
    width, height, left, top = struct.unpack_from("<hhhh", data, 0)
    grid: list[list[int | None]] = [[None] * width for _ in range(height)]
    col_offsets = struct.unpack_from(f"<{width}i", data, 8)
    for x in range(width):
        off = col_offsets[x]
        while True:
            row_start = data[off]
            if row_start == 0xFF:
                break
            pixel_count = data[off + 1]
            # off+2 is an unused padding byte, pixel data starts at off+3
            px_off = off + 3
            for i in range(pixel_count):
                y = row_start + i
                if 0 <= y < height:
                    grid[y][x] = data[px_off + i]
            off = px_off + pixel_count + 1  # +1 for trailing padding byte
    return width, height, grid


# ------------------------------------------------------------------- FLATS

def read_flat(data: bytes, size: int = 64) -> list[list[int]]:
    """Flats are raw size x size palette-index bytes, row-major."""
    return [list(data[y * size:(y + 1) * size]) for y in range(size)]
