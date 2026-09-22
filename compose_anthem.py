#!/usr/bin/env python3
"""ANTHEM as a full song: writes loops/anthem_*.psl, songs/anthem.song and
the packed songs/anthem.pss. Everything is composed here on the PC (same
step grid as the demos: 16 steps per bar, S frames per step).

    python3 compose_anthem.py && python3 songfile.py play anthem

Harmony throughout: Am - F - C - G, one chord per bar, ~128 BPM (S = 7).
"""
import os
import zlib

import contextlib
import io

with contextlib.redirect_stdout(io.StringIO()):
    import gen_demos as gd                     # (regenerates demos.inc, same bytes)
import loopfile as lf

HERE = os.path.dirname(os.path.abspath(__file__))
S, N = 7, 64                                   # 4 bars of 16ths
n = gd.n
ROOTS = ["A", "F", "C", "G"]


def section(t1, t2, drums, p1, p2):
    """-> psl body: lanes exactly like the demo loader writes them"""
    L = [bytearray(N * S) for _ in range(5)]
    for lane, tr in ((0, t1), (3, t2)):
        for t, note, d in tr:
            assert 0 <= t and t + d <= N, (t, d)
            L[lane][t * S] = note + 1
            L[lane][(t + d) * S - 2] = 0xFE
    for k, v in enumerate(drums):
        if v:
            L[1][k * S] = v
    L[2][0] = gd.PRE[p1] + 1 if p1 else 0
    L[4][0] = gd.PRE[p2] + 1 if p2 else 0
    return L, (1 if t1 else 0)


def factory_presets():
    lbl, mem = lf.labels(), lf.xex_bytes()
    return bytes(mem[lbl["factory"] + i] for i in range(lf.NPRESET_BYTES))


def write(name, t1, t2, drums, p1, p2, presets):
    L, t1used = section(t1, t2, drums, p1, p2)
    body = (N * S).to_bytes(2, "little") + bytes([t1used]) + b"".join(L) + presets
    os.makedirs(lf.LOOPS, exist_ok=True)
    open(lf.path(name), "wb").write(lf.MAGIC + zlib.compress(body, 9))
    print(f"  {name:18s} " + lf.describe(N * S, t1used, L))


# ---- bass ------------------------------------------------------------------
def lo_hi(root):
    return (n("C2"), n("C3")) if root == "C" else (n(root + "1"), n(root + "2"))


def anthem_bass(bars=range(4)):                # the chorus groove
    out = []
    for bar in bars:
        lo, hi = lo_hi(ROOTS[bar])
        b = bar * 16
        out += [(b, lo, 2), (b + 3, lo, 2), (b + 6, hi, 2), (b + 8, lo, 2),
                (b + 10, lo, 1), (b + 11, lo, 2), (b + 14, hi, 2)]
    return out


def quarter_bass():                            # verse: steady quarters
    out = []
    for bar in range(4):
        lo, _ = lo_hi(ROOTS[bar])
        out += [(bar * 16 + q * 4, lo, 3) for q in range(4)]
    return out


def eighths(bar, root):                        # intro build
    lo, _ = lo_hi(root)
    return [(bar * 16 + e * 2, lo, 2) for e in range(8)]


# ---- melodies --------------------------------------------------------------
H = lambda t, s, d: (t, n(s), d)
HOOK = [                                       # the ANTHEM hook
    H(0, "E5", 2), H(2, "E5", 1), H(3, "D5", 1), H(4, "E5", 2), H(6, "G5", 2),
    H(8, "A5", 3), H(11, "G5", 1), H(12, "E5", 2), H(14, "D5", 2),
    H(16, "C5", 3), H(19, "C5", 1), H(20, "D5", 2), H(22, "E5", 2),
    H(24, "C5", 4), H(28, "A4", 4),
    H(32, "E5", 2), H(34, "E5", 1), H(35, "D5", 1), H(36, "E5", 2), H(38, "G5", 2),
    H(40, "C6", 3), H(43, "B5", 1), H(44, "G5", 2), H(46, "E5", 2),
    H(48, "D5", 3), H(51, "D5", 1), H(52, "E5", 2), H(54, "D5", 2),
    H(56, "B4", 4), H(60, "C5", 2), H(62, "D5", 2),
]
VERSE = [                                      # calmer, lower, stepwise
    H(0, "A4", 2), H(2, "C5", 2), H(4, "E5", 4), H(8, "D5", 2), H(10, "C5", 2),
    H(12, "A4", 4),
    H(16, "A4", 2), H(18, "C5", 2), H(20, "F5", 4), H(24, "E5", 2), H(26, "D5", 2),
    H(28, "C5", 4),
    H(32, "G4", 2), H(34, "C5", 2), H(36, "E5", 4), H(40, "D5", 2), H(42, "C5", 2),
    H(44, "E5", 4),
    H(48, "D5", 4), H(52, "B4", 2), H(54, "G4", 2), H(56, "G4", 4),
    H(60, "B4", 2), H(62, "D5", 2),            # lifts into the chorus' E5
]
BREAK = [                                      # hook fragments, lots of air
    H(4, "E5", 2), H(6, "G5", 2), H(8, "A5", 6),
    H(24, "C5", 4), H(28, "A4", 4),
    H(36, "E5", 2), H(38, "G5", 2), H(40, "C6", 6),
    H(56, "B4", 4), H(60, "D5", 4),
]
OUTRO = HOOK[:24] + [H(48, "D5", 3), H(51, "D5", 1), H(52, "E5", 2), H(54, "G5", 2),
                     H(56, "A5", 8)]           # last bar resolves up to A


# ---- drums -----------------------------------------------------------------
def beat(kick=(), snare=(), hat=(), open_=(), tom=(), tom2=(), crash=(), bars=range(4)):
    k, s, h, o = [], [], [], []
    for bar in bars:
        b = bar * 16
        k += [b + x for x in kick]
        s += [b + x for x in snare]
        h += [b + x for x in hat]
        o += [b + x for x in open_]
    return dict(kick=k, snare=s, hat=h, open=o, tom=list(tom), tom2=list(tom2),
                crash=list(crash))


def kit(*parts):
    lanes = {}
    for p in parts:
        for k, v in p.items():
            lanes.setdefault(k, []).extend(v)
    for k in lanes:
        lanes[k] = sorted(set(lanes[k]))
    return gd.drums(N, **lanes)


FILL = dict(snare=[59], tom=[61], tom2=[62, 63])
ROLL = dict(snare=[48, 52, 56, 58, 60, 61, 62, 63])
CHORUS_KIT = kit(beat(kick=(0, 7, 8), snare=(4, 12), hat=(2, 6, 10, 14)), FILL,
                 dict(crash=[0]))


def minus(d, steps):
    return [0 if i in steps else v for i, v in enumerate(d)]


def main():
    pre = factory_presets()
    print("writing ANTHEM sections:")
    write("anthem_intro", anthem_bass(range(3)) + eighths(3, "G"), [],
          kit(beat(kick=(0, 8), hat=(2, 6, 10, 14), bars=range(3)),
              dict(kick=[48]), ROLL), "BASS", None, pre)
    write("anthem_verse", quarter_bass(), VERSE,
          kit(beat(kick=(0, 8), snare=(4, 12), hat=(2, 6, 10, 14))),
          "BASS", "FLUTE", pre)
    write("anthem_chorus", anthem_bass(), HOOK, CHORUS_KIT, "BASS", "ORGAN", pre)
    write("anthem_break",
          [(bar * 16, n(p), 16) for bar, p in enumerate(("A3", "F3", "C4", "G3"))],
          BREAK, kit(beat(kick=(0,), hat=(8,), bars=range(3)), ROLL),
          "STRINGS", "BELL", pre)
    write("anthem_outro", anthem_bass(range(3)) + [(48, n("A1"), 16)], OUTRO,
          minus(CHORUS_KIT, set(range(49, 64))) [:48] + [8] + [0] * 15,
          "BASS", "ORGAN", pre)
    os.makedirs(os.path.join(HERE, "songs"), exist_ok=True)
    open(os.path.join(HERE, "songs/anthem.song"), "w").write(
        "# ANTHEM - full arrangement (compose_anthem.py). ~80 s.\n"
        "anthem_intro 1\n"
        "anthem_verse 1\n"
        "anthem_chorus 2\n"
        "anthem_verse 1\n"
        "anthem_chorus 2\n"
        "anthem_break 1\n"
        "anthem_chorus 2\n"
        "anthem_outro 1\n")
    import songfile
    songfile.pack("anthem")


if __name__ == "__main__":
    main()
