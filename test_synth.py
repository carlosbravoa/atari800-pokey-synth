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
    mm = re.match(r"^([A-Z_][A-Z0-9_]*)\s*=\s*(\$[0-9A-Fa-f]+|\d+|[A-Z_][A-Z0-9_]*(?:\+\d+)?)\b", line)
    if mm:
        v = mm.group(2)
        if v.startswith("$"):
            lbl[mm.group(1)] = int(v[1:], 16)
        elif v.isdigit():
            lbl[mm.group(1)] = int(v)
        elif v in lbl or v.split("+")[0] in lbl:
            b, _, o = v.partition("+")
            lbl[mm.group(1)] = lbl[b] + int(o or 0)


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
        if m.pc == lbl.get("wait_lcmd"):   # stand in for the VBI taking LCMD
            if mem[lbl["LCMD"]] == 3:
                mem[lbl["LSTATE"]] = 0
            mem[lbl["LCMD"]] = 0
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
    mem[L("POLY4B")] = 0
    call("lv_step", x=20)
    call("lv_step", x=0)
    call("drum_step")
    call("pokey_out")
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
kick = [(mem[0xD206], mem[0xD207])]
for _ in range(7):
    frame(C)
    kick.append((mem[0xD206], mem[0xD207]))
want = [(0x00, 0x1F), (0x20, 0xAF), (0xD0, 0xCF), (0xE0, 0xCB), (0xF0, 0xC8), (0xF8, 0xC4)]
check(mem[L("DRUMCNT")] == 1 and kick[:6] == want and kick[6][1] == 0,
      f"battery kick script: {[f'{f:02X}/{c:02X}' for f, c in kick[:7]]}")
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
while w(L("LPOSLO")) != 0: frame(); main_frame()
fired = {}
v2vol = []
for f in range(LL):
    a, b, c = mem[L("NOTE2CNT")], mem[L("DRUMCNT")], mem[L("NOTECNT")]
    frame(); main_frame()
    if mem[L("NOTE2CNT")] != a: fired.setdefault("v2note", f)
    if mem[L("DRUMCNT")] != b: fired.setdefault("kick", f)
    if mem[L("NOTECNT")] != c: fired.setdefault("lead", f)
    v2vol.append(mem[0xD205])
check(fired.get("v2note") == on[0] and fired.get("kick") == kick[0] and "lead" not in fired,
      f"track 1 replays on voice 2 at the recorded frames {fired}")
check(max(v2vol[on[0]:on[0] + 5]) & 0x0F > 8 and v2vol[on[0]] & 0xF0 == 0xA0
      and mem[0xD204] == mem[L("lay64") + 36],
      f"voice 2 drives ch3: AUDC3 {v2vol[on[0]:on[0]+4]} AUDF3 {mem[0xD204]}")
check(mem[L("LOOPCNT")] >= 2 and mem[L("LCELL")] <= 1, "loop wrapped, bar restarted")
# overdub a snare
tap(SP)
check(mem[L("LSTATE")] == 3, "SPACE while playing = overdub")
for _ in range(5): frame()
sn = w(L("LPOSLO"))
frame(V); frame()
for _ in range(10): frame()
k0 = w(L("LPOSLO"))
for _ in range(8): frame(K)             # overdub a melody note (K = C5)
frame()
tap(SP)
check(mem[L("LSTATE")] == 2, "SPACE again = back to play")
dl = [mem[L("DLANE") + i] for i in range(LL)]
check(sorted(v for v in dl if v) == [1, 2], f"drum lane now kick + snare {[(i, v) for i, v in enumerate(dl) if v]}")
m2 = [mem[L("M2LANE") + i] for i in range(LL)]
on2 = [(i, v) for i, v in enumerate(m2) if v]
check(len(on2) == 2 and on2[0][1] == 49 and on2[1][1] == 0xFE and on2[0][0] - k0 in (0, 1),
      f"track 2 lane holds the overdubbed C5 {on2}")
p2 = [(i, v) for i, v in enumerate(mem[L("P2LANE") + i] for i in range(LL)) if v]
check(len(p2) == 1 and p2[0][1] == 1, f"track 2 preset stamped at overdub start {p2}")
d0, n0, v0 = mem[L("DRUMCNT")], mem[L("NOTECNT")], mem[L("NOTE2CNT")]
for _ in range(LL): frame(); main_frame()
check(mem[L("DRUMCNT")] - d0 == 2, "a full pass plays both drums")
check(mem[L("NOTECNT")] - n0 == 1 and mem[L("NOTE2CNT")] - v0 == 1,
      "a full pass plays track 1 on voice 2 and track 2 on the lead")
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
check(mem[L("V2EST")] == 0, "voice 2 released on stop")
tap(TAB)
check(mem[L("LSTATE")] == 2 and w(L("LPOSLO")) < 3, "TAB again plays from the top")
tap(BK)
check(mem[L("LSTATE")] == 0, "BACKSPACE clears")
tap(SP); frame(); tap(SP)
check(mem[L("LSTATE")] == 0, "a loop under half a second is cancelled")

# 10. drums-only loop: the layer keeps ch3 (ORGAN = octave-up layer)
tap(BK)
call("select_preset", a=1)
tap(SP)
for _ in range(10): frame()
frame(C); frame()
for _ in range(30): frame()
tap(SP)
check(mem[L("LSTATE")] == 2 and mem[L("T1USED")] == 0, "drums-only loop playing")
for _ in range(4): frame(A)
check(mem[0xD205] & 0xF0 == 0xA0 and mem[0xD205] & 0x0F > 5
      and mem[0xD204] == mem[L("lay64") + 48],
      f"ORGAN layer still on ch3 (AUDC3 {mem[0xD205]:02X}, AUDF3 = C5 octave)")
for _ in range(20): frame()
tap(BK)

# 11. built-in demos: > loads + plays; lanes match demos.inc; names show
import importlib.util
spec = importlib.util.spec_from_file_location("gd", "gen_demos.py")
gd = importlib.util.module_from_spec(spec)
import contextlib, io
with contextlib.redirect_stdout(io.StringIO()):
    spec.loader.exec_module(gd)
Q, PREV = 0x37, 0x36                    # '>' next, '<' previous
for di, (name, S, N, p1, p2, t1, t2, dr) in enumerate(gd.DEMOS):
    tap(Q)
    LL = w(L("LLENLO"))
    check(mem[L("DEMOIDX")] == di + 1 and LL == N * S and mem[L("LSTATE")] == 2,
          f"> -> demo {di + 1} {name}: {LL} frames, playing")
    ok_l = all(mem[L("MLANE") + t * S] == nn + 1 and mem[L("MLANE") + (t + d) * S - 2] == 0xFE
               for t, nn, d in t1)
    ok_l &= all(mem[L("M2LANE") + t * S] == nn + 1 for t, nn, d in t2)
    ok_l &= all(mem[L("DLANE") + k * S] == v for k, v in enumerate(dr))
    ok_l &= mem[L("PLANE")] == p1 and mem[L("P2LANE")] == p2
    check(ok_l, f"  lanes match the demo data")
    while w(L("LPOSLO")) != 0: frame(); main_frame()
    c = [mem[L(x)] for x in ("NOTE2CNT", "NOTECNT", "DRUMCNT")]
    for _ in range(LL): frame(); main_frame()
    got = [(mem[L(x)] - c[i]) & 255 for i, x in enumerate(("NOTE2CNT", "NOTECNT", "DRUMCNT"))]
    want = [len(t1), len(t2), sum(1 for v in dr if v)]
    check(got == want, f"  one pass plays voice2/lead/drums {got} (want {want})")
    row = "".join(chr((c & 0x7F) + 32) for c in mem[0x4000 + 10 * 40 + 29:0x4000 + 10 * 40 + 39])
    check(row == f"<{name:<8}>", f"  row 10 shows '{row}'")
tap(Q)
check(mem[L("DEMOIDX")] == 1, "> wraps back to demo 1")
# drums-only toggle (Q) on GROOVE
MQ = 0x2F
call("select_preset", a=0)             # player picks PIANO
tap(MQ)
check(mem[L("MUTEMEL")] == 1, "Q mutes the loop's melody")
row = "".join(chr((c & 0x7F) + 32) for c in mem[0x4000 + 10 * 40 + 6:0x4000 + 10 * 40 + 11])
check(row == "DRUMS", f"  loop row shows '{row}'")
while w(L("LPOSLO")) != 0: frame(); main_frame()
c = [mem[L(x)] for x in ("NOTE2CNT", "NOTECNT", "DRUMCNT")]
for _ in range(w(L("LLENLO"))): frame(); main_frame()
got = [(mem[L(x)] - c[i]) & 255 for i, x in enumerate(("NOTE2CNT", "NOTECNT", "DRUMCNT"))]
check(got == [0, 0, 16] and mem[L("PRESET")] == 0,
      f"  a pass plays drums only {got}, player keeps PIANO")
for _ in range(4): frame(A)
check(mem[L("NOTE")] == 36 and mem[L("VOLHI")] > 0, "  live playing works over the drums")
for _ in range(30): frame()
call("select_preset", a=1)             # ORGAN: its octave layer gets ch3 back
for _ in range(4): frame(A)
check(mem[0xD205] & 0x0F > 5 and mem[0xD204] == mem[L("lay64") + 48],
      "  the layer has ch3 back while muted")
for _ in range(30): frame()
tap(MQ)
check(mem[L("MUTEMEL")] == 0, "Q again unmutes")
c = [mem[L(x)] for x in ("NOTE2CNT", "NOTECNT")]
while w(L("LPOSLO")) != 0: frame(); main_frame()
for _ in range(w(L("LLENLO"))): frame(); main_frame()
check((mem[L("NOTE2CNT")] - c[0]) & 255 >= 16 and (mem[L("NOTECNT")] - c[1]) & 255 >= 8,
      "  melodies are back")
tap(PREV)
check(mem[L("DEMOIDX")] == len(gd.DEMOS) and w(L("LLENLO")) == gd.DEMOS[-1][1] * gd.DEMOS[-1][2],
      "< from demo 1 wraps to the last demo")
tap(PREV)
check(mem[L("DEMOIDX")] == len(gd.DEMOS) - 1, "< steps back one")
tap(BK)
check(mem[L("DEMOIDX")] == 0 and mem[L("LSTATE")] == 0, "BACKSPACE clears the demo")
for _ in range(3): frame(); main_frame()

# 12. stereo (second POKEY forced on; py65's static RANDOM detects mono)
check(mem[L("STEREO")] == 0, "py65 detects mono (RANDOM never changes)")
tap(BK)
call("select_preset", a=0)
mem[L("STEREO")] = 1
mem[0xD21F] = 0x04                     # a real POKEY2 has no key down
tap(Q)                                 # '>' -> GROOVE
name, S, N, p1, p2, t1, t2, dr = gd.DEMOS[0]
while w(L("LPOSLO")) != 0: frame(); main_frame()
cn = [mem[L(x)] for x in ("NOTE2CNT", "NOTE3CNT", "NOTECNT", "DRUMCNT")]
seen = dict(p2pair=set(), p2c3=set(), p2d=0, p1c3=0, p1d=0)
bass0 = t1[0][1]
for f in range(N * S):
    frame(); main_frame()
    if f == 2:
        per = mem[0xD210] | mem[0xD212] << 8
        seen["bass"] = (per, mem[0xD213], mem[0xD211])
    if mem[0xD215] & 0x0F: seen["p2c3"].add(mem[0xD215] & 0xF0)
    if mem[0xD217] & 0x0F: seen["p2d"] += 1
    if mem[0xD207] & 0x0F: seen["p1d"] += 1
got = [(mem[L(x)] - cn[i]) & 255 for i, x in enumerate(("NOTE2CNT", "NOTE3CNT", "NOTECNT", "DRUMCNT"))]
check(got == [len(t1), len(t2), 0, sum(1 for v in dr if v)],
      f"stereo pass: track1/track2/lead/drums {got}")
bl = mem[L("buzz_lo") + bass0] | mem[L("buzz_hi") + bass0] << 8
per, c2, c1 = seen["bass"]
check(per == bl and c2 & 0xF0 == 0xC0 and c2 & 0x0F and c1 == 0,
      f"track 1 bass on POKEY2 ch1+2 16-bit: period {per} (= buzz table {bl}), AUDC ${c2:02X}")
check(seen["p2c3"] == {0xA0}, f"track 2 flute on POKEY2 ch3 (AUDC hi {seen['p2c3']})")
check(seen["p2d"] > 0 and seen["p1d"] == 0, f"loop drums on POKEY2 ch4 only ({seen['p2d']} vs {seen['p1d']} frames)")
check(mem[L("PRESET")] == 0, "the lead keeps the player's PIANO (track 2 has its own voice)")
call("select_preset", a=1)             # ORGAN: layer stays on POKEY1 ch3
for _ in range(4): frame(A)
check(mem[0xD205] & 0x0F > 5 and mem[0xD204] == mem[L("lay64") + 48],
      "POKEY1 ch3 keeps the lead's layer while the loop plays")
for _ in range(30): frame()
frame(C)
for _ in range(3): frame()
check(mem[0xD207] & 0x0F > 0, "a live kick sounds on POKEY1 ch4 over the loop")
tap(TAB)
for _ in range(3): frame()
check(mem[L("V_EST")] == 0 and mem[L("V_EST") + 20] == 0
      and mem[0xD213] == mem[0xD203] and mem[0xD215] == mem[0xD205],
      "stop releases the loop voices; POKEY2 goes back to mirroring the player")
# solo in stereo: POKEY2 mirrors POKEY1, the lead a few cents flat
tap(BK)
call("select_preset", a=1)             # ORGAN: lead + octave layer
for _ in range(4): frame(A)
per1 = mem[0xD200] | mem[0xD202] << 8
per2 = mem[0xD210] | mem[0xD212] << 8
check(per2 == per1 + (per1 >> 8) and mem[0xD213] == mem[0xD203] and mem[0xD213] & 0x0F,
      f"solo: right lead {per2} = left {per1} + {per1 >> 8} (~7 cents), same AUDC")
check(mem[0xD214] == mem[0xD204] and mem[0xD215] == mem[0xD205] and mem[0xD215] & 0x0F,
      "solo: the layer is mirrored on POKEY2 ch3")
frame(C); frame()
check(mem[0xD217] == mem[0xD207] and mem[0xD217] & 0x0F, "solo: drums mirrored on POKEY2 ch4")
for _ in range(40): frame()
tap(SP)                                # recording: still mirrored
for _ in range(3): frame(A)
check(mem[L("LSTATE")] == 1 and mem[0xD213] == mem[0xD203] and mem[0xD213] & 0x0F,
      "while recording POKEY2 still mirrors the player")
for _ in range(40): frame()
tap(SP)                                # close -> PLAY: POKEY2 back to the loop
while w(L("LPOSLO")) != 0: frame()
for _ in range(20): frame()             # the recorded C4 is sounding on track 1
per2 = mem[0xD210] | mem[0xD212] << 8
pure36 = mem[L("pure_lo") + 36] | mem[L("pure_hi") + 36] << 8
check(mem[L("LSTATE")] == 2 and per2 == pure36,
      f"loop playing: POKEY2 pair = track 1's exact C4 ({per2}), not the detuned mirror")
for _ in range(40): frame()
tap(BK)
call("select_preset", a=0)
# buzz stays in tune on both sides: every output period coprime, no detune
from math import gcd
KEYS = [0x3F, 0x2E, 0x3E, 0x2A, 0x3A, 0x38, 0x2D, 0x3D, 0x2B, 0x39, 0x0B, 0x01,
        0x05, 0x08, 0x00, 0x0A, 0x02]
for pre, name in ((4, "BASS"), (6, "SYNTH")):
    call("select_preset", a=pre)
    bad, diff = [], []
    for k in KEYS:
        for f in range(24):                  # vibrato/glide sweep across frames
            frame(k)
            p1 = mem[0xD200] | mem[0xD202] << 8
            p2 = mem[0xD210] | mem[0xD212] << 8
            if gcd(p1 + 7, 15) > 1: bad.append((k, f, p1))
            if p2 != p1: diff.append((k, f, p1, p2))
        for _ in range(3): frame()
    check(not bad and not diff, f"{name}: all 17 keys x 24 frames coprime, right == left "
                                f"(bad {bad[:3]}, differ {diff[:3]})")
    for _ in range(40): frame()
call("select_preset", a=0)
# recorded held chords (the poly chord problem): stereo = a real chord
def rec_chord_loop():
    tap(BK)
    call("select_preset", a=1)          # ORGAN
    tap(0x0C)                           # factory
    tap(0x28)                           # R: AUTO + POLY
    tap(SP)
    for _ in range(5): frame()
    for _ in range(30): frame(A)        # hold C for 30 frames
    for _ in range(40): frame()
    tap(SP)
rec_chord_loop()
check(mem[L("LSTATE")] == 2 and mem[L("MLANE") + 5] == 37 or any(mem[L("MLANE") + i] == 37 for i in range(10)),
      "a chord was recorded as its root (C4) on track 1")
while w(L("LPOSLO")) != 0: frame()
for _ in range(12): frame()             # the recorded C is sounding
p2 = mem[0xD210] | mem[0xD212] << 8
lay = lambda k: mem[L("lay64") + k]
check(p2 == (mem[L("pure_lo") + 36] | mem[L("pure_hi") + 36] << 8)
      and mem[0xD214] == lay(40) and mem[0xD216] == lay(43)
      and mem[0xD213] & 0x0F and mem[0xD215] & 0x0F and mem[0xD217] & 0x0F,
      f"stereo playback: root C4 on POKEY2 1+2, E4 on ch3, G4 on ch4 (a real C major)")
tap(BK)
# mono: no spare channels -> the chord comes back as a 1-frame arpeggio
mem[L("STEREO")] = 0
rec_chord_loop()
while w(L("LPOSLO")) != 0: frame()
for _ in range(6): frame()
seen = set()
for _ in range(9):
    frame(); seen.add(mem[L("V_IDX")])
check(seen == {36, 40, 43}, f"mono playback: C major as a fast arpeggio on voice 2 {sorted(seen)}")
tap(BK)
tap(0x0C)
call("select_preset", a=0)
mem[L("STEREO")] = 1
# passive fallback: key down but POKEY2's SKSTAT agrees -> mirror -> mono
mem[0xD21F] = 0x00                     # (in py65 $D20F/$D21F are separate bytes)
frame(A)
check(mem[L("STEREO")] == 0, "a held key seen on both SKSTATs drops back to mono")
mem[0xD21F] = 0x04
for _ in range(20): frame()
tap(BK)

# 13. held chords: R = AUTO + POLY on the current preset
RK, DK, GK = 0x28, 0x3A, 0x3D           # R, D (E), G (G)
call("select_preset", a=0)
tap(RK)
check(mem[L("P_CHORD")] == 7 and mem[L("P_CHDSPD")] == 0, "R -> CHORD AUTO, CHD SPD POLY")
ed = lambda r, c: "".join(chr((ch & 0x7F) + 32) for ch in mem[0x4000 + r * 40 + c:0x4000 + r * 40 + c + 6])
check(ed(19, 29) == "AUTO  " and ed(20, 29).startswith("POLY"), f"editor shows '{ed(19, 29)}' / '{ed(20, 29)}'")
lay = lambda n: mem[L("lay64") + n]
for key, root, t3, t5, nm in ((A, 36, 40, 43, "C major"), (DK, 40, 43, 47, "E minor"),
                              (GK, 43, 47, 50, "G major")):
    for _ in range(3): frame(key)
    check(mem[L("NOTE")] == root and mem[L("NOTEIDX")] == root and mem[0xD204] == lay(t3)
          and mem[0xD206] == lay(t5) and mem[0xD205] & 0x0F > 5 and mem[0xD207] & 0x0F > 5,
          f"{nm}: lead {root}, ch3 {t3}, ch4 {t5} sounding together")
    for _ in range(30): frame()
for _ in range(3): frame(A)
frame(C)                                # kick takes ch4
check(mem[0xD207] & 0xF0 in (0x10, 0x80, 0xC0), "a drum hit takes ch4 over the chord")
for _ in range(20): frame(A)
check(mem[0xD206] == lay(43) and mem[0xD207] & 0x0F > 0, "the fifth returns to ch4 after the drum")
for _ in range(30): frame()
check(mem[0xD207] & 0x0F == 0 and mem[0xD205] & 0x0F == 0, "released chord goes silent")
tap(RK)
check(mem[L("P_CHORD")] == 0 and mem[L("P_CHDSPD")] == 7, "R again -> chords off")
# AUTO as an arpeggio (speed > 0) walks the diatonic triad
mem[L("P_CHORD")] = 7; mem[L("P_CHDSPD")] = 7
seq = []
for _ in range(8):
    frame(DK); seq.append(mem[L("NOTEIDX")] - 40)
check(set(seq) == {0, 3, 7}, f"AUTO arpeggio on E: offsets {sorted(set(seq))}")
for _ in range(30): frame()
mem[L("P_CHORD")] = 0
tap(0x0C)                               # RETURN: factory PIANO

# 14. song mode: queue a second section into bank 1, switch at the seam
def lanes_of(demo_i):
    name, S, N, p1, p2, t1, t2, dr = gd.DEMOS[demo_i]
    L5 = [bytearray(N * S) for _ in range(5)]
    for lane, tr in ((0, t1), (3, t2)):
        for t, nn, d in tr:
            L5[lane][t * S] = nn + 1
            L5[lane][(t + d) * S - 2] = 0xFE
    for k, v in enumerate(dr):
        if v: L5[1][k * S] = v
    L5[2][0], L5[4][0] = p1, p2
    return N * S, L5, len(t1), len(t2), sum(1 for v in dr if v)
tap(BK)
tap(Q)                                  # GROOVE in bank 0 (the demo loader)
check(mem[L("LBANK")] == 0, "demo plays from bank 0")
n2, L5, c1, c2, cd = lanes_of(1)        # TECHNO -> bank 1
for k, base in enumerate((0x5000, 0x6000, 0x7000, 0x8000, 0x9000)):
    for i, v in enumerate(L5[k]): mem[base + 0x800 + i] = v
mem[L("NEXTLEN")], mem[L("NEXTLEN") + 1] = n2 & 255, n2 >> 8
mem[L("NEXTT1")] = 1
sc0 = mem[L("SECTCNT")]
mem[L("NEXTREQ")] = 1
while mem[L("SECTCNT")] == sc0: frame(); main_frame()
check(mem[L("LBANK")] == 8 and w(L("LLENLO")) == n2 and w(L("LPOSLO")) == 0
      and mem[L("NEXTREQ")] == 0, "at the seam: bank 1, TECHNO's length, from frame 0")
cn = [mem[L(x)] for x in ("NOTE2CNT", "NOTECNT", "DRUMCNT")]
for _ in range(n2): frame(); main_frame()
got = [(mem[L(x)] - cn[i]) & 255 for i, x in enumerate(("NOTE2CNT", "NOTECNT", "DRUMCNT"))]
check(got == [c1, c2, cd], f"bank 1 pass plays TECHNO {got} (want {[c1, c2, cd]})")
mem[L("NEXTREQ")] = 2
sc0 = mem[L("SECTCNT")]
while mem[L("SECTCNT")] == sc0: frame(); main_frame()
check(mem[L("LSTATE")] == 4 and w(L("LPOSLO")) == 0, "NEXTREQ 2 stops the song at the seam")
tap(BK)
check(mem[L("LBANK")] == 0 and mem[L("NEXTREQ")] == 0, "clear resets to bank 0")

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
