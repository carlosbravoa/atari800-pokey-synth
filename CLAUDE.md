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

Hardware tests assume nothing else is playing. `hwtest.py` starts with
BKSP, `1` and RETURN, because a demo's overdub track changes the lead preset
and edits persist per preset.

`hwtest.py` gotcha: `AtariLink.key(hid, hold_ms=…)` returns immediately and
the firmware keeps the key down for `hold_ms` — sleep past the hold before
checking release state. The firmware injector appears to hold ONE key: pressing
a second releases the first, so rollover can't be fully tested remotely.
The first key() of a link session is often lost; send a throwaway first.

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
| `SPACE` | looper: record -> close loop (plays) -> overdub (drums + melody) <-> play |
| `TAB` | looper: stop / play from the top |
| `BACKSPACE` | looper: clear |
| `Q` | drums only: mute the loop's melody tracks (any loop or demo) and keep your own sound |
| `<` `>` (PC `-` `=`) | built-in demo loops: previous / next (loads + plays; jam or overdub on it) |

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
  vol = min(TMR·4 >> VSH, 15)), with an optional one-frame loud noise
  click (`dr_clk` AUDF) as the attack transient. Keep hat noise at AUDF ≥3:
  AUDF 0-1 noise is mostly above what a TV speaker reproduces (was
  "almost inaudible").
- **Keyboard**: OS key/break IRQs are disabled. The VBI polls KBCODE +
  SKSTAT bit 2 (held), so notes gate on press and release. New presses are
  posted to the main thread (KEYEV/KEYSEQ). Legato: with GLIDE > 0 a new note
  while sounding keeps the envelope.

## Looper

- **Per-frame lanes**, one byte per frame, max 4096 frames (~68 s), in
  this order (`lp_next` steps +$1000): MLANE `$5000` track 1 melody (0
  none, 1-96 note-on n+1, `$FE` note-off), DLANE `$6000` drums (d+1),
  PLANE `$7000` track 1 preset (p+1; frame 0 = the starting sound), M2LANE
  `$8000` track 2 melody, P2LANE `$9000` track 2 preset. Overdub stamps
  nonzero live events into the lanes at LPOS, so nothing needs merging.
  Passes accumulate.
- **Two melodic voices during playback.** Track 1, the first recording,
  plays on **voice 2**: ch3 8-bit @64 kHz using its recorded preset's WAVE,
  ADSR and CHORD. There is no vibrato, sweep, glide or layer. Pitch tables
  are lay64 for pure (folded up below B2), and buzz64/rasp64 (poly-period
  corrected, fine for basslines). Track 2, the overdub, plays on the lead,
  and its presets reach the main thread via PRESREQ. Live playing is on the
  lead too, and a live event wins its frame over track 2.
- Voice 2 owns ch3 only while the loop plays AND track 1 has melody
  (`v2_owns`: T1USED and PLAY/DUB). Otherwise the lead's layer
  (sub/fifth/oct/chorus/echo) keeps ch3, so drum-only loops keep it.
- The dual POKEY (below) is the path to a full-quality voice 2.
- **Drums only** (`Q`, MUTEMEL `$0671`, command LCMD 5 -> `lp_mute`) skips
  both melody lanes AND track 2's preset lane, so the player keeps their
  preset. `v2_owns` is false, so ch3 goes back to the layer. Overdub still
  records. The loop row shows `DRUMS` in place of `PLAY`. It persists across
  demos and loops until toggled.
- States (LSTATE): EMPTY -> SPACE -> REC -> SPACE -> PLAY <-> SPACE <-> DUB;
  TAB = STOP/PLAY; BKSP = EMPTY; ESC also stops. A loop under 30 frames
  cancels. The 4096 cap auto-closes it. A key held at close gets a note-off
  on the last frame.
- Main thread posts commands through `LCMD`. The VBI executes them, so the
  multi-byte loop state is only ever written in the VBI. Lanes are cleared by
  the main thread on SPACE-from-EMPTY, while the VBI isn't touching them.
- Live events are captured in the VBI (`LIVEM`/`LIVED`) and by
  `select_preset` (`LIVEP`), then written by `loop_step` in REC/DUB. In
  playback a live drum hit wins its frame. A held live key keeps its note
  over loop note-offs. Playback preset changes go to the main thread
  (`PRESREQ`) and keep the player's octave.
- **ZP exception**: the VBI uses `$F0-$F1` (`VP`) as its lane pointer, the
  same documented exception as the tetris music engine.
- `hwloop.py` runs the full record/replay/overdub/stop/clear cycle with real
  HID keys and checks lanes and counters. Per-pass counts are measured
  between loop wraps (`aligned()`), not over wall-clock windows.
- VBI order: kb_poll -> loop_step -> synth (lead + layer) -> v2_step -> drum_step.
- **Code budget**: two load segments. MAIN `$2000-$3BFF` holds code +
  RODATA, ending ~$37DF (~1 KB free). HIDATA `$4400-$4FFF` holds the pitch
  tables and demos, ending ~$4A43 (~1.5 KB free). Don't use `$A000+`: BASIC
  is still mapped when USR-launched from READY.

## Stereo / dual POKEY (auto-detected, no toggle)

The program runs on any Atari. With one POKEY it behaves as the mono design
above. When a second POKEY answers at `$D210` (this board: OSD stereo
option, POKEY2 -> right HDMI channel; also stereo-upgraded real machines),
it switches to expanded mode by itself:

| | mono | stereo |
|---|---|---|
| live lead (16-bit), layer, live drums | POKEY1 ch1+2, ch3, ch4 | same (left) |
| loop track 1 | POKEY1 ch3, 8-bit (layer yields) | POKEY2 ch1+2, **16-bit** (right) |
| loop track 2 (overdub) | the lead (shares with live) | POKEY2 ch3, own voice |
| loop drums | POKEY1 ch4 (live hit wins) | POKEY2 ch4 (independent) |
| track 2's preset changes | switch the lead (PRESREQ) | load track 2's voice only |

- **Detection** (`detect_stereo`: at startup before the VBI, and on every
  ESC): put POKEY1 in run mode, write 0 to `$D21F`, sample POKEY1's RANDOM.
  Stock hardware mirrors `$D21x` onto POKEY1, which is now in init, so
  RANDOM freezes (mono). A real POKEY2 leaves POKEY1's RANDOM running
  (stereo), and the routine then sets up POKEY2 (AUDCTL `$50`, silent). In
  mono it never writes POKEY2 registers, since those writes would hit
  POKEY1.
- **Runtime fallback** (kb_poll): while a key is held, POKEY1's SKSTAT bit 2
  is 0. POKEY2 has no keyboard, so its bit 2 must read 1. If `$D21F` agrees
  with POKEY1, the addresses are mirrored again (the board's stereo was
  switched off), so STEREO drops to 0. Switching stereo ON mid-session is
  picked up by the next ESC.
- The title shows `STEREO 2-POKEY` in place of `8-BIT KEYBOARD`.
- Engines: `lv_step` (X = voice block 0/VBS) drives both loop voices,
  choosing the output registers (Y offset) and 8/16-bit per mode.
  `drum_one` (X = block 0/8, Y = register offset) drives both drum
  channels. Voice and drum blocks live at `$0B40-$0B77`, and the old V2*
  names are aliases.
- Verified on hardware with the board's stereo ON: detection, the key-held
  check staying stereo, and all six demos routed (track 2 on its own voice,
  lead and preset untouched). Hardware tests are mode-aware. **Not yet seen
  on hardware:** the stereo-off fallback, and mono after this refactor
  (py65-covered). Switch OSD stereo off and rerun `hwtest.py`/`hwloop.py`/
  `hwdemo.py` to check.

## Screen

Row 0 title+octave · row 1 mode-7 preset name (PF0 = preset hue) · row 2
black-key labels · rows 3-7 mode-4 piano · row 8 white-key labels · row 9
note + volume meter · row 10 loop state + progress · rows 11-12 drums · 13-15 presets · 16 editor header ·
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
$0622 DRUMLIT  $0623 NOTECNT  $0624 DRUMCNT
$0625 KEYCNT  $0627 GATE  $0630-3B PARAMS (live sound)  $063D PARKREQ
$0643 UICNT (main-loop liveness)
$0645 LOGPOS  $0646 LOGN  $0647 LASTKB  $0648 LASTSK
$0649 LSTATE 0 empty 1 rec 2 play 3 dub 4 stop  $064A LCMD
$064B/4C LPOS  $064D/4E LLEN  $064F LCELL (bar 0-16)
$0652-54 LIVEM/LIVED/LIVEP  $0655 PRESREQ  $0658 LOOPCNT (+1 per wrap)
$066D NOTE2CNT (+1 per track-1 note)  $066E T1USED  $066F DEMOIDX
$0671 MUTEMEL  $0672 NOTE3CNT (+1 per track-2 note in stereo)
$0673 STEREO (1 = second POKEY detected)
(voice/drum engine state moved to $0B40-$0B77; $065x/$0661 are free)
$0A40-$0B3F key logger: 64 x (RTCLOK lo, VCOUNT, KBCODE, SKSTAT&$0C),
  written by wait_frame on every raw register change (sk $08 = key down,
  $0C = up; bit 3 = shift). Read it after a real-keyboard test.
```

Params: WAVE ATK DEC SUS REL LAYER VIB VIBSPD CHORD CHDSPD SWEEP(7=off) GLIDE.

## Memory map

| Range | What |
|---|---|
| `$0600-$0643` | state (above) |
| `$0680-$0690` | hot-swap trampoline + RTI stub |
| `$0A00-$0A3F` | echo ring |
| `$0A40-$0B3F` | key logger |
| `$0B40-$0B77` | loop voice blocks (2 x 20) + drum blocks (2 x 8) |
| `$5000-$9FFF` | looper lanes (M1, drums, P1, M2, P2) |
| `$F0-$F1` | VBI lane pointer (ZP exception) |
| `$2000-$3BFF` | code + data (MAIN cap) |
| `$3C00-$3FFF` | RAM charset (ROM font + piano/meter glyphs on lowercase codes) |
| `$4000-$43BF` | screen |
| `$4400-$4FFF` | HIDATA segment: pitch/env/key tables + demos |

## Built-in demos (< >)

Six demos: GROOVE, TECHNO, CHIPTUNE, DREAMY, ROCK, SPACE. They are defined
in `gen_demos.py` with readable note names and generated into `demos.inc`.
Format per demo: name(8) S N P1 P2, then T1 (step, note, dur)… $FF, then T2
…$FF, then N drum bytes. `next_demo` stops and empties the loop (LCMD 3 +
`wait_lcmd`), clears the lanes and expands the events. Note-on goes at
step·S and note-off 2 frames before (step+dur)·S. It then sets LLEN and
T1USED, sets LSTATE = STOP, and posts TAB to play from the top. A demo is
a normal loop from then on: SPACE overdubs on it, TAB and BKSP work.
DEMOIDX `$066F` (1..6, 0 = none) shows as `<NAME    >` on row 10. The PC `-`/`=` mapping holds in the board's default Atari-positional layout only; in its PC-symbolic layout those keys type Atari `-`/`=`, which are the editor's up/down.
`hwdemo.py` presses > (PC `=`) through all six, then < to wrap back, on hardware and checks each one's
per-pass voice-2/lead/drum counts against the generator's data. To add a
demo, add a `demo(...)` call. The py65 and hardware tests pick it up.

`demo_loop.py` is the original PC-side poke of GROOVE, kept as an example
of driving the lanes from the PC.

## Open issue (2026-09-22)

One cold USR launch hung: black screen, FRAME stuck at 1. It happened after
the user pressed RESET on a running synth by mistake. A fresh reboot and
redeploy worked, and a py65 cold start with dirty RAM runs clean. If it
recurs, dump `$0600-$06FF` and the code range before resetting.

## Not verified by machine

Timbre is judged by ear, and the agent can't hear. Drum voicings and preset
balance need a human listen. Tuning is verified by math (table self-check
and py65) and by peeking the periods the engine writes.
