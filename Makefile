CA65   := $(HOME)/.local/bin/ca65
LD65   := $(HOME)/.local/bin/ld65

all: build/synth.xex

demos.inc: gen_demos.py
	python3 gen_demos.py

tables.inc: gen_tables.py
	python3 gen_tables.py

build/synth.xex: synth.s tables.inc demos.inc atari-xex.cfg
	@mkdir -p build
	$(CA65) -g -o build/synth.o synth.s
	$(LD65) -C atari-xex.cfg -Ln build/synth.lbl -o $@ build/synth.o
	@ls -l $@

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

.PHONY: all deploy clean save load loops song pack stream
