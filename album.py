#!/usr/bin/env python3
"""The disk album: convert every song for POKEY PLAYER at full length.

    python3 album.py            # (re)convert into songs/album/, print a table
    python3 mkdisk.py           # then build the disk (it reads ALBUM from here)

Rated songs (songs/ratings.md) were converted for listening with --end 50.
Their full-length versions reuse the parts the picker chose for that rated
50 s window, passed explicitly, so the whole song sounds like what was rated.
New songs use the picker on the whole file. A song whose events pass the
player's 20 KB buffer is cut at the longest length that fits.
"""
import os
import re
import subprocess
import sys

import psq

HERE = os.path.dirname(os.path.abspath(__file__))
MIDIS = "/home/carlos/DOSGames/dosmid98/midis"
OUT = os.path.join(HERE, "songs", "album")
LIMIT = 20480                    # $5000-$9FFF, 160 sectors

# Left out: LittleD (every part plays in only 40% of the file) and superc3
# (its lead is silent for the first 19 s): the coverage map says the auto
# pick is wrong, and nobody has listened yet to pick them by hand.
# (name, title, how): "keep" = use songs/NAME.psq as it is (already full
# length or hand-made), "rated" = full length with the rated window's parts,
# "new" = full length, auto-picked.
ALBUM = [
    ("anthem", "ANTHEM", "keep"),
    ("kalinka", "KALINKA", "keep"),
    ("StarmanE", "STARMAN", "rated"),
    ("dbztheme", "DBZ THEME", "rated"),
    ("MetalstormLvl3", "METAL STORM 3", "rated"),
    ("cas-kid_", "CAS KID", "rated"),
    ("Revontulet", "REVONTULET", "rated"),
    ("KoopaTroopaBeach", "KOOPA BEACH", "rated"),
    ("DonutPlains", "DONUT PLAINS", "rated"),
    ("topgear1", "TOP GEAR", "rated"),
    ("rcr-main", "RIVER CITY", "rated"),
    ("rcr-boss", "RIVER CITY BOSS", "rated"),
    ("btdslv5surf", "TOADS SURF", "rated"),
    ("dd2shad", "DD2 SHADOW", "rated"),
    ("dbz2bvt", "DBZ2 BVT", "rated"),
    ("dbz2bsgt", "DBZ2 BSGT", "rated"),
    ("Dbz2", "DBZ2", "rated"),
    ("ng2_act", "NINJA GAIDEN 2", "rated"),
    ("smb109", "SMB 1-09", "rated"),
    ("temp", "TEMP", "rated"),
    ("smkrainbow", "RAINBOW ROAD", "rated"),
    ("battletoads_turbo", "TURBO TUNNEL", "rated"),
    ("sdb-titl", "SDB TITLE", "rated"),
    ("gtgm", "GTGM", "rated"),
    # not rated yet
    ("BattleMode", "BATTLE MODE", "new"),
    ("Level_1", "LEVEL 1", "new"),
    ("Level_5", "LEVEL 5", "new"),
    ("Level_6", "LEVEL 6", "new"),
    ("Metlstrm", "METAL STORM", "new"),
    ("battletoads_level1", "TOADS LEVEL 1", "new"),
    ("contra7", "CONTRA 7", "new"),
    ("ng2_dark", "NINJA G2 DARK", "new"),
    ("sdb-usa", "SDB USA", "new"),
    ("smkbatt", "SMK BATTLE", "new"),
    ("supercendstage", "SUPER C END", "new"),
    ("CHOCOBO", "CHOCOBO", "new"),
    ("KNIDOG_N", "KNIDOG", "new"),
]


def convert(mid, out, title, args):
    r = subprocess.run([sys.executable, os.path.join(HERE, "midi2psq.py"), mid,
                        "--title", title, "-o", out] + args,
                       capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        raise RuntimeError((r.stdout + r.stderr).strip().splitlines()[-1])
    return r.stdout


def picks(text):
    """the parts a run chose (its "auto-picked parts" block), as options"""
    role, got, inside = None, {}, False
    for line in text.splitlines():
        if line.startswith("auto-picked parts"):
            inside = True
            continue
        if not inside:
            continue
        m = re.match(r"^\s+(lead|bass|harmony|drums|\+ also)\s+(\d[\d:,]*)(\s|$)", line)
        if not m:
            break                       # the block ended
        if m.group(1) != "+ also":
            role = {"harmony": "harm"}.get(m.group(1), m.group(1))
            got[role] = [m.group(2)]
        elif role:
            got[role].append(m.group(2))
    return [x for r, specs in got.items() for x in (f"--{r}", ",".join(specs))]


def window(path, frames=int(49 * 59.92)):
    """(frame, op, track, arg) of the notes and hits in the first ~49 s"""
    return [e for e in psq.read(path)[1] if e[0] < frames and e[1] in (0, 1, 2)]


def body_size(path):
    return os.path.getsize(path) - 32


def length(path):
    return psq.read(path)[0]["frames"] / 59.92


def build():
    os.makedirs(OUT, exist_ok=True)
    tmp = os.path.join(OUT, "_window.psq")
    rows = []
    for name, title, how in ALBUM:
        out = os.path.join(OUT, name + ".psq")
        mid = next((os.path.join(MIDIS, f) for f in os.listdir(MIDIS)
                    if f.lower() == name.lower() + ".mid"), None)
        note, warn = "", ""
        if how == "keep":
            data = bytearray(open(os.path.join(HERE, "songs", name + ".psq"), "rb").read())
            data[10:26] = title.ljust(16)[:16].encode()
            open(out, "wb").write(bytes(data))
        else:
            args = []
            if how == "rated":          # the parts of the rated 50 s window
                args = picks(convert(mid, tmp, title, ["--end", "50"]))
            text = convert(mid, out, title, args)
            warn = "; ".join(l.strip() for l in text.splitlines() if l.strip().startswith("!"))
            if body_size(out) > LIMIT:  # cut to the longest length that fits
                full = length(out)
                end = full * LIMIT / body_size(out) * 0.97
                while True:
                    convert(mid, out, title, args + ["--end", f"{end:.1f}"])
                    if body_size(out) <= LIMIT:
                        break
                    end *= 0.95
                note = f"cut to {end:.0f} s of {full:.0f} s"
        if how == "rated":              # the full song must begin as rated
            same = window(out) == window(os.path.join(HERE, "songs", name + ".psq"))
            note += "" if same else " (converter changed since it was rated)"
        rows.append((title, how, length(out), body_size(out), note, warn))
        print(f"  {title:16s} {how:5s} {int(length(out)) // 60}:{int(length(out)) % 60:02d} "
              f"{body_size(out):6d} B  {note} {('WARN ' + warn) if warn else ''}", flush=True)
    if os.path.exists(tmp):
        os.remove(tmp)
    total = sum(r[3] for r in rows)
    print(f"{len(rows)} songs, {total} bytes of events, "
          f"{sum(r[2] for r in rows) / 60:.0f} minutes")


if __name__ == "__main__":
    build()
