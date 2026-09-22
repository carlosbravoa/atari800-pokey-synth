#!/usr/bin/env python3
"""POKEY SYNTH sequence files (.psq): music the PC streams to the Atari.

Unlike a loop (.psl) or a song of loops (.song/.pss), a .psq isn't stored on
the Atari at all: the PC feeds timed events over the bridge and the synth's
VBI plays each one on the frame it's due. So a .psq has no length limit, and
it can drive several voices at once (polyphony = simultaneous tracks).

FILE FORMAT
  header, 32 bytes
    0-3   b"PSQ1"
    4     mode: 0 mono, 1 stereo, 2 either (see TRACK LAYOUT)
    5     melodic tracks used (1-3)
    6     drum channels used (1-2)
    7     tick rate, frames per second (60 = NTSC; informational)
    8-9   total length in frames, little endian (informational)
    10-25 title, ASCII, space padded
    26-31 reserved, zero
  events, until END
    delta  u8   frames since the previous event; 255 = wait 255 and read
                another delta (so any gap is expressible)
    cmd    u8   op<<4 | track
    arg    u8   only for the ops that take one
  ops
    0  NOTE_ON  arg = note, 0 = C1 ... 95 = B8
    1  NOTE_OFF
    2  DRUM     arg = 0 kick 1 snare 2 hat 3 open 4 tom 5 tom2 6 clap 7 crash
                (track = drum channel)
    3  PRESET   arg = 0-9 (PIANO ORGAN FLUTE STRINGS BASS CHIPARP SYNTH BELL
                LASER UFO)
    4  PARAM    arg = param<<4 | value, lead track only (param order: WAVE
                ATK DEC SUS REL LAYER VIB VIBSPD CHORD CHDSPD SWEEP GLIDE)
    14 ALLOFF
    15 END

TRACK LAYOUT (what the Atari can actually sound at once)
  mono (1 POKEY)   track 0 -> the lead (16-bit, all effects)
                   track 1 -> voice 0 on ch3 (wave + ADSR + chord only)
                   drums 0 -> ch4
  stereo (2 POKEYs) track 0 -> the lead, POKEY1 (left)
                   track 1 -> voice 0, POKEY2 16-bit (right)
                   track 2 -> voice 1, POKEY2 ch3 (right)
                   drums 0 -> POKEY1 ch4, drums 1 -> POKEY2 ch4
  A stereo file played on a mono machine drops track 2 and folds drums 1
  into drums 0; the player says so. Mode 2 means the file already fits both.

Each track is monophonic, so chords need one track per note (or the synth's
own held-chord mode via PARAM CHORD/CHDSPD on the lead).
"""
import struct

MAGIC = b"PSQ1"
MONO, STEREO, EITHER = 0, 1, 2
NOTE_ON, NOTE_OFF, DRUM, PRESET, PARAM, ALLOFF, END = 0, 1, 2, 3, 4, 14, 15
PRESETS = "PIANO ORGAN FLUTE STRINGS BASS CHIPARP SYNTH BELL LASER UFO".split()
DRUMS = "kick snare hat open tom tom2 clap crash".split()
NAMES = "C C# D D# E F F# G G# A A# B".split()

# op -> does it carry an argument
HAS_ARG = {NOTE_ON: True, NOTE_OFF: False, DRUM: True, PRESET: True,
           PARAM: True, ALLOFF: False, END: False}

# (op, track) -> the Atari's stream command, per mode
CMD = {
    STEREO: {(NOTE_ON, 0): 0, (NOTE_OFF, 0): 1, (NOTE_ON, 1): 2, (NOTE_OFF, 1): 3,
             (NOTE_ON, 2): 4, (NOTE_OFF, 2): 5, (PRESET, 0): 8, (PRESET, 1): 9,
             (PRESET, 2): 10},
    MONO: {(NOTE_ON, 0): 0, (NOTE_OFF, 0): 1, (NOTE_ON, 1): 2, (NOTE_OFF, 1): 3,
           (PRESET, 0): 8, (PRESET, 1): 9},
}
DRUM_CMD = {(STEREO, 0): 6, (STEREO, 1): 7, (MONO, 0): 6, (MONO, 1): 6}
PARAM_CMD, ALLOFF_CMD, END_CMD = 11, 12, 13


def note(name):
    """'C#4' -> note number (C1 = 0)"""
    return NAMES.index(name[:-1]) + (int(name[-1]) - 1) * 12


def note_name(n):
    return f"{NAMES[n % 12]}{n // 12 + 1}"


class Writer:
    """Collect (frame, op, track, arg) events, then write the file."""

    def __init__(self, title="", mode=EITHER, tracks=2, drums=1, rate=60):
        self.title, self.mode, self.tracks, self.drums, self.rate = \
            title, mode, tracks, drums, rate
        self.ev = []

    def at(self, frame, op, track=0, arg=0):
        self.ev.append((int(frame), op, track, arg))
        return self

    def note_on(self, frame, track, n):
        return self.at(frame, NOTE_ON, track, n)

    def note_off(self, frame, track):
        return self.at(frame, NOTE_OFF, track)

    def play(self, frame, track, n, frames, gap=2):
        """a note of `frames` frames, released `gap` frames early"""
        self.note_on(frame, track, n)
        return self.note_off(frame + max(1, frames - gap), track)

    def drum(self, frame, d, channel=0):
        return self.at(frame, DRUM, channel, d)

    def preset(self, frame, track, p):
        return self.at(frame, PRESET, track, p if isinstance(p, int) else PRESETS.index(p))

    def param(self, frame, idx, value):
        return self.at(frame, PARAM, 0, (idx << 4) | (value & 15))

    def encode(self):
        ev = sorted(self.ev, key=lambda e: (e[0], e[1] != NOTE_OFF))  # offs first
        total = (ev[-1][0] + 60) if ev else 0
        out = bytearray()
        t = 0
        for frame, op, track, arg in ev:
            d = frame - t
            while d > 254:
                out += bytes([255])
                d -= 255
            out += bytes([d, (op << 4) | (track & 15)])
            if HAS_ARG[op]:
                out += bytes([arg])
            t = frame
        out += bytes([0, (END << 4)])
        head = bytearray(32)
        head[0:4] = MAGIC
        head[4] = self.mode
        head[5] = self.tracks
        head[6] = self.drums
        head[7] = self.rate
        head[8:10] = struct.pack("<H", min(total, 0xFFFF))
        head[10:26] = self.title.upper().ljust(16)[:16].encode("ascii", "replace")
        return bytes(head) + bytes(out)

    def save(self, path):
        open(path, "wb").write(self.encode())
        return path


def read(path):
    """-> (header dict, [(frame, op, track, arg)])"""
    d = open(path, "rb").read()
    if d[:4] != MAGIC:
        raise ValueError(f"{path}: not a PSQ1 file")
    h = dict(mode=d[4], tracks=d[5], drums=d[6], rate=d[7],
             frames=struct.unpack("<H", d[8:10])[0],
             title=d[10:26].decode("ascii", "replace").strip())
    ev, i, t = [], 32, 0
    while i < len(d):
        while d[i] == 255:
            t += 255
            i += 1
        t += d[i]
        op, track = d[i + 1] >> 4, d[i + 1] & 15
        i += 2
        arg = 0
        if HAS_ARG[op]:
            arg = d[i]
            i += 1
        ev.append((t, op, track, arg))
        if op == END:
            break
    return h, ev


def to_commands(ev, stereo):
    """file events -> (frame, Atari stream command, arg), folding for mono"""
    mode = STEREO if stereo else MONO
    out, dropped = [], 0
    for frame, op, track, arg in ev:
        if op == DRUM:
            out.append((frame, DRUM_CMD[(mode, min(track, 1))], arg))
        elif op == PARAM:
            out.append((frame, PARAM_CMD, arg))
        elif op == ALLOFF:
            out.append((frame, ALLOFF_CMD, 0))
        elif op == END:
            out.append((frame, END_CMD, 0))
        else:
            c = CMD[mode].get((op, track))
            if c is None:
                dropped += 1
                continue
            out.append((frame, c, arg))
    return out, dropped


def describe(h, ev):
    notes = sum(1 for e in ev if e[1] == NOTE_ON)
    hits = sum(1 for e in ev if e[1] == DRUM)
    per = {}
    for _, op, track, _ in ev:
        if op == NOTE_ON:
            per[track] = per.get(track, 0) + 1
    mode = {MONO: "mono", STEREO: "stereo", EITHER: "mono or stereo"}[h["mode"]]
    return (f"{h['title'] or '(untitled)'}: {mode}, {h['frames']} frames "
            f"({h['frames'] / 59.92:.1f} s), {notes} notes "
            f"{tuple(per.get(t, 0) for t in range(h['tracks']))}, {hits} drum hits")


if __name__ == "__main__":
    import sys
    for f in sys.argv[1:]:
        h, ev = read(f)
        print(f, "->", describe(h, ev))
