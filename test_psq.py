#!/usr/bin/env python3
"""Unit tests for the .psq sequence format (no Atari needed)."""
import psq

ok = True


def check(c, msg):
    global ok
    print(("PASS " if c else "FAIL ") + msg)
    ok &= bool(c)


w = psq.Writer("ROUND TRIP", mode=psq.STEREO, tracks=3, drums=2)
w.preset(0, 0, "ORGAN").preset(0, 1, "BASS").preset(0, 2, "STRINGS")
w.play(0, 0, psq.note("C5"), 30)
w.play(0, 1, psq.note("C2"), 60)
w.play(0, 2, psq.note("E4"), 60, gap=4)
w.drum(0, 0).drum(30, 1, channel=1)
w.param(60, 8, 7)                      # CHORD = AUTO on the lead
w.at(400, psq.ALLOFF)
w.at(900, psq.NOTE_ON, 0, psq.note("G5"))   # a gap past 255 frames
w.at(1000, psq.NOTE_OFF, 0)
blob = w.encode()
open("/tmp/_psq_test.psq", "wb").write(blob)
h, ev = psq.read("/tmp/_psq_test.psq")
check(h["title"] == "ROUND TRIP" and h["mode"] == psq.STEREO and h["tracks"] == 3
      and h["drums"] == 2 and h["rate"] == 60, f"header round-trips: {h}")
check([(f, op, t, a) for f, op, t, a in ev if op == psq.NOTE_ON] ==
      [(0, 0, 0, psq.note("C5")), (0, 0, 1, psq.note("C2")), (0, 0, 2, psq.note("E4")),
       (900, 0, 0, psq.note("G5"))], "note-ons round-trip, including the 900-frame gap")
check(any(op == psq.PARAM and a == (8 << 4 | 7) for _, op, _, a in ev), "param event")
check(ev[-1][1] == psq.END, "ends with END")
st, ds = psq.to_commands(ev, True)
mo, dm = psq.to_commands(ev, False)
check(ds == 0 and {c for _, c, _ in st} >= {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11},
      f"stereo keeps every track and both drum channels ({len(st)} commands)")
check(dm == 3 and all(c not in (4, 5) for _, c, _ in mo),
      f"mono drops track 2's 3 events ({dm}) and emits no voice-1 commands")
check(all(c != 7 for _, c, _ in mo), "mono folds drum channel 1 into 0")
check(psq.note("C1") == 0 and psq.note("C4") == 36 and psq.note_name(48) == "C5",
      "note numbering: C1 = 0, C4 = 36, 48 = C5")
# ordering: note-offs at a frame come before note-ons at the same frame
w2 = psq.Writer("ORDER")
w2.note_on(10, 0, 40).note_off(10, 0)
open("/tmp/_psq_o.psq", "wb").write(w2.encode())
_, e2 = psq.read("/tmp/_psq_o.psq")
check([op for _, op, _, _ in e2][:2] == [psq.NOTE_OFF, psq.NOTE_ON],
      "same-frame note-off is emitted before the note-on (re-articulation)")
print("ALL PASS" if ok else "SOME FAILED")
raise SystemExit(0 if ok else 1)
