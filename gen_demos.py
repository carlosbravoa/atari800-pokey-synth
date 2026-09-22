#!/usr/bin/env python3
"""Built-in demo loops -> demos.inc (ca65, HIDATA segment).

Per demo:  name(8) S N P1 P2  T1 events  $FF  T2 events  $FF  drums[N]
  S = frames per step, N = steps (loop = N*S frames, <= 4096)
  P1/P2 = preset+1 for track 1 (voice 2) / track 2 (lead), 0 = none
  events = (step, note, dur_steps), note 0 = C1
  drums  = one byte per step: 0 none, 1 kick 2 snare 3 hat 4 open 5 tom
           6 tom2 7 clap 8 crash
The 6502 loader writes note-on at step*S and note-off 2 frames before
(step+dur)*S, so back-to-back notes re-articulate.
"""
NAMES = "C C# D D# E F F# G G# A A# B".split()
PRE = {n: i for i, n in enumerate(
    "PIANO ORGAN FLUTE STRINGS BASS CHIPARP SYNTH BELL LASER UFO".split())}


def n(s):
    """'C#4' -> note index (C1 = 0)"""
    name, octv = s[:-1], int(s[-1])
    return NAMES.index(name) + (octv - 1) * 12


def seq(pairs, dur=2, start=0):
    """list of note names (or None = rest), one per `dur` steps"""
    out, t = [], start
    for p in pairs:
        if p:
            out.append((t, n(p), dur))
        t += dur
    return out


def drums(N, **lanes):
    code = dict(kick=1, snare=2, hat=3, open=4, tom=5, tom2=6, clap=7, crash=8)
    d = [0] * N
    for k in ("hat", "open", "tom", "tom2", "clap", "kick", "snare", "crash"):
        for s in lanes.get(k, []):       # later names win a shared step
            d[s] = code[k]
    return d


DEMOS = []


def demo(name, S, N, p1, p2, t1, t2, dr):
    assert N * S <= 4096 and len(dr) == N
    for t, _, d in t1 + t2:
        assert 0 <= t and t + d <= N and d >= 1
    DEMOS.append((name, S, N, PRE[p1] + 1 if p1 else 0,
                  PRE[p2] + 1 if p2 else 0, t1, t2, dr))


# 1 GROOVE — the first demo loop: buzz bass, flute tune
demo("GROOVE", 8, 32, "BASS", "FLUTE",
     seq("C2 C2 G2 C2 D#2 C2 G2 A#2 F2 F2 C3 F2 G2 G2 A#2 G2".split()),
     [(0, n("G4"), 4), (4, n("A#4"), 4), (8, n("C5"), 6), (14, n("D#5"), 2),
      (16, n("D5"), 4), (20, n("C5"), 4), (24, n("A#4"), 4), (28, n("G4"), 4)],
     drums(32, kick=[0, 8, 16, 24, 22, 30], snare=[4, 12, 20, 28],
           hat=list(range(2, 32, 2))))

# 2 TECHNO — offbeat buzz bass, synth motif, four-on-the-floor
demo("TECHNO", 7, 32, "BASS", "SYNTH",
     seq([None, "A1", None, "A1", None, "A1", None, "C2",
          None, "A1", None, "A1", None, "G1", None, "A1"], dur=2),
     [(0, n("E4"), 2), (3, n("E4"), 1), (6, n("G4"), 2), (10, n("A4"), 2),
      (14, n("G4"), 2), (16, n("E4"), 2), (19, n("E4"), 1), (22, n("D4"), 2),
      (26, n("C4"), 2), (30, n("D4"), 2)],
     drums(32, kick=[0, 8, 16, 24], clap=[4, 12, 20, 28],
           open=list(range(2, 32, 4)), hat=list(range(1, 32, 2))))

# 3 CHIPTUNE — arpeggiated I-IV-V-I on voice 2, piano arpeggio melody
demo("CHIPTUNE", 7, 32, "CHIPARP", "PIANO",
     [(0, n("C4"), 8), (8, n("F4"), 8), (16, n("G4"), 8), (24, n("C4"), 8)],
     seq("E5 G5 C6 G5 A5 F5 A5 C6 B5 G5 D5 G5".split()) +
     [(24, n("C6"), 4), (28, n("G5"), 2), (30, n("E5"), 2)],
     drums(32, kick=[0, 8, 16, 24, 14, 30], snare=[4, 12, 20, 28],
           hat=list(range(2, 32, 4))))

# 4 DREAMY — slow string pads Am F C G, bell melody
demo("DREAMY", 10, 32, "STRINGS", "BELL",
     [(0, n("A3"), 8), (8, n("F3"), 8), (16, n("C4"), 8), (24, n("G3"), 8)],
     [(0, n("E5"), 4), (4, n("C5"), 2), (6, n("A4"), 2), (8, n("C5"), 4),
      (12, n("F5"), 4), (16, n("E5"), 4), (20, n("G5"), 4), (24, n("D5"), 6),
      (30, n("B4"), 2)],
     drums(32, kick=[0, 10, 16], snare=[8, 24], hat=[4, 12, 20, 28]))

# 5 ROCK — driving E bass, organ riff
demo("ROCK", 8, 32, "BASS", "ORGAN",
     seq("E2 E2 E2 E2 G2 G2 A2 A2 E2 E2 E2 E2 D2 D2 B1 B1".split()),
     [(0, n("E4"), 3), (3, n("G4"), 3), (6, n("A4"), 2), (8, n("E4"), 3),
      (11, n("G4"), 3), (14, n("A#4"), 1), (15, n("A4"), 1), (16, n("E4"), 3),
      (19, n("G4"), 3), (22, n("A4"), 2), (24, n("G4"), 2), (26, n("E4"), 6)],
     drums(32, kick=[0, 6, 8, 16, 22, 24], snare=[4, 12, 20, 28],
           hat=[2, 10, 14, 18, 26, 30], crash=[0]))

# 6 SPACE — low buzz drone, UFO melody, sparse toms
demo("SPACE", 9, 32, "BASS", "UFO",
     [(0, n("C2"), 16), (16, n("A#1"), 16)],
     [(0, n("G4"), 6), (8, n("A#4"), 6), (16, n("C5"), 8), (26, n("D#5"), 6)],
     drums(32, kick=[0, 16], tom=[12, 28], tom2=[14, 30], clap=[24],
           open=[8]))

# 7 ANTHEM — original pop hook over Am-F-C-G, ~128 BPM, 4 bars.
# Bass: syncopated buzz with octave jumps. Lead: a call (bars 1 and 3 share
# the motif) and answer (bars 2/4), bar 4 climbing back into the hook.
def bassbar(bar, root):
    lo, hi = n(root + "1"), n(root + "2")
    if root in ("C",):                       # C sits an octave up
        lo, hi = n("C2"), n("C3")
    b = bar * 16
    return [(b + 0, lo, 2), (b + 3, lo, 2), (b + 6, hi, 2), (b + 8, lo, 2),
            (b + 10, lo, 1), (b + 11, lo, 2), (b + 14, hi, 2)]


anthem_bass = bassbar(0, "A") + bassbar(1, "F") + bassbar(2, "C") + bassbar(3, "G")
H = lambda t, s_, d: (t, n(s_), d)
anthem_lead = [
    # bar 1 (Am): the hook
    H(0, "E5", 2), H(2, "E5", 1), H(3, "D5", 1), H(4, "E5", 2), H(6, "G5", 2),
    H(8, "A5", 3), H(11, "G5", 1), H(12, "E5", 2), H(14, "D5", 2),
    # bar 2 (F): the answer, settling on A
    H(16, "C5", 3), H(19, "C5", 1), H(20, "D5", 2), H(22, "E5", 2),
    H(24, "C5", 4), H(28, "A4", 4),
    # bar 3 (C): the hook again, reaching higher
    H(32, "E5", 2), H(34, "E5", 1), H(35, "D5", 1), H(36, "E5", 2), H(38, "G5", 2),
    H(40, "C6", 3), H(43, "B5", 1), H(44, "G5", 2), H(46, "E5", 2),
    # bar 4 (G): turnaround, climbing back into the hook
    H(48, "D5", 3), H(51, "D5", 1), H(52, "E5", 2), H(54, "D5", 2),
    H(56, "B4", 4), H(60, "C5", 2), H(62, "D5", 2),
]
kick, snare, hat, tom, tom2, crash = [], [], [], [], [], [0]
for bar in range(4):
    b = bar * 16
    kick += [b + 0, b + 7, b + 8]
    snare += [b + 4, b + 12]
    hat += [b + 2, b + 6, b + 10, b + 14]
snare += [59]                                # bar-4 fill: snare, toms
tom += [61]
tom2 += [62, 63]
kick = [k for k in kick if k not in (59, 61, 62, 63)]
demo("ANTHEM", 7, 64, "BASS", "ORGAN", anthem_bass, anthem_lead,
     drums(64, kick=kick, snare=snare, hat=hat, tom=tom, tom2=tom2, crash=crash))

L = ["; generated by gen_demos.py — do not edit",
     f"NDEMO = {len(DEMOS)}"]
for i, (name, S, N, p1, p2, t1, t2, dr) in enumerate(DEMOS):
    L.append(f"demo{i}:  .byte \"{name:<8}\", {S}, {N}, {p1}, {p2}")
    for tr in (t1, t2):
        ev = [x for e in tr for x in e]
        for k in range(0, len(ev), 12):
            L.append("        .byte " + ",".join(str(v) for v in ev[k:k + 12]))
        L.append("        .byte $FF")
    for k in range(0, len(dr), 16):
        L.append("        .byte " + ",".join(str(v) for v in dr[k:k + 16]))
L.append("demo_lo: .byte " + ",".join(f"<demo{i}" for i in range(len(DEMOS))))
L.append("demo_hi: .byte " + ",".join(f">demo{i}" for i in range(len(DEMOS))))
open("demos.inc", "w").write("\n".join(L) + "\n")
print(f"{len(DEMOS)} demos, ~{sum(8 + 4 + 3 * len(a) + 3 * len(b) + 2 + N for _, _, N, _, _, a, b, _ in DEMOS)} bytes")
