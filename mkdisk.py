#!/usr/bin/env python3
"""Build build/pokeyplayer.atr: a bootable POKEY PLAYER disk, no PC needed.

    python3 mkdisk.py [song ...]          # default: the album (album.py)

Single density (128-byte sectors), at least 720 sectors:
    1-3     boot loader (boot.s), patched with where the player lives
    4-11    catalog: count byte + 24 bytes per song (max 42)
              title(16, screen codes) first-sector(2) frames-per-progress-
              cell(2) minutes seconds mode sectors
    12..    the player (build/player_disk.xex, a normal binary-load file)
    then    each song's .psq event stream, starting on a sector boundary,
            at most 160 sectors (the $5000-$9FFF buffer)
The player reads the catalog at boot and loads a song when it's picked.
"""
import os
import sys

import psq

HERE = os.path.dirname(os.path.abspath(__file__))
SS = 128
CATSEC, CATN = 4, 8
ENT = 24
MAXSEC = (0xA000 - 0x5000) // SS
RATE = 59.92

def album_paths():
    """the album (album.py), in its order, from songs/album/"""
    import album
    return [os.path.join(album.OUT, name + ".psq") for name, _, _ in album.ALBUM]


DISK_SONGS = album_paths()


def sectors(data):
    return (len(data) + SS - 1) // SS


def build(names, out="build/pokeyplayer.atr"):
    boot = bytearray(open(os.path.join(HERE, "build/boot.bin"), "rb").read())
    xex = open(os.path.join(HERE, "build/player_disk.xex"), "rb").read()
    assert len(boot) == 3 * SS
    xsec = CATSEC + CATN
    boot[9:11] = xsec.to_bytes(2, "little")
    boot[11:13] = len(xex).to_bytes(2, "little")

    songs = []
    for name in names:
        path = name if os.path.exists(name) else os.path.join(HERE, "songs", name + ".psq")
        name = os.path.basename(path)[:-4]
        h, _ = psq.read(path)
        body = open(path, "rb").read()[32:]
        if sectors(body) > MAXSEC:
            print(f"  skipped {name}: {len(body)} bytes is over the 20 KB buffer")
            continue
        songs.append((name, h, body))
    maxsongs = (CATN * SS - 1) // ENT
    if len(songs) > maxsongs:
        print(f"  catalog holds {maxsongs}: dropping {len(songs) - maxsongs}")
        songs = songs[:maxsongs]

    sec = xsec + sectors(xex)
    cat = bytearray([len(songs)])
    image = {1: boot}
    for name, h, body in songs:
        title = (h["title"] or name.upper())[:16].ljust(16)
        secs = round(h["frames"] / RATE)
        cat += bytes((ord(c.upper()) - 32) & 0x3F for c in title)
        cat += sec.to_bytes(2, "little")
        cat += max(1, h["frames"] // 40).to_bytes(2, "little")
        cat += bytes([min(99, secs // 60), secs % 60, h["mode"], sectors(body)])
        image[sec] = body
        print(f"  {title.strip():16s} sector {sec:4d}  {sectors(body):3d} sectors  "
              f"{secs // 60}:{secs % 60:02d}")
        sec += sectors(body)
    image[CATSEC] = bytes(cat)
    image[xsec] = xex
    total = max(720, sec - 1)

    disk = bytearray(total * SS)
    for s, data in image.items():
        disk[(s - 1) * SS:(s - 1) * SS + len(data)] = data
    para = len(disk) // 16
    head = bytearray(16)
    head[0:2] = b"\x96\x02"
    head[2:4] = (para & 0xFFFF).to_bytes(2, "little")
    head[4:6] = SS.to_bytes(2, "little")
    head[6] = para >> 16
    path = os.path.join(HERE, out)
    open(path, "wb").write(bytes(head) + bytes(disk))
    print(f"{out}: {len(songs)} songs, player {len(xex)} bytes at sector {xsec}, "
          f"{sec - 1} of {total} sectors used ({(len(disk) + 16) // 1024} KB)")
    return path


if __name__ == "__main__":
    build(sys.argv[1:] or DISK_SONGS)
