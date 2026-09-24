#!/usr/bin/env python3
"""The songs on the POKEY PLAYER disk, as chosen by ear (yay / nay rounds on
the real machine, 2026-09-24). mkdisk.py builds the disk from this list,
sorted by title; the files are the exact conversions that were approved.

    YAY     go on the disk
    FILLER  only while there are free slots (MAX), in this order
Verdicts and notes: songs/album|audition|fixes/verdicts.json.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
MAX = 53                         # catalog: 10 sectors of 24-byte entries

A, N, F = "songs/album/", "songs/audition/", "songs/fixes/"

# (psq file, title on the disk)
YAY = [
    # from the first album
    (A + "anthem.psq", "ANTHEM"),
    (A + "kalinka.psq", "KALINKA"),
    (A + "StarmanE.psq", "STARMAN"),
    (A + "dbztheme.psq", "DBZ THEME"),
    (A + "cas-kid_.psq", "CAS KID"),
    (A + "KoopaTroopaBeach.psq", "KOOPA BEACH"),
    (A + "DonutPlains.psq", "DONUT PLAINS"),
    (A + "rcr-main.psq", "RIVER CITY"),
    (A + "rcr-boss.psq", "RIVER CITY BOSS"),
    (A + "Dbz2.psq", "DBZ2"),
    (A + "ng2_act.psq", "NINJA G2 ACT"),
    (A + "smb109.psq", "SMB 1-09"),
    (A + "temp.psq", "X-WEEKEND"),
    (A + "smkrainbow.psq", "RAINBOW ROAD"),
    (A + "sdb-titl.psq", "SDB TITLE"),
    (A + "gtgm.psq", "GTGM"),
    (A + "Level_5.psq", "LEVEL 5"),
    (A + "sdb-usa.psq", "SDB USA"),
    (A + "CHOCOBO.psq", "CHOCOBO"),
    # from ~/Music/seleccion
    (N + "Adventure_Island_II-Overworld_1.psq", "ADV ISLAND 2"),
    (N + "contra-1.psq", "CONTRA"),
    (N + "ct600ad.psq", "CHRONO 600 AD"),
    (N + "cv1-1b.psq", "CASTLEVANIA"),
    (N + "ddstage.psq", "DOUBLE DRAGON"),
    (N + "DocMarTune.psq", "DR MARIO"),
    (N + "ff3jbatt.psq", "FF3 BATTLE"),
    (N + "ff3PRELUDE.psq", "FF PRELUDE"),
    (N + "mm2air.psq", "AIR MAN"),
    (N + "MM4Skull.psq", "SKULL MAN"),
    (N + "ng2stg11.psq", "NINJA GAIDEN 2"),
    (N + "NinjaBro.psq", "NINJA BROS"),
    (N + "sdb-london.psq", "SDB LONDON"),
    (N + "sf2Ryu456.psq", "SF2 RYU"),
    (N + "sm3ow2.psq", "SMB3 WORLD 2"),
    (N + "smb2overworld1.psq", "SMB2 OVERWORLD"),
    (N + "Smbtheme.psq", "SUPER MARIO"),
    (N + "smwwd1.psq", "SUPER MARIO WLD"),
    (N + "SRnR_-_Stage_01.psq", "SRNR STAGE 1"),
    (N + "St-Seiya.psq", "SAINT SEIYA"),
    (N + "tetris-1.psq", "TETRIS"),
    (N + "topgear1.psq", "TOP GEAR"),
    (N + "Tyrian_-_The_Level.psq", "TYRIAN"),
    (N + "z1overw.psq", "ZELDA"),
    # hand-fixed (audition.py FIXES)
    (F + "MM1-_Elecman.psq", "ELEC MAN"),
    (F + "mm3magnt_2.psq", "MAGNET MAN"),
    (F + "Nintendo_World_Cup_-_Golden_Goal.psq", "WORLD CUP GOAL"),
    (F + "Puyo-Puyo-Tsu-Remix-By-Matthew.psq", "PUYO PUYO TSU"),
    (F + "sf2ken.psq", "SF2 KEN"),
    (F + "RR_Music1.psq", "RR MUSIC 1"),
]

# best known first: they take whatever slots are left
FILLER = [
    (F + "ddtheme.psq", "DOUBLE DRAGON TH"),      # "almost yay"
    (F + "corridor.psq", "CORRIDOR OF TIME"),     # Chrono Trigger
    (F + "wily9.psq", "WILY STAGE"),              # Mega Man
    (A + "Level_6.psq", "LEVEL 6"),
    (N + "Level5.psq", "LEVEL5"),
]


def songs():
    """-> [(path, title)] for the disk, alphabetical by title"""
    chosen = YAY + FILLER[:max(0, MAX - len(YAY))]
    return sorted(((os.path.join(HERE, p), t) for p, t in chosen), key=lambda e: e[1])


if __name__ == "__main__":
    s = songs()
    for p, t in s:
        print(f"  {t:16s} {os.path.relpath(p, HERE)}")
    print(f"{len(s)} songs ({len(YAY)} yay + {len(s) - len(YAY)} filler)")
