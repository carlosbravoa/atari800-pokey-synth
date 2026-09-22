#!/usr/bin/env python3
"""py65 pre-flight for POKEY SYNTH: drives the VBI engine routines and the
main-thread UI code on a bare 6502 (no OS), checks the sound math, and prints
the screen buffer as text. Usage: python3 test_synth.py [-v]"""
import sys
from py65.devices.mpu6502 import MPU

V = "-v" in sys.argv
lbl = {}
for line in open("build/synth.lbl"):
    _, a, n = line.split()
    lbl[n.lstrip(".")] = int(a, 16)


import re
for line in open("synth.s"):
    mm = re.match(r"^([A-Z_][A-Z0-9_]*)\s*=\s*(\$[0-9A-Fa-f]+|[A-Z_]+\+\d+)", line)
    if mm:
        v = mm.group(2)
        if v.startswith("$"):
            lbl[mm.group(1)] = int(v[1:], 16)
        else:
            b, o = v.split("+")
            lbl[mm.group(1)] = lbl[b] + int(o)


def L(n):
    return lbl[n]


m = MPU()
d = open("build/synth.xex", "rb").read()
i = 2
while i < len(d):
    if d[i:i + 2] == b"\xff\xff":
        i += 2
    s = int.from_bytes(d[i:i + 2], "little")
    e = int.from_bytes(d[i + 2:i + 4], "little")
    m.memory[s:e + 1] = list(d[i + 4:i + 5 + e - s])
    i += 5 + e - s
mem = m.memory
SENT = 0xFFF0
mem[SENT] = 0xEA


def call(name, a=0, x=0, y=0, limit=200000):
    m.a, m.x, m.y = a, x, y
    m.sp = 0xFF
    ret = SENT - 1
    m.memory[0x1FF] = ret >> 8
    m.memory[0x1FE] = ret & 255
    m.sp = 0xFD
    m.pc = L(name)
    n = 0
    while m.pc != SENT:
        m.step()
        n += 1
        assert n < limit, f"runaway in {name} pc={m.pc:04X}"
    return n


def w(addr):
    return mem[addr] | mem[addr + 1] << 8


ok = True


def check(cond, msg):
    global ok
    print(("PASS " if cond else "FAIL ") + msg)
    ok &= bool(cond)


# --- minimal init (what start does, minus OS calls) ---
for a in range(0x0600, 0x067C):
    mem[a] = 0
for k in range(130):
    mem[L("live") + k] = 0
# execute start's factory->live copy loop for real (LDX #0 ... BNE)
fa, li = L("factory"), L("live")
pat = [0xA2, 0x00, 0xBD, fa & 255, fa >> 8, 0x9D, li & 255, li >> 8]
code = list(mem[L("start"):L("start") + 400])
at = next(j for j in range(len(code)) if code[j:j + 8] == pat) + L("start")
m.pc, m.sp = at, 0xFF
while m.pc != at + 13:
    m.step()
assert list(mem[li:li + 130]) == list(mem[fa:fa + 130]), "factory->live copy"
for n in ("HELD", "LITKEY", "DRUMLIT", "LASTDRUM", "DISPNOTE", "PREVCON"):
    mem[L(n)] = 0xFF
mem[L("PREVSTK")] = 0x0F
mem[L("PRESREQ")] = 0xFF
mem[0xD20F] = 0x04          # SKSTAT: no key
call("cls")
call("print_list", a=L("static_text") & 255, x=L("static_text") >> 8)
call("select_preset", a=0)
call("draw_drums")
call("ui_update")


def frame(key=None):
    """one VBI: key = KBCODE held this frame, or None"""
    if key is None:
        mem[0xD20F] = 0x04
    else:
        mem[0xD20F] = 0x00
        mem[0xD209] = key
    call("kb_poll")
    call("loop_step")
    call("synth")
    call("drum_step")
    return w(L("OUTLO")), mem[L("VOLHI")], mem[L("ESTATE")]


def main_frame():
    call("main_tick")


F = 1789772.5
pure = lambda n: w(0)  # placeholder


def tbl(name, n):
    return mem[L(name + "_lo") + n] | mem[L(name + "_hi") + n] << 8


def hz(N, per=2):
    return F / (per * (N + 7))


A, K, C, S = 0x3F, 0x05, 0x12, 0x3E

# 1. piano: press A (C4) -> period, volume shape, release
out, vol, st = frame(A)
check(mem[L("NOTE")] == 36 and out == tbl("pure", 36),
      f"PIANO A -> C4 note 36, period {out} = {hz(out):.1f} Hz")
check(vol == 15, f"attack 0 hits full volume on frame 1 (vol {vol})")
vols = [frame(A)[1] for _ in range(30)]
check(vols[0] >= vols[-1] and vols[-1] < 15, f"piano decays while held: {vols[::5]}")
check(mem[L("LITKEY")] == 0, "piano key 0 lit")
main_frame()
rel = [frame()[1] for _ in range(30)]
check(rel[-1] == 0 and mem[L("ESTATE")] == 0, f"release to silence: {rel[:8]}")
check(mem[L("LITKEY")] == 0xFF, "piano unlit after release")

# 2. octave keys + presets via main thread
frame(0x16); main_frame(); frame()
check(mem[L("OCTAVE")] == 5, "X raises octave to 5")
frame(0x17); main_frame(); frame(); frame(0x17); main_frame(); frame()
check(mem[L("OCTAVE")] == 3, "Z twice -> octave 3")
frame(0x1B); main_frame(); frame()     # key 6 = CHIPARP
check(mem[L("PRESET")] == 5 and mem[L("P_CHORD")] == 1 and mem[L("OCTAVE")] == 4,
      "key 6 selects CHIPARP (chord MAJOR, home octave 4)")
seq = []
for _ in range(12):
    frame(A)
    seq.append(mem[L("NOTEIDX")] - 36)
check(set(seq) == {0, 4, 7}, f"major arpeggio offsets {seq}")
for _ in range(40):
    frame()

# 3. glide legato (SYNTH, glide 3): A then K held -> period slides
frame(0x33); main_frame(); frame()     # key 7 = SYNTH
for _ in range(5):
    frame(A)
p0 = w(L("CURNLO"))
tr = [frame(K)[0] for _ in range(40)]
tgt = tbl("buzz", mem[L("NOTE")])
cur = w(L("CURNLO"))
check(tr[0] > tgt and tr[-1] <= tr[0] and abs(cur - tgt) <= 1,
      f"glide {p0} -> {tgt}: {tr[:12:2]}... {tr[-1]}")
check(mem[L("NOTECNT")] >= 2 and mem[L("ESTATE")] in (2, 3), "legato kept envelope")
for _ in range(60):
    frame()

# 4. vibrato (UFO, depth 7): period oscillates around the note
frame(0x32); main_frame(); frame()     # key 0 = UFO
mem[L("P_SWEEP")] = 7                  # isolate vibrato
outs = [frame(A)[0] for _ in range(40)]
base = tbl("pure", mem[L("NOTE")])
lo_, hi_ = min(outs[4:]), max(outs[4:])
check(lo_ < base < hi_, f"vibrato {lo_}..{hi_} around {base} "
      f"(+/-{(hi_ - base) / base * 100:.1f}%)")
for _ in range(80):
    frame()

# 5. laser sweep down: period grows
frame(0x30); main_frame(); frame()     # key 9 = LASER
outs = [frame(A)[0] for _ in range(10)]
check(all(b > a for a, b in zip(outs, outs[1:])), f"laser sweeps down {outs[:6]}")
for _ in range(60):
    frame()

# 6. drums: kick sweeps AUDF4 upward, counts, lights
frame(C)
f4 = []
for _ in range(12):
    f4.append(mem[0xD206])
    frame(C)
check(mem[L("DRUMCNT")] == 1 and f4[-1] > f4[0], f"kick AUDF4 {f4[:6]}")
main_frame()
for _ in range(20):
    frame()
check(mem[L("DRUMLIT")] == 0xFF and mem[0xD207] == 0, "kick ends silent")

# 7. editor: arrows move selection and change the value, saved to preset
frame(0x31 if False else 0x1F); main_frame(); frame()   # key 1 PIANO
frame(0x0F); main_frame(); frame()     # '=' down -> ATTACK
frame(0x07); main_frame(); frame()     # '*' right -> +1
check(mem[L("EDSEL")] == 1 and mem[L("P_ATK")] == 1, "down + right: ATTACK 0 -> 1")
frame(0x1E); main_frame(); frame(); frame(0x1F); main_frame(); frame()
check(mem[L("P_ATK")] == 1, "edit survives switching presets away and back")
frame(0x0C); main_frame(); frame()
check(mem[L("P_ATK")] == 0, "RETURN restores factory")
# held arrow auto-repeats
frame(0x0E); main_frame()               # up -> WAVE
n0 = mem[L("KEYSEQ")]
for _ in range(40):
    frame(0x07)
check(mem[L("KEYSEQ")] - n0 >= 4, f"held arrow repeats ({mem[L('KEYSEQ')] - n0} events)")
frame()

# 8. remote mailbox
mem[L("REMKEY")] = A
mem[L("REMHOLD")] = 10
n0 = mem[L("NOTECNT")]
frame(); check(mem[L("NOTECNT")] == n0 + 1 and mem[L("GATE")] == 1, "REMKEY plays a note")
for _ in range(12):
    frame()
check(mem[L("GATE")] == 0, "REMHOLD expiry releases it")

# 9. looper: record a note + a kick, close, replay, overdub a snare
SP, TAB, BK, V = 0x21, 0x2C, 0x34, 0x10
call("select_preset", a=0)
for _ in range(5):
    frame()
tap = lambda k: (frame(k), main_frame(), frame(), main_frame())
tap(SP)
check(mem[L("LSTATE")] == 1, "SPACE starts recording")
t0 = w(L("LPOSLO"))
for _ in range(10): frame()
for _ in range(12): frame(A)            # note held 12 frames
for _ in range(20): frame()
frame(C); frame()                       # kick
for _ in range(40): frame()
tap(SP)
LL = w(L("LLENLO"))
check(mem[L("LSTATE")] == 2 and 80 < LL < 100, f"SPACE closes the loop: {LL} frames, playing")
ml = [mem[L("MLANE") + i] for i in range(LL)]
dl = [mem[L("DLANE") + i] for i in range(LL)]
on = [i for i, v in enumerate(ml) if 0 < v < 0xFE]
off = [i for i, v in enumerate(ml) if v == 0xFE]
kick = [i for i, v in enumerate(dl) if v]
check(len(on) == 1 and ml[on[0]] == 37 and len(off) == 1 and off[0] - on[0] == 12,
      f"melody lane: on@{on} (C4) off@{off}")
check(len(kick) == 1 and dl[kick[0]] == 1, f"drum lane: kick@{kick}")
check(mem[L("PLANE")] == 1, "preset lane: PIANO at frame 0")
# play one pass: note and kick fire at their recorded frames
n0, d0 = mem[L("NOTECNT")], mem[L("DRUMCNT")]
while w(L("LPOSLO")) != 0: frame(); main_frame()
fired = {}
for f in range(LL):
    a, b = mem[L("NOTECNT")], mem[L("DRUMCNT")]
    frame(); main_frame()
    if mem[L("NOTECNT")] != a: fired.setdefault("note", f)
    if mem[L("DRUMCNT")] != b: fired.setdefault("kick", f)
check(fired.get("note") == on[0] and fired.get("kick") == kick[0],
      f"playback fires at the recorded frames {fired}")
check(mem[L("LOOPCNT")] >= 2 and mem[L("LCELL")] <= 1, "loop wrapped, bar restarted")
# overdub a snare
tap(SP)
check(mem[L("LSTATE")] == 3, "SPACE while playing = overdub")
for _ in range(5): frame()
sn = w(L("LPOSLO"))
frame(V); frame()
tap(SP)
check(mem[L("LSTATE")] == 2, "SPACE again = back to play")
dl = [mem[L("DLANE") + i] for i in range(LL)]
check(sorted(v for v in dl if v) == [1, 2], f"drum lane now kick + snare {[(i, v) for i, v in enumerate(dl) if v]}")
d0 = mem[L("DRUMCNT")]
for _ in range(LL): frame(); main_frame()
check(mem[L("DRUMCNT")] - d0 == 2, "a full pass plays both drums")
# octave survives the loop's preset event
frame(0x16); main_frame(); frame()
for _ in range(LL + 2): frame(); main_frame()
check(mem[L("OCTAVE")] == 5, "octave kept across loop wraps")
frame(0x17); main_frame(); frame()
# stop / play / clear
tap(TAB)
n0 = mem[L("NOTECNT")] + mem[L("DRUMCNT")]
for _ in range(LL + 5): frame(); main_frame()
check(mem[L("LSTATE")] == 4 and mem[L("NOTECNT")] + mem[L("DRUMCNT")] == n0, "TAB stops: silence")
tap(TAB)
check(mem[L("LSTATE")] == 2 and w(L("LPOSLO")) < 3, "TAB again plays from the top")
tap(BK)
check(mem[L("LSTATE")] == 0, "BACKSPACE clears")
tap(SP); frame(); tap(SP)
check(mem[L("LSTATE")] == 0, "a loop under half a second is cancelled")

# edge: every preset x every key x octave extremes, run frames w/o runaway
for p in range(10):
    call("select_preset", a=p)
    for octv in (1, 7):
        mem[L("OCTAVE")] = octv
        call("set_octave")
        for k in (A, 0x02):
            for _ in range(6):
                frame(k)
            for _ in range(3):
                frame()
check(True, "all presets x octave 1/7 x lowest/highest key ran clean")

# --- screen dump ---
call("select_preset", a=0)
mem[L("LITKEY")] = 4
call("ui_update")


def sc2a(c):
    inv = c & 0x80
    c &= 0x7F
    ch = chr(c + 32) if c < 64 else (chr(c - 64) if c < 96 else chr(c))
    if not ch.isprintable():
        ch = "?"
    return ch.lower() if inv and ch.isalpha() and ch.isupper() else ch


print("+" + "-" * 40 + "+")
for r in range(24):
    row = mem[0x4000 + r * 40: 0x4000 + r * 40 + 40]
    print("|" + "".join(sc2a(c) for c in row) + "|")
print("+" + "-" * 40 + "+")
print("ALL PASS" if ok else "SOME FAILED")
sys.exit(0 if ok else 1)
