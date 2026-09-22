#!/usr/bin/env python3
"""Hardware check of the built-in demos: press > (PC '=' key) through all
of them; each must load, play, and replay its data every pass."""
import sys, time, importlib.util, io, contextlib
sys.path.insert(0, "/home/carlos/devel/fpga/atari800_tang_nano20k_parallel/tools")
from atari_link import AtariLink

spec = importlib.util.spec_from_file_location("gd", "gen_demos.py")
gd = importlib.util.module_from_spec(spec)
with contextlib.redirect_stdout(io.StringIO()):
    spec.loader.exec_module(gd)
Q, PREV, ESC, BKSP = 0x2E, 0x2D, 0x29, 0x2A   # PC '=' -> Atari '>', '-' -> '<'
ok = True


def check(c, msg):
    global ok
    print(("PASS " if c else "FAIL ") + msg)
    ok &= bool(c)


with AtariLink() as l:
    st = lambda: l.peek(0x0600, 0x72)
    l.key(ESC, hold_ms=100); time.sleep(0.4)          # throwaway first key
    l.key(BKSP, hold_ms=100); time.sleep(0.4)
    for di, (name, S, N, p1, p2, t1, t2, dr) in enumerate(gd.DEMOS):
        l.key(Q, hold_ms=100); time.sleep(0.5)
        b = st()
        LL = b[0x4D] | b[0x4E] << 8
        check(b[0x6F] == di + 1 and LL == N * S and b[0x49] == 2,
              f"> -> demo {di + 1} {name}: {LL} frames, state {b[0x49]}")
        c = st()[0x58]
        while st()[0x58] == c:
            pass
        a = st()
        while (st()[0x58] - a[0x58]) & 255 < 1:
            pass
        z = st()
        got = [(z[i] - a[i]) & 255 for i in (0x6D, 0x23, 0x24)]
        want = [len(t1), len(t2), sum(1 for v in dr if v)]
        check(got == want, f"  one pass voice2/lead/drums {got} (want {want})")
        print("  " + l.screen().split("\n")[10].strip())
    l.key(Q, hold_ms=100); time.sleep(0.5)
    check(st()[0x6F] == 1, "> wraps to GROOVE")
    l.key(PREV, hold_ms=100); time.sleep(0.5)
    check(st()[0x6F] == len(gd.DEMOS), "< wraps back to the last demo")
    l.key(Q, hold_ms=100); time.sleep(0.5)
    check(st()[0x6F] == 1, "> again: GROOVE (left playing)")
print("ALL PASS" if ok else "SOME FAILED")
