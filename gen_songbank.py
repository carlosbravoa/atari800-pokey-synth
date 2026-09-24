#!/usr/bin/env python3
"""Pack .psq sequences into songbank.bin, the player's song bank ($5000).

    python3 gen_songbank.py [song ...]        # names or paths, songs/ implied

Layout (little endian, base $5000):
    0           number of songs
    1 + i*24    catalog entry i:
        0-15    title, screen codes (ASCII-32), space padded
        16-17   address of the event stream
        18-19   frames per progress cell (length / 40, min 1)
        20      total minutes      21  total seconds
        22      mode 0 mono 1 stereo 2 either      23 reserved
    then each song's event stream, copied verbatim from the .psq body
    (delta / cmd / arg triples, END terminated). The Atari maps each psq
    op+track to an engine command at play time, so one bank plays on a
    mono or a stereo machine.

The bank is capped at BANK_SIZE; songs are taken in the order given until
the next one would not fit (it says which).
"""
import os
import sys

import psq

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = 0x5000
BANK_SIZE = 0xA000 - BASE       # $5000-$9FFF
ENT = 24
RATE = 59.92

# five full-length album songs (songs/album/) that fit the 20 KB together
DEFAULT = ["anthem", "kalinka", "MetalstormLvl3", "Dbz2", "smb109"]


def resolve(name):
    for p in (name, os.path.join(HERE, "songs", "album", name + ".psq"),
              os.path.join(HERE, "songs", name),
              os.path.join(HERE, "songs", name + ".psq")):
        if os.path.exists(p):
            return p
    sys.exit(f"gen_songbank: no such song: {name}")


def build(names, out="songbank.bin"):
    songs = []
    for name in names:
        path = resolve(name)
        h, _ = psq.read(path)
        body = open(path, "rb").read()[32:]
        songs.append((os.path.basename(path)[:-4], h, body))

    keep, used = [], 0
    for s in songs:
        head = 1 + (len(keep) + 1) * ENT
        if head + used + len(s[2]) > BANK_SIZE:
            print(f"  skipped {s[0]}: {len(s[2])} bytes would overflow the bank")
            continue
        keep.append(s)
        used += len(s[2])

    cat = bytearray([len(keep)])
    addr = BASE + 1 + len(keep) * ENT
    body = bytearray()
    for name, h, ev in keep:
        title = (h["title"] or name.upper())[:16].ljust(16)
        cat += bytes((ord(c.upper()) - 32) & 0x3F for c in title)
        cat += addr.to_bytes(2, "little")
        cat += max(1, h["frames"] // 40).to_bytes(2, "little")
        secs = round(h["frames"] / RATE)
        cat += bytes([min(99, secs // 60), secs % 60, h["mode"], 0])
        mode = {0: "mono", 1: "stereo", 2: "either"}[h["mode"]]
        print(f"  {title.strip():16s} ${addr:04X}  {len(ev):5d} B  "
              f"{secs // 60}:{secs % 60:02d}  {mode}")
        addr += len(ev)
        body += ev
    blob = bytes(cat) + bytes(body)
    open(os.path.join(HERE, out), "wb").write(blob)
    print(f"{out}: {len(keep)} songs, {len(blob)} bytes "
          f"(${BASE:04X}-${BASE + len(blob) - 1:04X}, "
          f"{BANK_SIZE - len(blob)} free)")


if __name__ == "__main__":
    build(sys.argv[1:] or DEFAULT)
