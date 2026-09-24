#!/usr/bin/env python3
"""Listen to candidate songs on the Atari before they go on the disk.

    python3 audition.py convert ~/Music/seleccion   # all of them -> songs/audition/
    python3 audition.py list                        # what's there, in play order
    python3 audition.py fixes ~/Music/seleccion     # FIXES (hand-picked parts)
                                                    #  -> songs/fixes/, then:
    python3 audition.py --fixes next yay|nay|maybe
    python3 audition.py --album next yay|nay|maybe  # the same over songs/album/
                                                    #  (its index.json = what to review)
    python3 audition.py play NAME                   # that song alone, on the board
    python3 audition.py next yay|nay|maybe          # verdict on the one playing,
                                                    #  then play the next unheard one

`convert` makes each MIDI a full-length .psq (auto-picked parts, cut to the
player's 20 KB buffer when needed) and prints its parts and warnings.
`play` builds POKEY PLAYER with just that song (-D AUDITION, the bank in
build/audition.bin) and hot-swaps it onto the running machine, so what you
hear is exactly what the disk would play: panel, stereo and voice 4.
Chosen songs then go into album.py's ALBUM list.
"""
import json
import os
import re
import subprocess
import sys

import album
import gen_songbank
import psq

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "songs", "audition")
if "--album" in sys.argv:              # review the disk album instead
    sys.argv.remove("--album")
    OUT = os.path.join(HERE, "songs", "album")
if "--fixes" in sys.argv:              # review the hand-fixed versions
    sys.argv.remove("--fixes")
    OUT = os.path.join(HERE, "songs", "fixes")
INDEX = os.path.join(OUT, "index.json")      # name -> source MIDI, title
VERDICTS = os.path.join(OUT, "verdicts.json")  # name -> yay / nay, "_playing"

# readable titles for file names people wouldn't recognise (16 chars max)
TITLES = {
    "Adventure_Island_II-Overworld_1": "ADV ISLAND 2",
    "DocMarTune": "DR MARIO",
    "MM1-_Elecman": "ELEC MAN",
    "MM4Skull": "SKULL MAN",
    "NinjaBro": "NINJA BROS",
    "Nintendo_World_Cup_-_Golden_Goal": "WORLD CUP GOAL",
    "Puyo-Puyo-Tsu-Remix-By-Matthew": "PUYO PUYO TSU",
    "RR_Music1": "RR MUSIC 1",
    "SRnR_-_Stage_01": "SRNR STAGE 1",
    "Smbtheme": "SUPER MARIO",
    "St-Seiya": "SAINT SEIYA",
    "Tyrian_-_The_Level": "TYRIAN",
    "contra-1": "CONTRA",
    "corneria": "CORNERIA",
    "corridor": "CORRIDOR OF TIME",       # Chrono Trigger, Corridors of Time
    "ct600ad": "CHRONO 600 AD",           # Chrono Trigger
    "cv1-1b": "CASTLEVANIA",
    "ddstage": "DOUBLE DRAGON",
    "ddtheme": "DOUBLE DRAGON TH",
    "ff336": "FF3 336",
    "ff3PRELUDE": "FF PRELUDE",
    "ff3jbatt": "FF3 BATTLE",
    "mm2air": "AIR MAN",
    "mm3magnt_2": "MAGNET MAN",
    "mmx01": "MEGA MAN X",
    "ng2stg11": "NINJA GAIDEN 2",
    "sdb-london": "SDB LONDON",
    "sf2Ryu456": "SF2 RYU",
    "sf2ken": "SF2 KEN",
    "sm3ow2": "SMB3 WORLD 2",
    "smb2overworld1": "SMB2 OVERWORLD",
    "smwwd1": "SUPER MARIO WLD",
    "tetris-1": "TETRIS",
    "topgear1": "TOP GEAR",
    "wily9": "WILY STAGE",
    "z1overw": "ZELDA",
}


# Hand-picked parts for songs whose auto pick was wrong (from the channel
# listings: python3 midi2psq.py FILE --inspect). name -> (title, options)
FIXES = {
    "ddtheme": ("DOUBLE DRAGON TH",     # the tune is the sparser 1:2, not 1:4
                "--lead 1:2 --bass 1:3 --harm 1:4 --drums 1:10"),
    "MM1-_Elecman": ("ELEC MAN",        # lead and harmony swapped
                     "--lead 2:11 --bass 4:13 --harm 3:12 --drums 5:10"),
    "mm3magnt_2": ("MAGNET MAN",        # lead and harmony swapped
                   "--lead 2:1 --bass 5:4 --harm 3:2,4:3 --drums 6:10"),
    "Nintendo_World_Cup_-_Golden_Goal": ("WORLD CUP GOAL",   # every part is
                   "--lead 2:1 --bass 7:6 --harm 4:3"),      #  doubled; 2:1 = tune
    "Puyo-Puyo-Tsu-Remix-By-Matthew": ("PUYO PUYO TSU",      # tune on the
                   "--lead 4:3,5:4 --bass 8:7 --harm 3:2 "   #  sparse music box
                   "--voice4 13:12,12:11 --drums 11:10"),    #  and e-piano
    "sf2ken": ("SF2 KEN",               # the high line from 11 s, guitar before
               "--lead 6:5,3:2 --bass 8:7,7:6,2:1 --harm 4:3 --voice4 5:4 "
               "--drums 10:10,11:10,12:10"),
    "corridor": ("CORRIDOR OF TIME",    # harmony kept at its written octave
                 "--lead 2:1 --bass 3:2 --harm 5:4,4:3 --no-drop"),
    "wily9": ("WILY STAGE",             # the sax melody (echoed on 3:2, 4:3)
              "--lead 2:1 --bass 10:4 --harm 11:11 --voice4 5:7 --drums 17:10"),
    "RR_Music1": ("RR MUSIC 1",         # as auditioned, bass an octave down
                  "--lead 2:1 --bass 3:2 --harm 5:3 --drums 4:10 --octave-bass -1"),
}


def fixes(folder):
    out_dir = os.path.join(HERE, "songs", "fixes")
    os.makedirs(out_dir, exist_ok=True)
    index = {}
    for name, (title, opts) in FIXES.items():
        mid = os.path.join(folder, name + ".mid")
        out = os.path.join(out_dir, name + ".psq")
        note, warn, text = album.fit(mid, out, title, opts.split())
        secs = round(psq.read(out)[0]["frames"] / 59.92)
        index[name] = {"midi": mid, "title": title, "options": opts}
        print(f"  {title:16s} {secs // 60}:{secs % 60:02d} {album.body_size(out):6d} B  {note}"
              + (f"\n{'':20s}WARN {warn}" if warn else ""), flush=True)
    json.dump(index, open(os.path.join(out_dir, "index.json"), "w"), indent=1)


def title_for(name):
    return TITLES.get(name) or re.sub(r"[_\-]+", " ", name).upper()[:16].strip()


def convert(folder):
    os.makedirs(OUT, exist_ok=True)
    index = {}
    for f in sorted(os.listdir(folder), key=str.lower):
        if not f.lower().endswith(".mid"):
            continue
        name, mid = f[:-4], os.path.join(folder, f)
        title = title_for(name)
        out = os.path.join(OUT, name + ".psq")
        try:
            note, warn, text = album.fit(mid, out, title, [])
        except RuntimeError as e:
            print(f"  {title:16s} FAILED: {e}")
            continue
        h, ev = psq.read(out)
        parts = re.search(r"lead (\d+), bass (\d+), harmony (\d+)(?:, voice 4 (\d+))?", text)
        secs = round(h["frames"] / 59.92)
        index[name] = {"midi": mid, "title": title}
        print(f"  {title:16s} {secs // 60}:{secs % 60:02d} {album.body_size(out):6d} B  "
              f"parts {parts.group(0) if parts else '?'}  {note}"
              + (f"\n{'':20s}WARN {warn}" if warn else ""), flush=True)
    json.dump(index, open(INDEX, "w"), indent=1)
    print(f"{len(index)} songs in {OUT}")


def play(name):
    index = json.load(open(INDEX))
    key = next((k for k in index if k.lower() == name.lower()
                or index[k]["title"].lower() == name.lower()), None)
    if not key:
        sys.exit(f"no such song: {name} (see: audition.py list)")
    path = os.path.join(OUT, key + ".psq")
    os.makedirs(os.path.join(HERE, "build"), exist_ok=True)
    gen_songbank.build([path], out="build/audition.bin")
    ca, ld = os.path.expanduser("~/.local/bin/ca65"), os.path.expanduser("~/.local/bin/ld65")
    subprocess.run([ca, "-D", "AUDITION", "-o", "build/audition.o", "player.s"], cwd=HERE, check=True)
    subprocess.run([ld, "-C", "atari-player.cfg", "-o", "build/audition.xex", "build/audition.o"],
                   cwd=HERE, check=True)
    subprocess.run([sys.executable, "deploy.py", "--xex", "build/audition.xex"], cwd=HERE, check=True)
    v = verdicts()
    v["_playing"] = key
    json.dump(v, open(VERDICTS, "w"), indent=1)
    print(f"playing {index[key]['title']} ({key})")


def verdicts():
    return json.load(open(VERDICTS)) if os.path.exists(VERDICTS) else {}


def next_song(verdict):
    v = verdicts()
    cur = v.get("_playing")
    if cur:
        v[cur] = verdict
        json.dump(v, open(VERDICTS, "w"), indent=1)
        print(f"{cur}: {verdict}")
    left = [k for k in json.load(open(INDEX)) if k not in v]
    if not left:
        print("all heard: " + ", ".join(k for k in v if v[k] == "yay"))
        return
    play(left[0])
    print(f"{len(left) - 1} more after this one")


def listing():
    for k, v in json.load(open(INDEX)).items():
        h, _ = psq.read(os.path.join(OUT, k + ".psq"))
        secs = round(h["frames"] / 59.92)
        print(f"  {v['title']:16s} {secs // 60}:{secs % 60:02d}  {k}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if a[:1] == ["convert"] and len(a) == 2:
        convert(os.path.expanduser(a[1]))
    elif a[:1] == ["play"] and len(a) == 2:
        play(a[1])
    elif a[:1] == ["next"] and len(a) == 2 and a[1] in ("yay", "nay", "maybe"):
        next_song(a[1])
    elif a[:1] == ["fixes"] and len(a) == 2:
        fixes(os.path.expanduser(a[1]))
    elif a[:1] == ["list"]:
        listing()
    else:
        sys.exit(__doc__)
