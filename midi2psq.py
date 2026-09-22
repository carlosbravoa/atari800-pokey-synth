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
            if (c == DRUM_CH) != drums_only:
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


def channel_stats(mid, start=0.0, end=0.0):
    """[(spec, notes, mean pitch, first, last, is_drum)] per track/channel,
    counted only inside the window that is actually being converted"""
    out = []
    for i in range(len(mid.tracks)):
        per = {}
        for n, c, s0, s1 in raw_notes(mid, i):
            if end and s0 >= end:
                continue
            if start and s1 <= start:
                continue
            per.setdefault(c, []).append((n, s0, s1))
        for c, ns in per.items():
            out.append((f"{i + 1}:{c + 1}", len(ns),
                        sum(n for n, _, _ in ns) / len(ns),
                        min(s for _, s, _ in ns), max(e for _, _, e in ns),
                        c == DRUM_CH))
    return out


def auto_pick(mid, start=0.0, end=0.0):
    """Pick lead / bass / harmony / drums from the file itself.

    Each role wants a register AND a part that actually plays: a sparse
    8-note line in the cellar is not the bass, and the highest sparkle is
    not the tune. Roles are then filled out with other parts in the same
    register that cover the stretches the first one is silent for, because
    arrangements hand a part between instruments.
    """
    st = channel_stats(mid, start, end)
    drums = [x[0] for x in st if x[5]]
    mel = [x for x in st if not x[5] and x[1] >= 8]
    if not mel:
        return "", "", "", ",".join(drums)
    span = max(x[4] for x in mel) - min(x[3] for x in mel) or 1

    def cover(x):
        return (x[4] - x[3]) / span

    def pick(pool, centre, low=False):
        def score(x):
            reg = max(0, x[2] - centre) / 6 if low else abs(x[2] - centre) / 8
            return cover(x) * 4 + x[1] / 150 - reg
        return max(pool, key=score) if pool else None

    lead = pick(mel, 72)
    rest = [x for x in mel if x is not lead]
    bass = pick(rest, 45, low=True)
    rest = [x for x in rest if x is not bass]
    harm = pick(rest, 64)

    def relay(seed, pool):
        chosen = [seed]
        for c in sorted(pool, key=lambda x: -x[1]):
            if abs(c[2] - seed[2]) > 8:
                continue
            overlap = any(min(c[4], x[4]) - max(c[3], x[3]) > 0.5 * (c[4] - c[3])
                          for x in chosen)
            if not overlap:
                chosen.append(c)
        return chosen

    used = {x[0] for x in (lead, bass, harm) if x}
    free = lambda: [x for x in mel if x[0] not in used]
    leads = relay(lead, free()) if lead else []
    used |= {x[0] for x in leads}
    basses = relay(bass, free()) if bass else []
    used |= {x[0] for x in basses}
    harms = relay(harm, free()) if harm else []
    print("auto-picked parts (override with --lead/--bass/--harm/--drums):")
    for nm, xs in (("lead", leads), ("bass", basses), ("harmony", harms)):
        for k, x in enumerate(xs):
            print(f"  {(nm if k == 0 else ' + also'):8s} {x[0]:6s} {x[1]:4d} notes, "
                  f"mean midi {x[2]:.0f}, {x[3]:.0f}-{x[4]:.0f}s")
    if drums:
        print(f"  drums    {','.join(drums)}")
    j = lambda xs: ",".join(x[0] for x in xs)
    return j(leads), j(basses), j(harms), ",".join(drums)


def coverage_check(parts, drums, length):
    """the heuristic that catches a wrong track choice: how much of the
    song each part actually plays, and where the long silences are"""
    print("coverage (bars of 10% of the song, # = playing):")
    bad = []
    for name in ("lead", "bass", "harm"):
        ev = parts[name]
        if not ev:
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


def add_part(w, track, events, preset, start_frame=0):
    if not events:
        return 0
    w.preset(0, track, preset)
    n = 0
    for note, s0, s1 in events:
        f0 = max(0, round(s0 * FPS) - start_frame)
        f1 = max(f0 + 1, round(s1 * FPS) - start_frame)
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
    ap.add_argument("--harm-second", action="store_true",
                    help="take the harmony as the 2nd note of chords "
                         "(when --harm points at the same tracks as --lead)")
    ap.add_argument("--drums", default="", help="tracks whose channel-10 notes become drums")
    ap.add_argument("--preset-lead", default="ORGAN")
    ap.add_argument("--preset-bass", default="BASS")
    ap.add_argument("--preset-harm", default="STRINGS")
    ap.add_argument("--transpose", type=int, default=0)
    ap.add_argument("--start", type=float, default=0.0, help="skip to this second")
    ap.add_argument("--end", type=float, default=0.0)
    ap.add_argument("--title", default="")
    a = ap.parse_args()

    mid = mido.MidiFile(a.midi)
    if a.inspect:
        inspect(mid)
        return
    if not (a.lead or a.bass):                 # nothing chosen: choose for them
        a.lead, a.bass, a.harm, a.drums = auto_pick(mid, a.start, a.end)
        if not a.lead:
            sys.exit("no melodic parts found; use --inspect and pick by hand")

    nums = lambda s: [x.strip() for x in s.split(",") if x.strip()]
    parts = {}
    for name, sel, which in (("lead", a.lead, "high"), ("bass", a.bass, "low"),
                             ("harm", a.harm, "high")):
        parts[name] = part(mid, nums(sel), which,
                           second=(name == "harm" and a.harm_second)) if sel else []
    drums = events_of(mid, nums(a.drums), drums_only=True) if a.drums else []

    if a.end:
        for k in parts:
            parts[k] = [e for e in parts[k] if e[1] < a.end]
        drums = [e for e in drums if e[1] < a.end]
    if a.start:
        for k in parts:
            parts[k] = [e for e in parts[k] if e[2] > a.start]
        drums = [e for e in drums if e[1] > a.start]
    start_frame = round(a.start * FPS)

    for k in parts:
        parts[k], _ = fit_range(parts[k], k, a.transpose)
    coverage_check(parts, drums, (a.end or mid.length) - a.start)

    stereo = bool(parts["harm"])
    title = a.title or os.path.basename(a.midi).rsplit(".", 1)[0]
    w = psq.Writer(title, mode=psq.STEREO if stereo else psq.EITHER,
                   tracks=3 if stereo else 2, drums=1)
    counts = {
        "lead": add_part(w, 0, parts["lead"], a.preset_lead, start_frame),
        "bass": add_part(w, 1, parts["bass"], a.preset_bass, start_frame),
        "harm": add_part(w, 2, parts["harm"], a.preset_harm, start_frame),
    }
    hits, unknown = 0, set()
    for n, s0, _ in drums:
        d = GM_DRUM.get(n)
        if d is None:
            unknown.add(n)
            d = 2
        w.drum(max(0, round(s0 * FPS) - start_frame), d)
        hits += 1
    if unknown:
        print(f"  drums: unmapped GM notes {sorted(unknown)} played as hats")
    last = max([e[2] for p in parts.values() for e in p] +
               [e[1] for e in drums] + [0])
    w.at(max(0, round(last * FPS) - start_frame) + 30, psq.ALLOFF)

    out = a.out or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "songs", title.lower().replace(" ", "_") + ".psq")
    w.save(out)
    h, ev = psq.read(out)
    print(f"{out}: {psq.describe(h, ev)}")
    print(f"  lead {counts['lead']}, bass {counts['bass']}, harmony {counts['harm']} notes, "
          f"{hits} drum hits, {os.path.getsize(out)} bytes")


if __name__ == "__main__":
    main()
