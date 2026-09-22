#!/usr/bin/env python3
"""Hardware round trip for loopfile.py: demo + a preset edit -> save ->
wipe both -> load -> identical lanes, edit restored, same per-pass playback."""
import os, subprocess, sys, time
sys.path.insert(0, "/home/carlos/devel/fpga/atari800_tang_nano20k_parallel/tools")
from atari_link import AtariLink
import loopfile as lf

ok = True
NAME = "_hwsave_test"


def check(c, msg):
    global ok
    print(("PASS " if c else "FAIL ") + msg)
    ok &= bool(c)


def keys(l, *hids):
    for k in hids:
        l.key(k, hold_ms=100)
        time.sleep(0.4)


def one_pass(l):
    st = lambda: l.peek(0x0600, 0x75)
    c = st()[0x58]
    while st()[0x58] == c:
        pass
    a = st()
    while (st()[0x58] - a[0x58]) & 255 < 1:
        pass
    z = st()
    return [(z[i] - a[i]) & 255 for i in (0x6D, 0x72, 0x23, 0x24)]


def run(*args):
    r = subprocess.run([sys.executable, "loopfile.py", *args], capture_output=True, text=True)
    print("  $ loopfile.py", *args, "->", (r.stdout + r.stderr).strip())
    return r.returncode


live = lf.labels()["live"]
with AtariLink() as l:
    keys(l, 0x29, 0x2A, 0x1E, 0x28)            # throwaway, clear, PIANO, RETURN
    l.poke(0x0603, bytes([0]))                 # editor on WAVE (row 0)
    keys(l, 0x51, 0x4F, 0x4F, 0x52)            # PIANO: down, right x2 (ATTACK 2), up
    check(l.peek(live + 1, 1)[0] == 2, "PIANO attack edited to 2")
    keys(l, 0x2E, 0x2E)                        # '>' '>' -> TECHNO
    before = [lf.peek(l, a, 224) for a in lf.LANES]
    ref = one_pass(l)
    print("  reference pass", ref)
check(run("save", NAME) == 0, "save")
with AtariLink() as l:
    keys(l, 0x29, 0x2A, 0x1E, 0x28)            # wipe: clear loop, RETURN restores PIANO
    check(l.peek(0x0649, 1)[0] == 0 and l.peek(live + 1, 1)[0] == 0, "loop cleared, edit undone")
check(run("load", NAME) == 0, "load")
with AtariLink() as l:
    b = l.peek(0x0600, 0x75)
    check(b[0x49] == 2 and (b[0x4D] | b[0x4E] << 8) == 224, "loaded loop playing, 224 frames")
    after = [lf.peek(l, a, 224) for a in lf.LANES]
    check(after == before, "all five lanes identical")
    check(l.peek(live + 1, 1)[0] == 2, "PIANO's edited attack restored in the preset table")
    got = one_pass(l)
    check(got == ref, f"same per-pass playback {got}")
check(run("info", NAME) == 0, "info")
os.remove(lf.path(NAME))
with AtariLink() as l:
    keys(l, 0x29, 0x2A, 0x1E, 0x28)            # clear, PIANO factory again
check(run("save", NAME) != 0 and not os.path.exists(lf.path(NAME)),
      "save refuses an EMPTY loop")
print("ALL PASS" if ok else "SOME FAILED")
