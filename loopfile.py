#!/usr/bin/env python3
"""Save / load POKEY SYNTH loops over the PC link.

    python3 loopfile.py save NAME     # snapshot the playing loop + your presets
    python3 loopfile.py load NAME     # write it back and play it
    python3 loopfile.py info NAME     # what's in a file
    python3 loopfile.py list          # saved loops

Files live in loops/NAME.psl: magic "PSL1", then zlib of
    LLEN(2 LE) T1USED  lanes M1 D P1 M2 P2 (LLEN bytes each)  live presets (130)

Everything goes through RAM: the looper's lanes and state are plain memory,
so no 6502 code is involved. Loading uses the same safe sequence as the
built-in demos: LCMD clear -> VBI empties the loop -> write lanes -> LLEN,
T1USED -> LSTATE STOP -> LCMD play-from-top.
"""
import os
import sys
import time
import zlib

ATARI = "/home/carlos/devel/fpga/atari800_tang_nano20k_parallel"
sys.path.insert(0, f"{ATARI}/tools")
from atari_link import AtariLink  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
LOOPS = os.path.join(HERE, "loops")
MAGIC = b"PSL1"

LANES = (0x5000, 0x6000, 0x7000, 0x8000, 0x9000)   # M1 D P1 M2 P2
PRESET, LSTATE, LCMD, LLEN = 0x0600, 0x0649, 0x064A, 0x064D
PRESREQ, T1USED, DEMOIDX, LOOPCNT = 0x0655, 0x066E, 0x066F, 0x0658
NPRESET_BYTES = 130
STATES = ["EMPTY", "REC", "PLAY", "DUB", "STOP"]


def labels():
    lbl = {}
    for line in open(os.path.join(HERE, "build/synth.lbl")):
        _, a, n = line.split()
        lbl[n.lstrip(".")] = int(a, 16)
    return lbl


def xex_bytes():
    """{address: byte} for the built program (to check the running build)"""
    d = open(os.path.join(HERE, "build/synth.xex"), "rb").read()
    mem, i = {}, 2
    while i < len(d):
        if d[i:i + 2] == b"\xff\xff":
            i += 2
        s = int.from_bytes(d[i:i + 2], "little")
        e = int.from_bytes(d[i + 2:i + 4], "little")
        for k, b in enumerate(d[i + 4:i + 5 + e - s]):
            mem[s + k] = b
        i += 5 + e - s
    return mem


def peek(l, addr, n):
    out = b""
    while len(out) < n:
        k = min(1024, n - len(out))
        out += bytes(l.peek(addr + len(out), k))
    return out


def peek_stable(l, addr, n):
    """read twice, retry until two reads agree (the link can serve stale bytes)"""
    a = peek(l, addr, n)
    for _ in range(4):
        b = peek(l, addr, n)
        if a == b:
            return a
        a = b
    sys.exit(f"reads of ${addr:04X} keep changing - is an overdub running?")


def poke(l, addr, data):
    for off in range(0, len(data), 256):
        l.poke(addr + off, data[off:off + 256])
    if peek(l, addr, len(data)) != bytes(data):
        sys.exit(f"verify failed at ${addr:04X}")


def check_build(l, lbl):
    """the running program must be this build (live-table address etc.)"""
    mem = xex_bytes()
    live = lbl["live"]
    lo = live - 64                      # static RODATA just before `live`
    want = bytes(mem[a] for a in range(lo, live))
    if peek(l, lo, 64) != want:
        sys.exit("the Atari isn't running this build - `make deploy` first")
    return live


def path(name):
    return os.path.join(LOOPS, name if name.endswith(".psl") else name + ".psl")


def read_file(name):
    raw = open(path(name), "rb").read()
    if raw[:4] != MAGIC:
        sys.exit(f"{name}: not a POKEY SYNTH loop file")
    d = zlib.decompress(raw[4:])
    n = d[0] | d[1] << 8
    lanes = [d[3 + k * n:3 + (k + 1) * n] for k in range(5)]
    presets = d[3 + 5 * n:3 + 5 * n + NPRESET_BYTES]
    return n, d[2], lanes, presets


def describe(n, t1used, lanes):
    m1, dr, _, m2, _ = lanes
    notes1 = sum(1 for v in m1 if 0 < v < 0xFE)
    notes2 = sum(1 for v in m2 if 0 < v < 0xFE)
    hits = sum(1 for v in dr if v)
    return (f"{n} frames ({n / 59.92:.1f} s): track 1 {notes1} notes, "
            f"track 2 {notes2} notes, {hits} drum hits")


def save(name):
    lbl = labels()
    with AtariLink() as l:
        l.ping()
        live = check_build(l, lbl)
        st = peek(l, LSTATE, 1)[0]
        if st in (0, 1):
            sys.exit(f"nothing to save: loop is {STATES[st]}"
                     + (" (close it with SPACE first)" if st == 1 else ""))
        if st == 3:
            print("note: overdub is on - saving what's recorded so far")
        n = int.from_bytes(peek(l, LLEN, 2), "little")
        t1 = peek(l, T1USED, 1)[0]
        lanes = [peek_stable(l, a, n) for a in LANES]
        presets = peek_stable(l, live, NPRESET_BYTES)
    os.makedirs(LOOPS, exist_ok=True)
    body = n.to_bytes(2, "little") + bytes([t1]) + b"".join(lanes) + presets
    open(path(name), "wb").write(MAGIC + zlib.compress(body, 9))
    print(f"saved {path(name)} ({os.path.getsize(path(name))} bytes): "
          + describe(n, t1, lanes))


def load(name):
    n, t1, lanes, presets = read_file(name)
    lbl = labels()
    with AtariLink() as l:
        l.ping()
        live = check_build(l, lbl)
        l.poke(LCMD, bytes([3]))                     # clear -> EMPTY
        for _ in range(50):
            time.sleep(0.05)
            if peek(l, LCMD, 1)[0] == 0 and peek(l, LSTATE, 1)[0] == 0:
                break
        else:
            sys.exit("the synth didn't take the clear command - is it running?")
        for a, lane in zip(LANES, lanes):
            poke(l, a, lane)
        poke(l, live, presets)
        l.poke(LLEN, n.to_bytes(2, "little"))
        l.poke(T1USED, bytes([t1]))
        l.poke(DEMOIDX, bytes([0]))
        l.poke(LSTATE, bytes([4]))                   # STOP: VBI leaves lanes be
        l.poke(PRESREQ, peek(l, PRESET, 1))          # reload the current sound
        l.poke(LCMD, bytes([2]))                     # play from the top
        time.sleep(0.3)
        st = peek(l, LSTATE, 1)[0]
    print(f"loaded {path(name)}: {describe(n, t1, lanes)}; loop {STATES[st]}")


def info(name):
    n, t1, lanes, presets = read_file(name)
    print(f"{path(name)}: {describe(n, t1, lanes)}")
    p1 = [v for v in lanes[2] if v]
    p2 = [v for v in lanes[4] if v]
    names = "PIANO ORGAN FLUTE STRINGS BASS CHIPARP SYNTH BELL LASER UFO".split()
    if p1:
        print("  track 1 sound:", ", ".join(names[v - 1] for v in p1))
    if p2:
        print("  track 2 sound:", ", ".join(names[v - 1] for v in p2))


def main():
    a = sys.argv[1:]
    if not a or a[0] not in ("save", "load", "info", "list") or (a[0] != "list" and len(a) < 2):
        sys.exit(__doc__)
    if a[0] == "list":
        if not os.path.isdir(LOOPS) or not os.listdir(LOOPS):
            print("no saved loops yet")
            return
        for f in sorted(os.listdir(LOOPS)):
            if f.endswith(".psl"):
                n, t1, lanes, _ = read_file(f)
                print(f"{f[:-4]:16s} {describe(n, t1, lanes)}")
        return
    {"save": save, "load": load, "info": info}[a[0]](a[1])


if __name__ == "__main__":
    main()
