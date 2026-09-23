# POKEY SYNTH & POKEY PLAYER

Two programs for the Atari 8-bit (NTSC 800XL class, 64 KB). Both run on one
POKEY and switch to stereo by themselves when a second POKEY answers at
`$D210`.

- **POKEY SYNTH** (`build/synth.xex`) is a playable keyboard synthesizer. It
  has 10 instrument presets, a sound editor, 8 drum pads, a looper with
  overdub, built-in demos and a built-in song. It can also play music
  streamed from the PC.
- **POKEY PLAYER** (`build/player.xex` or the bootable
  `build/pokeyplayer.atr`) plays songs with no PC attached. Its screen shows
  voice-pressure meters with peak hold, percussion LEDs that flash, the notes
  and instruments each voice is playing, an oscilloscope, a progress bar and
  a clock.

![POKEY PLAYER playing ANTHEM in stereo: voice meters with peak hold, the
notes and instruments per voice, percussion LEDs and the oscilloscope](docs/pokey-player.png)

*POKEY PLAYER playing ANTHEM in stereo (screenshot from the Altirra
emulator).*

Both programs use the same sound engine. `gen_engine.py` copies it out of
`synth.s` into `engine.inc`, so a sound fix reaches both on the next build.

## Build

You need cc65 (`ca65`/`ld65` in `~/.local/bin`) and Python 3 with `py65`
and `mido`.

```bash
make                    # synth.xex, player.xex and pokeyplayer.atr
python3 test_synth.py   # emulator checks of the synth
python3 test_player.py  # emulator checks of the player
python3 test_disk.py    # boots the .atr in the emulator and checks every song
```

## POKEY PLAYER

| Key | Does |
|---|---|
| `SPACE` | pause / resume |
| `<` `>` | previous / next song |
| `RETURN` | play the song again from the start |
| `ESC` | stop |
| `1`-`9` | pick a song |
| `L` or `TAB` | the song list: arrow keys or joystick move (hold to scroll), left/right page, `RETURN` plays, `ESC` goes back |
| joystick left/right | previous / next song (on the panel) |

When a song ends, the next one starts. The music keeps playing while the
song list is open.

The oscilloscope redraws the mix 12 times a second. POKEY's output can't be
read back, so each voice contributes a wave at its pitch and loudness: a sine
for pure tones, a square for buzzy sounds, and noise for drums. Pitch is
compressed so every note shows a few cycles.

**From a disk:** copy `build/pokeyplayer.atr` to the SD card, mount it on
D1: and cold-boot. The screen turns blue while the loader reads the player.
The player then reads the song list and loads each song from disk when you
pick it. The disk holds the album: 37 songs, about an hour.

Releases on GitHub carry both programs ready to run: `POKEY-SYNTH.xex`
and the `POKEY-PLAYER.atr` disk.

**As a .xex:** `build/player.xex` has five songs built in, which is all that
fits in memory. `make playerdeploy` puts it on the board over the PC link.

## The album

`album.py` lists every song on the disk and converts them all at full
length into `songs/album/`. `mkdisk.py` then builds the disk from that list.

```bash
python3 album.py     # convert (prints length, size and any warnings per song)
python3 mkdisk.py    # build/pokeyplayer.atr from the album
```

- Songs marked `rated` were rated 4-5 while listening to their first 50
  seconds. Their full versions use the same parts the converter picks for
  those 50 seconds.
- Songs marked `new` haven't been rated yet.
- A song too long for the 20 KB buffer is cut at the longest length that
  fits, and the table says so.
- To add a song, add a line to `ALBUM` in `album.py` and run both commands.
  That's the easy way to do step 4 below.

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
the fourth voice. The synth's PC streaming and mono machines skip it.

Useful options:

| Option | Does |
|---|---|
| `--start S` / `--end S` | keep only this part of the song, in seconds |
| `--transpose N` | shift every note by N semitones |
| `--preset-lead P` (also `-bass`, `-harm`, `-voice4`) | choose the instrument: PIANO ORGAN FLUTE STRINGS BASS CHIPARP SYNTH BELL LASER UFO |
| `--lead 5:4,3:2` | several parts feed one voice. The first one wins when both play |
| `--no-double`, `--echo N` | control the octave double and echo added to single-part songs |

### 3. Listen before you commit to it (optional, needs the PC link)

```bash
python3 pcplay.py songs/mysong.psq      # the Atari must be running POKEY SYNTH
python3 psq.py songs/mysong.psq         # length, notes and drum hits
```

### 4. Build the disk

`mkdisk.py` with no arguments builds the album (see above). To make a
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
- A disk holds at most 42 songs.
- The title comes from `--title`, at most 16 characters.
- A stereo song still plays on a one-POKEY machine. It drops the third part
  and folds both drum channels together.

### 5. Put it on the SD card

```bash
python3 ../../../fpga/atari800_tang_nano20k_parallel/tools/atari.py \
    send build/pokeyplayer.atr POKEYPLR.ATR
```

Or copy the file to the card any other way. Then mount it on D1: from the
OSD and boot.

## POKEY SYNTH

Play the keyboard like GarageBand's musical typing. `A S D F G H J K L ;`
are the white notes, and `W E T Y U O P` are the black notes. `Z` and `X`
change octave, `1`-`0` pick presets, and `C V B N M , . /` are the drums.
`SPACE` records, loops and overdubs. `<` `>` load the built-in demos and
song. `HELP` shows every key.

Other tools that work over the PC link:

- `loopfile.py` saves and loads loops.
- `songfile.py` plays songs made of loop sections.
- `pcplay.py` streams `.psq` files.
- `compose_anthem.py` is a worked example of writing a song in Python.

`CLAUDE.md` has the full technical notes: the engine, the memory map, the
file formats and the hardware tests.
