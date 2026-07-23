"""Minimal Doom WAD reader.

Reads the WAD directory table and exposes lumps by name/index. Good enough
to pull PLAYPAL, TEXTURE1/PNAMES, patches/flats/sprites, and a level's
THINGS/LINEDEFS/SIDEDEFS/VERTEXES/SECTORS lumps.
"""
from __future__ import annotations

import struct
from dataclasses import dataclass

MAP_LUMP_ORDER = [
    "THINGS", "LINEDEFS", "SIDEDEFS", "VERTEXES", "SEGS",
    "SSECTORS", "NODES", "SECTORS", "REJECT", "BLOCKMAP",
]


@dataclass
class Lump:
    name: str
    offset: int
    size: int
    index: int


class Wad:
    def __init__(self, path: str):
        self.path = path
        with open(path, "rb") as f:
            self.data = f.read()

        magic = self.data[0:4].decode("ascii")
        if magic not in ("IWAD", "PWAD"):
            raise ValueError(f"Not a WAD file: {path} (magic={magic!r})")
        self.wad_type = magic

        num_lumps, dir_offset = struct.unpack_from("<ii", self.data, 4)
        self.lumps: list[Lump] = []
        self._by_name: dict[str, list[int]] = {}

        for i in range(num_lumps):
            entry_off = dir_offset + i * 16
            offset, size, raw_name = struct.unpack_from("<ii8s", self.data, entry_off)
            name = raw_name.split(b"\0", 1)[0].decode("ascii", errors="replace")
            lump = Lump(name=name, offset=offset, size=size, index=i)
            self.lumps.append(lump)
            self._by_name.setdefault(name, []).append(i)

    def find(self, name: str, start: int = 0) -> int:
        """Return the index of the first lump named `name` at or after `start`."""
        for i in range(start, len(self.lumps)):
            if self.lumps[i].name == name:
                return i
        raise KeyError(f"Lump not found: {name}")

    def read(self, index: int) -> bytes:
        lump = self.lumps[index]
        return self.data[lump.offset: lump.offset + lump.size]

    def read_name(self, name: str) -> bytes:
        return self.read(self.find(name))

    def is_map_marker(self, index: int) -> bool:
        """A map marker lump (e.g. E1M1) is immediately followed by THINGS."""
        if index + 1 >= len(self.lumps):
            return False
        return self.lumps[index + 1].name == "THINGS"

    def list_maps(self) -> list[str]:
        return [lump.name for i, lump in enumerate(self.lumps) if self.is_map_marker(i)]

    def map_lumps(self, map_name: str) -> dict[str, int]:
        """Return {lump_name: index} for the standard lumps following a map marker."""
        start = self.find(map_name)
        result = {}
        for offset, lump_name in enumerate(MAP_LUMP_ORDER, start=1):
            idx = start + offset
            if idx < len(self.lumps) and self.lumps[idx].name == lump_name:
                result[lump_name] = idx
        return result
