#!/usr/bin/env python3
"""Load a 2-bar demo loop straight into the looper lanes and start it:
BASS buzz line on voice 2 (track 1), FLUTE melody on the lead (track 2),
kick/snare/hat drums. ~112 BPM (8 frames per 16th). TAB/BACKSPACE work on it
like on a recorded loop. Usage: python3 demo_loop.py"""
import sys, time
sys.path.insert(0, "/home/carlos/devel/fpga/atari800_tang_nano20k_parallel/tools")
from atari_link import AtariLink

S = 8                      # frames per 16th
LEN = 32 * S               # two bars
M1, D, P1, M2, P2 = (bytearray(LEN) for _ in range(5))


def note(lane, t16, n, dur16, gap=3):
    lane[t16 * S] = n + 1
    lane[t16 * S + dur16 * S - gap] = 0xFE


# bassline (note 0 = C1): C2 riff, then F2
bass = [12, 12, 19, 12, 15, 12, 19, 22, 17, 17, 24, 17, 19, 19, 22, 19]
for i, n in enumerate(bass):
    note(M1, i * 2, n, 2)
# melody (FLUTE): G4 A#4 C5 D#5 | D5 C5 A#4 G4
mel = [(0, 43, 4), (4, 46, 4), (8, 48, 6), (14, 51, 2),
       (16, 50, 4), (20, 48, 4), (24, 46, 4), (28, 43, 4)]
for t, n, d in mel:
    note(M2, t, n, d)
# drums: 1 kick 2 snare 3 hat (lane codes = drum+1)
for t in range(32):
    if t % 8 == 0 or t % 8 == 6 and t > 16:
        D[t * S] = 1
    elif t % 8 == 4:
        D[t * S] = 2
    elif t % 2 == 0:
        D[t * S] = 3
P1[0] = 5                  # BASS preset for voice 2
P2[0] = 3                  # FLUTE preset for the lead

with AtariLink() as l:
    l.poke(0x064A, bytes([3]))          # LCMD clear -> EMPTY (VBI stops touching lanes)
    time.sleep(0.2)
    for base, lane in zip((0x5000, 0x6000, 0x7000, 0x8000, 0x9000), (M1, D, P1, M2, P2)):
        for off in range(0, LEN, 256):
            l.poke(base + off, bytes(lane[off:off + 256]))
        assert bytes(l.peek(base, LEN)) == bytes(lane), f"lane ${base:04X} verify"
    l.poke(0x064D, LEN.to_bytes(2, "little"))   # LLEN
    l.poke(0x066E, bytes([1]))                  # T1USED: voice 2 owns ch3
    l.poke(0x0649, bytes([4]))                  # LSTATE = STOP
    time.sleep(0.1)
    l.poke(0x064A, bytes([2]))                  # LCMD = TAB -> play from the top
    time.sleep(1.0)
    b = l.peek(0x0600, 0x70)
    print(f"state {b[0x49]} (2 = PLAY), pos {b[0x4B] | b[0x4C] << 8}/{LEN}, "
          f"voice-2 notes {b[0x6D]}, lead notes {b[0x23]}, drums {b[0x24]}")
