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
