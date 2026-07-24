"""Bakes a Doom map (vertexes/linedefs/sidedefs/sectors/things) into the
engine-friendly format CCOOM's Lua renderer consumes.

Solid walls (one-sided linedefs) render as before. Two-sided linedefs are
now carried through as "portals" (front/back sector pair + endpoints) so
the engine can trace each ray through actual room-to-room crossings for
floor/ceiling texturing, instead of guessing a single sector for the whole
column.
"""
from __future__ import annotations

import struct
from dataclasses import dataclass, asdict

from .doom_format import (
    read_vertexes, read_linedefs, read_sidedefs, read_sectors, read_things,
)
from .wad import Wad

PLAYER1_START = 1


@dataclass
class Wall:
    x1: int
    y1: int
    x2: int
    y2: int
    sector: int
    tex: str
    x_offset: int
    y_offset: int


@dataclass
class Portal:
    x1: int
    y1: int
    x2: int
    y2: int
    front_sector: int
    back_sector: int


@dataclass
class SectorOut:
    floor: int
    ceiling: int
    light: int
    floor_flat: str
    ceiling_flat: str


@dataclass
class LevelData:
    player_start: dict
    sectors: list[SectorOut]
    walls: list[Wall]
    portals: list[Portal]


def convert_level(wad: Wad, map_name: str) -> LevelData:
    ml = wad.map_lumps(map_name)
    vertexes = read_vertexes(wad.read(ml["VERTEXES"]))
    linedefs = read_linedefs(wad.read(ml["LINEDEFS"]))
    sidedefs = read_sidedefs(wad.read(ml["SIDEDEFS"]))
    sectors = read_sectors(wad.read(ml["SECTORS"]))
    things = read_things(wad.read(ml["THINGS"]))

    sectors_out = [
        SectorOut(s.floor_height, s.ceiling_height, max(0, min(255, s.light_level)),
                  s.floor_flat, s.ceiling_flat)
        for s in sectors
    ]

    walls: list[Wall] = []
    portals: list[Portal] = []

    for ld in linedefs:
        x1, y1 = vertexes[ld.v1]
        x2, y2 = vertexes[ld.v2]
        if ld.back_sidedef == -1:
            sd = sidedefs[ld.front_sidedef]
            if sd.middle and sd.middle != "-":
                walls.append(Wall(x1, y1, x2, y2, sd.sector, sd.middle, sd.x_offset, sd.y_offset))
        else:
            front = sidedefs[ld.front_sidedef]
            back = sidedefs[ld.back_sidedef]
            portals.append(Portal(x1, y1, x2, y2, front.sector, back.sector))

    player_start = {"x": 0, "y": 0, "angle": 0}
    for t in things:
        if t.type == PLAYER1_START:
            player_start = {"x": t.x, "y": t.y, "angle": t.angle}
            break

    return LevelData(player_start, sectors_out, walls, portals)


def _i16(v: int) -> int:
    return max(-32768, min(32767, v))


def level_to_binary(level: LevelData, tex_id: dict[tuple[str, str], int]) -> bytes:
    out = bytearray()
    out += struct.pack("<hhh", _i16(level.player_start["x"]), _i16(level.player_start["y"]), _i16(level.player_start["angle"]))

    out += struct.pack("<H", len(level.sectors))
    for s in level.sectors:
        out += struct.pack(
            "<hhBBB",
            _i16(s.floor), _i16(s.ceiling), s.light,
            tex_id[("flat", s.floor_flat)], tex_id[("flat", s.ceiling_flat)],
        )

    out += struct.pack("<H", len(level.walls))
    for w in level.walls:
        out += struct.pack(
            "<hhhhHBhh",
            _i16(w.x1), _i16(w.y1), _i16(w.x2), _i16(w.y2),
            w.sector, tex_id[("wall", w.tex)], _i16(w.x_offset), _i16(w.y_offset),
        )

    out += struct.pack("<H", len(level.portals))
    for p in level.portals:
        out += struct.pack(
            "<hhhhHH",
            _i16(p.x1), _i16(p.y1), _i16(p.x2), _i16(p.y2),
            p.front_sector, p.back_sector,
        )
    return bytes(out)
