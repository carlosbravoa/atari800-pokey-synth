#!/usr/bin/env python3
"""Hardware song test: two demos saved as loops, a 3-part song played with
bank switching; each switch must land on the expected seam (Atari frames)."""
import os, subprocess, sys, time
sys.path.insert(0, "/home/carlos/devel/fpga/atari800_tang_nano20k_parallel/tools")
from atari_link import AtariLink
import loopfile as lf
import songfile as sf

ok = True
def check(c, msg):
    global ok
    print(("PASS " if c else "FAIL ") + msg)
    ok &= bool(c)

def keys(*hids):
    with AtariLink() as l:
        for k in hids:
            l.key(k, hold_ms=100); time.sleep(0.4)

def run(*args):
    r = subprocess.run([sys.executable, "loopfile.py", *args], capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr).strip()

keys(0x29, 0x2A, 0x1E, 0x28, 0x2E)             # clear, PIANO factory, '>' GROOVE
check(run("save", "_t_groove")[0] == 0, "saved GROOVE as a loop")
keys(0x2E)                                     # '>' TECHNO
check(run("save", "_t_techno")[0] == 0, "saved TECHNO as a loop")
os.makedirs(sf.SONGS, exist_ok=True)
open(sf.spath("_t_test", ".song"), "w").write("# test song\n_t_groove 2\n_t_techno\n_t_groove 1\n")

def verify(tag, tr):
    want = [(0, 0, 256, None), (512, 8, 224, 2), (736, 0, 256, 2), (992, None, None, 4)]
    check(len(tr) == 4, f"{tag}: {len(tr)} trace points (start, 2 switches, end)")
    ts = [e["t"] for e in tr]
    gaps = [b - a for a, b in zip(ts[1:], ts[2:])]
    check(all(abs(g - w) <= 3 for g, w in zip(gaps, (224, 256))),
          f"{tag}: seam-to-seam {gaps} frames (want [224, 256])")
    passes = [(b["loops"] - a["loops"]) & 255 for a, b in zip(tr, tr[1:])]
    check(passes == [2, 1, 1], f"{tag}: passes per section {passes} (song: 2, 1, 1 - no extra repeats)")
    for e, (_, bank, llen, st) in zip(tr, want):
        good = (bank is None or e["bank"] == bank) \
            and (llen is None or e["llen"] == llen) and (st is None or e.get("state") == st)
        check(good, f"{tag}: bank {e['bank']} len {e['llen']} state {e.get('state')}")

tr = []
sf.play("_t_test", trace=tr)
verify(".song", tr)
sf.pack("_t_test")
os.remove(sf.spath("_t_test", ".song"))
tr = []
sf.play("_t_test", trace=tr)                  # now only the .pss exists
verify(".pss", tr)
for f in (sf.spath("_t_test", ".pss"), lf.path("_t_groove"), lf.path("_t_techno")):
    os.remove(f)
keys(0x29, 0x2A)
print("ALL PASS" if ok else "SOME FAILED")
