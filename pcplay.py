#!/usr/bin/env python3
"""Stream a .psq sequence from the PC to the Atari over the bridge.

    python3 pcplay.py FILE.psq [--loop] [--lead N]

The synth's VBI keeps a 16-bit frame clock (SFRAME) and a 256-entry ring of
(frame, command, arg). This script writes events into the ring ahead of
time; the VBI runs each on the frame it's due, so link jitter never reaches
the music. Default lead-in is 120 frames (~2 s); --lead sets it.

Events go in batches of up to 64 per poke: one poke per event (~25 ms each)
could not keep up with dense passages, the ring ran dry and a note hung.

A stereo file on a mono machine drops its third track and folds the second
drum channel into the first (it says how many events that cost).
"""
import os
import sys
import time

import loopfile as lf
import psq
from loopfile import AtariLink

SRING = 0x1C00
STREAMON, SHEAD, STAIL, SFRAME, SEVCNT = 0x0BA7, 0x0BA8, 0x0BA9, 0x0BAA, 0x0BAC
RING = 256
LEAD = 120                      # frames of lead-in / how far ahead we fill
CHUNK = 64                      # events per poke (64 x 4 = 256 bytes)


def play(path, loop=False, lead=LEAD, quiet=False, watch=None):
    h, ev = psq.read(path)
    if not quiet:
        print(psq.describe(h, ev))
    with AtariLink() as l:
        l.ping()
        lf.check_build(l, lf.labels())
        stereo = lf.peek(l, 0x0673, 1)[0]
        cmds, dropped = psq.to_commands(ev, stereo)
        if h["mode"] == psq.STEREO and not stereo:
            print(f"  mono machine: folded the stereo layout ({dropped} events dropped)")
        elif not quiet:
            print(f"  playing in {'stereo' if stereo else 'mono'}")
        if cmds and cmds[-1][1] == 13:          # END: keep it for the last pass
            end = cmds.pop()
        else:
            end = (cmds[-1][0] + 60 if cmds else 60, 13, 0)

        l.poke(STREAMON, bytes([0]))            # stop anything else first
        l.poke(lf.LCMD, bytes([4]))
        time.sleep(0.1)
        l.poke(SHEAD, bytes([0, 0]))            # head = tail = 0
        base = int.from_bytes(lf.peek(l, SFRAME, 2), "little") + lead
        span = cmds[-1][0] + 1 if cmds else 1

        def frame_now():
            return int.from_bytes(lf.peek(l, SFRAME, 2), "little")

        queue = [(f + base, c, a) for f, c, a in cmds]
        passes, under = 0, 0
        tail, started = 0, False
        try:
            while True:
                while queue:
                    head = lf.peek(l, SHEAD, 1)[0]
                    free = (head - tail - 1) & (RING - 1)
                    now = frame_now()
                    if started and head == tail and queue[0][0] <= now:
                        under += 1          # the ring ran dry: we were too slow
                    batch = []
                    while queue and len(batch) < free and queue[0][0] - now < lead * 3:
                        batch.append(queue.pop(0))
                    if not batch:
                        if not started:
                            l.poke(STREAMON, bytes([1]))
                            started = True
                        time.sleep(0.05)
                        continue
                    i = 0                   # write whole runs: one poke per 64
                    while i < len(batch):   #  events, never crossing the wrap
                        run = min(len(batch) - i, RING - tail, CHUNK)
                        pay = b"".join(bytes([f & 255, (f >> 8) & 255, c, a])
                                       for f, c, a in batch[i:i + run])
                        l.poke(SRING + tail * 4, pay)
                        tail = (tail + run) & (RING - 1)
                        i += run
                    l.poke(STAIL, bytes([tail]))
                    if watch and time.time() - watch[0] > 1.0:
                        watch[0] = time.time()
                        st = lf.peek(l, 0x0600, 0x75)
                        v = lf.peek(l, 0x0B40, 0x30)
                        sh = lf.peek(l, 0x0B78, 32)
                        print(f"    t{frame_now() - base:5d} lead n{st[0x0A]:3d} "
                              f"est{st[0x0B]} vol{st[0x0D]:2d} AUDC{sh[3]:02X} | "
                              f"v0 n{v[1]:3d} est{v[2]} vol{v[4]:2d} AUDC{sh[0x13]:02X} | "
                              f"v1 n{v[21]:3d} est{v[22]} vol{v[24]:2d} AUDC{sh[0x15]:02X}",
                              flush=True)
                    if not started:
                        l.poke(STREAMON, bytes([1]))
                        started = True
                passes += 1
                if not loop:
                    break
                base += span                    # seamless: the next pass is
                queue = [(f + base, c, a) for f, c, a in cmds]   # already timed
                while frame_now() < base - lead:
                    time.sleep(0.05)
            f, c, a = end
            f += base
            l.poke(SRING + tail * 4, bytes([f & 255, (f >> 8) & 255, c, a]))
            tail = (tail + 1) & (RING - 1)
            l.poke(STAIL, bytes([tail]))
            while lf.peek(l, STREAMON, 1)[0]:   # the END command clears it
                time.sleep(0.1)
            if not quiet:
                print(f"done: {lf.peek(l, SEVCNT, 1)[0]} events executed (mod 256), "
                      f"{passes} pass(es)"
                      + (f", {under} underruns (raise --lead)" if under else ""))
        except (KeyboardInterrupt, Exception) as e:
            l.poke(STREAMON, bytes([0]))        # never leave a note hanging
            l.poke(STAIL, lf.peek(l, SHEAD, 1))
            l.poke(SRING, bytes([0, 0, 12, 0])) # all-off, due immediately
            l.poke(SHEAD, bytes([0, 1]))
            l.poke(STREAMON, bytes([1]))
            time.sleep(0.1)
            l.poke(STREAMON, bytes([0]))
            l.poke(0x064A, bytes([4]))          # silence the synth
            print("\nstopped" if isinstance(e, KeyboardInterrupt) else f"\nstopped: {e}")


def main():
    a = [x for x in sys.argv[1:] if not x.startswith("--")]
    if not a:
        sys.exit(__doc__)
    lead = LEAD
    for x in sys.argv[1:]:
        if x.startswith("--lead"):
            lead = int(x.split("=")[1]) if "=" in x else LEAD
    path = a[0]
    if not os.path.exists(path):
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "songs", a[0])
        if not path.endswith(".psq"):
            path += ".psq"
    play(path, loop="--loop" in sys.argv, lead=lead,
         watch=[0.0] if "--watch" in sys.argv else None)


if __name__ == "__main__":
    main()
