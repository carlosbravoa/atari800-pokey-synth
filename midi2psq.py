#!/usr/bin/env python3
"""MIDI -> .psq: turn a MIDI file into a sequence the PC streams to the synth.

    python3 midi2psq.py FILE.mid --inspect           # what's in it
    python3 midi2psq.py FILE.mid -o songs/x.psq \
        --lead 1,2 --bass 3 --harm 4 [--drums 10]    # tracks (1-based)
    python3 pcplay.py songs/x.psq

What it has to decide, and how:
  * The synth's tracks are monophonic, so each part keeps one note at a
    time: the lead keeps the top note of a chord, the bass the bottom, the
    harmony the second from the top. Overlapping notes interrupt (legato),
    which is what makes bounce figures survive.
  * With no --lead/--bass, parts are picked automatically from the file's
    own channel statistics, and every conversion prints a coverage map
    (which tenth of the song each part plays) with a warning when a part
    is mostly silent - that is what catches a wrong track choice.
  * Parts are picked as track or track:channel (both 1-based), which is
    what type-0 files need: everything is in one track there.
  * Several MIDI parts can feed one part: earlier ones mask later ones
    while sounding (an arrangement that hands the tune between instruments
    stays whole).
  * Range: the synth plays MIDI 24-119 (C1-B8). A part outside that is
    transposed by whole octaves, and anything still out of range is
    dropped (reported).
  * Drums: General MIDI percussion (channel 10) maps onto the 8 pads.
  * Time: MIDI seconds -> NTSC frames (59.92/s). No grid quantization; the
    original timing is kept to the frame.

Reuses the MIDI reading of ../tools/midi2pokey.py (skill: atari-music).
"""
import argparse
import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import midi2pokey as m2p  # noqa: E402
import mido  # noqa: E402
import psq  # noqa: E402

FPS = 59.92
LOW, HIGH = 24, 119                      # the synth's note range in MIDI terms
# General MIDI percussion -> the synth's 8 pads
# 0 kick 1 snare 2 hat 3 open hat 4 tom 5 tom2 6 clap 7 crash
GM_DRUM = {35: 0, 36: 0, 37: 6, 38: 1, 39: 6, 40: 1, 41: 4, 42: 2, 43: 4,
           44: 2, 45: 4, 46: 3, 47: 5, 48: 5, 49: 7, 50: 5, 51: 2, 52: 7,
           53: 2, 54: 2, 55: 7, 56: 2, 57: 7, 58: 2, 59: 2,
           60: 5, 61: 4, 62: 5, 63: 4, 64: 4, 65: 5, 66: 4, 67: 5, 68: 4,
           69: 2, 70: 2, 71: 2, 72: 2, 73: 2, 74: 2, 75: 6, 76: 5, 77: 4,
           78: 2, 79: 3, 80: 2, 81: 2, 82: 2, 83: 2, 84: 2, 85: 6, 86: 4,
           87: 4}


DRUM_CH = 9                              # GM percussion (channel 10, 0-based)


def raw_notes(mid, track):
    """[(note, channel, start, end)] with proper on/off pairing per channel"""
    tmap, tpb = m2p.tempo_map(mid), mid.ticks_per_beat
    t, open_, out = 0, {}, []
    for msg in mid.tracks[track]:
        t += msg.time
        sec = m2p.tick_to_sec(tmap, t, tpb)
        if msg.type not in ("note_on", "note_off"):
            continue
        key = (getattr(msg, "channel", 0), msg.note)
        if msg.type == "note_on" and msg.velocity > 0:
            if key in open_:
                out.append((msg.note, key[0], open_.pop(key), sec))
            open_[key] = sec
        elif key in open_:
            out.append((msg.note, key[0], open_.pop(key), sec))
    end = m2p.tick_to_sec(tmap, t, tpb)
    for (ch, n), s in open_.items():
        out.append((n, ch, s, end))
    return sorted(out, key=lambda e: e[2])


def events_of(mid, specs, drums_only=False):
    """[(note, start, end)] for specs like 3 or "3:1" (track[:channel], both
    1-based); channel 10 is percussion and only reaches the drum part"""
    out = []
    for spec in specs:
        tr, _, ch = str(spec).partition(":")
        want = int(ch) - 1 if ch else None
        for n, c, s0, s1 in raw_notes(mid, int(tr) - 1):
            if want is not None and c != want:
                continue
            # naming channel 10 explicitly means "use it as notes"
            if want != DRUM_CH and (c == DRUM_CH) != drums_only:
                continue
            out.append((n, s0, s1))
    return sorted(out, key=lambda e: e[1])


def inspect(mid):
    print(f"type={mid.type} tracks={len(mid.tracks)} "
          f"tpb={mid.ticks_per_beat} len={mid.length:.1f}s")
    for i in range(len(mid.tracks)):
        names = [m.name for m in mid.tracks[i] if m.type == "track_name"]
        notes = raw_notes(mid, i)
        if not notes:
            print(f"track {i + 1}: {names if names else ''} (no notes)")
            continue
        per = {}
        for n, c, s0, s1 in notes:
            per.setdefault(c, []).append(n)
        print(f"track {i + 1}: {' '.join(names)} {len(notes)} notes, "
              f"{notes[0][2]:.1f}-{notes[-1][3]:.1f}s")
        for c, ns in sorted(per.items()):
            kind = " PERCUSSION" if c == DRUM_CH else ""
            print(f"    channel {c + 1}: {len(ns)} notes, midi {min(ns)}-{max(ns)}"
                  f"{kind}   (--lead {i + 1}:{c + 1})")


def part(mid, tracks, prefer, second=False):
    """one monophonic line from 1-based tracks: earlier tracks mask later
    ones while sounding (an arrangement that hands the tune over stays
    whole); `second` takes the second note down of chords, for a harmony
    voice drawn from the same tracks as the lead."""
    lines = [m2p.mono_events(events_of(mid, [t]), prefer=prefer)
             for t in tracks if events_of(mid, [t])]  # per track/channel
    if not lines:
        return []
    out = lines[0]
    for base in lines[1:]:
        out = m2p.overlay(out, base)
    if not second:
        return out
    raw = events_of(mid, tracks)
    rest = [e for e in raw
            if not any(e[0] == n and abs(e[1] - s0) < 0.02 for n, s0, _ in out)]
    return m2p.mono_events(rest, prefer=prefer) if rest else []


# GM instrument families, by program number: what a channel is FOR says
# more about its role than its register does.
def family(prog):
    if prog is None:
        return "?"
    if 32 <= prog <= 39:
        return "bass"
    if (80 <= prog <= 87 or 72 <= prog <= 79 or 64 <= prog <= 71
            or 8 <= prog <= 15):
        return "lead"        # synth lead, pipe, reed, and tuned percussion
                             # (glockenspiel/marimba/xylophone/music box),
                             # which carries the tune in most game rips
    if 56 <= prog <= 63 or 24 <= prog <= 31 or 0 <= prog <= 7:
        return "melodic"                 # brass, guitar, piano
    if 48 <= prog <= 55 or 88 <= prog <= 95 or 40 <= prog <= 47:
        return "pad"                     # strings, ensemble, pads
    return "other"


class Stat:
    """one track/channel, with everything the picker needs"""

    def __init__(self, spec, ns, prog):
        self.spec, self.prog = spec, prog
        self.family = family(prog)
        self.n = len(ns)
        self.mean = sum(n for n, _, _ in ns) / self.n
        self.first = min(s for _, s, _ in ns)
        self.last = max(e for _, _, e in ns)
        self.drum = spec.endswith(f":{DRUM_CH + 1}")
        span = max(1e-6, self.last - self.first)
        self.dens = self.n / span                      # notes per second
        # how much of the time more than one note sounds (a pad holds chords,
        # a melody does not)
        pts = sorted([(s, 1) for _, s, _ in ns] + [(e, -1) for _, _, e in ns])
        live = poly = 0.0
        cur, prev = 0, pts[0][0]
        for t, d in pts:
            if cur > 0:
                live += t - prev
                if cur > 1:
                    poly += t - prev
            cur += d
            prev = t
        self.poly = poly / live if live else 0.0
        self.active = live / span
        # Judge the part the way it will be PLAYED: one note at a time,
        # top note of each chord. A melody is often written as the top of a
        # chord channel, so raw polyphony says little about its role.
        top = m2p.mono_events(ns, prefer="high")
        seq = [n for n, _, _ in top]
        steps = [abs(b - a) for a, b in zip(seq, seq[1:])] or [12]
        self.step = sum(steps) / len(steps)
        self.ntop = len(top)
        self.repeats = (sum(1 for d in steps if d < 1.2) / len(steps)) if steps else 0
        self.iv = [(a, b) for _, a, b in ns]           # when it sounds
        self.pitches = sorted({n for n, _, _ in ns})
        # percussion written on an ordinary channel (NES/arcade rips do
        # this): a sound-effect program, or a couple of pitches hammered
        # fast. Melodically it is noise, so keep it out of the parts.
        # A sound-effect program is the reliable sign. Few pitches alone is
        # not: a power-chord guitar riff also uses three (x-japan_weekend),
        # so an ordinary instrument has to be hammering to qualify.
        self.perc = (not self.drum and
                     ((self.prog is not None and self.prog >= 120) or
                      (len(self.pitches) <= 4 and self.dens >= 8)))


def channel_stats(mid, start=0.0, end=0.0):
    """Stat per track/channel, inside the window being converted"""
    out = []
    for i in range(len(mid.tracks)):
        per, prog, t = {}, {}, 0
        cur = {}
        for msg in mid.tracks[i]:
            if msg.type == "program_change":
                cur[msg.channel] = msg.program
            elif msg.type == "note_on" and msg.velocity > 0:
                ch = getattr(msg, "channel", 0)
                prog.setdefault(ch, cur.get(ch))
        for n, c, s0, s1 in raw_notes(mid, i):
            if end and s0 >= end:
                continue
            if start and s1 <= start:
                continue
            per.setdefault(c, []).append((n, s0, s1))
        for c, ns in per.items():
            out.append(Stat(f"{i + 1}:{c + 1}", ns, prog.get(c)))
    return out


def auto_pick(mid, start=0.0, end=0.0):
    """Pick lead / bass / harmony / drums from the file itself.

    The lead is the part that behaves like a tune: a melody instrument,
    mostly one note at a time, busy, moving in steps rather than leaps, and
    playing through the piece. Picking by register alone kept landing on
    the second voice - a counter-line or a pad sitting above the melody.
    """
    st = channel_stats(mid, start, end)
    drums = [x.spec for x in st if x.drum]
    perc = [x for x in st if x.perc]
    if not drums and perc:                   # no channel 10: use the
        drums = [x.spec for x in perc]       #  percussion-like channels
        print("  (no percussion channel; using " +
              ", ".join(f"{x.spec} prog {x.prog}" for x in perc) + " as drums)")
    mel = [x for x in st if not x.drum and not x.perc and x.n >= 8]
    # Arrangements often double a part on a second channel (another
    # instrument, same notes). A copy adds nothing and, picked as the
    # harmony, it hides the part that should have been there (Nintendo
    # World Cup: lead and harmony were one part twice, the tune left out).
    uniq = []
    for x in mel:
        if not any(y.iv == x.iv and y.pitches == x.pitches for y in uniq):
            uniq.append(x)
    mel = uniq
    if not mel:
        return "", "", "", "", ",".join(drums)   # percussion-only file
    span = max(x.last for x in mel) - min(x.first for x in mel) or 1
    cover = lambda x: (x.last - x.first) / span

    # Weights tuned against files rated on the real machine (see
    # songs/ratings.md). What actually identifies a tune: it plays one note
    # at a time, it moves in steps of a tone or two (a mean step under ~1
    # semitone is a repeated-note ostinato, over ~8 is an arpeggio or a
    # bass), and it is sounding most of the time. The GM instrument label
    # is only a hint: game rips put melodies on "bass" programs.
    def fam_hint(x, want):
        return {"lead": 1.0, "melodic": 0.6, "other": 0.2, "?": 0.2,
                "pad": 0.0, "bass": -0.5}[x.family] if want == "lead" else 0.0

    def step_fit(x):
        if x.step < 1.0:
            return -0.3      # repeated notes: playable as a lead, but only
        if x.step <= 6.0:    #  on a percussive preset (see pick_preset)
            return 1.5       # stepwise: a tune
        return 0.3 if x.step <= 9.0 else 0.0     # leaps: arpeggio or bass

    def whole_arrangement(x):
        """one channel carrying melody AND accompaniment AND bass (a piano
        reduction): wide range with a low centre. Its top line is not the
        tune. Chordy leads with a high centre are fine (StarmanE, rcr-main)."""
        rng = max(x.pitches) - min(x.pitches)
        return 1.5 if rng >= 36 and x.mean <= 60 else 0.0

    def lead_score(x):
        # note count, not "how much of the time it sounds": in the rated
        # set the busiest-sounding channel was wrong in both directions
        # note count carries real weight: picking the sparser of two
        # melodic lines cost a 5 -> 3 on dbz2bsgt
        return (0.6 * (1.0 - x.poly) + 2.5 * min(x.ntop, 120) / 120
                + 0.8 * min(x.dens, 6) / 6 + step_fit(x)
                + 0.8 * fam_hint(x, "lead") - abs(x.mean - 74) / 40
                - whole_arrangement(x))

    def bass_score(x):
        fam = {"bass": 1.2, "melodic": 0.2, "other": 0.2, "?": 0.2,
               "pad": -0.3, "lead": -0.5}[x.family]
        return (fam + 1.0 * x.active + 1.5 * (1.0 - x.poly)
                + 1.2 * min(x.n, 120) / 120 - max(0, x.mean - 50) / 6)

    def harm_score(x):
        fam = {"pad": 1.0, "melodic": 0.6, "lead": 0.5, "other": 0.3,
               "?": 0.3, "bass": -1.0}[x.family]
        # a counter-line has to move: a repeated-note ostinato played on a
        # sustaining preset just sounds like one stuck note
        return (fam + 1.0 * x.active + 1.5 * min(x.n, 120) / 120
                + step_fit(x) - abs(x.mean - 66) / 14)

    # a tune does not live in the bass register: keep those out of the
    # running while anything else is available (note count alone would
    # otherwise hand the lead to a busy bass line)
    high = [x for x in mel if x.mean >= 50] or mel
    lead = max(high, key=lead_score)
    # (an older rule swapped away from chord channels here; with the score
    # now computed on each candidate's top line that was wrong - it handed
    # the lead to a counter-line in rcr-main)
    # A sung melody: strictly one note at a time, stepwise, in the singer's
    # register, and a real amount of it. When the lead picked above is
    # mostly chords (a riff, comping) and such a line exists, the line is
    # the tune and takes the lead; the chord part is not dropped but moves
    # to the fourth voice (POKEY1 ch3). dbztheme: the vocal sits on a
    # sound-effect program (1:1) and lost the lead to the synth riff (1:2).
    # The line has to carry on to the end, like a singer does: a solo that
    # stops well before the song ends is an episode, not the tune (wily9:
    # a guitar solo from 26 s to 75 s took the melody's place).
    voice4 = None
    if lead.poly > 0.5:
        end = max(x.last for x in mel)
        sung = [x for x in high if x is not lead and x.poly < 0.05
                and 1.0 <= x.step <= 4.0 and 62 <= x.mean <= 82 and x.ntop >= 40
                and x.last >= end - 0.12 * span]
        if sung:
            voice4, lead = lead, max(sung, key=lead_score)
    rest = [x for x in mel if x is not lead and x is not voice4]
    bass = max(rest, key=bass_score) if rest else None
    rest = [x for x in rest if x is not bass]
    harm = max(rest, key=harm_score) if rest else None

    def sounding(ivs):
        """merge intervals -> total seconds and the merged list"""
        out = []
        for a2, b in sorted(ivs):
            if out and a2 <= out[-1][1]:
                out[-1][1] = max(out[-1][1], b)
            else:
                out.append([a2, b])
        return sum(b - a2 for a2, b in out), out

    def fills(cand, have):
        """how many seconds the candidate sounds while `have` is silent"""
        _, merged = sounding(have)
        extra = 0.0
        for a2, b in cand:
            seg = [(a2, b)]
            for x, y in merged:
                seg = [p for s0, s1 in seg
                       for p in ((s0, min(s1, x)), (max(s0, y), s1))
                       if p[1] - p[0] > 0.01]
            extra += sum(s1 - s0 for s0, s1 in seg)
        return extra

    def relay(seed, pool, melodic=True):
        """Arrangements hand a part between instruments: a second channel
        carries the tune where the first is silent (smkrainbow's chorus).
        So the test is what a candidate ADDS while the chosen part rests -
        not its register, and not whether their spans overlap. part() then
        masks it note by note wherever the chosen part is sounding."""
        chosen, have = [seed], list(seed.iv)
        for c in sorted(pool, key=lambda x: -x.n):
            if melodic and step_fit(c) <= 0 and c.step >= 1.0:
                continue
            if c.family == "bass" and seed.family != "bass":
                continue
            if abs(c.mean - seed.mean) > 14:
                continue
            if fills(c.iv, have) < 0.08 * span:        # adds little: skip
                continue
            chosen.append(c)
            have += c.iv
        return chosen

    used = {x.spec for x in (lead, bass, harm, voice4) if x}
    free = lambda: [x for x in mel if x.spec not in used]
    leads = relay(lead, free()) if lead else []
    used |= {x.spec for x in leads}
    v4s = relay(voice4, free()) if voice4 else []
    used |= {x.spec for x in v4s}
    basses = relay(bass, free(), melodic=False) if bass else []
    used |= {x.spec for x in basses}
    harms = relay(harm, free()) if harm else []
    print("auto-picked parts (override with --lead/--bass/--harm/--voice4/--drums):")
    for nm, xs in (("lead", leads), ("bass", basses), ("harmony", harms),
                   ("voice4", v4s)):
        for k, x in enumerate(xs):
            print(f"  {(nm if k == 0 else ' + also'):8s} {x.spec:6s} {x.n:4d} notes, "
                  f"midi {x.mean:.0f}, {x.dens:.1f}/s, {int(x.poly * 100):2d}% chords, "
                  f"step {x.step:.1f}, {x.family}")
    if drums:
        print(f"  drums    {','.join(drums)}")
    j = lambda xs: ",".join(x.spec for x in xs)
    return j(leads), j(basses), j(harms), j(v4s), ",".join(drums)


def find_pulse(onsets, lo=0.17, hi=0.33):
    """-> (eighth-note period, phase) in seconds that best line the note
    onsets up. Game-music MIDIs are often captures played in real time,
    so the file's own tempo and bar lines say nothing. The search range
    (90-176 BPM) keeps it off the half and double of the pulse."""
    import cmath, math
    best = (0.0, lo, 0.0)
    e = lo
    while e <= hi:
        z = sum(cmath.exp(2j * math.pi * t / e) for t in onsets) / len(onsets)
        if abs(z) > best[0]:
            best = (abs(z), e, (cmath.phase(z) / (2 * math.pi)) % 1 * e)
        e += 0.0005
    return best[1], best[2], best[0]


def add_beat(w, parts, start_frame):
    """A pop-rock beat for a file with no percussion, on the song's pulse:
    kick on 1 and 3, snare on 2 and 4 (drum channel 0, the left POKEY),
    closed hats on the eighths and a crash every 8 bars (channel 1, the
    right POKEY, so hats never cut the kick). A tom fill ends each 8 bars."""
    notes = [e for k in ("bass", "lead", "harm") for e in parts.get(k, [])]
    if not notes:
        return 0
    onsets = [s0 for _, s0, _ in notes]
    eighth, phase, strength = find_pulse(onsets)
    first, last = min(onsets), max(s1 for _, _, s1 in notes)
    # which eighth of the bar is the downbeat: long notes start on strong beats
    score = [0.0] * 8
    for _, s0, s1 in notes:
        j = round((s0 - phase) / eighth)
        score[j % 8] += min(s1 - s0, 4 * eighth)
    down = max(range(8), key=lambda b: score[b])
    print(f"  beat: {60 / (2 * eighth):.1f} BPM (alignment {strength:.2f}), "
          f"bars start on eighth {down}")
    fr = lambda t: max(0, round(t * FPS) - start_frame)
    j = math.ceil((first - phase) / eighth)
    # start the beat on the first bar line at or after the first note
    while (j - down) % 8:
        j += 1
    hits = 0
    while True:
        t = phase + j * eighth
        if t > last:
            break
        pos, bar = (j - down) % 8, (j - down) // 8
        fill = bar % 8 == 7 and pos >= 4
        if fill:
            w.drum(fr(t), {4: 1, 5: 1, 6: 4, 7: 5}[pos], 0)   # snare snare tom tom2
        elif pos in (0, 4):
            w.drum(fr(t), 0, 0)                                # kick
        elif pos in (2, 6):
            w.drum(fr(t), 1, 0)                                # snare
        if pos == 0 and bar % 8 == 0:
            w.drum(fr(t), 7, 1)                                # crash
        elif not fill:
            w.drum(fr(t), 2, 1)                                # closed hat
        hits += 1
        j += 1
    return hits


def coverage_check(parts, drums, length):
    """the heuristic that catches a wrong track choice: how much of the
    song each part actually plays, and where the long silences are"""
    print("coverage (bars of 10% of the song, # = playing):")
    bad = []
    for name in ("lead", "bass", "harm", "v4"):
        ev = parts[name]
        if not ev:
            if name != "v4":
                print(f"  {name:5s} -  (not used)")
            continue
        bins = [0] * 10
        for _, s0, s1 in ev:
            for b in range(10):
                if s0 < length * (b + 1) / 10 and s1 > length * b / 10:
                    bins[b] += 1
        bar = "".join("#" if b else "." for b in bins)
        pct = sum(1 for b in bins if b) * 10
        print(f"  {name:5s} {bar}  {pct}% of the song, {len(ev)} notes")
        if pct < 60:
            bad.append(f"{name} plays in only {pct}% of the song")
        elif not bins[0]:
            silent = next(i for i, b in enumerate(bins) if b) * 10
            bad.append(f"{name} is silent for the first {silent}% "
                       f"({silent * length / 100:.0f}s)")
    if drums:
        print(f"  drums {'#' * 10}  {len(drums)} hits")
    for w in bad:
        print(f"  ! {w} - check the track choice (--inspect)")
    return bad


def fit_range(events, name, transpose=0):
    """transpose by octaves until it fits; report what still doesn't"""
    if not events:
        return events, 0
    ev = [(n + transpose, a, b) for n, a, b in events]
    lo, hi = min(n for n, _, _ in ev), max(n for n, _, _ in ev)
    shift = 0
    while lo + shift < LOW:
        shift += 12
    while hi + shift > HIGH:
        shift -= 12
    if shift:
        print(f"  {name}: transposed {shift:+d} semitones to fit the synth")
        ev = [(n + shift, a, b) for n, a, b in ev]
    keep = [e for e in ev if LOW <= e[0] <= HIGH]
    if len(keep) != len(ev):
        print(f"  {name}: {len(ev) - len(keep)} notes outside C1-B8 dropped")
    return keep, shift


def add_part(w, track, events, preset, start_frame=0, gap=2):
    """Notes onto one synth track. Each note is released `gap` frames before
    the next one starts: without that, a repeated pitch on a sustaining
    preset never re-articulates and a run of separate notes is heard as one
    long note."""
    if not events:
        return 0
    w.preset(0, track, preset)
    ev = sorted(events, key=lambda e: e[1])
    n = 0
    for i, (note, s0, s1) in enumerate(ev):
        f0 = max(0, round(s0 * FPS) - start_frame)
        f1 = max(f0 + 1, round(s1 * FPS) - start_frame)
        if i + 1 < len(ev):
            nxt = max(0, round(ev[i + 1][1] * FPS) - start_frame)
            if f1 > nxt - gap:
                f1 = max(f0 + 1, nxt - gap)
        w.note_on(f0, track, note - LOW)
        w.note_off(f1, track)
        n += 1
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("midi")
    ap.add_argument("-o", "--out")
    ap.add_argument("--inspect", action="store_true",
                    help="list tracks and channels, then stop")
    ap.add_argument("--lead", default="",
                    help="parts for the lead: track or track:channel, 1-based, "
                         "comma separated (earlier ones mask later ones)")
    ap.add_argument("--bass", default="")
    ap.add_argument("--harm", default="", help="a third voice (stereo only)")
    ap.add_argument("--voice4", default="",
                    help="a fourth voice on POKEY1 ch3 (stereo, POKEY PLAYER only; "
                         "the synth's stream player ignores it)")
    ap.add_argument("--harm-second", action="store_true",
                    help="take the harmony as the 2nd note of chords "
                         "(when --harm points at the same tracks as --lead)")
    ap.add_argument("--drums", default="", help="tracks whose channel-10 notes become drums")
    ap.add_argument("--preset-lead", default="ORGAN")
    ap.add_argument("--preset-bass", default="BASS")
    ap.add_argument("--preset-harm", default="STRINGS")
    ap.add_argument("--preset-voice4", default="ORGAN")
    for part_ in ("lead", "bass", "harm", "voice4"):
        ap.add_argument(f"--octave-{part_}", type=int, default=0,
                        help=f"move the {part_} part by this many octaves" if part_ == "lead"
                        else argparse.SUPPRESS)
    ap.add_argument("--transpose", type=int, default=0)
    ap.add_argument("--start", type=float, default=0.0, help="skip to this second")
    ap.add_argument("--end", type=float, default=0.0)
    ap.add_argument("--title", default="")
    ap.add_argument("--echo", type=int, default=7,
                    help="frames of delay for the echo voice when a file has "
                         "only one part (default 7 = ~0.12 s)")
    ap.add_argument("--no-drop", action="store_true",
                    help="keep the harmony at its written octave even if it "
                         "sits above the 8-bit voice's accurate range")
    ap.add_argument("--beat", action="store_true",
                    help="no drums in the file: add a pop-rock beat locked to the "
                         "song's own pulse (found from its note onsets)")
    ap.add_argument("--no-double", action="store_true",
                    help="leave a single-part file as one voice")
    a = ap.parse_args()

    mid = mido.MidiFile(a.midi)
    if a.inspect:
        inspect(mid)
        return
    if not (a.lead or a.bass):                 # nothing chosen: choose for them
        a.lead, a.bass, a.harm, a.voice4, a.drums = auto_pick(mid, a.start, a.end)
        if not a.lead and not a.drums:
            sys.exit("nothing to play; use --inspect and pick by hand")
        if not a.lead:
            print("  (percussion only: a drums-only sequence)")

    nums = lambda s: [x.strip() for x in s.split(",") if x.strip()]
    parts = {}
    for name, sel, which in (("lead", a.lead, "high"), ("bass", a.bass, "low"),
                             ("harm", a.harm, "high"), ("v4", a.voice4, "high")):
        parts[name] = part(mid, nums(sel), which,
                           second=(name == "harm" and a.harm_second)) if sel else []
    # channel 10 normally, but a rip may put its drums on an ordinary
    # channel (auto_pick spots those), so fall back to reading it as-is
    drums, gm_drums = [], True
    if a.drums:
        drums = events_of(mid, nums(a.drums), drums_only=True)
        if not drums:                        # a rip with drums on an
            gm_drums = False                 #  ordinary channel: the
            drums = events_of(mid, nums(a.drums), drums_only=False)

    if a.end:
        for k in parts:
            parts[k] = [e for e in parts[k] if e[1] < a.end]
        drums = [e for e in drums if e[1] < a.end]
    if a.start:
        for k in parts:
            parts[k] = [e for e in parts[k] if e[2] > a.start]
        drums = [e for e in drums if e[1] > a.start]
    start_frame = round(a.start * FPS)

    for k, o in (("lead", a.octave_lead), ("bass", a.octave_bass),
                 ("harm", a.octave_harm), ("v4", a.octave_voice4)):
        if o:
            parts[k] = [(n + 12 * o, s0, s1) for n, s0, s1 in parts[k]]
    for k in parts:
        parts[k], _ = fit_range(parts[k], k, a.transpose)
    # The harmony plays on POKEY2's 8-bit voice, whose pitch resolution
    # coarsens with height: ~11 cents at B4, 22 in octave 5, 33 in octave 6.
    # Drop it by octaves until it sits where it can be in tune.
    # (voice 4 is 8-bit too, on POKEY1 ch3: same rule)
    for k, label in (("harm", "harmony"), ("v4", "voice 4")):
        while (parts[k] and not a.no_drop
               and sum(n for n, _, _ in parts[k]) / len(parts[k]) > 62
               and min(n for n, _, _ in parts[k]) - 12 >= LOW):
            parts[k] = [(n - 12, s0, s1) for n, s0, s1 in parts[k]]
            print(f"  {label} dropped an octave (the 8-bit voice drifts sharp "
                  "above B4)")
    coverage_check(parts, drums, (a.end or mid.length) - a.start)

    # A file with only one usable part leaves both POKEY2 voices idle. Use
    # them: an octave-down double for body and a short delayed echo for
    # width, which turns a bare solo into something stereo.
    if parts["lead"] and not parts["bass"] and not parts["harm"] and not a.no_double:
        lead_ev = parts["lead"]
        parts["bass"] = [(n - 12, s0, s1) for n, s0, s1 in lead_ev if n - 12 >= LOW]
        d = a.echo / FPS
        parts["harm"] = [(n, s0 + d, s1 + d) for n, s0, s1 in lead_ev]
        a.preset_bass = a.preset_lead
        a.preset_harm = "FLUTE"
        print(f"  only one part in the file: doubling it an octave down and "
              f"echoing it {a.echo} frames later on POKEY2")

    # A part that repeats one pitch (or nearly) has to be played on a
    # percussive sound: on a sustaining preset each repeat merges into the
    # one before and a whole melody is heard as a single stuck note.
    def auto_preset(events, default):
        """PIANO when the part repeats pitches a lot. The mean step hides
        this once two channels are merged (a leaping part averages the
        repeats away), so count how many steps are repeats instead."""
        if not events:
            return default
        seq = [n for n, _, _ in sorted(events, key=lambda e: e[1])]
        steps = [abs(b - a2) for a2, b in zip(seq, seq[1:])] or [12]
        repeats = sum(1 for d in steps if d < 1.2) / len(steps)
        return "PIANO" if repeats >= 0.4 else default

    if a.preset_lead == "ORGAN":
        a.preset_lead = auto_preset(parts["lead"], "ORGAN")
    if a.preset_harm == "STRINGS":
        a.preset_harm = auto_preset(parts["harm"], "STRINGS")
    if a.preset_voice4 == "ORGAN":
        a.preset_voice4 = auto_preset(parts["v4"], "ORGAN")
    print(f"  sounds: lead {a.preset_lead}, bass {a.preset_bass}, "
          f"harmony {a.preset_harm}" +
          (f", voice 4 {a.preset_voice4}" if parts["v4"] else ""))

    stereo = bool(parts["harm"] or parts["v4"])
    title = a.title or os.path.basename(a.midi).rsplit(".", 1)[0]
    w = psq.Writer(title, mode=psq.STEREO if stereo else psq.EITHER,
                   tracks=4 if parts["v4"] else 3 if stereo else 2, drums=1)
    counts = {
        "lead": add_part(w, 0, parts["lead"], a.preset_lead, start_frame),
        "bass": add_part(w, 1, parts["bass"], a.preset_bass, start_frame),
        "harm": add_part(w, 2, parts["harm"], a.preset_harm, start_frame),
        "v4": add_part(w, 3, parts["v4"], a.preset_voice4, start_frame),
    }
    hits, unknown = 0, set()
    gm = gm_drums                            #  pitches mean nothing there
    order = sorted({n for n, _, _ in drums})
    # a non-GM percussion part (pitches mean nothing): lowest = kick, next
    # = snare, the rest = hats
    byorder = {n: (0 if i == 0 else 1 if i == 1 else 2) for i, n in enumerate(order)}
    for n, s0, _ in drums:
        d = GM_DRUM.get(n) if gm else byorder.get(n, 2)
        if d is None:
            unknown.add(n)
            d = 2
        w.drum(max(0, round(s0 * FPS) - start_frame), d)
        hits += 1
    if unknown:
        print(f"  drums: unmapped GM notes {sorted(unknown)} played as hats")
    if a.beat and not drums:
        hits += add_beat(w, parts, start_frame)
    last = max([e[2] for p in parts.values() for e in p] +
               [e[1] for e in drums] + [0])
    w.at(max(0, round(last * FPS) - start_frame) + 30, psq.ALLOFF)

    out = a.out or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "songs", title.lower().replace(" ", "_") + ".psq")
    w.save(out)
    h, ev = psq.read(out)
    print(f"{out}: {psq.describe(h, ev)}")
    print(f"  lead {counts['lead']}, bass {counts['bass']}, harmony {counts['harm']}"
          + (f", voice 4 {counts['v4']}" if counts["v4"] else "")
          + f" notes, {hits} drum hits, {os.path.getsize(out)} bytes")


if __name__ == "__main__":
    main()
