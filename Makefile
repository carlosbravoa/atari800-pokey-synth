CA65   := $(HOME)/.local/bin/ca65
LD65   := $(HOME)/.local/bin/ld65

all: build/synth.xex build/player.xex build/pokeyplayer.atr

demos.inc: gen_demos.py
	python3 gen_demos.py

tables.inc: gen_tables.py
	python3 gen_tables.py

songdata.inc: gen_song.py compose_anthem.py
	python3 gen_song.py

build/synth.xex: synth.s tables.inc demos.inc songdata.inc atari-xex.cfg
	@mkdir -p build
	$(CA65) -g -o build/synth.o synth.s
	$(LD65) -C atari-xex.cfg -Ln build/synth.lbl -o $@ build/synth.o
	@ls -l $@

engine.inc: gen_engine.py synth.s
	python3 gen_engine.py

songbank.bin: gen_songbank.py $(wildcard songs/*.psq)
	python3 gen_songbank.py

# the standalone visual song player (no PC attached)
scope.inc: gen_scope.py
	python3 gen_scope.py

build/player.xex: player.s engine.inc tables.inc scope.inc songbank.bin atari-player.cfg
	@mkdir -p build
	$(CA65) -g -o build/player.o player.s
	$(LD65) -C atari-player.cfg -Ln build/player.lbl -o $@ build/player.o
	@ls -l $@

build/player_disk.xex: player.s engine.inc tables.inc scope.inc atari-player-disk.cfg
	@mkdir -p build
	$(CA65) -g -D DISK -o build/player_disk.o player.s
	$(LD65) -C atari-player-disk.cfg -Ln build/player_disk.lbl -o $@ build/player_disk.o

build/boot.bin: boot.s atari-boot.cfg
	@mkdir -p build
	$(CA65) -o build/boot.o boot.s
	$(LD65) -C atari-boot.cfg -o $@ build/boot.o

# a bootable disk: loader + catalog + player + every song in DISK_SONGS
build/pokeyplayer.atr: build/boot.bin build/player_disk.xex mkdisk.py $(wildcard songs/*.psq)
	python3 mkdisk.py

playerdeploy: build/player.xex
	python3 deploy.py --xex build/player.xex

# hot-swap onto the running machine, or USR-launch from BASIC READY
deploy: all
	python3 deploy.py

# loops over the PC link:  make save NAME=mysong / make load NAME=mysong
save:
	python3 loopfile.py save $(NAME)

load:
	python3 loopfile.py load $(NAME)

loops:
	python3 loopfile.py list

# MIDI -> .psq:  make midi MID=song.mid ARGS="--lead 1 --bass 3 --drums 10"
midi:
	python3 midi2psq.py $(MID) $(ARGS)

# stream a .psq sequence from the PC (no Atari memory limits)
stream:
	python3 pcplay.py $(NAME)

# songs: songs/NAME.song = one "<loop> [repeats]" per line
song:
	python3 songfile.py play $(NAME)

pack:
	python3 songfile.py pack $(NAME)

clean:
	rm -rf build

.PHONY: all deploy playerdeploy clean save load loops song pack stream midi
