"""Doom THINGS type -> sprite name mapping, for the subset of types that
actually appear in E1M1 (verified against doomwiki.org's Thing types page,
with one correction: the exploding barrel's sprite is BAR1, not BAR11 --
the wiki table's radius column bled into the sprite name).

Player starts (1-4) and deathmatch starts (11) are handled separately
(player_start / no sprite) and are not included here.
"""
from __future__ import annotations

PLAYER1_START = 1
DEATHMATCH_START = 11

# type -> 4-letter sprite name prefix
THING_SPRITE: dict[int, str] = {
    5: "BKEY",    # Blue keycard
    8: "BPAK",    # Backpack
    9: "SPOS",    # Shotgun guy (Sergeant)
    10: "PLAY",   # Bloody mess
    12: "PLAY",   # Bloody mess 2
    15: "PLAY",   # Dead player
    17: "CELP",   # Energy cell pack
    18: "POSS",   # Dead former human
    19: "SPOS",   # Dead former sergeant
    20: "TROO",   # Dead imp
    21: "SARG",   # Dead demon
    24: "POL5",   # Pool of blood/flesh
    26: "POL6",   # Skull on pole
    43: "TRE1",   # Burnt tree
    47: "SMIT",   # Brown stump
    48: "ELEC",   # Tall techno column
    54: "TRE2",   # Large brown tree
    58: "SARG",   # Spectre
    60: "GOR4",   # Hanging pair of legs
    2001: "SHOT", # Shotgun
    2002: "MGUN", # Chaingun
    2003: "LAUN", # Rocket launcher
    2004: "PLAS", # Plasma gun
    2005: "CSAW", # Chainsaw
    2007: "CLIP", # Clip
    2008: "SHEL", # 4 shotgun shells
    2010: "ROCK", # Rocket
    2011: "STIM", # Stimpack
    2012: "MEDI", # Medikit
    2013: "SOUL", # Supercharge (soulsphere)
    2014: "BON1", # Health bonus
    2015: "BON2", # Armor bonus
    2018: "ARM1", # Armor
    2019: "ARM2", # Megaarmor
    2023: "PSTR", # Berserk
    2028: "COLU", # Floor lamp
    2035: "BAR1", # Exploding barrel
    2046: "BROK", # Box of rockets
    2047: "CELL", # Energy cell
    2048: "AMMO", # Box of bullets
    2049: "SBOX", # Box of shotgun shells
    3001: "TROO", # Imp
    3002: "SARG", # Demon
    3004: "POSS", # Zombieman
}
