"""Bakes a Doom map (vertexes/linedefs/sidedefs/sectors/things) into the
engine-friendly format CCOOM's Lua renderer consumes.

Stage 1 scope: only one-sided linedefs (solid walls) become renderable wall
segments, since the stage-1 engine renders a single flat wall height with no
sector floor/ceiling variation yet. Two-sided linedefs ("portals") and flat
(floor/ceiling) names are intentionally NOT carried into the stage-1 output
-- the 1MB CC computer storage budget doesn't leave room for data the
engine doesn't use yet. Re-run this converter against the WAD when stage 2
needs them; nothing here is lost, just not baked yet.
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
class SectorOut:
    floor: int
    ceiling: int
    light: int


@dataclass
class LevelData:
    player_start: dict
    sectors: list[SectorOut]
    walls: list[Wall]


def convert_level(wad: Wad, map_name: str) -> LevelData:
    ml = wad.map_lumps(map_name)
    vertexes = read_vertexes(wad.read(ml["VERTEXES"]))
    linedefs = read_linedefs(wad.read(ml["LINEDEFS"]))
    sidedefs = read_sidedefs(wad.read(ml["SIDEDEFS"]))
    sectors = read_sectors(wad.read(ml["SECTORS"]))
    things = read_things(wad.read(ml["THINGS"]))

    sectors_out = [
        SectorOut(s.floor_height, s.ceiling_height, max(0, min(255, s.light_level)))
        for s in sectors
    ]

    walls: list[Wall] = []

    for ld in linedefs:
        if ld.back_sidedef != -1:
            continue  # two-sided portal; not used by the stage-1 engine
        x1, y1 = vertexes[ld.v1]
        x2, y2 = vertexes[ld.v2]
        sd = sidedefs[ld.front_sidedef]
        if sd.middle and sd.middle != "-":
            walls.append(Wall(x1, y1, x2, y2, sd.sector, sd.middle, sd.x_offset, sd.y_offset))

    player_start = {"x": 0, "y": 0, "angle": 0}
    for t in things:
        if t.type == PLAYER1_START:
            player_start = {"x": t.x, "y": t.y, "angle": t.angle}
            break

    return LevelData(player_start, sectors_out, walls)


def _i16(v: int) -> int:
    return max(-32768, min(32767, v))


def level_to_binary(level: LevelData, tex_name_to_id: dict[str, int]) -> bytes:
    out = bytearray()
    out += struct.pack("<hhh", _i16(level.player_start["x"]), _i16(level.player_start["y"]), _i16(level.player_start["angle"]))

    out += struct.pack("<H", len(level.sectors))
    for s in level.sectors:
        out += struct.pack("<hhB", _i16(s.floor), _i16(s.ceiling), s.light)

    out += struct.pack("<H", len(level.walls))
    for w in level.walls:
        tex_id = tex_name_to_id[w.tex]
        out += struct.pack(
            "<hhhhHBhh",
            _i16(w.x1), _i16(w.y1), _i16(w.x2), _i16(w.y2),
            w.sector, tex_id, _i16(w.x_offset), _i16(w.y_offset),
        )
    return bytes(out)
