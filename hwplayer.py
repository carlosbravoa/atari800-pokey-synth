#!/usr/bin/env python3
"""Hardware check of POKEY PLAYER: real key presses, verified by peeks.
> next song, < previous, SPACE pause/resume, RETURN replay, song liveness,
and the panel keeping pace with the frame rate (DRAWN vs RTCLOK)."""
import sys, time
sys.path.insert(0, "/home/carlos/devel/fpga/atari800_tang_nano20k_parallel/tools")
from atari_link import AtariLink

NEXT, PREV, SPACE, RET, ESC = 0x2E, 0x2D, 0x2C, 0x28, 0x29
KEY_L, DOWN, TAB = 0x0F, 0x51, 0x2B
lbl = {ln.split()[2].lstrip("."): int(ln.split()[1], 16) for ln in open("build/player.lbl")}
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
    # the song list: L opens it, down twice, RETURN plays that song
    n0 = st()[1]
    l.key(KEY_L, hold_ms=80); time.sleep(0.6)
    on = l.peek(lbl["liston"], 1)[0]
    head = bytes(l.peek(0x1800, 40))            # LISTSCR = SCOPEA
    text = "".join(chr(32 + (c & 0x3F)) for c in head)
    check(on == 1 and "SONG LIST" in text, f"L opens the song list: {text.strip()!r}")
    for _ in range(2):
        l.key(DOWN, hold_ms=80); time.sleep(0.5)
    sel = l.peek(lbl["lsel"], 1)[0]
    check(sel == min(n0 + 2, st()[2] - 1), f"down arrows move the highlight to song {sel + 1}")
    l.key(RET, hold_ms=80); time.sleep(0.8)
    s2 = st()
    check(s2[1] == sel and l.peek(lbl["liston"], 1)[0] == 0, f"RETURN plays song {s2[1] + 1}, back to the panel")
    l.key(TAB, hold_ms=80); time.sleep(0.5)
    l.key(ESC, hold_ms=80); time.sleep(0.5)
    check(l.peek(lbl["liston"], 1)[0] == 0 and st()[1] == sel, "TAB opens it, ESC closes it, the song plays on")
    # the panel (meters + scope) must keep up: one main-loop pass per frame
    f0 = l.peek(0x12, 3); d0 = l.peek(0x0BC1, 1)[0]
    time.sleep(4)
    f1 = l.peek(0x12, 3); d1 = l.peek(0x0BC1, 1)[0]
    rt = ((f1[1] * 256 + f1[2]) - (f0[1] * 256 + f0[2])) % 65536
    check((rt - (d1 - d0)) % 256 == 0, f"no dropped frames ({rt} frames, DRAWN kept pace)")
print("ALL PASS" if ok else "FAILURES")
