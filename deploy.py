#!/usr/bin/env python3
"""Hot-swap deploy for POKEY SYNTH over the PC link.

The board currently ignores the firmware's reset/boot commands (2026-07-17),
so instead of `run FILE.XEX` this tool live-replaces the program in Atari RAM.

Running-game path (race-free, cooperative): poke the PARKREQ mailbox
($063D); the game's own main loop sees it during vblank, detaches its DLI
(VDSLST -> RTI stub) and VBI (SETVBV -> XITVBV) safely from the 6502 side,
and parks in a page-6 trampoline. We watch FRAME ($0617) stop ticking,
rewrite RAM, verify, and release the trampoline at the new entry.

Fresh-machine path (BASIC READY prompt): poke the binary, type X=USR(entry).

If FRAME is ticking but the running build doesn't honor PARKREQ (pre-mailbox
build), we abort — power cycle to READY and rerun.

Usage: python3 deploy.py [--xex build/synth.xex]
"""
import argparse
import sys
import time

ATARI = "/home/carlos/devel/fpga/atari800_tang_nano20k_parallel"
sys.path.insert(0, f"{ATARI}/tools")
from atari_link import AtariLink  # noqa: E402

FRAME = 0x0617
PARKREQ = 0x063D
TRAMP_VEC = 0x067C
TRAMP_FLAG = 0x067F


def parse_xex(path):
    d = open(path, "rb").read()
    assert d[:2] == b"\xff\xff", "not a .xex"
    segs, run, i = [], None, 2
    while i < len(d):
        if d[i:i + 2] == b"\xff\xff":
            i += 2
        s = int.from_bytes(d[i:i + 2], "little")
        e = int.from_bytes(d[i + 2:i + 4], "little")
        i += 4
        data = d[i:i + e - s + 1]
        i += e - s + 1
        if (s, e) == (0x02E0, 0x02E1):
            run = int.from_bytes(data, "little")
        else:
            segs.append((s, data))
    assert run is not None, "no RUNAD trailer"
    return segs, run


def usr_command(entry):
    """BASIC USR() launch whose typed text has NO adjacent duplicate chars.

    The board's `type` firmware collapses adjacent identical characters (e.g.
    "8288" -> "828"), which corrupts USR addresses with repeated digits. Emit
    an arithmetic form that evaluates to `entry` but avoids adjacent repeats.
    """
    def ok(s):
        return all(s[i] != s[i + 1] for i in range(len(s) - 1))
    cands = [str(entry)]
    for k in range(1, 10):
        cands.append(f"{entry - k}+{k}")
    for k in range(1, 10):
        cands.append(f"{entry + k}-{k}")
    for c in cands:
        s = f"X=USR({c})"
        if ok(s):
            return s
    # last resort: hi*256+lo (rarely needed)
    return f"X=USR({entry >> 8}*256+{entry & 255})"


def frame_ticking(l, wait=0.25):
    a = l.peek(FRAME, 1)
    time.sleep(wait)
    return l.peek(FRAME, 1) != a


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--xex", default="build/synth.xex")
    args = ap.parse_args()

    segs, entry = parse_xex(args.xex)
    print(f"entry ${entry:04X}, {sum(len(d) for _, d in segs)} bytes")

    with AtariLink() as l:
        running = frame_ticking(l)

        if running:
            print("game running — requesting self-park via mailbox")
            l.poke(TRAMP_FLAG, bytes([0]))
            l.poke(PARKREQ, bytes([1]))
            for _ in range(20):
                if not frame_ticking(l):
                    break
            else:
                sys.exit("build didn't park (no PARKREQ support?) — "
                         "power cycle to READY and rerun")
            print("parked")

        for start, data in segs:
            for off in range(0, len(data), 256):
                l.poke(start + off, data[off:off + 256])
            rb = b"".join(l.peek(start + o, min(1024, len(data) - o))
                          for o in range(0, len(data), 1024))
            ok = rb == data
            print(f"  ${start:04X}-${start + len(data) - 1:04X} "
                  f"{'OK' if ok else 'MISMATCH'}")
            if not ok:
                sys.exit("verify failed — NOT starting")

        if running:
            l.poke(TRAMP_VEC, entry.to_bytes(2, "little"))
            l.poke(TRAMP_FLAG, bytes([1]))
            print("released trampoline")
        else:
            cmd = usr_command(entry)
            # a bare RETURN first: text already on the cursor line (e.g. a
            # word typed at READY) would otherwise prefix the command and
            # BASIC answers ERROR instead of launching
            l.type_text("\n")
            time.sleep(0.4)
            l.type_text(cmd + "\n")
            print(f"typed launch: {cmd}")

        time.sleep(1.5)
        print("new build alive" if frame_ticking(l)
              else "WARNING: FRAME not ticking — check the machine")


if __name__ == "__main__":
    main()
