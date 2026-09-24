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
LSCR = 0x1C00                            # the loading screen (in SCOPEB)
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
dl_at_read = []                          # SDLSTL at each sector read
SENT = 0xFFF0
mem[SENT] = 0xEA
ok = True


def check(c, msg):
    global ok
    print(("PASS " if c else "FAIL ") + msg)
    ok &= bool(c)


def step():
    if L("wait_frame") <= m.pc < L("wait_frame") + 12:   # the OS clock ticks
        mem[0x14] = (mem[0x14] + 1) & 255
    if m.pc == DSKINV:                   # serve the sector, then RTS
        dl_at_read.append(mem[0x0230] | mem[0x0231] << 8)
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


def song_bytes(path):
    return open(path, "rb").read()[32:]


body = song_bytes(DISK_SONGS[0])
check(bytes(mem[0x5000:0x5000 + len(body)]) == body, f"song 1: {len(body)} bytes identical")

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
    h, ev = psq.read(name)
    want = {}                            # the player's own mapping: tracks
    for f, op, t, a in ev:               #  0-3, drum channels 0-1
        if f < 300 and op in (0, 2):
            k = ("n", t) if op == 0 else ("d",)
            want[k] = want.get(k, 0) + 1
    got = (mem[PAGE6["NOTECNT"]], mem[PAGE6["NOTE2CNT"]], mem[PAGE6["NOTE3CNT"]],
           mem[PAGE6["DRUMCNT"]])
    exp = tuple(x & 255 for x in (want.get(("n", 0), 0), want.get(("n", 1), 0),
                                  want.get(("n", 2), 0) + want.get(("n", 3), 0),
                                  want.get(("d",), 0)))
    if not same or got != exp:
        bad.append((name, same, got, exp))
check(not bad, f"all {len(DISK_SONGS)} songs load byte-exact and play their first 5 s"
      + (f": {bad}" if bad else ""))

# ---- voice 4: a four-part song drives POKEY1 ch3 --------------------------
four = [i for i, p in enumerate(DISK_SONGS) if psq.read(p)[0]["tracks"] == 4]
check(four, f"the album has four-part songs: {[DISK_SONGS[i].split('/')[-1] for i in four]}")
i = four[0]
call(L("song_load"), a=i)
mem[L("n4cnt")] = 0
h, ev = psq.read(DISK_SONGS[i])
first = min(f for f, op, t, a in ev if op == 0 and t == 3)
peak = 0
for _ in range(first + 120):
    call(L("vbi"))
    peak = max(peak, mem[0x0B78 + 5] & 15)
n4 = sum(1 for f, op, t, a in ev if op == 0 and t == 3 and f < first + 120)
check(mem[L("v3on")] == 1 and mem[L("n4cnt")] == n4 & 255,
      f"voice 4 plays its notes ({mem[L('n4cnt')]} of {n4})")
check(peak > 0, f"POKEY1 ch3 sounds for it (AUDC3 volume up to {peak})")

# ---- the LOADING screen covers every read, then gives the panel back ----
def m7(line):
    return "".join(chr(32 + (c & 0x3F)) for c in line)


dl_at_read.clear()
mem[0x0230] = mem[0x0231] = 0
seen = {}
orig = step


def watch():
    # snapshot the loading screen halfway through the load
    if m.pc == DSKINV and len(dl_at_read) == 20:
        seen["lines"] = [m7(mem[LSCR + 20 * r:LSCR + 20 * r + 20]) for r in range(4)]
    if m.pc == L("load_hide") and "bar" not in seen:     # loading just ended
        seen["bar"] = list(mem[LSCR + 40:LSCR + 60])


def step():
    watch()
    orig()


call(L("song_load"), a=1)
check(dl_at_read and all(a == L("dlist_load") for a in dl_at_read),
      f"all {len(dl_at_read)} sectors read behind the LOADING screen")
lines = seen.get("lines", ["", "", "", ""])
print("     " + " | ".join(lines))
check("LOADING" in lines[0] and lines[1].strip() and "SONG 02 OF" in lines[3],
      "it shows LOADING, the title and the song number")
bar = seen.get("bar", [])
check(len(bar) == 20 and all(b == (6 | 0xC0) for b in bar), "the bar is full when the song has loaded")
check((mem[0x0230] | mem[0x0231] << 8) == L("dlist"), "the panel is back afterwards")

# ---- the song list: page through all the songs, pick one from disk ------
KEYS = dict(L=0x00, DOWN=0x0F, RIGHT=0x07, RET=0x0C, ESC=0x1C)


def press(k):
    mem[0xD20F] = 0xFB
    mem[0xD209] = KEYS[k]
    call(L("read_keys"))
    mem[0xD20F] = 0xFF
    call(L("read_keys"))


def lrow(r):
    b = L("dlist_list")  # (just to be sure it exists)
    base = 0x1800 + r * 40
    return "".join(chr(32 + (c & 0x3F)) for c in mem[base:base + 40])


n = len(DISK_SONGS)
call(L("song_load"), a=0)
press("L")
check(mem[L("liston")] == 1 and f"OF {n}" in lrow(0), f"the list opens: {lrow(0).strip()!r}")
press("RIGHT")
check(mem[L("lsel")] == 20 and mem[L("ltop")] <= 20 <= mem[L("ltop")] + 19, "a page down: song 21 on screen")
pages = 1
while mem[L("lsel")] != n - 1 and pages < 5:
    press("RIGHT")
    pages += 1
check(mem[L("lsel")] == n - 1 and mem[L("ltop")] == n - 20,
      f"{pages} page-downs reach the last song, window {mem[L('ltop')] + 1}-{mem[L('ltop')] + 20}")
check(f"{n:02d}" in lrow(21), f"row 21 shows song {n}: {lrow(21).strip()!r}")
dl_at_read.clear()
press("RET")
check(mem[PAGE6["SONGN"]] == n - 1 and mem[PAGE6["PLAYING"]] == 1 and mem[L("liston")] == 0,
      f"RETURN loads song {n} from disk and plays it")
check(dl_at_read and all(a == L("dlist_load") for a in dl_at_read), "behind the LOADING screen")
check((mem[0x0230] | mem[0x0231] << 8) == L("dlist"), "then the panel")

# ---- a bad disk: the catalog read fails -> no songs, no crash -------------
disk = bytes(3 * SS)                     # only the boot sectors exist
reads.clear()
call(L("read_catalog"))
check(mem[0x0C00] == 0, "unreadable catalog -> 0 songs")
call(L("song_load"), a=0)
check(True, "song_load on an empty catalog returns")
print("\n" + ("ALL PASS" if ok else "FAILURES"))
sys.exit(0 if ok else 1)
