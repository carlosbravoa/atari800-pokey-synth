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
| `R` | held chords on/off for this preset: CHORD = AUTO, CHD SPD = POLY (RETURN restores) |
| `Q` | drums only: mute the loop's melody tracks (any loop or demo) and keep your own sound |
| SHIFT `SPACE` | recording grid on/off (metronome + snap + whole-bar loops) |
| `I` | undo the last overdub pass (restores what it wrote, including overwritten hits) |
| `HELP` (PC F5 / Insert) | full-screen key list; any key returns |
| SHIFT `<` `>` | tempo: a loaded demo's, else the recording grid (`S=nn` on row 9, inverse = grid on) |
| `<` `>` (PC `-` `=`) | built-in demo loops: previous / next (loads + plays; jam or overdub on it) |

Edits are kept per preset (the `live` table) until RETURN.

## Sound architecture

- **Lead**: POKEY ch1+ch2 joined 16-bit, ch1 clocked at 1.79 MHz
  (AUDCTL `$50`), output on AUDC2. Pure tone is within 4 cents over 8
  octaves. BUZZ (dist C, poly4) and RASP (poly5) tables are pitch-corrected
  by their poly periods (15/31, N+7 kept coprime). Good through octave 4;
  up to ~1 semitone off at the very top. GRIT/NOISE/HISS use the pure table
  (pitch = noise color).
- **Buzz coprime guard**: `coprime` runs on the lead's final period. It
  nudges it up 1-2 steps until (P+7) is coprime to 15, because vibrato,
  glide and sweep otherwise pass through bad periods (octave jumps /
  silence). It computes mod 15 by adding bytes and nibbles (256 == 16 == 1
  mod 15), with no division. RASP (mod 31) isn't guarded on the lead: no
  preset uses it with vibrato.
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
- **Scripted drums**: a drum with `dr_seq` != 0 plays `drseq` frame by
  frame, as (AUDF, AUDC) pairs with AUDC 0 ending it, instead of the
  envelope. The kick is the classic POKEY "battery kick": a volume-only
  `$1F` DC pop, then 9 frames of poly4 `$CF` -> `$C2` at AUDF `$C0`-`$F8`
  (falling), 10 frames total. Tried and rejected: AUDF `$D0`-`$FF` (deeper
  but too quiet to hear). Tag `kick-v2-pop-thud` = the earlier 6-frame
  version. The recipe's pure-tone "beater" frame (`$AF`, AUDF
  `$20`) was dropped: at 64 kHz it's a ~1 kHz beep that sounds like a
  keyclick. Tweak
  the table to reshape it. The old swept-buzz kick values are still in
  `dr_*[0]` (set `dr_seq[0]` to 0 to get it back).
- **Keyboard**: OS key/break IRQs are disabled. The VBI polls KBCODE +
  SKSTAT bit 2 (held), so notes gate on press and release. New presses are
  posted to the main thread (KEYEV/KEYSEQ). Legato: with GLIDE > 0 a new note
  while sounding keeps the envelope.

## Save / load loops (PC side, over the link)

```bash
python3 loopfile.py save NAME   # or: make save NAME=...  -> loops/NAME.psl
python3 loopfile.py load NAME   #     make load NAME=...  (plays at once)
python3 loopfile.py info NAME   # notes / hits / sounds in a file
python3 loopfile.py list        #     make loops
```

- No 6502 code: the loop is plain RAM. **save** reads LLEN, T1USED, the five
  lanes (LLEN bytes each) and the 130-byte `live` preset table, so your
  sound edits travel with the loop. Each block is read twice until two
  reads agree (stale-peek guard). It refuses EMPTY and REC. In DUB it saves
  what's recorded so far.
- **load** uses the demo sequence: LCMD 3 (the VBI empties the loop), write
  and verify the lanes and presets, then LLEN, T1USED, DEMOIDX 0, LSTATE
  STOP, PRESREQ = the current preset (reloads its edited sound), and
  LCMD 2 (play from the top).
- Both check that the Atari runs *this* build first: the 64 static bytes
  before `live` must match `build/synth.xex`, because `live`'s address
  comes from `build/synth.lbl`. A different build gets "make deploy first"
  instead of a write to the wrong address.
- File: `PSL1` + zlib(LLEN, T1USED, M1, D, P1, M2, P2, presets). A
  2-bar demo is about 160 bytes. Files keep working across builds as long
  as the lane layout and preset format don't change.
- `hwsave.py`: demo + preset edit -> save -> wipe -> load -> identical
  lanes, edit restored, same per-pass playback, and EMPTY refused. It sets
  EDSEL itself, since the editor selection persists across sessions.

## Built-in song (standalone, in the .xex)

Press `>` past the last demo: `<ANTHEM  >` plays the whole 82 s
arrangement with no PC attached, in stereo with all three parts — the same
music the `.psq` streams.

- `gen_song.py` writes `songdata.inc`: the five distinct sections (963
  bytes) + `song_arr`, the arrangement as (section+1, repeats) pairs
  ending in 0 (which loops it). Section layout:
  `S N P1 P2 P3  T1…$FF  T2…$FF  T3…$FF  drums[N]`, tracks as
  (step, note, duration) triples.
- **It drives the voices directly, not the looper**: `song_step` (VBI)
  advances one step every S frames, fires each track's due notes, releases
  the one whose duration ran out, and hits the step's drum. Track 1 ->
  loop voice 0, track 2 -> the lead, track 3 -> loop voice 1 (stereo only;
  mono has no channel for the fifths). SONGON `$0BAD` also lets `lv_step`
  run outside loop playback, like STREAMON.
- Because it never touches the lanes, **a recorded loop survives** playing
  the song, and starting it doesn't clear anything.
- TAB, BACKSPACE and ESC stop it (`song_stop`), as does selecting a demo.
- State: SONGON..SONGF `$0BAD-$0BBF`, three tracks x (ptr lo, hi, note-off
  step) at STRK `$0BB6`.
- **Space**: MAIN ends ~$3BB4 (~75 bytes free), HIDATA ~$4FC3 (~60),
  EXTRA/LOMEM ~$1BD9 (~38, the stream ring starts at $1C00). Adding
  anything now means moving code between segments first; all three are
  nearly full.

## MIDI -> .psq (`midi2psq.py`)

```bash
python3 midi2psq.py song.mid --inspect          # tracks AND channels
python3 midi2psq.py song.mid --lead 1,5 --bass 3,4 --harm 2,6 --drums 7,8,9,10 \
    --title KALINKA -o songs/kalinka.psq
python3 pcplay.py songs/kalinka.psq
```

- **With no `--lead`/`--bass` it picks the parts itself** from the file's
  channel statistics: each role wants a register *and* a part that plays
  (`auto_pick`: lead near midi 72, bass low, harmony mid, all weighted by
  coverage and note count), then `relay` adds same-register parts that
  cover the stretches the first one is silent for (arrangements hand a
  part between instruments: Kalinka's Square Bass -> Synth Bass).
- **Every conversion prints a coverage map** (which tenth of the song each
  part plays) and warns when a part is mostly silent or starts late. That
  is what catches a wrong track choice *before* you listen — the first
  Kalinka conversion had the melody in the harmony voice because the track
  numbers were off by one (the older `midi2pokey.py --inspect` counts
  tracks from 0, this one from 1).
- Parts are `track` or `track:channel`, both 1-based. Type-0 files keep
  everything in one track, so channels are how you pick parts there; the
  inspector prints a ready-made `--lead N:C` for each channel.
- Each part is reduced to one voice (the synth's tracks are monophonic):
  lead keeps the top note of a chord, bass the bottom, `--harm-second`
  takes the second note down when the harmony comes from the lead's own
  tracks. Several parts feeding one voice mask by priority (`overlay`), so
  an arrangement that hands the tune over stays whole. This reuses
  `tools/midi2pokey.py` (skill `atari-music`).
- Range: MIDI 24-119 (C1-B8). A part outside it is transposed by whole
  octaves, and stragglers are dropped, both reported.
- Drums: GM percussion (channel 10) mapped onto the 8 pads (`GM_DRUM`);
  unmapped notes become hats and are reported.
- Timing is kept to the frame (59.92/s), with no grid quantization.
- `--start/--end` cut a section, `--transpose`, `--preset-lead/bass/harm`
  pick the sounds. Verified on hardware with `tetris_karinka.mid`
  (112 s, 966 notes + 812 hits) and `canyon.mid` (type 0, by channel).

## Streamed sequences (.psq) — the PC drives the voices

```bash
python3 pcplay.py songs/anthem.psq [--loop]   # or: make stream NAME=anthem
python3 psq.py songs/anthem.psq               # what's in a file
python3 test_psq.py                           # format unit tests (no Atari)
```

- **Not stored on the Atari**: the PC sends timed events, the VBI plays each
  on its frame. No length limit, and one more voice than the looper has.
- **Atari side**: SRING `$1C00` = 256 entries of (frame lo, frame hi, cmd,
  arg); SHEAD `$0BA8` (Atari consumes), STAIL `$0BA9` (PC writes), SFRAME
  `$0BAA` 16-bit frame clock, SEVCNT `$0BAC`, STREAMON `$0BA7`.
  `stream_step` runs first in the VBI (before loop_step, so streamed notes
  can be recorded into a loop) and executes every event whose frame has
  come, via a jump table. STREAMON also makes `lv_step` drive the loop
  voices outside loop playback.
- **Commands**: 0/1 lead note on/off, 2/3 voice 0, 4/5 voice 1, 6/7 drums
  (POKEY1/POKEY2 ch4), 8/9/10 presets, 11 param (`param<<4|value`),
  12 all-off, 13 end (clears STREAMON).
- **Format** (`psq.py`, docstring is the spec): 32-byte header (magic, mode
  mono/stereo/either, melodic tracks, drum channels, rate, frames, title)
  then delta-coded events. Polyphony = simultaneous tracks; each track is
  monophonic. `to_commands` folds a stereo file for a mono machine (drops
  track 2, merges drum channel 1) and reports how many events that cost.
- **Write the ring in batches**: up to 64 events (256 bytes) per poke. One
  poke per event (~25 ms) cannot keep up with dense passages: the ring runs
  dry mid-song and the sounding note hangs. The player counts underruns and
  always sends an all-off on exit/error.
- **Player** (`pcplay.py`): fills the ring ~120 frames ahead, so link jitter
  never reaches the music; `--loop` re-times the next pass seamlessly;
  Ctrl-C stops and silences.
- `compose_anthem.py` also writes `songs/anthem.psq`: the same arrangement
  plus a third voice (bar-long fifths), 83 s, 556 notes, ~4 KB.
- **Memory**: the ring sits above the EXTRA segment (`LOMEM` is capped at
  `$1BFF` in the linker config for exactly this reason).

## Songs (PC-streamed sections, gapless)

```bash
cat songs/mysong.song      # one section per line: <loop name> [repeats]
  intro 1
  verse 4
  chorus 2
python3 songfile.py play mysong [--loop]   # or: make song NAME=mysong
python3 songfile.py pack mysong            # -> songs/mysong.pss (self-contained)
python3 songfile.py info mysong
```

- Sections are loop files (`loopfile.py save NAME`), each **<= 2048 frames
  (~34 s)**. Record a section, save it, repeat, then list them in a .song.
  A .pss packs the .song and its loops into one file. `play` uses the .pss
  when no .song of that name exists.
- **Atari side** (~50 bytes): the lanes split into two banks. `lp_ptr` adds
  LBANK (`$0676`, hi-byte offset `$00`/`$08`, so bank 1 is lane + `$800`).
  At each seam, `lp_wrap` checks NEXTREQ (`$0677`). 1 means flip LBANK,
  take NEXTLEN (`$0678`) and NEXTT1 (`$067A`), and bump SECTCNT (`$067B`).
  2 means stop at the seam (song end). The switch happens inside the VBI on
  the exact wrap frame, so it's gapless by construction. Clear/EMPTY and a
  fresh REC reset to bank 0, so plain loops, demos and `loopfile.py load`
  are unchanged.
- **PC side** (`songfile.py`): starts section 1 in bank 0 with the demo
  sequence. While a section plays, it writes the next section into the
  other bank. When the Atari's LOOPCNT shows the section's last repeat has
  begun, it arms NEXTREQ, then waits for SECTCNT. If a load ever overruns a
  short section, it reports "late" and the section repeats once more,
  audibly but safely. Presets come from the first section's file. Ctrl-C
  stops immediately (TAB).
- `hwsong.py`: two demos saved as loops, song "GROOVE x2, TECHNO, GROOVE"
  from .song and from the packed .pss. It checks bank and length at each
  switch, passes per section `[2, 1, 1]` via LOOPCNT, and seam-to-seam
  gaps on the Atari clock. Read RTCLOK hi/lo in one peek: two single-byte
  peeks tear across the low-byte wrap (a phantom 256-frame gap).

### Composed songs

`compose_anthem.py` writes a song entirely on the PC: loops/anthem_*.psl
(intro, verse, chorus, break, outro), songs/anthem.song and the packed
anthem.pss. It's ~82 s, arranged intro-verse-chorus x2-verse-chorus
x2-break-chorus x2-outro. Sections are built on the demo grid (16
steps/bar, S frames/step) exactly as the 6502 loader would lay them out,
with the factory preset table read from the build. Copy it as a template
for new songs. `songfile.py play anthem` verified on hardware: passes
[1,1,2,1,2,1,2,1], seam gaps within polling jitter.

## Chords (polyphony without two keys)

- CHORD values: OFF MAJOR MINOR 7TH OCTAVE POWER DIM **AUTO**. AUTO is
  one-finger diatonic harmony in C major: C Dm Em F G Am B°, and the
  black keys give Db Eb F#° Ab Bb (tables `auto3`/`auto5` in
  gen_tables.py).
- CHD SPD 1-7 arpeggiates the chord on the lead (AUTO walks the key's
  triad). **CHD SPD 0 = POLY**: the chord sounds held. The lead keeps the
  root, and `poly_out` puts the two chord tones (`poly1`/`poly2`, or AUTO's
  third/fifth) on POKEY1 ch3 + ch4. They use the lead's wave (8-bit
  lay64/buzz64/rasp64) at 3/4 of its envelope, and replace the layer.
- Channel priority: ch3 yields to the loop's voice 2 (mono, track 1 with
  melody). ch4 yields to a drum on block 0 for the drum's length: POLY4
  `$0675` marks a frame where the chord owns ch4, so `drum_one` doesn't
  silence it.
- **Recorded chords**: the loop records the root only (notes, not
  sounds), and playback rebuilds the chord from the track's preset:
  - stereo track 1: a real chord. The root plays on POKEY2 1+2, and
    `lv_tones` puts the tones on POKEY2 ch3 (only while track 2 is silent)
    and ch4 (only while no loop drum rings). POLY4B `$0B98` keeps the idle
    loop-drum block from zeroing that ch4. lv_step runs slot 1 before
    slot 0 so the tone wins a silent ch3.
  - mono track 1 and stereo track 2 have no spare channels, so POLY
    becomes a 1-frame arpeggio (the chiptune fake chord).
  - mono track 2 replays on the lead, so its chords come back complete.
  - Loop-voice AUTO arpeggios use the note's own triad (auto3/auto5), not
    MAJOR.
- `R` toggles AUTO+POLY on the current preset (kept in `live`, RETURN
  restores).

## Recording grid (metronome, snap, whole bars)

- **Grid** = 16th notes of RSTEP `$0BA0` frames (default 8 = ~112 BPM;
  SHIFT `<` `>` sets it when no demo is loaded). GRIDON `$0BA5` (SHIFT
  SPACE) turns the whole thing off for free-time recording.
- **Count-in**: SPACE from EMPTY goes to LS_CNT (5, shown as `COUNT`),
  one bar of clicks, then REC from frame 0. SPACE/TAB during it cancel.
- **Metronome**: `grid_step` clicks every 4 steps (accent = tom2 on the
  bar line, hat elsewhere) during count-in, REC and DUB. It calls
  `drum_start`, not `drum_trig`, so it never reaches LIVED and is never
  recorded. **The click must never cut the player off**: in stereo it runs
  on POKEY2's drum block (block 8, skipped while the loop's own drums ring
  in DUB); in mono it shares ch4, so it is skipped whenever a drum of the
  player's is still sounding. (First version clicked on block 0
  unconditionally and made percussion impossible to record.)
- **Snap**: `grid_step` also sets SNAPD, the signed distance to the
  nearest step (no division: STEPPOS counts frames since the last step).
  Note-ons and drums are written at VP + SNAPD (`snap_vp`/`unsnap_vp`,
  which is also what `undo_push` logs). Note-offs keep their real timing,
  so phrasing survives.
- **Bar-line flash**: `grid_step` sets BFLASH `$0BA6` = 3 at each bar, and
  `bar_flash` (last in the VBI) puts the preset hue at full luminance into
  COLOR4 for those frames, else black. The border is the only thing the
  DLI leaves alone, so this costs nothing.
- **Visual metronome**: during COUNT/REC/DUB (with the grid on) the loop
  row's 16 cells become one bar of 16ths: a bright cell is the current
  step, half cells mark the four beats. It's drawn by the main thread
  (LASTCELL holds `$20|GRIDST` in this mode, a domain LCELL never uses, so
  switching modes always redraws). PLAY keeps the loop progress bar.
- **Whole bars**: `lp_bars` rounds LLEN at close to BARN x 16 x RSTEP
  (rounding up from half a bar, minimum one bar), so loops, overdubs and
  song sections line up. Events past the rounded end are dropped.
- Tests: py65 covers count-in length, the 4 clicks, snapped note-ons,
  whole-bar length, the clicks staying out of the drum lane, and the
  grid-off path. Tests 9-15 set GRIDON = 0, since they record
  free-time loops with exact expectations.

## Undo, tempo, help

- **Undo** (`I`): while overdubbing, `undo_push` logs (address, previous
  byte) for every lane byte a stamp is about to overwrite, into
  `$0C00-$0EFF` (768 entries), pointer UNDOP `$0B99`. `lp_dub` resets it,
  so `I` undoes the last DUB session, restoring hits the overdub wrote
  over. If pressed during DUB it leaves DUB first (the VBI owns the log).
  The log is outside every load segment, so deploys don't disturb it.
- **Tempo** (SHIFT `<` `>`): TEMPO `$0B9E` (-4..+4) is added to a demo's
  S when `load_demo` expands it, clamped to 4..14 frames/step, and the
  demo reloads. Recorded loops keep their own timing (changing it would
  mean resampling the lanes). CURS `$0B9C` shows as `S=nn` at row 9 col 35.
  SHIFT comes from KBCODE bit 6 (SHIFTF `$0B9B`), sampled in kb_poll.
- **Help** (`HELP`, i.e. F5/Insert on the board): HELPON `$0B9F` switches
  SDLSTL to `dlist_help` (24 plain GR.0 rows) and prints `help_text`; the
  DLI skips its per-row colors while it's up; `main_tick` routes the next
  key to `hide_help`, which rebuilds the normal screen. Help text and the
  help/undo routines live in the EXTRA segment.
- **Third load segment**: EXTRA at `$0F00-$1FFF` (~3.4 KB free) holds
  main-thread code and text. MAIN has ~170 bytes free, HIDATA ~170.

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
- VBI order: kb_poll -> loop_step -> synth (lead + layer/chords) -> lv_step x2 -> drum_step -> pokey_out.
- **Code budget**: two load segments. MAIN `$2000-$3BFF` holds code +
  RODATA, ending ~$3924 (~730 bytes free). The loop-voice engine, chord
  output and `pokey_out` now live in HIDATA (code runs from any segment),
  which ends ~$4EBC (~320 bytes free). HIDATA `$4400-$4FFF` holds the pitch
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
- **Solo mirror**: whenever POKEY2 isn't carrying a loop **or a stream or
  the built-in song** (STREAMON/SONGON/PLAY/DUB), `pokey_out` mirrors
  POKEY1 onto it: layer, chord tones and drums
  identical, and the lead's period + period/256 (~7 cents flat on the
  right). The result is a centered, slightly wide chorus for solo playing.
  BUZZ/RASP get no detune: the pitch of these poly waves needs
  gcd(period+7, 15 or 31) = 1, and period + period/256 broke that for
  most BASS/SYNTH keys (C2 silent, others 2-3 octaves up on the right).
  In PLAY/DUB — and while STREAMON or SONGON is set — POKEY2 carries its
  own voices. **Miss one of those and the mirror silently overwrites the
  loop voices every frame**: streamed 3-part music played as lead + drums
  only (found 2026-09-22 by A/B-ing a phrase on each POKEY; the register
  image looked right because the engines write it *before* pokey_out). Only the sound changes;
  recording stores notes, not registers.
- **Register image**: the VBI engines (synth, poly_out, lv_step, drum_one)
  never write POKEY directly. They write the 32-byte image `SH` at `$0B78`
  (= `$D200-$D21F`, same offsets), and `pokey_out` runs last in the VBI and
  copies it out. That's the only way to mirror, since POKEY registers are
  write-only. Main-thread code (init, park, detect) still writes directly.
  New VBI sound code must use the `SAUD*` names.
- Engines: `lv_step` (X = voice block 0/VBS) drives both loop voices,
  choosing the output registers (Y offset) and 8/16-bit per mode.
  `drum_one` (X = block 0/8, Y = register offset) drives both drum
  channels. Voice and drum blocks live at `$0B40-$0B77`, and the old V2*
  names are aliases.
- Verified on hardware with the board's stereo ON: detection, the key-held
  check staying stereo, and all six demos routed (track 2 on its own voice,
  lead and preset untouched). Hardware tests are mode-aware. Mono verified on
  hardware too (2026-09-22, OSD stereo off + cold boot): detected mono, so no
  false positive on this core's POKEY, and all three suites pass. **Not yet
  seen on hardware:** the runtime fallback (stereo switched off in the OSD
  WHILE the synth runs, then a key press). py65 covers it.

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
$0673 STEREO (1 = second POKEY detected)  $0675 POLY4
$0676 LBANK  $0677 NEXTREQ  $0678/79 NEXTLEN  $067A NEXTT1  $067B SECTCNT
  (song mode; page 6 is now full up to the trampoline at $067C)
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
| `$0B78-$0B97` | POKEY register image (both chips), copied out by `pokey_out` |
| `$5000-$9FFF` | looper lanes (M1, drums, P1, M2, P2) |
| `$F0-$F1` | VBI lane pointer (ZP exception) |
| `$2000-$3BFF` | code + data (MAIN cap) |
| `$3C00-$3FFF` | RAM charset (ROM font + piano/meter glyphs on lowercase codes) |
| `$4000-$43BF` | screen |
| `$4400-$4FFF` | HIDATA segment: pitch/env/key tables + demos |

## Built-in demos (< >)

Seven demos: GROOVE, TECHNO, CHIPTUNE, DREAMY, ROCK, SPACE, ANTHEM (an original
4-bar pop hook over Am-F-C-G, 64 steps at S=7). They are defined
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

## Cold launch gotcha (resolved 2026-09-22)

Two "hangs" after a manual reset turned out to be the typed USR command
landing on a line that already had text (e.g. `RESETED`). BASIC answered
ERROR and the program never started, which showed as FRAME stuck at 0.
`deploy.py` now sends a bare RETURN before the launch line. If FRAME isn't
ticking after a USR launch, check the screen for `ERROR-` first.

## Not verified by machine

Timbre is judged by ear, and the agent can't hear. Drum voicings and preset
balance need a human listen. Tuning is verified by math (table self-check
and py65) and by peeking the periods the engine writes.
