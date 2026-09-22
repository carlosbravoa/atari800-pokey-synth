#!/usr/bin/env python3
"""Hardware looper check: record/close/replay/overdub/stop/clear with real
HID key presses, verified by peeking the looper state and lanes."""
import sys, time
sys.path.insert(0, "/home/carlos/devel/fpga/atari800_tang_nano20k_parallel/tools")
from atari_link import AtariLink

SPACE, TAB, BKSP, A, C, V, ESC = 0x2C, 0x2B, 0x2A, 0x04, 0x06, 0x19, 0x29
ok = True


def check(c, msg):
    global ok
    print(("PASS " if c else "FAIL ") + msg)
    ok &= bool(c)


def st(l):
    b = l.peek(0x0600, 0x59)
    return dict(ls=b[0x49], pos=b[0x4B] | b[0x4C] << 8, len=b[0x4D] | b[0x4E] << 8,
                notes=b[0x23], drums=b[0x24], loops=b[0x58], cell=b[0x4F])


def tap(l, k, wait=0.35):
    l.key(k, hold_ms=100)
    time.sleep(wait)


with AtariLink() as l:
    tap(l, ESC)                       # throwaway: first key of a session is lost
    tap(l, ESC)
    tap(l, BKSP)
    check(st(l)['ls'] == 0, "starts EMPTY")
    tap(l, SPACE, 0.2)
    check(st(l)['ls'] == 1, "SPACE -> REC")
    time.sleep(0.3)
    l.key(A, hold_ms=400); time.sleep(0.8)
    tap(l, C, 0.8)
    tap(l, SPACE, 0.3)
    s = st(l)
    check(s['ls'] == 2 and 90 < s['len'] < 250, f"SPACE -> PLAY, loop {s['len']} frames")
    L = s['len']
    ml = l.peek(0x5000, L); dl = l.peek(0x6000, L); pl = l.peek(0x7000, 4)
    on = [i for i, v in enumerate(ml) if 0 < v < 0xFE]
    off = [i for i, v in enumerate(ml) if v == 0xFE]
    kk = [i for i, v in enumerate(dl) if v]
    check(len(on) == 1 and ml[on[0]] == 37 and off and 18 <= off[0] - on[0] <= 30,
          f"lanes: note C4 on@{on} off@{off} ({(off[0]-on[0]) if off else '?'} frames)")
    check(len(kk) == 1 and dl[kk[0]] == 1 and pl[0] == 1, f"kick@{kk}, preset PIANO@0")
    a = st(l); time.sleep(L / 60 * 3 + 0.2); b = st(l)
    loops = (b['loops'] - a['loops']) & 255
    check(loops >= 3 and (b['notes'] - a['notes']) & 255 == loops
          and (b['drums'] - a['drums']) & 255 == loops,
          f"{loops} passes replayed {(b['notes']-a['notes'])&255} notes, "
          f"{(b['drums']-a['drums'])&255} kicks")
    tap(l, SPACE, 0.2)
    check(st(l)['ls'] == 3, "SPACE -> DUB")
    tap(l, V, 0.2)
    time.sleep(L / 60)
    tap(l, SPACE, 0.2)
    check(st(l)['ls'] == 2, "SPACE -> PLAY")
    dl = l.peek(0x6000, L)
    hits = sorted((i, v) for i, v in enumerate(dl) if v)
    check([v for _, v in hits].count(2) >= 1 and [v for _, v in hits].count(1) == 1,
          f"drum lane after overdub {hits}")
    a = st(l); time.sleep(L / 60 * 2 + 0.2); b = st(l)
    loops = (b['loops'] - a['loops']) & 255
    check((b['drums'] - a['drums']) & 255 == loops * len(hits),
          f"{loops} passes x {len(hits)} drums = {(b['drums']-a['drums'])&255} hits")
    tap(l, TAB, 0.3)
    a = st(l); time.sleep(L / 60 + 0.3); b = st(l)
    check(a['ls'] == 4 and b['drums'] == a['drums'] and b['notes'] == a['notes'],
          "TAB -> STOP, silent")
    tap(l, TAB, 0.3)
    check(st(l)['ls'] == 2, "TAB -> PLAY")
    print("\n".join(l.screen().split("\n")[9:11]))
    tap(l, BKSP, 0.3)
    check(st(l)['ls'] == 0, "BACKSPACE -> EMPTY")
print("ALL PASS" if ok else "SOME FAILED")
