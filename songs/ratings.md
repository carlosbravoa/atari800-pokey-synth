# MIDI conversion ratings (1 bad - 5 great)

**The ratings below were taken with a bug: in stereo, `pokey_out` mirrored
POKEY1 onto POKEY2 whenever the looper wasn't playing, which included
streamed (.psq) and built-in-song playback — so the bass and harmony were
overwritten every frame and only the lead + drums were audible.** Fixed
2026-09-22 (STREAMON/SONGON now count as "POKEY2 is in use"). Everything
below therefore rates a one-voice rendering, not the conversion; re-rate
before drawing conclusions about the part picker.

Rated by Carlos on the real machine, to find where the auto-pick heuristic
fails. Coverage is what `midi2psq.py` reported at conversion time.

| file | rating | lead | bass | harm | drums | picked parts | notes |
|---|---|---|---|---|---|---|---|
| kalinka (tetris_karinka.mid) | good (after fix) | 100% | 100% | 70% | 992 | 2:1 / 5:3+4:2 / 3:5 | melody as lead after the off-by-one fix |
| StarmanE | 1-2 | 100% | 90% | 90% | 569 | 1:1 / 1:4 / auto | coverage looked fine, so the fault is elsewhere |
| ng2_rel | 3 | 100% | 80% (22 notes) | 50% | 288 | 4:3 / 2:1 / auto | bass part is thin: 22 notes over the slice |
| worms | 3 | 50% | 50% | 50% | none | 1:5 / 1:3 / auto | the file itself is only 19 s; no percussion channel |
| sdb-titl | 4 | 90% | 90% | 90% | 312 | 3:2 / 6:5 / auto | clean pick, no warnings |
| dbz2bsgt | 5 | 60% (43 notes) | 70% | 90% | 280 | 8:7 / 4:3 / auto | rated great DESPITE three coverage warnings |
| dbztheme | 1 ("terrible") | 80% | 100% | 90% | 491 | 1:2 / 1:3 / auto | type-0 file, all channels in one track |
| Hikari_no_Willpower | 3 | 100% | 50% | 80% | 405 | 6:5 / 10:9 / auto | bass enters halfway; no earlier partner merged |
| cas-kid_ | 5 | 100% | 100% | 100% | 350 | 3:2 / 4:3 / auto | clean multi-track file |
| smkrainbow | 1-2 | 100% | 100% | 100% | 682 | 5:4 (79 notes) / 2:1 / auto | sparse "lead": likely a pad, not the tune |
| MetalstormLvl3 | 5 | 100% (500 notes) | 100% | 90% | 62 | 4:3 / 6:4 / auto | lead and bass in the same register, still great |

## What the ratings say so far (9 rated)

- **Coverage does not predict quality.** dbz2bsgt scored 5 with three
  coverage warnings; smkrainbow and StarmanE scored 1-2 with clean 100%
  coverage. The warnings are worth keeping as information, not as a
  quality gate.
- **Lead note density looks like the real signal.** The two worst
  (smkrainbow 79 notes / 50 s, StarmanE) have sparse or wrong leads, while
  the best (MetalstormLvl3 500 notes, cas-kid_, dbz2bsgt) have a busy,
  clearly melodic lead. A sparse high part is usually a pad or an effect,
  not the tune.
- **Type-0 files are the weak spot.** dbztheme (everything in one track,
  picked by channel) was rated terrible.
- Next step: try picking the lead by note density and melodic motion
  (steps rather than leaps, few simultaneous notes) instead of register
  plus coverage, and re-rate the three bad cases.

## After the stereo-mirror fix (all voices audible)

| file | rating | notes |
|---|---|---|
| kalinka | 5+ ("REALLY AWESOME") | same file as before; the difference was the mirror bug |
| smkrainbow | 4 (was 1-2) | auto-pick 3:2 lead; the fix, not the picker, was the problem |
| StarmanE | 5 (was 1-2) | unchanged pick (1:1 lead); the mirror bug was the whole problem |
| dbztheme | 5 (was "terrible") | type-0 file; unchanged pick, the mirror bug again |

**Conclusion:** the part picker was not the problem. One playback bug
made every 3-part conversion sound like lead + drums. Re-rate before
tuning heuristics on ears.

## What the session actually taught (2026-09-22)

1. **A playback bug, not the picker.** The stereo mirror overwrote POKEY2
   during streamed and built-in-song playback, so every 3-part piece came
   out as lead + drums. StarmanE and dbztheme went 1-2 -> 5 with no change
   to the conversion. Rate only after the audio path is known good.
2. **A repeated-note part can be the tune** (smkrainbow's lead moves 0.6
   semitones on average). It just has to be played on a percussive preset,
   or each repeat merges into the last and the melody sounds like one
   stuck note. `auto_preset` now picks PIANO for such parts.
3. **Never merge a repeated-note line into a sustaining voice**: that was
   the "stuck note" in the harmony (a 37-times-repeated note 47 on
   STRINGS).
4. **Merging is about filling silence, not registers.** Arrangements hand
   the tune over: smkrainbow's chorus lives on another channel while the
   main lead rests. `relay` now accepts a candidate when it sounds while
   the chosen part is silent (`fills`), and `part()` masks it note by note
   elsewhere. Manually: `--lead 5:4,3:2` (first has priority).
5. **Note count beats register** when choosing between melodic lines:
   picking the sparser one cost a 5 -> 3 on dbz2bsgt.

## Second round, after scoring each candidate by its TOP LINE

6. **Judge a candidate as it will be played**: one note at a time, top note
   of each chord. Melodies are often written as the top of a chord channel
   (StarmanE, rcr-main), so raw polyphony says little. Scoring the
   mono-reduced line - and deleting the old "swap away from chord
   channels" rule - turned rcr-main from "that's the second voice" into a 5.

| file | rating | lead picked |
|---|---|---|
| rcr-main | 4 -> 5 | 11:9 (top line of a chord channel) after the fix |
| rcr-boss | 5 | 10:9 lead, merged harmony |
| bt-theme | 3 | poor source MIDI, per Carlos |
| battletoads_turbo | 1-2 -> 4 | its drums live on an ordinary channel (prog 126, 2 pitches at 10/s): now detected, kept out of the melody, and mapped by pitch order |
| btdslv5surf | 5 | |
| topgear1 | 5 | 1756 notes + 585 hits in 50 s: the stream keeps up |
| drmfever | 1-2 | source problem: melody+accompaniment+bass share one channel; skipped |
| Dbz2 | 5 | |
| smb109 | 5 | |

### Round 2 summary (9 files, picker fixed as we went)

5: rcr-main (after the top-line fix), rcr-boss, btdslv5surf, topgear1,
Dbz2, smb109 · 4: battletoads_turbo (after percussion detection) ·
3: bt-theme (poor source) · 1-2: drmfever (melody, accompaniment and bass
share one channel in the source)

Three more picker lessons, all confirmed on the machine:
7. **Score the top line, not raw polyphony** - melodies are often the top
   of a chord channel (rcr-main 4 -> 5).
8. **Percussion hides on ordinary channels** in rips (sound-effect program,
   or 2 pitches at 10/s): keep it out of the melody and play it as drums,
   mapped by pitch order (battletoads_turbo 1-2 -> 4).
9. **A wide range with a low centre is a whole arrangement**, not a tune:
   its top line mixes melody with accompaniment.

### Round 3

| file | rating | notes |
|---|---|---|
| DonutPlains | 5 | |
| Revontulet | 5 | dense: 1067 notes + 454 hits |
| KoopaTroopaBeach | 5 | |
| dbz3batt | skipped | conversion fine, source poor (per Carlos) |
| temp | 5 | single-part file: doubled an octave down + echoed on POKEY2 for stereo |

### Round 4 (all remaining files converted; interesting ones played)

| file | rating | notes |
|---|---|---|
| gtgm | 4 | 97%-chord lead with repeated notes -> PIANO |
| ng2_rfb | 1-2 | skipped by Carlos; lead is a step-0.1 repeated line |
| dd2shad | 5 | lead = top line of an 88%-chord channel |
| vanlake | skipped | lead fixed to the xylophone line (tuned percussion = lead family) |
| ng2_act | 5 | single-part file, doubled + echoed |
| bt-pause | moved on | percussion-only file: now converts as a drums-only sequence instead of failing |
| dbz2bvt | 5 | 888 drum hits in 50 s |
| x-japan_weekend | 3 | real song, very dense; vocal+riff merged as lead; "complex song, move on" |

### Round 4 lessons

10. **Tuned percussion is a lead instrument** (glockenspiel, marimba,
    xylophone, music box): in game rips it usually carries the tune
    (vanlake). Lead-family instruments now outrank other melodic ones.
11. **Few pitches alone doesn't mean percussion**: a power-chord guitar
    riff uses three (x-japan_weekend). A sound-effect program is the
    reliable sign; an ordinary instrument must also be hammering (>= 8/s).
12. **A percussion-only file** converts to a drums-only sequence
    (bt-pause) instead of failing or being played as a melody.
13. **The harmony voice is 8-bit**: ~11 cents at B4, 22 in octave 5, 33 in
    octave 6. A high harmony is dropped an octave so it can be in tune.
14. **The Atari's stream clock is 16-bit** (~18 minutes). pcplay now zeroes
    it at the start, or a long song crosses the wrap and the events land in
    the past - that was the "buffer dying" on a 5:39 song.
