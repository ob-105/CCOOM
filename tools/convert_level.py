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
from .thing_types import THING_SPRITE, PLAYER1_START, DEATHMATCH_START
from .wad import Wad


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
class Sprite:
    x: int
    y: int
    angle: int
    sprite_name: str
    floor_z: int


@dataclass
class LevelData:
    player_start: dict
    sectors: list[SectorOut]
    walls: list[Wall]
    portals: list[Portal]
    sprites: list[Sprite]


def _point_to_segment_dist_sq(px, py, x1, y1, x2, y2):
    abx, aby = x2 - x1, y2 - y1
    apx, apy = px - x1, py - y1
    ab_len_sq = abx * abx + aby * aby
    t = 0.0
    if ab_len_sq > 0:
        t = (apx * abx + apy * aby) / ab_len_sq
        t = max(0.0, min(1.0, t))
    cx, cy = x1 + t * abx, y1 + t * aby
    dx, dy = px - cx, py - cy
    return dx * dx + dy * dy


def _sector_at(px, py, walls, portals) -> int:
    """Same heuristic as the Lua engine's currentSector(): the sector of
    whichever boundary edge (wall or portal) is nearest to the point,
    resolving portals via a cross-product side test (front sector is to the
    right of the directed line v1->v2, per Doom convention)."""
    best_dist_sq, best_sector = float("inf"), 0
    for w in walls:
        d = _point_to_segment_dist_sq(px, py, w.x1, w.y1, w.x2, w.y2)
        if d < best_dist_sq:
            best_dist_sq, best_sector = d, w.sector
    for p in portals:
        d = _point_to_segment_dist_sq(px, py, p.x1, p.y1, p.x2, p.y2)
        if d < best_dist_sq:
            best_dist_sq = d
            abx, aby = p.x2 - p.x1, p.y2 - p.y1
            apx, apy = px - p.x1, py - p.y1
            cross = abx * apy - aby * apx
            best_sector = p.front_sector if cross < 0 else p.back_sector
    return best_sector


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

    sprites: list[Sprite] = []
    for t in things:
        if t.type in (PLAYER1_START, DEATHMATCH_START):
            continue
        sprite_name = THING_SPRITE.get(t.type)
        if sprite_name is None:
            continue
        sector_idx = _sector_at(t.x, t.y, walls, portals)
        sprites.append(Sprite(t.x, t.y, t.angle, sprite_name, sectors_out[sector_idx].floor))

    return LevelData(player_start, sectors_out, walls, portals, sprites)


def _i16(v: int) -> int:
    return max(-32768, min(32767, v))


def level_to_binary(
    level: LevelData,
    tex_id: dict[tuple[str, str], int],
    sprite_tex_id: dict[str, int],
) -> bytes:
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

    visible_sprites = [s for s in level.sprites if s.sprite_name in sprite_tex_id]
    out += struct.pack("<H", len(visible_sprites))
    for s in visible_sprites:
        out += struct.pack(
            "<hhhhB",
            _i16(s.x), _i16(s.y), _i16(s.floor_z), _i16(s.angle),
            sprite_tex_id[s.sprite_name],
        )
    return bytes(out)
