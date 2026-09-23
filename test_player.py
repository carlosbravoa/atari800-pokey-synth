#!/usr/bin/env python3
"""py65 pre-flight for POKEY PLAYER: boots the player on a bare 6502 (no OS),
runs whole songs through its sequencer and checks what it played against the
.psq files, then renders the panel as text. Usage: python3 test_player.py [-v]"""
import re
import sys

from py65.devices.mpu6502 import MPU

import psq

V = "-v" in sys.argv
lbl = {}
for line in open("build/player.lbl"):
    _, a, n = line.split()
    lbl[n.lstrip(".")] = int(a, 16)
for src in ("engine.inc", "player.s"):
    for line in open(src):
        mm = re.match(r"^([A-Z_][A-Z0-9_]*)\s*=\s*(\$[0-9A-Fa-f]+|\d+|"
                      r"[A-Z_][A-Z0-9_]*(?:\+\d+)?)\b", line)
        if mm:
            v = mm.group(2)
            if v.startswith("$"):
                lbl[mm.group(1)] = int(v[1:], 16)
            elif v.isdigit():
                lbl[mm.group(1)] = int(v)
            elif v.split("+")[0] in lbl:
                b, _, o = v.partition("+")
                lbl[mm.group(1)] = lbl[b] + int(o or 0)


def L(n):
    return lbl[n]


m = MPU()
d = open("build/player.xex", "rb").read()
i = 2
while i < len(d):
    if d[i:i + 2] == b"\xff\xff":
        i += 2
    s = int.from_bytes(d[i:i + 2], "little")
    e = int.from_bytes(d[i + 2:i + 4], "little")
    m.memory[s:e + 1] = list(d[i + 4:i + 5 + e - s])
    i += 5 + e - s
mem = m.memory
for a in range(0xE000, 0xE400):         # a stand-in ROM font
    mem[a] = a & 255
mem[0xE45C] = 0x60                      # SETVBV -> rts
mem[0xE462] = 0x60                      # XITVBV -> rts
mem[0xD20F] = 0xFF                      # SKSTAT: no key held
mem[0xD20A] = 0x77                      # RANDOM (mono: it freezes)
SENT = 0xFFF0
mem[SENT] = 0xEA

ok = True


def check(cond, msg):
    global ok
    print(("PASS " if cond else "FAIL ") + msg)
    ok &= bool(cond)


def call(name, a=0, x=0, y=0, limit=4000000):
    m.a, m.x, m.y = a, x, y
    ret = SENT - 1
    mem[0x1FF] = ret >> 8
    mem[0x1FE] = ret & 255
    m.sp = 0xFD
    m.pc = L(name) if isinstance(name, str) else name
    n = 0
    while m.pc != SENT:
        m.step()
        n += 1
        assert n < limit, f"runaway in {name} pc={m.pc:04X}"
    return n


def boot(stereo):
    """run start up to mainloop, then force the wanted POKEY count"""
    m.pc = L("start")
    m.sp = 0xFF
    n = 0
    while m.pc != L("mainloop"):
        m.step()
        n += 1
        assert n < 4000000, f"start never reached mainloop (pc={m.pc:04X})"
    mem[L("STEREO")] = stereo
    call("draw_static")
    call("song_load", a=0)
    return n


def frame():
    """one VBI + one main-thread pass"""
    call("vbi")
    call("read_keys")
    if mem[L("PRESREQ")] != 0xFF:
        p = mem[L("PRESREQ")]
        mem[L("PRESREQ")] = 0xFF
        call("set_preset", a=p)
    call("draw_all")


def seq_frames(n):
    for _ in range(n):
        call("seq_step")


def screen():
    out = []
    for r in range(24):
        row = mem[0x4000 + r * 40:0x4000 + r * 40 + 40]
        out.append("".join(chr(32 + (c & 0x3F)) if 0 <= (c & 0x3F) < 0x40 else "."
                           for c in row))
    return out


# ---------------------------------------------------------------------------
print("== boot ==")
steps = boot(stereo=1)
import gen_songbank
NS = len(gen_songbank.DEFAULT)
check(mem[L("NSONG")] == NS, f"song bank found: {mem[L('NSONG')]} songs")
check(mem[L("PLAYING")] == 1, "song 1 playing")
check(mem[L("STREAMON")] == 1, "POKEY2 carries its own voices (no mirror)")
vp = mem[0xF0] | mem[0xF1] << 8
check(0x5000 < vp < 0xA000, f"event pointer in the bank: ${vp:04X}")
check(mem[L("mapt")] == 0 and mem[L("mapt") + 2] == 4, "stereo command map loaded")

# the title is on the mode-7 row, the static panel around it
scr = screen()
check("ANTHEM" in scr[1], f"title row: {scr[1].strip()!r}")
check("POKEY" in scr[0] and "PLAYER" in scr[0], "header row")
check("STEREO" in scr[2] and f"SONG 01 OF {NS:02d}" in scr[2], f"status row: {scr[2].strip()!r}")
check("PERCUSSION" in scr[17] and "KICK" in scr[19], "percussion panel")

print("\n== play ANTHEM (stereo): what the sequencer did vs the .psq ==")
h, ev = psq.read("songs/anthem.psq")
cmds, _ = psq.to_commands(ev, stereo=1)
seq_frames(400)
check(mem[L("SEVN")] > 0, f"events executed: {mem[L('SEVN')]}")
lead = mem[L("NOTECNT")]
v0 = mem[L("NOTE2CNT")]
v1 = mem[L("NOTE3CNT")]
dr = mem[L("DRUMCNT")]
want = {}
for f, c, a in cmds:
    if f < 400:
        want[c] = want.get(c, 0) + 1
check(lead == want.get(0, 0) & 255, f"lead note-ons {lead} == {want.get(0, 0)}")
check(v0 == want.get(2, 0) & 255, f"voice 0 note-ons {v0} == {want.get(2, 0)}")
check(v1 == want.get(4, 0) & 255, f"voice 1 note-ons {v1} == {want.get(4, 0)}")
check(dr == (want.get(6, 0) + want.get(7, 0)) & 255,
      f"drum hits {dr} == {want.get(6, 0) + want.get(7, 0)}")

print("\n== the panel while it plays ==")
for _ in range(30):
    frame()
scr = screen()
if V:
    for i, r in enumerate(scr):
        print(f"{i:2d}|{r}|")
bars = "".join(scr[5:14])
check(any(c != chr(32 + 3) for c in bars), "meters show something")
check(mem[L("vupk")] > 0 or mem[L("vupk") + 3] > 0, "peak hold is tracking")
check(mem[L("SECS")] > 0 or mem[L("MINS")] > 0, "the clock is running")
mem[L("pstep")], mem[L("pstep") + 1] = 2, 0      # a cell every 2 frames
mem[L("pacc")] = mem[L("pacc") + 1] = 0
for _ in range(12):
    call("draw_prog")
row3 = mem[0x4000 + 3 * 40:0x4000 + 3 * 40 + 40]
check(row3.count(0x80) == 6 and L("G_OFF") in row3,
      f"progress bar advanced {row3.count(0x80)} cells of 40")

print("\n== oscilloscope ==")
dl = L("scope_lms")
shown = mem[dl + 2]
cyc = []
for _ in range(4):                      # clear, then three thirds + swap
    c0 = m.processorCycles
    call("draw_all")
    cyc.append(m.processorCycles - c0)
check(mem[dl + 2] != shown and mem[dl + 2] in (0x18, 0x1C), f"scope buffers swap (${shown:02X}00 -> ${mem[dl + 2]:02X}00)")
buf = mem[mem[dl + 2] * 256:mem[dl + 2] * 256 + 960]
trace = sum(1 for b in buf if b & 0xAA)
check(trace >= 40, f"a trace is drawn: {trace} bytes carry trace pixels")
rows_hit = {i // 40 for i, b in enumerate(buf) if b & 0xAA}
check(len(rows_hit) >= 3, f"it moves vertically: rows {min(rows_hit)}-{max(rows_hit)}")
worst = 0
for _ in range(120):                    # two seconds of the song, frame by frame
    call("vbi")
    c0 = m.processorCycles
    call("draw_all")
    worst = max(worst, m.processorCycles - c0)
print(f"     draw_all cycles: first trace {cyc}, worst of 120 frames {worst}")
check(worst < 14500, "the panel fits the frame (hardware kept pace at 13.7k: see hwplayer.py)")
if V:
    for r in range(24):
        line = ""
        for b in buf[r * 40:r * 40 + 40]:
            for k in (6, 4, 2, 0):
                line += " .#*"[(b >> k) & 3]
        print("|" + line[:160] + "|")

print("\n== keys ==")
mem[0xD20F] = 0xFB                      # a key is down
mem[0xD209] = L("K_GT")                 # '>' next song
call("read_keys")
check(mem[L("SONGN")] == 1, f"'>' moved to song {mem[L('SONGN')] + 1}")
scr = screen()
check("KALINKA" in scr[1], f"title updated: {scr[1].strip()!r}")
mem[0xD20F] = 0xFF
call("read_keys")
mem[0xD20F] = 0xFB
mem[0xD209] = L("K_LT")
call("read_keys")
check(mem[L("SONGN")] == 0, "'<' moved back")
mem[0xD20F] = 0xFF
call("read_keys")
mem[0xD20F] = 0xFB
mem[0xD209] = L("K_SPACE")
call("read_keys")
check(mem[L("PAUSED")] == 1, "SPACE pauses")
before = mem[L("SEVN")]
seq_frames(60)
check(mem[L("SEVN")] == before, "a paused song executes nothing")
mem[0xD20F] = 0xFF
call("read_keys")
mem[0xD20F] = 0xFB
call("read_keys")
check(mem[L("PAUSED")] == 0, "SPACE resumes")
mem[0xD20F] = 0xFF
call("read_keys")

print("\n== end of song rolls on to the next ==")
last = NS - 1                           # SMB 1-09: the short one, last
call("song_load", a=last)
n = 0
while mem[L("PLAYING")] and n < 4000:
    call("seq_step")
    n += 1
check(not mem[L("PLAYING")], f"the stream ended after {n} frames")
check(mem[L("PENDN")] == 1, "it asked the main thread for the next song")
check(mem[0xD200 + 1] == 0 or mem[L("VOLHI")] == 0, "voices hushed at the end")
call("next_song")
check(mem[L("SONGN")] == 0 and mem[L("PLAYING")] == 1, "wrapped to song 1")

print("\n== mono machine ==")
boot(stereo=0)
call("draw_static")
call("song_load", a=0)
check(mem[L("mapt") + 2] == 0xFF, "mono map drops the third track")
scr = screen()
check("MONO" in scr[2], "status says MONO")
check("VOICE" in scr[14], f"mono labels: {scr[14].strip()!r}")
cmds_m, dropped = psq.to_commands(ev, stereo=0)
seq_frames(400)
wantm = {}
for f, c, a in cmds_m:
    if f < 400:
        wantm[c] = wantm.get(c, 0) + 1
check(mem[L("NOTECNT")] == wantm.get(0, 0) & 255,
      f"mono lead note-ons {mem[L('NOTECNT')]} == {wantm.get(0, 0)}")
check(mem[L("NOTE3CNT")] == 0, "no voice-1 notes on a mono machine")
check(mem[L("vusrc") + 3] == 0xFF, "the right-hand meters are marked dead")

print("\n" + ("ALL PASS" if ok else "FAILURES"))
sys.exit(0 if ok else 1)
