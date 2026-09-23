#!/usr/bin/env python3
"""Hardware check of POKEY PLAYER: real key presses, verified by peeks.
> next song, < previous, SPACE pause/resume, RETURN replay, song liveness."""
import sys, time
sys.path.insert(0, "/home/carlos/devel/fpga/atari800_tang_nano20k_parallel/tools")
from atari_link import AtariLink

NEXT, PREV, SPACE, RET, ESC = 0x2E, 0x2D, 0x2C, 0x28, 0x29
ok = True


def check(c, msg):
    global ok
    print(("PASS " if c else "FAIL ") + msg)
    ok &= bool(c)


with AtariLink() as l:
    st = lambda: l.peek(0x0644, 0x28)       # PLAYING SONGN NSONG SEVN PAUSED ...
    pos = lambda s: s[0x16] | s[0x17] << 8  # SPOS $065A
    l.key(0x04, hold_ms=60); time.sleep(0.5)   # throwaway first key ('A': unused)
    s0 = st()
    print("stereo:", l.peek(0x0673, 1)[0], " songs:", s0[2])
    time.sleep(1.0)
    s1 = st()
    check(s1[0] == 1 and pos(s1) > pos(s0), f"playing: SPOS {pos(s0)} -> {pos(s1)}")
    n0 = s1[1]
    l.key(NEXT, hold_ms=80); time.sleep(0.8)
    s = st()
    check(s[1] == (n0 + 1) % s[2] and s[0] == 1, f"> : song {n0 + 1} -> {s[1] + 1}")
    time.sleep(1.0)
    s2 = st()
    check(pos(s2) > pos(s), f"new song advancing: SPOS {pos(s)} -> {pos(s2)}")
    l.key(PREV, hold_ms=80); time.sleep(0.8)
    check(st()[1] == n0, "< : back to the first song")
    l.key(SPACE, hold_ms=80); time.sleep(0.6)
    a = st(); time.sleep(1.0); b = st()
    check(a[4] == 1 and pos(a) == pos(b), f"SPACE pauses (SPOS held at {pos(a)})")
    l.key(SPACE, hold_ms=80); time.sleep(0.6)
    a = st(); time.sleep(1.0); b = st()
    check(a[4] == 0 and pos(b) > pos(a), "SPACE resumes")
    l.key(RET, hold_ms=80); time.sleep(0.5)
    check(pos(st()) < 60, f"RETURN replays from the top (SPOS {pos(st())})")
print("ALL PASS" if ok else "FAILURES")
