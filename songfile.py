#!/usr/bin/env python3
"""POKEY SYNTH songs: a list of saved loops (sections) with repeat counts,
played gaplessly on the Atari while the PC streams the next section.

    python3 songfile.py play NAME [--loop]   # play songs/NAME.song or .pss
    python3 songfile.py pack NAME            # .song + its loops -> one .pss
    python3 songfile.py info NAME
    python3 songfile.py list

A .song is text, one section per line:  <loop name> [repeats]
    # my first song
    intro 1
    verse 4
    chorus 2
Loop names are files in loops/ (made with loopfile.py save). A .pss is the
same song with the loop data packed in, so it's a single file to keep/share.

How it plays: the Atari's loop lanes hold two banks of 2048 frames (~34 s).
The current section plays from one bank while this script writes the next
section into the other. During the section's last repeat it sets NEXTREQ,
and the Atari's VBI flips banks exactly at the loop seam (frame-exact, no
gap). NEXTREQ 2 stops the song at the final seam. Ctrl-C stops at once.
"""
import os
import sys
import time

import loopfile as lf
from loopfile import AtariLink

HERE = os.path.dirname(os.path.abspath(__file__))
SONGS = os.path.join(HERE, "songs")
BANKLEN = 2048
LBANK, NEXTREQ, NEXTLEN, NEXTT1, SECTCNT = 0x0676, 0x0677, 0x0678, 0x067A, 0x067B


def spath(name, ext):
    return os.path.join(SONGS, name if name.endswith(ext) else name + ext)


def parse_song(name):
    """-> [(section name, repeats, (LLEN, T1USED, lanes, presets))]"""
    if os.path.exists(spath(name, ".pss")) and not os.path.exists(spath(name, ".song")):
        return read_pss(name)
    secs = []
    for n, line in enumerate(open(spath(name, ".song")), 1):
        line = line.split("#")[0].strip()
        if not line:
            continue
        parts = line.split()
        reps = int(parts[1]) if len(parts) > 1 else 1
        if not 1 <= reps <= 99:
            sys.exit(f"line {n}: repeats must be 1..99")
        if not os.path.exists(lf.path(parts[0])):
            sys.exit(f"line {n}: no loop '{parts[0]}' in loops/ (loopfile.py save {parts[0]})")
        secs.append((parts[0], reps, lf.read_file(parts[0])))
    if not secs:
        sys.exit("empty song")
    return secs


def read_pss(name):
    d = open(spath(name, ".pss"), "rb").read()
    if d[:4] != b"PSS1":
        sys.exit("not a packed POKEY SYNTH song")
    secs, i, blobs = [], 5, {}
    for _ in range(d[4]):
        k = d[i]; nm = d[i + 1:i + 1 + k].decode(); i += 1 + k
        reps = d[i]; bl = d[i + 1] | d[i + 2] << 8; i += 3
        blob = d[i:i + bl]; i += bl
        tmp = os.path.join(SONGS, ".unpack.psl")
        open(tmp, "wb").write(blob)
        secs.append((nm, reps, lf.read_file(tmp)))
        os.remove(tmp)
    return secs


def pack(name):
    secs = []
    for n, line in enumerate(open(spath(name, ".song")), 1):
        line = line.split("#")[0].strip()
        if line:
            p = line.split()
            secs.append((p[0], int(p[1]) if len(p) > 1 else 1))
    out = bytearray(b"PSS1" + bytes([len(secs)]))
    for nm, reps in secs:
        blob = open(lf.path(nm), "rb").read()
        out += bytes([len(nm)]) + nm.encode() + bytes([reps]) + len(blob).to_bytes(2, "little") + blob
    open(spath(name, ".pss"), "wb").write(out)
    print(f"packed {spath(name, '.pss')} ({len(out)} bytes, {len(secs)} sections)")


def describe(secs):
    total = 0
    for nm, reps, (n, _, lanes, _) in secs:
        total += n * reps
        print(f"  {nm:16s} x{reps:<3d} {n:5d} frames  " + lf.describe(n, 0, lanes).split(": ")[1])
    print(f"  total {total} frames = {total / 59.92:.1f} s")


def write_bank(l, bank, sec):
    n, t1, lanes, _ = sec
    for base, lane in zip(lf.LANES, lanes):
        lf.poke(l, base + bank * 0x800, lane)


def play(name, loop=False, trace=None):
    secs = parse_song(name)
    for nm, _, (n, _, _, _) in secs:
        if n > BANKLEN:
            sys.exit(f"section '{nm}' is {n} frames; song sections max {BANKLEN} (~34 s)")
    print(f"song {name}:")
    describe(secs)
    lbl = lf.labels()
    with AtariLink() as l:
        l.ping()
        live = lf.check_build(l, lbl)
        pk = lambda a: lf.peek(l, a, 1)[0]

        def clock():                                 # RTCLOK hi/lo in one read
            b = lf.peek(l, 0x13, 2)
            return b[0] << 8 | b[1]
        l.poke(lf.LCMD, bytes([3]))                  # clear: EMPTY, bank 0
        for _ in range(50):
            time.sleep(0.05)
            if pk(lf.LCMD) == 0 and pk(lf.LSTATE) == 0:
                break
        else:
            sys.exit("the synth didn't take the clear command - is it running?")
        n0, t10, _, presets = secs[0][2]
        write_bank(l, 0, secs[0][2])
        lf.poke(l, live, presets)                    # the first section's sounds
        l.poke(lf.LLEN, n0.to_bytes(2, "little"))
        l.poke(lf.T1USED, bytes([t10]))
        l.poke(lf.DEMOIDX, bytes([0]))
        l.poke(lf.LSTATE, bytes([4]))
        l.poke(lf.PRESREQ, bytes([pk(lf.PRESET)]))
        f0 = clock()                                 # Atari frame clock
        l.poke(lf.LCMD, bytes([2]))                  # play bank 0 from the top
        time.sleep(0.2)
        bank, i = 0, 0
        base, sc = pk(lf.LOOPCNT), pk(SECTCNT)
        if trace is not None:
            trace.append(dict(t=0, bank=pk(LBANK), llen=n0, loops=base))
        try:
            while True:
                nm, reps, sec = secs[i]
                nxt = i + 1 if i + 1 < len(secs) else (0 if loop else None)
                print(f"> {nm} x{reps}", flush=True)
                if nxt is not None:                  # preload the other bank
                    write_bank(l, bank ^ 1, secs[nxt][2])
                while (pk(lf.LOOPCNT) - base) & 255 < reps - 1:
                    time.sleep(0.03)
                late = ((pk(lf.LOOPCNT) - base) & 255) - (reps - 1)
                if nxt is None:
                    l.poke(NEXTREQ, bytes([2]))
                else:
                    n, t1, _, _ = secs[nxt][2]
                    l.poke(NEXTLEN, n.to_bytes(2, "little"))
                    l.poke(NEXTT1, bytes([t1]))
                    l.poke(NEXTREQ, bytes([1]))
                if late > 0:
                    print(f"  (late by {late} pass(es): the section repeated extra)")
                while pk(SECTCNT) == sc:
                    time.sleep(0.02)
                sc = pk(SECTCNT)
                base = pk(lf.LOOPCNT)
                if trace is not None:
                    f = clock()
                    trace.append(dict(t=(f - f0) & 0xFFFF, bank=pk(LBANK),
                                      llen=int.from_bytes(lf.peek(l, lf.LLEN, 2), "little"),
                                      state=pk(lf.LSTATE), loops=base))
                if nxt is None:
                    print("song over")
                    return
                bank ^= 1
                i = nxt
        except KeyboardInterrupt:
            l.poke(NEXTREQ, bytes([0]))
            l.poke(lf.LCMD, bytes([2]))              # TAB: stop now
            print("\nstopped")


def main():
    a = sys.argv[1:]
    if not a or a[0] not in ("play", "pack", "info", "list") or (a[0] != "list" and len(a) < 2):
        sys.exit(__doc__)
    if a[0] == "list":
        if not os.path.isdir(SONGS):
            print("no songs yet (write songs/NAME.song)")
            return
        for f in sorted(os.listdir(SONGS)):
            if f.endswith((".song", ".pss")):
                print(f)
        return
    if a[0] == "play":
        tr = [] if "--trace" in a else None
        play(a[1], loop="--loop" in a, trace=tr)
        for e in tr or []:
            print("  trace", e)
    elif a[0] == "pack":
        pack(a[1])
    else:
        print(f"song {a[1]}:")
        describe(parse_song(a[1]))


if __name__ == "__main__":
    main()
