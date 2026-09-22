#!/usr/bin/env python3
"""Hardware check for POKEY SYNTH: real HID key presses through the board's
keyboard path, verified by peeking page-6 state. Usage: python3 hwtest.py"""
import sys, time
sys.path.insert(0, "/home/carlos/devel/fpga/atari800_tang_nano20k_parallel/tools")
from atari_link import AtariLink

HID = {'a': 0x04, 'k': 0x0E, 'c': 0x06, 'x': 0x1B, 'z': 0x1D, '6': 0x23,
       '1': 0x1E, '0': 0x27, 'right': 0x4F, 'left': 0x50, 'down': 0x51,
       'up': 0x52, 'ret': 0x28, 'esc': 0x29, 'f8': 0x41}
P = 0x0600
ok = True


def st(l):
    b = l.peek(P, 0x44)
    return dict(preset=b[0], octave=b[1], edsel=b[3], held=b[7], lit=b[9],
                note=b[0x0A], estate=b[0x0B], vol=b[0x0D],
                out=b[0x12] | b[0x13] << 8, frame=b[0x17], gate=b[0x27],
                notecnt=b[0x23], drumcnt=b[0x24], keycnt=b[0x25],
                params=list(b[0x30:0x3C]), ui=b[0x43])


def check(c, msg):
    global ok
    print(("PASS " if c else "FAIL ") + msg)
    ok &= bool(c)


with AtariLink() as l:
    for k in (0x29, 0x2A, 0x1E, 0x28):  # throwaway, BKSP (stop loop), 1 PIANO, RETURN
        l.key(k, hold_ms=100); time.sleep(0.4)
    s0 = st(l); time.sleep(0.5); s1 = st(l)
    check(s1['frame'] != s0['frame'] and s1['ui'] != s0['ui'],
          f"VBI + main loop alive (frame {s0['frame']}->{s1['frame']})")
    check(s1['params'][:5] == [0, 0, 9, 0, 6] and s1['octave'] == 4,
          f"PIANO preset loaded {s1['params']} oct {s1['octave']}")

    t = time.time(); l.key(HID['a'], hold_ms=1500); dt = time.time() - t
    s = st(l)
    print(f"  key() returned after {dt:.2f}s; state {s}")
    check(s['notecnt'] == s1['notecnt'] + 1 and s['note'] == 36,
          "A played one note, C4 (note 36)")
    time.sleep(1.8)                  # key() returns at once; hold runs on
    s = st(l)
    check(s['gate'] == 0 and s['lit'] == 0xFF and s['estate'] == 0,
          f"released: gate {s['gate']} estate {s['estate']} vol {s['vol']}")

    l.key(HID['x'], hold_ms=120); time.sleep(0.3)
    check(st(l)['octave'] == 5, "X -> octave 5")
    l.key(HID['z'], hold_ms=120); time.sleep(0.3)
    check(st(l)['octave'] == 4, "Z -> octave 4")

    l.key(HID['6'], hold_ms=120); time.sleep(0.3)
    s = st(l)
    check(s['preset'] == 5 and s['params'][8] == 1, "6 -> CHIPARP")
    l.key(HID['1'], hold_ms=120); time.sleep(0.3)

    d0 = st(l)['drumcnt']
    l.key(HID['c'], hold_ms=100); time.sleep(0.3)
    check(st(l)['drumcnt'] == d0 + 1, "C hits the kick")

    l.key(HID['down'], hold_ms=120); time.sleep(0.3)
    l.key(HID['right'], hold_ms=120); time.sleep(0.3)
    s = st(l)
    check(s['edsel'] == 1 and s['params'][1] == 1,
          f"arrow down+right: edsel {s['edsel']} attack {s['params'][1]}")
    l.key(HID['right'], hold_ms=1200); time.sleep(1.5)
    s = st(l)
    check(s['params'][1] >= 5, f"held right arrow repeats: attack {s['params'][1]}")
    l.key(HID['ret'], hold_ms=120); time.sleep(0.3)
    s = st(l)
    check(s['params'][1] == 0, "RETURN restores factory attack")
    l.key(HID['up'], hold_ms=120); time.sleep(0.3)

    l.key(HID['f8'], hold_ms=150); time.sleep(0.3)
    check(st(l)['preset'] == 1, "F8 (OPTION) -> next preset ORGAN")
    l.key(HID['1'], hold_ms=120); time.sleep(0.3)
    check(st(l)['preset'] == 0, "back to PIANO")
    print(l.screen())
print("ALL PASS" if ok else "SOME FAILED")
