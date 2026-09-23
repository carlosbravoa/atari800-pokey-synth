#!/usr/bin/env python3
"""py65 boot of build/pokeyplayer.atr: the OS's part is faked (sectors 1-3 at
$0700, JSR $0706) and DSKINV serves sectors from the image. Checks that the
loader places the player, the player reads the catalog, and each song it
loads from disk is byte-identical to the .psq and plays like it."""
import sys

from py65.devices.mpu6502 import MPU

import psq
from mkdisk import DISK_SONGS

atr = open("build/player_disk.xex", "rb")  # (exists check)
img = open("build/pokeyplayer.atr", "rb").read()
assert img[:2] == b"\x96\x02"
disk = img[16:]
SS = 128
lbl = {}
for line in open("build/player_disk.lbl"):
    _, a, n = line.split()
    lbl[n.lstrip(".")] = int(a, 16)
L = lbl.__getitem__
PAGE6 = dict(PLAYING=0x0644, SONGN=0x0645, NSONG=0x0646, SEVN=0x0647,
             NOTECNT=0x0623, NOTE2CNT=0x066D, NOTE3CNT=0x0672, DRUMCNT=0x0624,
             STEREO=0x0673, LOADING=0x0BC0)

m = MPU()
mem = m.memory
for a in range(0xE000, 0xE400):
    mem[a] = a & 255
mem[0xE45C] = mem[0xE462] = 0x60        # SETVBV / XITVBV
mem[0xD20F] = 0xFF
DSKINV = 0xE453
mem[DSKINV] = 0x60
reads = []
SENT = 0xFFF0
mem[SENT] = 0xEA
ok = True


def check(c, msg):
    global ok
    print(("PASS " if c else "FAIL ") + msg)
    ok &= bool(c)


def step():
    if m.pc == DSKINV:                   # serve the sector, then RTS
        sec = mem[0x030A] | mem[0x030B] << 8
        buf = mem[0x0304] | mem[0x0305] << 8
        reads.append(sec)
        if 1 <= sec <= len(disk) // SS:
            mem[buf:buf + SS] = list(disk[(sec - 1) * SS:sec * SS])
            mem[0x0303] = 1
        else:
            mem[0x0303] = 0x8B           # NAK
    m.step()


def call(addr, a=0, limit=6000000):
    m.a = a
    ret = SENT - 1
    mem[0x1FF], mem[0x1FE] = ret >> 8, ret & 255
    m.sp = 0xFD
    m.pc = addr
    n = 0
    while m.pc != SENT:
        step()
        n += 1
        assert n < limit, f"runaway pc={m.pc:04X}"


# ---- the OS boot: sectors 1-3 -> $0700, then JSR $0706 ---------------------
mem[0x0700:0x0880] = list(disk[:3 * SS])
check(mem[0x0701] == 3 and mem[0x0702] | mem[0x0703] << 8 == 0x0700, "boot header: 3 sectors at $0700")
m.pc, m.sp = 0x0706, 0xFF
n = 0
while m.pc != L("mainloop"):
    step()
    n += 1
    assert n < 8000000, f"boot never reached mainloop (pc={m.pc:04X})"
xex = open("build/player_disk.xex", "rb").read()
check(mem[0x02E0] | mem[0x02E1] << 8 == L("start"), "RUNAD -> the player's start")
seg0 = xex[6:6 + 64]
check(bytes(mem[0x2000:0x2040]) == seg0, "player code placed at $2000")
check(mem[PAGE6["NSONG"]] == len(DISK_SONGS), f"catalog read: {mem[PAGE6['NSONG']]} songs")
check(mem[PAGE6["PLAYING"]] == 1 and mem[PAGE6["LOADING"]] == 0, "song 1 loaded and playing")


def song_bytes(name):
    return open(f"songs/{name}.psq", "rb").read()[32:]


body = song_bytes(DISK_SONGS[0])
check(bytes(mem[0x5000:0x5000 + len(body)]) == body, f"{DISK_SONGS[0]}: {len(body)} bytes identical")

# ---- every song: load from disk, compare bytes, play 300 frames -----------
mem[PAGE6["STEREO"]] = 1
bad = []
for i, name in enumerate(DISK_SONGS):
    for k in ("NOTECNT", "NOTE2CNT", "NOTE3CNT", "DRUMCNT"):
        mem[PAGE6[k]] = 0
    call(L("song_load"), a=i)
    body = song_bytes(name)
    same = bytes(mem[0x5000:0x5000 + len(body)]) == body
    for _ in range(300):
        call(L("seq_step"))
    h, ev = psq.read(f"songs/{name}.psq")
    cmds, _ = psq.to_commands(ev, stereo=1)
    want = {}
    for f, c, a in cmds:
        if f < 300:
            want[c] = want.get(c, 0) + 1
    got = (mem[PAGE6["NOTECNT"]], mem[PAGE6["NOTE2CNT"]], mem[PAGE6["NOTE3CNT"]],
           mem[PAGE6["DRUMCNT"]])
    exp = tuple(x & 255 for x in (want.get(0, 0), want.get(2, 0), want.get(4, 0),
                                  want.get(6, 0) + want.get(7, 0)))
    if not same or got != exp:
        bad.append((name, same, got, exp))
check(not bad, f"all {len(DISK_SONGS)} songs load byte-exact and play their first 5 s"
      + (f": {bad}" if bad else ""))

# ---- a bad disk: the catalog read fails -> no songs, no crash -------------
disk = bytes(3 * SS)                     # only the boot sectors exist
reads.clear()
call(L("read_catalog"))
check(mem[0x0C00] == 0, "unreadable catalog -> 0 songs")
call(L("song_load"), a=0)
check(True, "song_load on an empty catalog returns")
print("\n" + ("ALL PASS" if ok else "FAILURES"))
sys.exit(0 if ok else 1)
