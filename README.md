# POKEY SYNTH & POKEY PLAYER

Two programs for the Atari 8-bit computers. Both run on one POKEY and switch
to stereo by themselves when a second POKEY answers at `$D210`.

- **POKEY SYNTH** (`POKEY-SYNTH.xex`) is a playable keyboard synthesizer. It
  has 10 instrument presets, a sound editor, 8 drum pads, a looper with
  overdub, built-in demos and a built-in song.
- **POKEY PLAYER** (`POKEY-PLAYER.atr`) is a jukebox disk with 53 songs,
  about 1 hour 45 minutes of music. Its screen shows voice-pressure meters
  with peak hold, percussion LEDs that flash, the notes and instruments each
  voice is playing, an oscilloscope, a progress bar and a clock.

![POKEY PLAYER playing ANTHEM in stereo: voice meters with peak hold, the
notes and instruments per voice, percussion LEDs and the oscilloscope](docs/pokey-player.png)

*POKEY PLAYER playing ANTHEM in stereo (screenshot from the Altirra
emulator).*

Both programs use the same sound engine. `gen_engine.py` copies it out of
`synth.s` into `engine.inc`, so a sound fix reaches both on the next build.

## What you need

Any one of these:

- **An emulator.** [Altirra](https://www.virtualdub.org/altirra.html)
  (Windows, runs under Wine) or [atari800](https://atari800.github.io/)
  (Linux, macOS, Windows). Pick an NTSC 800XL or 130XE with 64 KB or more.
- **A real Atari 800XL, 65XE, 130XE or similar**, with a way to get files to
  it: an SD-card drive (SDrive, SIO2SD and the like), FujiNet, or SIO2PC/APE
  from a PC.
- **An FPGA Atari** or any other compatible machine.

Things to know:

- **NTSC.** The programs are timed for 60 Hz. On a PAL machine the music
  plays about 17% slower and about 16 cents flat.
- **Stereo is optional.** With a second POKEY, the looper, the song player
  and the drums spread over both chips. Real machines need a stereo POKEY
  upgrade. In Altirra, turn on the stereo option in the audio settings; in
  atari800, start it with `-stereo`. Without one, everything still plays
  in mono.
- **XL/XE keyboard.** The synth's key list is on the `HELP` key, which the
  400/800 don't have. Everything else works from the regular keys.

## Get it running

Download `POKEY-SYNTH.xex` and `POKEY-PLAYER.atr` from the
[GitHub releases](../../releases), or build them yourself (below).

**POKEY PLAYER disk (`.atr`):** mount it as drive D1: and cold-boot. It is a
boot disk with its own loader: no DOS, no BASIC needed. The screen turns
blue while the loader reads the player, then the player reads the song list
and loads each song from disk when you pick it.

The image is about 420 KB: some 3,400 single-density (128-byte) sectors.
That's too big for a physical 810 or 1050 drive (720 or 1,040 sectors), but
fine for anything that serves ATR images over SIO: FujiNet, SDrive-MAX,
SIO2SD, APE/AspeQt/RespeQt, and every emulator. SIO addresses sectors with
16 bits, so these devices handle images up to 65,535 sectors (8 MB at 128
bytes).

**POKEY SYNTH (`.xex`):** load it as a binary file with no DOS in memory:

- Altirra: *File > Boot Image*, or drag the file onto the window.
- atari800: `atari800 -xl -run POKEY-SYNTH.xex` (or pass the file as the
  last argument).
- Real hardware: use your SD drive's or FujiNet's own `.xex` loader.

Loading from the DOS 2.x menu is not expected to work: the programs use
memory from `$0F00` up, which DOS occupies. BASIC can be on or off.

## POKEY SYNTH

Play the keyboard like GarageBand's musical typing:

| Keys | Do |
|---|---|
| `A S D F G H J K L ;` | white notes C D E F G A B C D E |
| `W E` `T Y U` `O P` | black notes |
| `Z` / `X` | octave down / up |
| `1`-`9`, `0` | presets: PIANO ORGAN FLUTE STRINGS BASS CHIPARP SYNTH BELL LASER UFO |
| `C V B N M , . /` | drums: kick, snare, hat, open hat, tom, tom 2, clap, crash |
| joystick or arrow keys | sound editor: up/down picks a parameter, left/right changes it |
| `RETURN` | restore the current preset's factory sound |
| `ESC` | silence |
| `OPTION` / `SELECT` | next / previous preset |
| `SPACE` | looper: record, close the loop (it plays), overdub, back to play |
| `TAB` | looper: stop / play from the top |
| `BACKSPACE` | looper: clear |
| `I` | undo the last overdub pass |
| `SHIFT`+`SPACE` | recording grid on/off (count-in, metronome, snap to 16ths, whole bars) |
| `R` | held chords on/off for this preset |
| `Q` | drums only: mute the loop's melody and keep playing your own |
| `<` `>` | built-in demo loops: previous / next. Jam or overdub on them. Past the last demo is the built-in song, ANTHEM |
| `SHIFT`+`<` `>` | tempo |
| `HELP` | every key on one screen |

Sound edits are kept per preset until you press `RETURN`. On a stereo
machine the loop plays on the second POKEY, so you keep the whole left
POKEY for playing over it.

## POKEY PLAYER

| Key | Does |
|---|---|
| `SPACE` | pause / resume |
| `<` `>` | previous / next song |
| `RETURN` | play the song again from the start |
| `ESC` | stop |
| `1`-`9` | pick a song |
| `L` or `TAB` | the song list: joystick or arrow keys move (hold to scroll), left/right page, `RETURN` plays, `ESC` goes back |
| joystick left/right | previous / next song (on the panel) |

When a song ends, the next one starts. The music keeps playing while the
song list is open.

The oscilloscope redraws the mix 12 times a second. POKEY's output can't be
read back, so each voice contributes a wave at its pitch and loudness: a sine
for pure tones, a square for buzzy sounds, and noise for drums. Pitch is
compressed so every note shows a few cycles.

There is also a `.xex` build of the player (`build/player.xex`) with five
songs built in, which is all that fits in memory. It loads like the synth.

## Build from source

You need [cc65](https://cc65.github.io/) (`ca65` and `ld65`), GNU make, and
Python 3 with `py65` and `mido` (`pip install py65 mido`).

```bash
make                    # build/synth.xex, build/player.xex, build/pokeyplayer.atr
python3 test_synth.py   # emulator checks of the synth
python3 test_player.py  # emulator checks of the player
python3 test_disk.py    # boots the .atr in the emulator and checks every song
```

The Makefile looks for cc65 in `~/.local/bin`. If yours is elsewhere, say
so: `make CA65=ca65 LD65=ld65` (or give full paths).

The tests run the real 6502 code in `py65`, a CPU emulator, so they need no
Atari.

## Putting your own MIDI songs on the disk

Each song goes from a MIDI file (`.mid`) to a `.psq` sequence, then onto the
disk image.

### 1. Look inside the MIDI

```bash
python3 midi2psq.py path/to/song.mid --inspect
```

This lists every track and channel with its note count, range and
instrument. It also prints a ready-made `--lead N:C` option for each channel.

### 2. Convert it

Let the converter pick the parts:

```bash
python3 midi2psq.py path/to/song.mid --title "MY SONG" -o songs/mysong.psq
```

Or name them yourself. Parts are `track` or `track:channel`, counted from 1:

```bash
python3 midi2psq.py path/to/song.mid --lead 2 --bass 3 --harm 4 --drums 10 \
    --title "MY SONG" -o songs/mysong.psq
```

Read the coverage map it prints. It shows which tenth of the song each part
plays, and warns when a part is mostly silent or starts late. That usually
means the wrong track was picked, so fix it before listening.

On a stereo machine the player has a fourth voice on the lead's layer
channel. `--voice4 PART` fills it. The converter uses it by itself when a
song's busiest part is mostly chords and a single-note line exists in the
singer's register: that line becomes the lead, and the chord part moves to
the fourth voice. Mono machines skip it.

Useful options:

| Option | Does |
|---|---|
| `--start S` / `--end S` | keep only this part of the song, in seconds |
| `--transpose N` | shift every note by N semitones |
| `--preset-lead P` (also `-bass`, `-harm`, `-voice4`) | choose the instrument: PIANO ORGAN FLUTE STRINGS BASS CHIPARP SYNTH BELL LASER UFO |
| `--lead 5:4,3:2` | several parts feed one voice. The first one wins when both play |
| `--octave-bass N` (also `-lead`, `-harm`, `-voice4`) | move one part by N octaves (e.g. `-1` for a deeper bass) |
| `--beat` | the MIDI has no drums: add a pop-rock beat on the song's own pulse (kick and snare on the left POKEY, hats and crashes on the right) |
| `--no-drop` | keep the harmony at its written octave (sometimes sounds better than the tuned-down default) |
| `--no-double`, `--echo N` | control the octave double and echo added to single-part songs |

`python3 psq.py songs/mysong.psq` shows a file's length, notes and drum hits.

### 3. Build the disk

`mkdisk.py` with no arguments builds the album (see below). To make a
different disk, list the songs you want. A list replaces the album, and
songs play in the order given:

```bash
make build/player_disk.xex build/boot.bin    # the player and loader it packs
python3 mkdisk.py anthem kalinka mysong      # names in songs/, or paths to .psq files
python3 test_disk.py                         # optional: boot it in the emulator
```

Limits:

- A song can be at most 20 KB, which is 160 sectors. That's roughly 2-3
  minutes of a busy arrangement. `mkdisk.py` skips a longer song and says
  so. Use `--end` to cut it.
- A disk holds at most 53 songs.
- The title comes from `--title`, at most 16 characters.
- A stereo song still plays on a one-POKEY machine. It drops the third part
  and folds both drum channels together.

### 4. Listen

Boot `build/pokeyplayer.atr` in your emulator or copy it to your SD
drive, as in *Get it running*. A disk with just the song you're working on
is the quickest way to try a conversion.

## The disk's songs

The album holds 53 songs, alphabetical, all chosen by ear on real
hardware. `disk.py` lists them: the yays, then fillers that take whatever
slots are left. Each entry points at the exact conversion that was
approved. `album.py` made the first album's full-length conversions and is
kept as their record.

## Optional: the Tang Nano 20K Atari and its PC link

This part is only for people running my
[Tang Nano 20K Atari core](https://github.com/carlosbravoa/atari800_tang_nano20k)
with its USB serial bridge. The bridge lets the PC write the Atari's RAM
while it runs, which is how these programs were developed and tested. None
of it is needed to play them.

The tools below call that project's `tools/atari.py` / `atari_link.py`.

### Deploying

```bash
make deploy           # hot-swap the synth onto the running machine, or USR-launch it from BASIC READY
make playerdeploy     # the same for build/player.xex
```

To put the disk on the board's SD card:

```bash
python3 <board repo>/tools/atari.py send build/pokeyplayer.atr POKEYPLR.ATR
```

Then mount it on D1: from the OSD and cold-boot.

### Keys on the board

The board maps a PC keyboard onto the Atari:

| PC key | Atari |
|---|---|
| F5 or Insert | `HELP` |
| F8 / F7 | `OPTION` / `SELECT` |
| arrow keys | joystick 1 |
| `-` / `=` | `<` / `>` (in the board's default positional layout) |

In the board's PC-symbolic layout, `-` and `=` type the Atari's `-` and `=`,
which are the synth editor's up/down.

### PC-side tools

These talk to the running synth over the link:

- `pcplay.py songs/mysong.psq` streams a `.psq` to the synth, event by
  event, so there is no length limit (`make stream NAME=...`). Handy for
  hearing a conversion without building a disk.
- `loopfile.py save|load|info|list NAME` saves a loop, with your preset
  edits, to `loops/NAME.psl` and loads it back (`make save` / `make load`).
- `songfile.py play NAME` plays a song made of saved loop sections, listed
  in `songs/NAME.song`, gaplessly. `songfile.py pack` bundles one into a
  `.pss`.
- `compose_anthem.py` is a worked example of writing a song in Python.
- `audition.py` plays a folder of MIDIs one at a time in the real player
  and records your verdicts. That's how the album was chosen:

  ```bash
  python3 audition.py convert ~/Music/newsongs    # all of them -> songs/audition/
  python3 audition.py next yay                    # starts the first one; then
  python3 audition.py next yay|nay|maybe          #  your verdict + the next song
  ```

  Verdicts land in `songs/audition/verdicts.json`. For a song with the
  wrong parts, add hand-picked parts to `FIXES` in `audition.py`, run
  `audition.py fixes FOLDER` and review them with
  `audition.py --fixes next ...`. Then add the approved files to `disk.py`
  and run `python3 mkdisk.py`.

### Hardware tests

`hwtest.py`, `hwloop.py`, `hwdemo.py`, `hwsave.py`, `hwsong.py` and
`hwplayer.py` press real keys on the board and check the results by reading
the Atari's memory. They assume nothing else is playing.

`CLAUDE.md` has the full technical notes: the engine, the memory map, the
file formats and the hardware tests.
