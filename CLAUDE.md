# CLAUDE.md — POKEY SYNTH (Atari 8-bit keyboard synthesizer, real-hardware target)

## What this project is

**POKEY SYNTH** — a playable keyboard synth for the Atari 800XL in 6502
assembly (ca65), tested on the Tang Nano 20K FPGA Atari over its USB serial
bridge. Workspace-wide hardware rules live in `../CLAUDE.md` — read that first.

## Build, test, deploy

```bash
make                  # gen_tables.py -> tables.inc, then build/synth.xex
python3 test_synth.py # py65 pre-flight: engine math + main-thread UI + screen render
make deploy           # hot-swap onto the running machine / USR-launch from READY
python3 hwtest.py     # real HID key presses on the board, verified by peeks
```

`hwtest.py` gotcha: `AtariLink.key(hid, hold_ms=…)` returns immediately and
the firmware keeps the key down for `hold_ms` — sleep past the hold before
checking release state. The firmware injector appears to hold ONE key: pressing
a second releases the first, so rollover can't be fully tested remotely.

## Controls (GarageBand "musical typing")

| Keys | Do |
|---|---|
| `A S D F G H J K L ;` | white notes C D E F G A B C D E |
| `W E  T Y U  O P` | black notes |
| `Z` / `X` | octave down / up (1-7) |
| `1`-`9`, `0` | presets: PIANO ORGAN FLUTE STRINGS BASS CHIPARP SYNTH BELL LASER UFO |
| `C V B N M , . /` | drums: kick snare hat open-hat tom tom2 clap crash |
| arrows / joystick | editor: up/down pick parameter, left/right change (held = repeat) |
| `RETURN` | restore the current preset's factory sound |
| `ESC` | silence |
| OPTION / SELECT (F8/F7) | next / previous preset |

Edits are kept per preset (the `live` table) until RETURN.

## Sound architecture

- **Lead**: POKEY ch1+ch2 joined 16-bit, ch1 clocked at 1.79 MHz
  (AUDCTL `$50`), output on AUDC2. Pure tone is within 4 cents over 8
  octaves. BUZZ (dist C, poly4) and RASP (poly5) tables are pitch-corrected
  by their poly periods (15/31, N+7 kept coprime). Good through octave 4;
  up to ~1 semitone off at the very top. GRIT/NOISE/HISS use the pure table
  (pitch = noise color).
- **Per-frame pipeline (VBI `synth`)**: chord arpeggio -> table period ->
  glide (exponential, `>>GLIDE`) -> sweep (absolute period `SWP`,
  `±SWP>>shift`, clamped) -> vibrato (±(P>>7)·depth on an 8-step triangle) ->
  AUDF1/2. ADSR in 8.8 fixed point; rate tables from gen_tables.py.
  Sustain follows the editor live.
- **Layer**: ch3 8-bit @ 64 kHz pure, 3/4 volume: SUB / FIFTH / OCT UP /
  CHORUS (one AUDF step detune) / ECHO (32-frame ring at `$0A00`, 21-frame
  delay, half volume).
- **Drums**: ch4 envelope engine (FRQ += DLT, clamps at 255;
  vol = min(TMR·4 >> VSH, 15)).
- **Keyboard**: OS key/break IRQs are disabled. The VBI polls KBCODE +
  SKSTAT bit 2 (held), so notes gate on press and release. New presses are
  posted to the main thread (KEYEV/KEYSEQ). Legato: with GLIDE > 0 a new note
  while sounding keeps the envelope.

## Screen

Row 0 title+octave · row 1 mode-7 preset name (PF0 = preset hue) · row 2
black-key labels · rows 3-7 mode-4 piano · row 8 white-key labels · row 9
note + volume meter · rows 11-12 drums · 13-15 presets · 16 editor header ·
17-22 editor · 23 help. A DLI (keyed off VCOUNT) swaps PF0-3 to piano colors
for rows 3-7 and restores GR.0 colors after. Piano glyphs sit on lowercase
codes, so `screen` dumps read `w x b d` (unlit) / `c e` (lit black key).
Inverse bit = lit white key (PF3).

## Page-6 map (peek surface)

```
$0600 PRESET  $0601 OCTAVE  $0602 OCTBASE  $0603 EDSEL
$0604 KEYEV   $0605 KEYSEQ  $0607 HELD ($FF none)  $0609 LITKEY
$060A NOTE (0=C1)  $060B ESTATE 0 off 1 A 2 D 3 S 4 R  $060D VOLHI
$060E/0F CURN  $0610/11 SWP  $0612/13 OUT (period in AUDF1/2)
$0617 FRAME   $0619 NOTEIDX (incl. chord)  $061B REMKEY / $061C REMHOLD
  (remote test: poke a KBCODE into REMKEY, then frames into REMHOLD)
$061D-21 drum engine  $0622 DRUMLIT  $0623 NOTECNT  $0624 DRUMCNT
$0625 KEYCNT  $0627 GATE  $0630-3B PARAMS (live sound)  $063D PARKREQ
$0643 UICNT (main-loop liveness)
```

Params: WAVE ATK DEC SUS REL LAYER VIB VIBSPD CHORD CHDSPD SWEEP(7=off) GLIDE.

## Memory map

| Range | What |
|---|---|
| `$0600-$0643` | state (above) |
| `$0680-$0690` | hot-swap trampoline + RTI stub |
| `$0A00-$0A3F` | echo ring |
| `$2000-$3BFF` | code + data (MAIN cap) |
| `$3C00-$3FFF` | RAM charset (ROM font + piano/meter glyphs on lowercase codes) |
| `$4000-$43BF` | screen |

## Not verified by machine

Timbre is judged by ear, and the agent can't hear. Drum voicings and preset
balance need a human listen. Tuning is verified by math (table self-check
and py65) and by peeking the periods the engine writes.
