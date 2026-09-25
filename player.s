; ---------------------------------------------------------------------------
; POKEY PLAYER — a standalone song player for the Atari 8-bit (NTSC 800XL).
;
; No PC attached: songs are baked into the binary (or, later, read from a
; disk image) and played by the same sound engine as POKEY SYNTH, shared
; through the generated engine.inc (gen_engine.py slices it out of synth.s).
;
; The screen is the point: six voice-pressure meters with peak hold, eight
; percussion LEDs that blink on every hit, a progress bar, an oscilloscope
; and the notes/instruments each voice is playing.
;
; Keys:  SPACE pause/resume · < > previous/next song · RETURN replay
;        ESC stop · 1-9 pick a song
;
; VBI/DLI touch page 6 and the player's own RAM only, and the deploy.py
; mailbox (FRAME $0617, PARKREQ $063D, trampoline $0680) works as usual.
; ---------------------------------------------------------------------------

.include "engine.inc"           ; equates + sound engine, generated from synth.s

; ---- player state (page 6, peekable) --------------------------------------
PLAYING  = $0644        ; 1 = a song is running
SONGN    = $0645        ; current song 0..NSONG-1
NSONG    = $0646        ; songs in the bank
SEVN     = $0647        ; events executed (liveness)
PAUSED   = $0648
SPTR     = $0656        ; 2: event pointer (mirror of VP, for peeking)
DWAIT    = $0658        ; 2: frames until the next event
SPOS     = $065A        ; 2: frames played
SECS     = $065C        ; seconds played
SECTMR   = $065D        ; frames left of this second
SMODE    = $065E        ; the song's mode byte (0 mono 1 stereo 2 either)
KHELD    = $065F        ; key held ($FF none)
PENDN    = $0660        ; main-thread request: 1 = load the next song
MINS     = $0661        ; minutes played
DRT      = $0662        ; 8 drum LED timers ($0662-$0669)
LASTDL   = $066A        ; drum sounding on POKEY1 ch4
LASTDR   = $066B        ; ... and on POKEY2 ch4
ENDF     = $066C        ; the stream hit END
DRAWN    = $0BC1        ; +1 per main-loop pass: equals FRAME's pace when
                        ;  the panel keeps up (no dropped frames)

SONGS    = $5000        ; song bank: catalog + event streams (disk: the one
                        ;  song loaded from disk)
.ifdef DISK
CAT      = $0C00        ; catalog, read from sectors CATSEC.. at startup
CATSEC   = 4
CATN     = 10           ; 10 x 128 bytes ($0C00-$10FF): up to 53 songs
LOADING  = $0BC0        ; 1 = SIO owns POKEY: the VBI keeps its hands off
LSCR     = SCOPEB       ; the loading screen: 4 mode-7 lines of 20, in the
                        ;  scope's buffer (the panel is hidden meanwhile)
G_SOLID  = 6            ; loading bar: a filled cell (mode 7)
G_HOLE   = 7            ;              an empty one
SOUNDR   = $41
DDEVIC   = $0300
DUNIT    = $0301
DCOMND   = $0302
DSTATS   = $0303
DBUFLO   = $0304
DBUFHI   = $0305
DAUX1    = $030A
DAUX2    = $030B
DSKINV   = $E453
.elseif .defined(JAM)
CAT      = $0480        ; POKEY JAM: the style list, built at start ($0480-
                        ;  $057F: free once BASIC is gone; up to 10 styles --
                        ;  $0C00 is the composer's since 10 styles overran it)
.else
CAT      = SONGS
.endif
CATENT   = 24           ; bytes per catalog entry
NBAR     = 6            ; voice meters
BARTOP   = 5            ; first meter row
BARROWS  = 9

V3X      = $84          ; voice 4's block: VB + $84 = $0BC4-$0BD7 (free RAM),
                        ;  played on POKEY1 ch3 (the layer's channel)
SCOPEA   = $1800        ; oscilloscope: two 24-line ANTIC E bitmaps
SCOPEB   = $1C00        ;  (40 bytes a line), shown alternately
SCN      = 80           ; samples across (2 pixels each)

; glyph codes (punctuation slots: none of the player's text uses them)
G_FULL   = 1            ; meter segment, lit        (ANTIC 4)
G_HALF   = 2            ; meter segment, half lit   (ANTIC 4)
G_DARK   = 3            ; meter segment, unlit      (ANTIC 4)
G_PEAK   = 4            ; peak-hold marker          (ANTIC 4)
G_OFF    = 5            ; LED / progress cell, dark (GR.0)
G_ON     = $80          ; LED / progress cell, lit  (inverse space)

; ---- zero page (main thread) ----
PSCR     = $96          ; screen pointer
PT1      = $98
PT2      = $99
PT3      = $9A
PT4      = $9B
PLVL     = $9C
PPK      = $9D
PCOL     = $9E
SCV      = $A0          ; 2: the scope's column-routine entry (jmp indirect)
CPTR     = $A2          ; 2: a catalog entry (cat_ptr)
K_L      = $00          ; L: the song list (TAB too)
LISTSCR  = SCOPEA       ; the song list's screen (the scope is hidden then)
LROWS    = 20           ; songs on screen at once

; ===========================================================================
.segment "XEXHDR"
.import __MAIN_START__, __MAIN_LAST__
        .word $FFFF
        .word __MAIN_START__
        .word __MAIN_LAST__-1

.segment "XEXHDR2"
.import __HIMEM_START__, __HIMEM_LAST__
        .word __HIMEM_START__
        .word __HIMEM_LAST__-1

.ifndef DISK
.segment "XEXHDR3"
.import __SONG_START__, __SONG_LAST__
        .word __SONG_START__
        .word __SONG_LAST__-1
.endif

.segment "XEXHDR4"
.import __LOW2_START__, __LOW2_LAST__
        .word __LOW2_START__
        .word __LOW2_LAST__-1

.segment "XEXTRL"
        .word $02E0, $02E1
        .word start

; ===========================================================================
.segment "DLIST"
; every row carries its own LMS, so the two mode-7 rows (20 bytes fetched)
; keep the screen a plain 40-byte-per-row buffer
dlist:
        .byte $70,$70,$70
        .byte $47,<(SCREEN+0*40),>(SCREEN+0*40)         ; 0  POKEY PLAYER
        .byte $C7,<(SCREEN+1*40),>(SCREEN+1*40)         ; 1  song title  +DLI
        .byte $C2,<(SCREEN+2*40),>(SCREEN+2*40)         ; 2  status      +DLI
        .byte $C2,<(SCREEN+3*40),>(SCREEN+3*40)         ; 3  progress    +DLI
        .byte $C2,<(SCREEN+4*40),>(SCREEN+4*40)         ; 4  spacer      +DLI
        .byte $C4,<(SCREEN+5*40),>(SCREEN+5*40)         ; 5  meters (ANTIC 4)
        .byte $C4,<(SCREEN+6*40),>(SCREEN+6*40)
        .byte $C4,<(SCREEN+7*40),>(SCREEN+7*40)
        .byte $C4,<(SCREEN+8*40),>(SCREEN+8*40)
        .byte $C4,<(SCREEN+9*40),>(SCREEN+9*40)
        .byte $C4,<(SCREEN+10*40),>(SCREEN+10*40)
        .byte $C4,<(SCREEN+11*40),>(SCREEN+11*40)
        .byte $C4,<(SCREEN+12*40),>(SCREEN+12*40)
        .byte $C4,<(SCREEN+13*40),>(SCREEN+13*40)       ; 13 meters, last
        .byte $02,$02,$02                               ; 14 labels, 15 notes,
                                                        ;  16 instruments
        .byte $C2,<(SCREEN+17*40),>(SCREEN+17*40)       ; 17 rule       +DLI
        .byte $02                                       ; 18 drum LEDs
        .byte $C2,<(SCREEN+19*40),>(SCREEN+19*40)       ; 19 drum names +DLI
.ifdef JAM
        .byte $42,<(SCREEN+20*40),>(SCREEN+20*40)       ; 20 (no scope: the
        .byte $82                                       ; 21  panel's time goes
        .byte $02                                       ; 22  to the composer)
        .byte $02                                       ; 23 keys, credit
.else
scope_lms:                                              ; 20-22: the scope,
        .byte $4E,<SCOPEA,>SCOPEA                       ;  24 ANTIC E lines
        .res  22,$0E
        .byte $8E                                       ;  last line   +DLI
        .byte $42,<(SCREEN+23*40),>(SCREEN+23*40)       ; 23 keys
.endif
        .byte $41,<dlist,>dlist

.ifdef DISK
; between songs: a big LOADING screen instead of a frozen panel
dlist_load:
        .res  8,$70
        .byte $47,<LSCR,>LSCR                           ; LOADING
        .byte $70,$70
        .byte $07                                       ; the song's title
        .byte $70,$70
        .byte $07                                       ; the bar
        .byte $70,$70
        .byte $07                                       ; SONG nn OF nn
        .byte $41,<dlist_load,>dlist_load
.endif

; ===========================================================================
.segment "CODE"

start:
        ldx #$FF
        txs
        cld
        lda #0
        sta SDMCTL
        sta NMIEN
        ldx #7                  ; silence POKEY1, lead pair joined 16-bit
@snd:   sta AUDF1,x
        dex
        bpl @snd
        lda #$50
        sta AUDCTL
        lda #3
        sta SKCTL
        sei                     ; we poll the keyboard ourselves
        lda POKMSK
        and #$3F
        sta POKMSK
        sta IRQEN
        cli
        lda #$FF
        sta NOCLIK
        sta CH

        jsr init_chset
        lda #>$1100             ; the variables ($1100-$13FF, not in the file)
        sta PT2
        lda #0
        sta PT1
        tay
        ldx #3
@zv:    sta (PT1),y
        iny
        bne @zv
        inc PT2
        dex
        bne @zv
        lda #0                  ; page-6 state up to the trampoline
        ldx #$7B
@z6:    sta $0600,x
        dex
        bpl @z6
        ldx #3                  ; mix levels: full
@zm:    sta MIXL,x
        dex
        bpl @zm
        ldx #$3F
@ze:    sta ECHON,x
        dex
        bpl @ze
        ldx #0                  ; live presets <- factory
@lp:    lda factory,x
        sta live,x
        inx
        cpx #10*PSTRIDE
        bne @lp
        ldx #7                  ; hot-swap trampoline + RTI stub
@tr:    lda tramp_code,x
        sta TRAMP,x
        dex
        bpl @tr
        lda #$40
        sta RTISTUB
        ldx #VBS*2+16+32-1      ; voice + drum blocks + register image
        lda #0
@vz:    sta VB,x
        dex
        bpl @vz
        ldx #$47                ; $0B98-$0BDF: the synth's old song vars,
        lda #0                  ;  then voice 4's block
@vz2:   sta POLY4B,x
        dex
        bpl @vz2
.ifdef DISK
        sta SOUNDR              ; no SIO beeps
        sta LOADING
.endif
        lda #$FF
        sta KHELD
        sta LITKEY
        sta DRUMLIT

        lda #$1A                ; mode-7 title colors (rows 0-1)
        sta COLOR0
        lda #$96
        sta COLOR1
        lda #$4A
        sta COLOR2
        lda #$CA
        sta COLOR3
        lda #0
        sta COLOR4
        lda #<SCREEN
        sta SAVMSC
        lda #>SCREEN
        sta SAVMSC+1
        lda #>CHSET
        sta CHBAS
        lda #<dlist
        sta SDLSTL
        lda #>dlist
        sta SDLSTL+1
        lda #<dli
        sta VDSLST
        lda #>dli
        sta VDSLST+1

        jsr detect_stereo
        jsr cls
        jsr draw_static
.ifndef JAM
        jsr scope_init
.endif
        lda #7
        ldx #>vbi
        ldy #<vbi
        jsr SETVBV
        lda #$C0
        sta NMIEN
        lda #$22
        sta SDMCTL
.ifdef DISK
        jsr read_catalog
.endif
.ifdef JAM
        jsr jam_catalog         ; styles take the songs' place
.endif
        lda CAT                 ; how many songs are in the bank
        sta NSONG
        lda #0
        jsr song_load

mainloop:
        jsr wait_frame
        inc DRAWN
.ifdef MEASURE
        lda RTCLOK+1            ; ~30 s after boot: dump $0000-$0CFF to the
        cmp #7                  ;  emulator's H1: device, then stop (never
        bcc @run                ;  in a real build)
        jmp measure_dump
@run:
.endif
        lda PARKREQ
        bne park_self
        jsr read_keys
        jsr read_stick
        lda PENDN               ; the stream ended: roll on to the next song
        beq @p
        lda #0
        sta PENDN
        jsr next_song
        lda liston              ; browsing: the list's marker moves on too
        beq @p
        jsr list_rows
@p:     lda PRESREQ             ; the song asked for a lead instrument
        cmp #$FF
        beq @d
        pha
        lda #$FF
        sta PRESREQ
        pla
        jsr set_preset
@d:
.ifdef JAM
        jsr jam_pump            ; keep the composer a few bars ahead
.endif
        lda liston              ; the panel is hidden while the list is up
        bne @l
        jsr draw_all
@l:     jmp mainloop

park_self:                      ; deploy.py hot-swap: detach and wait
        lda #<RTISTUB
        sta VDSLST
        lda #>RTISTUB
        sta VDSLST+1
        lda #7
        ldx #>XITVBV
        ldy #<XITVBV
        jsr SETVBV
        lda #0
        sta AUDC1
        sta AUDC2
        sta AUDC3
        sta AUDC4
        sta AUDCTL
        ldx STEREO
        beq @pm
        sta AUDC1+P2
        sta AUDC2+P2
        sta AUDC3+P2
        sta AUDC4+P2
        sta AUDCTL+P2
@pm:    sta PARKREQ
        sei
        lda POKMSK
        ora #$C0
        sta POKMSK
        sta IRQEN
        cli
        jmp TRAMP

.ifdef MEASURE
measure_dump:
        ldx #$10                ; IOCB 1: OPEN "H1:M.BIN" for writing
        lda #3
        sta $0342,x
        lda #<@name
        sta $0344,x
        lda #>@name
        sta $0345,x
        lda #8
        sta $034A,x
        lda #0
        sta $034B,x
        jsr $E456
        ldx #$10                ; PUT $0D00 bytes from $0000
        lda #11
        sta $0342,x
        lda #0
        sta $0344,x
        sta $0345,x
        sta $0348,x
        lda #$0D
        sta $0349,x
        jsr $E456
        ldx #$10
        lda #12                 ; CLOSE
        sta $0342,x
        jsr $E456
@h:     jmp @h
@name:  .byte "H1:M.BIN",$9B
.endif

wait_frame:
        lda RTCLOK+2
        sta PT1
@w:     lda RTCLOK+2
        cmp PT1
        beq @w
        rts

; ---------------------------------------------------------------------------
; VBI: run the song, then the same engine chain the synth uses
vbi:
        inc FRAME
.ifdef DISK
        lda LOADING
        beq @go
        jmp XITVBV
@go:
.endif
        lda #0
        sta ATRACT
        sta dlin
        jsr seq_step
        jsr synth
        lda #0
        sta POLY4B
        ldx #VBS
        jsr lv_step
        ldx #0
        jsr lv_step
        lda v3on                ; voice 4 owns POKEY1 ch3 once its song uses
        beq @nv                 ;  it (it overrides the lead's layer there)
        ldx #V3X
        ldy #$04
        lda #0
        jsr lv_go
@nv:    jsr drum_step
        jsr pokey_out
        jmp XITVBV

; ---- the sequencer: delta-timed events straight out of the song bank ------
seq_step:
        lda PLAYING
        beq seq_rts
        lda PAUSED
        bne seq_rts
.ifdef JAM
        jsr jam_vbi_ok          ; stall rather than read past the composer
        bcc seq_rts
.endif
        inc SPOS
        bne @s
        inc SPOS+1
@s:     dec SECTMR
        bne @w
        lda #60
        sta SECTMR
        inc SECS
@w:     lda DWAIT
        ora DWAIT+1
        beq do_events
        lda DWAIT
        bne @d
        dec DWAIT+1
@d:     dec DWAIT
        lda DWAIT
        ora DWAIT+1
        beq do_events
seq_rts:
        rts

do_events:
        lda #0
        sta ENDF
ev_loop:
        ldy #0                  ; command byte: op<<4 | track
        lda (VP),y
        sta vt0
        jsr sq_adv
        lda vt0
        lsr a
        lsr a
        lsr a
        lsr a
        sta vt1                 ; op
        cmp #14
        bcs @big
        asl a                   ; index = op*4 + track
        asl a
        sta vt2
        lda vt0
        and #3
        clc
        adc vt2
        tax
        lda mapt,x
        sta vt2                 ; the Atari command ($FF = not in this mode)
        lda vt1
        cmp #1                  ; ops 0 2 3 4 carry an argument
        beq @noarg
        ldy #0
        lda (VP),y
        sta vt3
        jsr sq_adv
        jmp @go
@noarg: lda #0
        sta vt3
        beq @go
@big:   sec                     ; 14 ALLOFF -> 12, 15 END -> 13
        sbc #2
        sta vt2
        lda #0
        sta vt3
@go:    ldx vt2
        cpx #SCMDN
        bcs @next               ; dropped in this mode
.ifdef JAM
        jsr jam_mute            ; a muted voice's notes are skipped
        bcs @next
.endif
        inc SEVN
        lda cmd_hi,x
        pha
        lda cmd_lo,x
        pha
        lda vt3                 ; A = argument
        rts                     ; ... lands in the handler, which returns here
@next:  jmp seq_next

sq_adv:                         ; VP += 1 (mirrored for peeking; keeps A)
        pha
        inc VP
        bne @h
        inc VP+1
.ifdef JAM
        lda VP+1                ; the event ring wraps
        cmp #>(JRING+JRINGSZ)
        bne @h
        lda #>JRING
        sta VP+1
.endif
@h:     lda VP
        sta SPTR
        lda VP+1
        sta SPTR+1
        pla
        rts

sq_delta:                       ; DWAIT = next delta (255 = keep adding)
        lda #0
        sta DWAIT
        sta DWAIT+1
@rd:    ldy #0
        lda (VP),y
        jsr sq_adv
        cmp #255
        bne @add
        clc
        lda DWAIT
        adc #255
        sta DWAIT
        bcc @rd
        inc DWAIT+1
        bne @rd
@add:   clc
        adc DWAIT
        sta DWAIT
        bcc @x
        inc DWAIT+1
@x:     rts

; ---- stream command handlers (A = argument) -------------------------------
seq_next_j:
        jmp seq_next
cm_non: sta NOTE                ; 0: lead note on
        lda #1
        sta GATE
        jsr note_start
        jmp seq_next
cm_nof: lda #0                  ; 1: lead note off
        sta GATE
        lda ESTATE
        beq seq_next_j
        lda #4
        sta ESTATE
        jmp seq_next
cm_v0n: ldx #0                  ; 2: voice 0 note on
        jsr lv_on
        jmp seq_next
cm_v0f: ldx #0                  ; 3
        jsr lv_off
        jmp seq_next
cm_v1n: ldx #VBS                ; 4: voice 1 note on
        jsr lv_on
        jmp seq_next
cm_v1f: ldx #VBS                ; 5
        jsr lv_off
        jmp seq_next
cm_dr0: sta LASTDL              ; 6: drum, POKEY1 ch4
        tax
        lda #8
        sta DRT,x
        txa
        ldx #0
        jsr drum_start
        lda STEREO              ; stereo, and the song never uses the second
        beq @x                  ;  drum channel: mirror the hit onto it, so
        lda dr2used             ;  the drums come from both speakers
        bne @x
        lda LASTDL
        sta LASTDR
        ldx #8
        jsr drum_start
        dec DRUMCNT             ; (one hit, whatever it sounds on)
@x:     jmp seq_next
cm_dr1: sta LASTDR              ; 7: drum, POKEY2 ch4
        ldx #1                  ; the song has its own second drum part:
        stx dr2used             ;  no more mirroring
        tax
        lda #8
        sta DRT,x
        txa
        ldx #8
        jsr drum_start
        jmp seq_next
cm_pre: sta PRESREQ             ; 8: lead instrument (main thread loads it)
        jmp seq_next
cm_p0:  ldx #0                  ; 9
        jsr lv_load
        jmp seq_next
cm_p1:  ldx #VBS                ; 10
        jsr lv_load
        jmp seq_next
cm_par: tax                     ; 11: param<<4 | value
        and #$0F
        sta vt3
        txa
        lsr a
        lsr a
        lsr a
        lsr a
        cmp #NPARAM
        bcc @ok
        jmp seq_next
@ok:    tax
        lda vt3
        sta PARAMS,x
        jmp seq_next
cm_off: jsr hush                ; 12
        jmp seq_next
cm_v3n: ldx #V3X                ; 14: voice 4 note on (POKEY1 ch3)
        jsr lv_on
        inc n4cnt
        lda #1
        sta v3on
        jmp seq_next
cm_v3f: ldx #V3X                ; 15
        jsr lv_off
        jmp seq_next
cm_p3:  ldx #V3X                ; 16: voice 4's instrument
        jsr lv_load
        jmp seq_next
.segment "CODE2"                ; (MAIN is full in the disk build)
cm_lv0: sta MIXL                ; 17-20 (psq op 5 LEVEL): a track's volume cap
        jmp seq_next
cm_lv1: sta MIXV
        jmp seq_next
cm_lv2: sta MIXV+1
        jmp seq_next
cm_lv3: sta MIXV+2
        jmp seq_next
.segment "CODE"
cm_end: lda #0                  ; 13: end of song -> the main thread advances
        sta PLAYING
        lda #1
        sta ENDF
        sta PENDN
        jsr hush
        jmp seq_next
seq_next:                       ; one event done: take the next delta
.ifdef JAM
        jsr jam_empty
        bcc @r
        rts
@r:
.endif
        jsr sq_delta
        lda ENDF
        bne @x
        lda DWAIT
        ora DWAIT+1
        bne @x
        jmp ev_loop
@x:     rts

cmd_lo:     .byte <(cm_non-1),<(cm_nof-1),<(cm_v0n-1),<(cm_v0f-1)
            .byte <(cm_v1n-1),<(cm_v1f-1),<(cm_dr0-1),<(cm_dr1-1)
            .byte <(cm_pre-1),<(cm_p0-1),<(cm_p1-1),<(cm_par-1)
            .byte <(cm_off-1),<(cm_end-1),<(cm_v3n-1),<(cm_v3f-1),<(cm_p3-1)
            .byte <(cm_lv0-1),<(cm_lv1-1),<(cm_lv2-1),<(cm_lv3-1)
cmd_hi:     .byte >(cm_non-1),>(cm_nof-1),>(cm_v0n-1),>(cm_v0f-1)
            .byte >(cm_v1n-1),>(cm_v1f-1),>(cm_dr0-1),>(cm_dr1-1)
            .byte >(cm_pre-1),>(cm_p0-1),>(cm_p1-1),>(cm_par-1)
            .byte >(cm_off-1),>(cm_end-1),>(cm_v3n-1),>(cm_v3f-1),>(cm_p3-1)
            .byte >(cm_lv0-1),>(cm_lv1-1),>(cm_lv2-1),>(cm_lv3-1)
SCMDN = 21

hush:                           ; every voice silent, envelopes reset
        lda #0
        sta GATE
        sta ESTATE
        sta VOLHI
        sta V_EST
        sta V_VHI
        sta V_EST+VBS
        sta V_VHI+VBS
        sta V_EST+V3X
        sta V_VHI+V3X
        sta D_TMR
        sta D_TMR+8
        lda #$FF
        sta LITKEY
        rts

; ---------------------------------------------------------------------------
; songs: catalog entry = title(16) ptr(2) progress-step(2) min sec mode spare
song_load:                      ; A = song index
        cmp NSONG
        bcc @ok
        rts                     ; no such song (or an empty catalog)
@ok:    sta SONGN
.ifdef MEASURE
        ldx RTCLOK+1            ; the machine's clock when this song began
        stx $06C0
        ldx RTCLOK+2
        stx $06C1
        ldx DRAWN
        stx $06C2
.endif
        lda #0
        sta PLAYING
        sta PAUSED
        sta SEVN
        sta SPOS
        sta SPOS+1
        sta SECS
        sta MINS
        sta pcell
        sta pacc
        sta pacc+1
        sta lastsp
        sta ENDF
        sta PENDN
        lda #60
        sta SECTMR
        ldx #3                  ; every song starts at full level
        lda #0
@mx:    sta MIXL,x
        dex
        bpl @mx
        jsr hush
        jsr clear_meters
        lda SONGN               ; PSCR = its catalog entry
        jsr cat_ptr
        lda CPTR
        sta PSCR
        lda CPTR+1
        sta PSCR+1
        ldy #0                  ; title -> row 1 (mode 7, COLPF2)
@t:     lda (PSCR),y
        ora #$80
        sta SCREEN+40+2,y
        iny
        cpy #16
        bne @t
        ldy #23                 ; disk: sectors to read
        lda (PSCR),y
        sta dcnt
        ldy #16                 ; the event stream (disk: its first sector)
        lda (PSCR),y
        sta dsec
        iny
        lda (PSCR),y
        sta dsec+1
        iny
        lda (PSCR),y
        sta pstep
        iny
        lda (PSCR),y
        sta pstep+1
        iny
        lda (PSCR),y
        sta totm
        iny
        lda (PSCR),y
        sta tots
        iny
        lda (PSCR),y
        sta SMODE
.ifdef DISK
        jsr load_song
        bcc @in
        rts                     ; disk error: it says so on the status row
@in:    lda #<SONGS
        sta dsec
        lda #>SONGS
        sta dsec+1
.endif
.ifdef JAM
        lda SONGN               ; POKEY JAM: compose into the ring instead
        jsr jam_start
.else
        lda dsec
        sta VP
        sta SPTR
        lda dsec+1
        sta VP+1
        sta SPTR+1
.endif
        lda STEREO              ; pick the command map for this machine
        beq @mono
        ldy #23
@cs:    lda map_st,y
        sta mapt,y
        dey
        bpl @cs
        bmi @st
@mono:  ldy #23
@cm:    lda map_mono,y
        sta mapt,y
        dey
        bpl @cm
@st:    lda #0                  ; a fresh, quiet band
        jsr set_preset
        ldx #0
        lda #0
        jsr lv_load
        ldx #VBS
        lda #0
        jsr lv_load
        ldx #V3X
        lda #0
        jsr lv_load
        lda #0                  ; the layer keeps ch3 until track 3 plays
        sta v3on
        sta dr2used             ; drum channel 2 mirrors channel 1 until used
        lda #1                  ; POKEY2 carries its own voices (no mirror)
        sta STREAMON
        jsr sq_delta            ; the stream's first gap
        jsr draw_songno
        jsr force_redraw
        lda #1
        sta PLAYING
        rts

next_song:
        ldx SONGN
        inx
        cpx NSONG
        bcc @go
        ldx #0
@go:    txa
        jmp song_load

prev_song:
        ldx SONGN
        bne @d
        ldx NSONG
@d:     dex
        txa
        jmp song_load

set_preset:                     ; A = preset 0-9 -> the lead's live params
        sta PRESET
        tax
        lda pbase,x
        tay
        ldx #0
@c:     lda live,y
        sta PARAMS,x
        iny
        inx
        cpx #NPARAM
        bne @c
        rts

; ---------------------------------------------------------------------------
read_keys:
        lda SKSTAT
        and #$04
        bne @up
        lda KBCODE
        and #$3F
        cmp KHELD
        beq @held
        sta KHELD
        lda #0
        sta khold
        lda KHELD
        jmp key_cmd
@held:  ldx liston              ; in the list a held key repeats
        beq @x
        inc khold
        lda khold
        cmp #24
        bcc @x
        lda #20                 ; ... every 4 frames after 24
        sta khold
        lda KHELD
        jmp key_cmd
@up:    lda #$FF
        sta KHELD
@x:     rts

key_cmd:                        ; A = a new key press
        ldx liston
        beq @panel
        jmp list_key
@panel:
.ifdef JAM
        cmp #K_R                ; R: RANDOM on/off (the music goes on)
        bne @nr
        jmp jam_rtoggle
@nr:
.endif
        cmp #K_L
        beq @list
        cmp #K_TAB
        beq @list
        cmp #K_SPACE
        beq @pause
        cmp #K_GT
        beq @next
        cmp #K_LT
        beq @prev
        cmp #K_RET
        beq @again
        cmp #K_ESC
        beq @stop
.ifdef JAM
        ldx #9                  ; 1-9, 0 pick a style
.else
        ldx #8                  ; 1-9 pick a song
.endif
@d:     cmp numkeys,x
        beq @pick
        dex
        bpl @d
        rts
@pick:
.ifdef JAM
        jmp jam_key             ; 1-6: voices on/off
.else
        cpx NSONG
        bcs @r
        txa
        jmp song_load
.endif
@next:  jmp next_song
@prev:  jmp prev_song
@list:  jmp list_open
@again: lda SONGN
        jmp song_load
@stop:  lda #0
        sta PLAYING
        sta PENDN
        jsr hush
        jmp clear_meters
@pause: lda PAUSED
        eor #1
        sta PAUSED
        beq @r
        jsr hush
        jmp clear_meters
@r:     rts

; ===========================================================================
; the panel
; ---------------------------------------------------------------------------
draw_all:
        jsr draw_bars
        jsr draw_leds
.ifndef JAM
        jsr draw_scope
.endif
        jsr draw_voices
        jsr draw_prog
        jmp draw_time

; ---- six voice-pressure meters, 9 rows tall, with peak hold ---------------
draw_bars:                      ; half the meters each frame (30 Hz each)
        lda FRAME
        and #1
        tax
@bar:   stx PCOL
        ldy vusrc,x
        cpy #$FF
        beq @dead
        lda SH,y
        and #$0F
        tay
        lda vulut,y
        jmp @lvl
@dead:  lda #0
@lvl:   sta PLVL
        ldx PCOL
        cmp vupk,x
        bcc @fall
        sta vupk,x              ; new peak: hold it for a moment
        lda #20
        sta vufal,x
        jmp @draw
@fall:  lda vufal,x
        beq @slip
        dec vufal,x
        jmp @draw
@slip:  lda vupk,x
        beq @draw
        dec vupk,x
@draw:  lda PLVL                ; level and peak as last drawn: nothing to do
        cmp lastlv,x
        bne @chg
        lda vupk,x
        cmp lastpk,x
        bne @chg
        jmp @nextb
@chg:   lda PLVL
        sta lastlv,x
        lda vupk,x
        sta lastpk,x
        lda bar9,x              ; this meter's slice of the glyph cache
        sta bi
        lda barcol,x            ; bottom cell of this meter
        clc
        adc #<(SCREEN+13*40)
        sta PSCR
        lda #0
        adc #>(SCREEN+13*40)
        sta PSCR+1
        lda vupk,x
        sta PPK
        lda #0
        sta PT3
@seg:   lda PLVL                ; two levels per row: full, half, empty
        cmp #2
        bcc @one
        sec
        sbc #2
        sta PLVL
        lda #G_FULL
        jmp @put
@one:   cmp #1
        bne @none
        lda #0
        sta PLVL
        lda #G_HALF
        jmp @put
@none:  lda PPK
        beq @off
        sec
        sbc #1
        lsr a
        cmp PT3
        bne @off
        lda #G_PEAK
        jmp @put
@off:   lda #G_DARK
@put:   ldx bi                  ; unchanged since the last frame: skip it
        cmp barg,x
        beq @same
        sta barg,x
        ldy #4
@st:    sta (PSCR),y
        dey
        bpl @st
@same:  inc bi
        sec
        lda PSCR
        sbc #40
        sta PSCR
        bcs @nb
        dec PSCR+1
@nb:    inc PT3
        lda PT3
        cmp #BARROWS
        bne @seg
@nextb: ldx PCOL
        inx
        inx
        cpx #NBAR
        bcs @done
        jmp @bar
@done:  rts

clear_meters:
        ldx #NBAR-1
        lda #0
@z:     sta vupk,x
        sta vufal,x
        dex
        bpl @z
        rts

; ---- eight percussion LEDs, lit for a few frames per hit ------------------
draw_leds:
        ldx #7
@p:     lda DRT,x
        beq @off
        dec DRT,x
        lda #G_ON
        jmp @put
@off:   lda #G_OFF
@put:   sta PT1
        lda ledcol,x
        clc
        adc #<(SCREEN+18*40)
        sta PSCR
        lda #0
        adc #>(SCREEN+18*40)
        sta PSCR+1
        lda PT1
        ldy #3
@s:     sta (PSCR),y
        dey
        bpl @s
        dex
        bpl @p
        rts

; ---- what each voice is playing: note (row 15) and instrument (row 16) ----
draw_voices:
        lda ESTATE              ; 0 lead
        beq @b0
        lda NOTE
        jmp @s0
@b0:    lda #$FF
@s0:    sta ncode+0
        lda STEREO              ; 1 layer (mono: the bass voice lives here;
        beq @m1                 ;  stereo: voice 4 once its song uses it)
        lda v3on
        beq @b1
        lda V_EST+V3X
        beq @b1
        lda V_NOTE+V3X
        jmp @s1
@m1:    lda V_EST
        beq @b1
        lda V_NOTE
        jmp @s1
@b1:    lda #$FF
@s1:    sta ncode+1
        lda D_TMR               ; 2 drums, left
        beq @b2
        lda LASTDL
        ora #$80
        jmp @s2
@b2:    lda #$FF
@s2:    sta ncode+2
        lda STEREO
        beq @b3
        lda V_EST
        beq @b3
        lda V_NOTE
        jmp @s3
@b3:    lda #$FF
@s3:    sta ncode+3
        lda STEREO
        beq @b4
        lda V_EST+VBS
        beq @b4
        lda V_NOTE+VBS
        jmp @s4
@b4:    lda #$FF
@s4:    sta ncode+4
        lda STEREO
        beq @b5
        lda D_TMR+8
        beq @b5
        lda LASTDR
        ora #$80
        jmp @s5
@b5:    lda #$FF
@s5:    sta ncode+5
        lda PRESET              ; instruments
        sta pcode+0
        lda #$FF
        sta pcode+2
        sta pcode+5
        lda STEREO
        bne @ps
        lda V_PRE
        sta pcode+1
        lda #$FF
        sta pcode+3
        sta pcode+4
        jmp @cmp
@ps:    lda #$FF
        ldx v3on
        beq @p1
        lda V_PRE+V3X
@p1:    sta pcode+1
        lda V_PRE
        sta pcode+3
        lda V_PRE+VBS
        sta pcode+4
@cmp:   lda STEREO              ; column 1's label follows what plays there
        beq @lb
        lda v3on
        cmp lastv3
        beq @lb
        sta lastv3
        lda #<text_lyr
        ldx #>text_lyr
        ldy v3on
        beq @pl
        lda #<text_v4
        ldx #>text_v4
@pl:    jsr print_list
@lb:    ldx #NBAR-1
@c:     stx PCOL
        lda ncode,x
        cmp lastn,x
        beq @p
        sta lastn,x
        jsr put_voice
@p:     ldx PCOL
        lda pcode,x
        cmp lastp,x
        beq @n
        sta lastp,x
        jsr put_inst
@n:     ldx PCOL
        dex
        bpl @c
        rts

put_voice:                      ; X = column, A = $FF none / $80|drum / note
        pha
        lda barcol,x
        clc
        adc #<(SCREEN+15*40)
        sta PSCR
        lda #0
        adc #>(SCREEN+15*40)
        sta PSCR+1
        lda #0                  ; clear the field first
        ldy #4
@b:     sta (PSCR),y
        dey
        bpl @b
        pla
        cmp #$FF
        beq @dash
        cmp #$80
        bcs @drum
        ldx #1                  ; note: name + octave digit
@dv:    cmp #12
        bcc @dd
        sec
        sbc #12
        inx
        bne @dv
@dd:    asl a
        tay
        lda notenames,y
        sta PT2
        lda notenames+1,y
        sta PT3
        ldy #0
        lda PT2
        sta (PSCR),y
        iny
        lda PT3
        beq @oct                ; natural: no sharp sign, octave moves left
        sta (PSCR),y
        iny
@oct:   txa
        ora #$10
        sta (PSCR),y
        rts
@dash:  lda #'-'-32
        ldy #1
        sta (PSCR),y
        rts
@drum:  and #7                  ; drum name, 4 characters
        sta PT1
        asl a
        asl a
        tax
        ldy #0
@dn:    lda drumnames,x
        sta (PSCR),y
        inx
        iny
        cpy #4
        bne @dn
        rts

put_inst:                       ; X = column, A = $FF none / preset 0-9
        pha
        lda barcol,x
        clc
        adc #<(SCREEN+16*40)
        sta PSCR
        lda #0
        adc #>(SCREEN+16*40)
        sta PSCR+1
        lda #0
        ldy #4
@b:     sta (PSCR),y
        dey
        bpl @b
        pla
        cmp #$FF
        beq @x
        sta PT1                 ; name = presetnames + p*5
        asl a
        asl a
        clc
        adc PT1
        tax
        ldy #0
@n:     lda presetnames,x
        sta (PSCR),y
        inx
        iny
        cpy #5
        bne @n
@x:     rts

; ---- the oscilloscope ----------------------------------------------------
; POKEY's output can't be read back, so the trace is rebuilt from what the
; voices are doing: each contributes a wave at its pitch (sc_step by note)
; and loudness (its AUDC volume), a sine for pure tones and a square for the
; poly waves, and a drum adds noise. 80 samples, drawn into the hidden
; buffer over five frames (12 traces a second: four-part songs with busy
; drums dropped frames at 15).
.macro SCLEAR buf
        .local @c
        ldx #39
@c:     lda sc_vcol,x           ; even lines: vertical graticule dots
        .repeat 11, I
        sta buf+(I*2+2)*40,x
        .endrepeat
        lda #0                  ; odd lines: empty
        .repeat 11, I
        sta buf+(I*2+1)*40,x
        .endrepeat
        lda sc_hrow,x           ; top, centre and bottom lines
        sta buf+0*40,x
        sta buf+12*40,x
        sta buf+23*40,x
        dex
        bpl @c
.endmacro

.ifndef JAM                     ; POKEY JAM has no oscilloscope
scope_init:
        lda #>SCOPEB
        sta scback
        lda #0
        sta scstage
        jsr sc_clear
        lda #>SCOPEA
        sta scback
        jsr sc_clear            ; A is shown, so B is drawn first
        lda #>SCOPEB
        sta scback
        rts

sc_clear:
        lda scback
        cmp #>SCOPEA
        bne @b
        SCLEAR SCOPEA
        rts
@b:     SCLEAR SCOPEB
        rts

draw_scope:                     ; 5 frames a trace: clear, then 4 quarters
        lda scstage
        bne @run
        jsr sc_clear
        jsr sc_setup
        lda #0
        sta scs
        inc scstage
        rts
@run:   tax
        lda sc_ends-1,x
        sta scend
        jsr sc_run
        inc scstage
        lda scstage
        cmp #5
        bne @x
        lda scback              ; show it, draw into the other one next
        sta scope_lms+2
        eor #(>SCOPEA ^ >SCOPEB)
        sta scback
        jsr sc_flip
        lda #0
        sta scstage
@x:     rts

sc_ends:    .byte 20, 40, 60, SCN

; what each voice is doing -> level offsets, steps, shapes (self-modified)
sc_setup:
        lda #0
        sta PT4
        lda SH+3                ; 0: the lead
        ldx NOTEIDX
        ldy P_WAVE
        jsr sc_voice
        inc PT4
        lda STEREO
        beq @mono
        lda SH+3+P2             ; 1: track 1 (bass), POKEY2 pair
        ldx V_IDX
        ldy V_PAR
        jsr sc_voice
        inc PT4
        lda SH+5+P2             ; 2: track 2 (harmony), POKEY2 ch3
        ldx V_IDX+VBS
        ldy V_PAR+VBS
        jsr sc_voice
        inc PT4
        lda v3on                ; 3: voice 4, or the lead's layer
        beq @lay
        lda SH+5
        ldx V_IDX+V3X
        ldy V_PAR+V3X
        jsr sc_voice
        jmp @noise
@lay:   lda SH+5
        ldx NOTEIDX
        ldy P_WAVE
        jsr sc_voice
        jmp @noise
@mono:  ldx V_IDX               ; 1: ch3, the loop voice or the lead's layer
        lda V_EST
        bne @mv
        ldx NOTEIDX
@mv:    lda SH+5
        ldy V_PAR
        jsr sc_voice
        inc PT4
        lda #0                  ; 2, 3: nothing on a mono machine
        tax
        tay
        jsr sc_voice
        inc PT4
        lda #0
        tax
        tay
        jsr sc_voice
@noise: lda SH+7                ; drums: the louder channel's noise
        and #$0F
        sta PT3
        lda STEREO
        beq @n1
        lda SH+7+P2
        and #$0F
        cmp PT3
        bcc @n1
        sta PT3
@n1:    ldx PT3
        lda sc_noise,x
        sta scnm
        lsr a
        sta scnh
        lda scshp               ; shapes go straight into the sample loop
        sta sm0+2
        lda scshp+1
        sta sm1+2
        lda scshp+2
        sta sm2+2
        lda scshp+3
        sta sm3+2
        ldx #3
@p:     lda scpb,x              ; start where the last trace started, then
        sta scph,x              ;  drift the start so the wave travels
        lda scst,x
        asl a
        asl a
        clc
        adc scst,x
        clc
        adc scpb,x
        sta scpb,x
        dex
        bpl @p
        ldx #3                  ; silent voices: jump over their block
@k:     lda scof,x
        bne @on
        lda #$4C                ; JMP next block
        sta PT1
        lda scb_nlo,x
        sta PT2
        lda scb_nhi,x
        jmp @put
@on:    lda #$AD                ; LDA scph+k
        sta PT1
        txa
        clc
        adc #<scph
        sta PT2
        lda #>scph
        adc #0
@put:   sta PT3
        lda scb_lo,x
        sta PSCR
        lda scb_hi,x
        sta PSCR+1
        ldy #0
        lda PT1
        sta (PSCR),y
        iny
        lda PT2
        sta (PSCR),y
        iny
        lda PT3
        sta (PSCR),y
        dex
        bpl @k
        lda #$FF                ; no previous sample yet
        sta scy
        rts

scb_lo:     .byte <scb0,<scb1,<scb2,<scb3
scb_hi:     .byte >scb0,>scb1,>scb2,>scb3
scb_nlo:    .byte <scb1,<scb2,<scb3,<scb4
scb_nhi:    .byte >scb1,>scb2,>scb3,>scb4

sc_voice:                       ; A = AUDC image, X = note, Y = wave, PT4 = voice
        and #$0F
        sty PT3
        tay
        lda sc_lvl,y
        asl a                   ; level * 64 = its quarter of the table
        asl a
        asl a
        asl a
        asl a
        asl a
        ldy PT4
        sta scof,y
        txa
        and #$7F
        tax
        lda sc_step,x
        sta scst,y
        lda PT3                 ; pure tone -> sine, poly waves -> square
        beq @sine
        lda #>sc_square
        bne @s
@sine:  lda #>sc_sine
@s:     sta scshp,y
        rts

sc_run:                         ; samples scs .. scend-1
sc_samp:
        lda #0
        sta scsum
; each voice block starts with "lda scph+k"; sc_setup turns that into a
; "jmp" to the next block when the voice is silent
scb0:   lda scph
        clc
        adc scst
        sta scph
        lsr a
        lsr a
        ora scof
        tax
sm0:    lda sc_sine,x
        clc
        adc scsum
        sta scsum
scb1:   lda scph+1
        clc
        adc scst+1
        sta scph+1
        lsr a
        lsr a
        ora scof+1
        tax
sm1:    lda sc_sine,x
        clc
        adc scsum
        sta scsum
scb2:   lda scph+2
        clc
        adc scst+2
        sta scph+2
        lsr a
        lsr a
        ora scof+2
        tax
sm2:    lda sc_sine,x
        clc
        adc scsum
        sta scsum
scb3:   lda scph+3
        clc
        adc scst+3
        sta scph+3
        lsr a
        lsr a
        ora scof+3
        tax
sm3:    lda sc_sine,x
        clc
        adc scsum
        sta scsum
scb4:
        lda scnm
        beq @nn
        lda RANDOM
        and scnm
        sec
        sbc scnh
        clc
        adc scsum
        sta scsum
@nn:    lda #12                 ; row = 12 - sum, clipped to the screen
        sec
        sbc scsum
        bmi @top
        cmp #24
        bcc @y
        lda #23
        bne @y
@top:   lda #0
@y:     jsr sc_plot
        inc scs
        lda scs
        cmp scend
        beq @x
        jmp sc_samp
@x:     rts

sc_plot:                        ; A = row: a vertical run from the last row
        ldx scy
        cpx #$FF
        bne @h
        tax                     ; the first sample is a single dot
@h:     stx PT1
        sta scy
        cmp PT1
        bcs @dn
        sta sclo
        lda PT1
        sta schi
        jmp @go
@dn:    sta schi
        lda PT1
        sta sclo
@go:    lda scs
        lsr a
        tay                     ; byte column (2 samples a byte)
        lda #$A0                ; PF1 pixel pair, left or right half
        bcc @m
        lda #$0A
@m:     sta PT2
        lda schi
        sec
        sbc sclo
        cmp #2
        bcs @long
        ldx sclo                ; 1-2 rows (most samples): direct
        lda sc_m40lo,x
        sta PSCR
        lda sc_m40hi,x
        ora scback
        sta PSCR+1
        lda (PSCR),y
        ora PT2
        sta (PSCR),y
        lda schi
        cmp sclo
        beq @x
        tya
        clc
        adc #40
        tay
        lda (PSCR),y
        ora PT2
        sta (PSCR),y
@x:     rts
@long:  lda sclo                ; enter the column routine at row lo ...
        asl a
        asl a
        asl a
        clc
        adc #<sc_col
        sta SCV
        lda #>sc_col
        adc #0
        sta SCV+1
        lda schi                ; ... and stop it after row hi
        clc
        adc #1
        asl a
        asl a
        asl a
        tax
        lda sc_col,x
        sta scmask
        lda #$60                ; RTS
        sta sc_col,x
        jsr @run
        lda scmask
        sta sc_col,x
        rts
@run:   jmp (SCV)

; one block per scope row: OR the trace pixels into that row at column Y.
; The operands address the buffer being drawn; draw_scope flips them
; between SCOPEA and SCOPEB (they differ in bit 2 of the high byte).
sc_col:
        .repeat 24, K
        lda SCOPEB+K*40,y
        ora PT2
        sta SCOPEB+K*40,y
        .endrepeat
        rts

sc_flip:
        ldx #0
@t:     lda sc_col+2,x
        eor #>(SCOPEA ^ SCOPEB)
        sta sc_col+2,x
        lda sc_col+7,x
        eor #>(SCOPEA ^ SCOPEB)
        sta sc_col+7,x
        txa
        clc
        adc #8
        tax
        cpx #24*8
        bne @t
        rts
.endif

; ---- progress bar and clock ----------------------------------------------
draw_prog:                      ; follows the song's own clock (SPOS), so
        lda PLAYING             ;  a dropped panel frame can't slow it
        beq @x
        sec
        lda SPOS
        sbc lastsp
        tax
        lda SPOS
        sta lastsp
        txa
        clc
        adc pacc
        sta pacc
        bcc @chk
        inc pacc+1
@chk:   lda pacc+1
        cmp pstep+1
        bcc @x
        bne @adv
        lda pacc
        cmp pstep
        bcc @x
@adv:   sec
        lda pacc
        sbc pstep
        sta pacc
        lda pacc+1
        sbc pstep+1
        sta pacc+1
        lda pcell
        cmp #40
        bcs @chk
        ldx pcell
        lda #G_ON
        sta SCREEN+3*40,x
        inc pcell
        jmp @chk
@x:     rts

draw_time:
        lda SECS
        cmp lsecs
        beq @x
        sta lsecs
        cmp #60
        bcc @ok
        lda #0
        sta SECS
        sta lsecs
        inc MINS
@ok:    lda #<(SCREEN+2*40+28)
        sta PSCR
        lda #>(SCREEN+2*40+28)
        sta PSCR+1
        lda MINS
        ldy #0
        jsr put_2dig
        lda SECS
        ldy #3
        jsr put_2dig
        lda totm
        ldy #6
        jsr put_2dig
        lda tots
        ldy #9
        jsr put_2dig
@x:     rts

put_2dig:                       ; A = 0-99 -> two digits at (PSCR),y
        ldx #0
@t:     cmp #10
        bcc @d
        sec
        sbc #10
        inx
        bne @t
@d:     sta PT1
        txa
        ora #$10
        sta (PSCR),y
        iny
        lda PT1
        ora #$10
        sta (PSCR),y
        rts

draw_songno:
        lda #<(SCREEN+2*40+5)
        sta PSCR
        lda #>(SCREEN+2*40+5)
        sta PSCR+1
        lda SONGN
        clc
        adc #1
        ldy #0
        jsr put_2dig
        lda NSONG
        ldy #6
        jsr put_2dig
        rts

force_redraw:                   ; make the next draw_voices write every field
        ldx #NBAR-1
        lda #$FE
@f:     sta lastn,x
        sta lastp,x
        dex
        bpl @f
        lda #$FF
        sta lsecs
        ldx #39                 ; progress bar and trace back to empty
        lda #G_OFF
@p:     sta SCREEN+3*40,x
        dex
        bpl @p
        rts

.ifdef DISK
; ---------------------------------------------------------------------------
; disk: read dcnt sectors from dsec into dbuf through the OS (DSKINV).
; C set = a sector failed 4 times. SIO drives POKEY1 ch3/4, AUDCTL and SKCTL,
; so the VBI stays out (LOADING) and they're restored afterwards.
disk_read:
        lda #1
        sta LOADING
        lda #0
        sta AUDC1
        sta AUDC2
        sta AUDC3
        sta AUDC4
        ldx STEREO
        beq @sec
        sta AUDC1+P2
        sta AUDC2+P2
        sta AUDC3+P2
        sta AUDC4+P2
@sec:   lda #4
        sta dtry
@try:   lda #$31
        sta DDEVIC
        lda #1
        sta DUNIT
        lda #$52
        sta DCOMND
        lda dbuf
        sta DBUFLO
        lda dbuf+1
        sta DBUFHI
        lda dsec
        sta DAUX1
        lda dsec+1
        sta DAUX2
        jsr DSKINV
        lda DSTATS
        bpl @ok
        dec dtry
        bne @try
        jsr snd_back
        sec
        rts
@ok:    clc
        lda dbuf
        adc #128
        sta dbuf
        bcc @s
        inc dbuf+1
@s:     inc dsec
        bne @c
        inc dsec+1
@c:     jsr load_tick
        dec dcnt
        bne @sec
        jsr snd_back
        clc
        rts

snd_back:                       ; POKEY back the way the engine wants it
        lda #$50
        sta AUDCTL
        lda #3
        sta SKCTL
        lda #0
        sta LOADING
        rts

read_catalog:
        lda #<CAT
        sta dbuf
        lda #>CAT
        sta dbuf+1
        lda #CATSEC
        sta dsec
        lda #0
        sta dsec+1
        lda #CATN
        sta dcnt
        ldx #19
@tt:    lda m7_list,x           ; "SONG LIST" / "POKEY PLAYER"
        sta LSCR+20,x
        lda m7_foot,x
        sta LSCR+60,x
        dex
        bpl @tt
        jsr load_screen
        jsr disk_read
        php
        jsr load_hide
        plp
        bcc @x
        lda #0                  ; unreadable: no songs
        sta CAT
        lda #<text_err
        ldx #>text_err
        jsr print_list
@x:     rts

load_song:                      ; dsec/dcnt -> SONGS, behind the LOADING screen
        ldx #19                 ; title line: the song's name, centred
@t:     lda #0
        sta LSCR+20,x
        lda m7_song,x           ; footer: "SONG    OF"
        sta LSCR+60,x
        dex
        bpl @t
        ldx #15                 ; the title's length, trailing spaces off
@len:   lda SCREEN+40+2,x
        and #$3F
        bne @got
        dex
        bpl @len
@got:   inx
        stx PT1
        beq @nt
        lda #20
        sec
        sbc PT1
        lsr a
        tay                     ; centred
        ldx #0
@n:     lda SCREEN+40+2,x       ; (already in mode-7 pink)
        sta LSCR+20,y
        iny
        inx
        cpx PT1
        bne @n
@nt:
        lda #<(LSCR+60+8)
        sta PSCR
        lda #>(LSCR+60+8)
        sta PSCR+1
        lda SONGN
        clc
        adc #1
        ldy #0
        jsr put_2dig
        lda NSONG
        ldy #6
        jsr put_2dig
        ldx #7                  ; the digits in the footer's blue
@b:     lda LSCR+60+8,x
        cmp #$10
        bcc @nb
        ora #$40
        sta LSCR+60+8,x
@nb:    dex
        bpl @b
        jsr load_screen
        lda #<SONGS
        sta dbuf
        lda #>SONGS
        sta dbuf+1
        jsr disk_read
        php
        jsr load_hide
        plp
        bcs @err
        rts
@err:   lda #<text_err
        ldx #>text_err
        jsr print_list
        sec
        rts

load_screen:                    ; LOADING + empty bar, then show it (the caller
        ldx #19                 ;  has written the title and footer lines)
@t:     lda m7_load,x
        sta LSCR,x
        lda #G_HOLE|$40         ; empty cells, blue
        sta LSCR+40,x
        dex
        bpl @t
        lda #0
        sta lbacc
        sta lbcell
        lda dcnt
        sta lbtot
        lda #1
        sta lshow
        lda #<dlist_load
        sta SDLSTL
        lda #>dlist_load
        sta SDLSTL+1
        jmp wait_frame          ; on screen before SIO holds off the OS VBI

load_hide:
        lda #0
        sta lshow
        jsr scope_init          ; the loading screen used a scope buffer
        lda liston              ; back to whichever screen was up
        bne @l
        lda #<dlist
        sta SDLSTL
        lda #>dlist
        sta SDLSTL+1
        rts
@l:     lda #<dlist_list
        sta SDLSTL
        lda #>dlist_list
        sta SDLSTL+1
        rts

load_tick:                      ; a sector arrived: 20 cells over lbtot sectors
        lda lshow
        beq @x
        clc
        lda lbacc
        adc #20
        sta lbacc
@w:     lda lbacc
        cmp lbtot
        bcc @x
        sbc lbtot
        sta lbacc
        ldx lbcell
        cpx #20
        bcs @w
        lda #G_SOLID|$C0        ; filled, green
        sta LSCR+40,x
        inc lbcell
        jmp @w
@x:     rts
.endif

; ---------------------------------------------------------------------------
; DLI: one entry per colored band, stepped by dlin (reset in the VBI)
dli:
        pha
        txa
        pha
        ldx dlin
        lda dpf0,x
        sta WSYNC
        sta COLPF0
        lda dpf1,x
        sta COLPF1
        lda dpf2,x
        sta COLPF2
        inc dlin
        pla
        tax
        pla
        rti

; ---------------------------------------------------------------------------
init_chset:                     ; ROM font -> RAM, then the player's glyphs
        lda #$E0
        sta PT2
        lda #0
        sta PT1
        sta PSCR
        lda #>CHSET
        sta PSCR+1
        ldx #4
        ldy #0
@cp:    lda (PT1),y
        sta (PSCR),y
        iny
        bne @cp
        inc PT2
        inc PSCR+1
        dex
        bne @cp
        ldx #0
@gl:    stx PT3
        lda glyph_codes,x
        beq @x
        sta PSCR                ; PSCR = CHSET + code*8
        lda #0
        sta PSCR+1
        asl PSCR
        rol PSCR+1
        asl PSCR
        rol PSCR+1
        asl PSCR
        rol PSCR+1
        lda PSCR+1
        clc
        adc #>CHSET
        sta PSCR+1
        txa
        asl a
        asl a
        asl a
        tax
        ldy #0
@gb:    lda glyph_data,x
        sta (PSCR),y
        inx
        iny
        cpy #8
        bne @gb
        ldx PT3
        inx
        bne @gl
@x:     rts

cls:
        lda #<SCREEN
        sta PSCR
        lda #>SCREEN
        sta PSCR+1
        ldx #4
        lda #0
        tay
@c:     sta (PSCR),y
        iny
        bne @c
        inc PSCR+1
        dex
        bne @c
        rts

set_scr:                        ; Y = row, A = col -> PSCR
        clc
        adc rowlo,y
        sta PSCR
        lda rowhi,y
        adc #0
        sta PSCR+1
        rts

asc2int:                        ; ATASCII -> screen code
        cmp #32
        bcc @lo
        cmp #96
        bcs @x
        sbc #31
        rts
@lo:    adc #64
@x:     rts

print_list:                     ; records of row, col, attr, text, 0; $FF ends
        sta PT1
        stx PT2
@rec:   ldy #0
        lda (PT1),y
        cmp #$FF
        beq @end
        pha
        iny
        lda (PT1),y
        sta PT3
        iny
        lda (PT1),y
        sta PT4
        pla
        tay
        lda PT3
        jsr set_scr
        lda PT1
        clc
        adc #3
        sta PT1
        bcc @t
        inc PT2
@t:     ldy #0
@ch:    lda (PT1),y
        beq @eos
        jsr asc2int
        ora PT4
        sta (PSCR),y
        iny
        bne @ch
@eos:   iny
        tya
        clc
        adc PT1
        sta PT1
        bcc @rec
        inc PT2
        bne @rec
@end:   rts

draw_static:
        lda #<text_all
        ldx #>text_all
        jsr print_list
        lda STEREO
        beq @mono
        lda #<text_st
        ldx #>text_st
        jsr print_list
        ldy #5                  ; both POKEYs feed the meters
@vs:    lda vusrc_st,y
        sta vusrc,y
        dey
        bpl @vs
        jmp @fill
@mono:  lda #<text_mono
        ldx #>text_mono
        jsr print_list
        ldy #5
@vm:    lda vusrc_mo,y
        sta vusrc,y
        dey
        bpl @vm
@fill:  ldx #NBAR*BARROWS-1      ; meter rows: all segments unlit
        lda #G_DARK
@g:     sta barg,x
        dex
        bpl @g
        ldx #0
@f:     sta SCREEN+5*40,x
        sta SCREEN+6*40,x
        sta SCREEN+7*40,x
        sta SCREEN+8*40,x
        sta SCREEN+9*40,x
        sta SCREEN+10*40,x
        sta SCREEN+11*40,x
        sta SCREEN+12*40,x
        sta SCREEN+13*40,x
        inx
        cpx #40
        bne @f
        rts

; ===========================================================================
.segment "RODATA"

rowlo:  .repeat 24, I
        .byte <(SCREEN + I*40)
        .endrepeat
rowhi:  .repeat 24, I
        .byte >(SCREEN + I*40)
        .endrepeat

tramp_code:                     ; hot-swap trampoline, copied to $0680
        .byte $AD,$7F,$06       ; LDA TRAMPFLG
        .byte $F0,$FB           ; BEQ *-3
        .byte $6C,$7C,$06       ; JMP (TRAMPVEC)

; psq op/track -> the engine's command number ($FF = not in this mode).
; Track 3 (voice 4) needs POKEY1 ch3, which mono spends on track 1.
;   ops 0 note-on, 1 note-off, 2 drum, 3 preset, 4 param; index = op*4+track
map_st: .byte 0,2,4,14, 1,3,5,15, 6,7,6,6, 8,9,10,16, 11,11,11,11, 17,18,19,20
map_mono:
        .byte 0,2,$FF,$FF, 1,3,$FF,$FF, 6,6,6,6, 8,9,$FF,$FF, 11,11,11,11, 17,18,$FF,$FF

vusrc_st:   .byte 3,5,7,3+P2,5+P2,7+P2      ; AUDC of each metered voice
vusrc_mo:   .byte 3,5,7,$FF,$FF,$FF
barcol:     .byte 3,9,15,21,27,33
bar9:       .byte 0,9,18,27,36,45           ; bar * BARROWS           ; screen column of each meter
ledcol:     .byte 0,5,10,15,20,25,30,35
sc_vcol:    .repeat 40, I                   ; graticule: a dot every 20 px
            .byte (I .mod 5 = 0) * $40 + (I = 39) * $01
            .endrepeat
sc_hrow:    .repeat 40, I                   ; dotted top/centre/bottom lines
            .byte $11 | ((I .mod 5 = 0) * $40)
            .endrepeat
sc_m40lo:   .repeat 24, I
            .byte <(I*40)
            .endrepeat
sc_m40hi:   .repeat 24, I
            .byte >(I*40)
            .endrepeat
vulut:      .byte 0,1,2,4,5,6,7,8,10,11,12,13,14,16,17,18
numkeys:    .byte $1F,$1E,$1A,$18,$1D,$1B,$33,$35,$30
.ifdef JAM
            .byte $32                       ; 0: the tenth style
.endif

; DLI color bands: 0 status, 1 progress, 2 spacer, 3-11 meters (top to
; bottom), 12 labels, 13 percussion, 14 scope (PF0 graticule, PF1 trace,
; PF2 trace over graticule), 15 footer
dpf0:   .byte $00,$00,$00, $3C,$3A,$2A,$1C,$1A,$CC,$CA,$CA,$C8, $00,$00,$B4,$00
dpf1:   .byte $0E,$0C,$0E, $0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F, $0E,$0C,$BE,$0E
dpf2:   .byte $00,$B2,$00, $02,$02,$02,$02,$02,$02,$02,$02,$02, $00,$32,$BE,$00

glyph_codes: .byte G_FULL,G_HALF,G_DARK,G_PEAK,G_OFF,6,7,0
glyph_data:
        .byte $00,$55,$55,$55,$55,$55,$55,$00   ; meter cell, lit
        .byte $00,$00,$00,$00,$55,$55,$55,$00   ; meter cell, half
        .byte $00,$00,$00,$FF,$FF,$00,$00,$00   ; meter cell, unlit
        .byte $00,$AA,$AA,$00,$00,$00,$00,$00   ; peak marker
        .byte $00,$00,$00,$18,$18,$00,$00,$00   ; LED / progress, dark
        .byte $00,$7E,$7E,$7E,$7E,$7E,$7E,$00   ; 6: loading bar, filled
        .byte $00,$7E,$42,$42,$42,$42,$7E,$00   ; 7: loading bar, empty

text_all:
        .byte 0,4,$00,  "POKEY",0
.ifdef JAM
        .byte 0,10,$C0, "JAM",0
.else
        .byte 0,10,$C0, "PLAYER",0
.endif
        .byte 2,0,$00,  "SONG",0
        .byte 2,8,$00,  "OF",0
        .byte 2,30,$00, ":",0
        .byte 2,33,$00, "/",0
        .byte 2,36,$00, ":",0
        .byte 17,0,$00, "----------------------------------------",0
        .byte 17,14,$00," PERCUSSION ",0
        .byte 19,0,$00, "KICK SNAR HAT  OPEN TOM  TOM2 CLAP CRSH",0
.ifdef JAM
        .byte 22,0,$00, " 1-6 MUTE  <> STYLE  RET NEW  R RANDOM",0
        .byte 23,12,$00,"(c) Carlos Bravo",0
.else
        .byte 23,0,$00, "SPACE PAUSE  <> SONG  TAB LIST  ESC STOP",0
.endif
        .byte $FF
text_st:
        .byte 2,16,$00, "STEREO",0
        .byte 14,3,$00, "LEAD",0
        .byte 14,9,$00, "LAYER",0
        .byte 14,15,$00,"DRUM",0
        .byte 14,21,$00,"BASS",0
        .byte 14,27,$00,"HARM",0
        .byte 14,33,$00,"DRUM2",0
        .byte $FF
.ifdef DISK
.macro M7 str, col               ; a 20-cell mode-7 line, in one color
        .repeat 20, I
        .if I < .strlen(str)
        .byte ((.strat(str, I) - 32) & $3F) | col
        .else
        .byte 0
        .endif
        .endrepeat
.endmacro
.segment "CODE2"                ; (MAIN is full in the disk build)
m7_load:    M7 "      LOADING", $00
m7_list:    M7 "     SONG LIST", $80
m7_foot:    M7 "    POKEY PLAYER", $40
m7_song:    M7 "   SONG    OF", $40
.segment "RODATA"
text_err:
        .byte 2,16,$80, "DISK ERROR",0
        .byte $FF
.endif
text_lyr:
        .byte 14,9,$00, "LAYER",0
        .byte $FF
text_v4:
        .byte 14,9,$00, "VOICE",0
        .byte $FF
text_mono:
        .byte 2,16,$00, "MONO",0
        .byte 14,3,$00, "LEAD",0
        .byte 14,9,$00, "VOICE",0
        .byte 14,15,$00,"DRUM",0
        .byte $FF

; ===========================================================================
.segment "DATA"
vusrc:  .res 6
vupk:   .res 6
vufal:  .res 6
mapt:   .res 24
ncode:  .res 6
pcode:  .res 6
lastn:  .res 6
lastp:  .res 6
pcell:  .res 1
pacc:   .res 2
pstep:  .res 2
totm:   .res 1
tots:   .res 1
lsecs:  .res 1
dlin:   .res 1
vt0:    .res 1
vt1:    .res 1
vt2:    .res 1
vt3:    .res 1
scback: .res 1                  ; hi byte of the buffer being drawn
scstage:.res 1
barg:   .res NBAR*BARROWS       ; meter glyphs as drawn (skip unchanged)
bi:     .res 1
lastlv: .res NBAR
liston: .res 1                  ; the song list is up
lsel:   .res 1                  ; highlighted song
ltop:   .res 1                  ; first song on screen
khold:  .res 1                  ; frames the key has been held
lstick: .res 1                  ; joystick as last read
shold:  .res 1                  ; frames it has been held
lrow:   .res 1                  ; list_rows' line counter
lastsp: .res 1                  ; SPOS low byte at the last progress update
v3on:   .res 1                  ; the song uses voice 4 (POKEY1 ch3)
dr2used:.res 1                  ; the song plays drum channel 2 itself
lastv3: .res 1
n4cnt:  .res 1                  ; voice 4 note-ons (tests)
lastpk: .res NBAR
scof:   .res 4                  ; per voice: amplitude level * 64
scshp:  .res 4                  ; per voice: wave table page                  ; 0 clear + first half, 1 second half + swap
scph:   .res 4                  ; running phase per voice
scpb:   .res 4                  ; phase at the start of the trace
scst:   .res 4                  ; phase step per sample per voice
scy:    .res 1                  ; previous sample's row
scs:    .res 1                  ; sample index
scend:  .res 1
scsum:  .res 1
scnm:   .res 1                  ; noise mask / half
scnh:   .res 1
sclo:   .res 1
schi:   .res 1
scmask: .res 1
dsec:   .res 2
dcnt:   .res 1
dbuf:   .res 2
dtry:   .res 1
lshow:  .res 1                  ; the LOADING screen is up
lbtot:  .res 1
lbacc:  .res 1
lbcell: .res 1

; ===========================================================================
.segment "HIDATA"
.align 256
.ifndef JAM
.include "scope.inc"            ; its tables must be page-aligned
.assert <sc_sine = 0 && <sc_square = 0, error, "scope tables must be page-aligned"
.endif
.include "tables.inc"
; names for the panel (moved here: MAIN is full in the disk build)
notenames:
        .byte 'C'-32,0, 'C'-32,3, 'D'-32,0, 'D'-32,3, 'E'-32,0, 'F'-32,0
        .byte 'F'-32,3, 'G'-32,0, 'G'-32,3, 'A'-32,0, 'A'-32,3, 'B'-32,0
drumnames:
        .byte 'K'-32,'I'-32,'C'-32,'K'-32
        .byte 'S'-32,'N'-32,'A'-32,'R'-32
        .byte 'H'-32,'A'-32,'T'-32,0
        .byte 'O'-32,'P'-32,'E'-32,'N'-32
        .byte 'T'-32,'O'-32,'M'-32,0
        .byte 'T'-32,'O'-32,'M'-32,'2'-32
        .byte 'C'-32,'L'-32,'A'-32,'P'-32
        .byte 'C'-32,'R'-32,'S'-32,'H'-32
presetnames:
        .byte 'P'-32,'I'-32,'A'-32,'N'-32,'O'-32
        .byte 'O'-32,'R'-32,'G'-32,'A'-32,'N'-32
        .byte 'F'-32,'L'-32,'U'-32,'T'-32,'E'-32
        .byte 'S'-32,'T'-32,'R'-32,'N'-32,'G'-32
        .byte 'B'-32,'A'-32,'S'-32,'S'-32,0
        .byte 'A'-32,'R'-32,'P'-32,'E'-32,'G'-32
        .byte 'S'-32,'Y'-32,'N'-32,'T'-32,'H'-32
        .byte 'B'-32,'E'-32,'L'-32,'L'-32,0
        .byte 'L'-32,'A'-32,'S'-32,'E'-32,'R'-32
        .byte 'U'-32,'F'-32,'O'-32,0,0


.ifdef JAM
.include "jamglue.s"            ; the composer, in the song bank's place
.elseif .not .defined(DISK)
.segment "SONGS"
.ifdef AUDITION
.incbin "build/audition.bin"    ; one song to listen to (audition.py play)
.else
.incbin "songbank.bin"
.endif
.endif

; ===========================================================================
; the song list (CODE2, $1400: MAIN is full in the disk build)
.segment "CODE2"

; 24 GR.0 lines on LISTSCR. One DLI on the last blank line applies DLI band
; 0 (white on black) to the whole list.
dlist_list:
        .byte $70,$70,$F0
        .byte $42,<LISTSCR,>LISTSCR
        .res  23,$02
        .byte $41,<dlist_list,>dlist_list

; The board sends the PC's arrow keys to joystick 1, so the list (and a
; real joystick) steer through STICK0: up/down move, left/right page. On
; the panel, left/right change song.
read_stick:
        lda STICK0
        and #$0F
        cmp lstick
        beq @held
        sta lstick
        lda #0
        sta shold
        beq @go
@held:  ldx liston              ; held: repeats in the list only
        beq @x
        inc shold
        lda shold
        cmp #24
        bcc @x
        lda #20
        sta shold
@go:    lda lstick
        ldx #3
@m:     cmp stick_v,x
        beq @k
        dex
        bpl @m
@x:     rts
@k:     lda stick_k,x
        ldx liston
        beq @panel
        jmp list_key
@panel: cmp #K_LEFT
        bne @r
        jmp prev_song
@r:     cmp #K_RIGHT
        bne @x
        jmp next_song

stick_v:    .byte $0E,$0D,$0B,$07           ; up, down, left, right
stick_k:    .byte K_UP,K_DOWN,K_LEFT,K_RIGHT

cat_ptr:                        ; A = song -> CPTR = CAT + 1 + A*24
        sta CPTR
        lda #0
        sta CPTR+1
        asl CPTR
        rol CPTR+1
        asl CPTR
        rol CPTR+1
        asl CPTR
        rol CPTR+1              ; *8
        lda CPTR
        sta PT3
        lda CPTR+1
        sta PT4
        asl CPTR
        rol CPTR+1              ; *16
        clc
        lda CPTR
        adc PT3
        sta CPTR
        lda CPTR+1
        adc PT4
        sta CPTR+1              ; *24
        clc
        lda CPTR
        adc #<(CAT+1)
        sta CPTR
        lda CPTR+1
        adc #>(CAT+1)
        sta CPTR+1
        rts

list_open:
        lda NSONG
        beq @x
        lda #1
        sta liston
        lda SONGN               ; start on the song that is playing,
        sta lsel                ;  roughly in the middle of the screen
        sec
        sbc #LROWS/2
        bcs @t
        lda #0
@t:     sta ltop
        jsr list_top
        ldx #39                 ; the frame: title, rules, keys
@f:     lda lt_head,x
        sta LISTSCR+0*40,x
        lda lt_rule,x
        sta LISTSCR+1*40,x
        sta LISTSCR+22*40,x
        lda lt_keys,x
        sta LISTSCR+23*40,x
        dex
        bpl @f
        lda #<(LISTSCR+37)      ; song count, top right
        sta PSCR
        lda #>(LISTSCR+37)
        sta PSCR+1
        lda NSONG
        ldy #0
        jsr put_2dig
        jsr list_rows
        lda #<dlist_list
        sta SDLSTL
        lda #>dlist_list
        sta SDLSTL+1
@x:     rts

list_close:
        lda #0
        sta liston
.ifndef JAM
        jsr scope_init          ; the list used the scope's buffer
.endif
        lda #<dlist
        sta SDLSTL
        lda #>dlist
        sta SDLSTL+1
        rts

list_key:                       ; A = key, while the list is up
        cmp #K_UP
        beq @up
        cmp #K_DOWN
        beq @down
        cmp #K_LEFT
        beq @pgup
        cmp #K_LT
        beq @pgup
        cmp #K_RIGHT
        beq @pgdn
        cmp #K_GT
        beq @pgdn
        cmp #K_RET
        beq @play
        cmp #K_ESC
        beq @close
        cmp #K_L
        beq @close
        cmp #K_TAB
        beq @close
        rts
@close: jmp list_close
@play:  jsr list_close
        lda lsel
        jmp song_load
@up:    lda lsel
        beq @r
        dec lsel
        jmp @move
@down:  ldx lsel
        inx
        cpx NSONG
        bcs @r
        stx lsel
        jmp @move
@pgup:  lda lsel
        sec
        sbc #LROWS
        bcs @s
        lda #0
        beq @s
@pgdn:  lda lsel
        clc
        adc #LROWS
        cmp NSONG
        bcc @s
        ldx NSONG
        dex
        txa
@s:     sta lsel
@move:  jsr list_top
        jmp list_rows
@r:     rts

list_top:                       ; keep lsel on screen, and the screen full
        lda lsel
        cmp ltop
        bcs @a
        sta ltop                ; above the window: it becomes the top
@a:     lda lsel
        sec
        sbc #LROWS-1
        bcc @b
        cmp ltop
        bcc @b
        sta ltop                ; below it: it becomes the bottom
@b:     lda NSONG               ; never past the last full screen
        sec
        sbc #LROWS
        bcs @c
        lda #0
@c:     cmp ltop
        bcs @x
        sta ltop
@x:     rts

list_rows:                      ; the 20 song lines, rows 2-21
        lda #0
        sta lrow                ; screen row - 2 (put_2dig uses PT1)
@row:   lda lrow
        clc
        adc #2
        tax
        lda sc_m40lo,x
        sta PSCR
        lda sc_m40hi,x
        ora #>LISTSCR
        sta PSCR+1
        ldy #39
        lda #0
@clr:   sta (PSCR),y
        dey
        bpl @clr
        lda lrow
        clc
        adc ltop
        sta PT2                 ; song index
        cmp NSONG
        bcs @next
        cmp SONGN               ; the song that is playing: a marker
        bne @num
        lda #'>'-32
        ldy #1
        sta (PSCR),y
@num:   lda PT2
        clc
        adc #1
        ldy #3
        jsr put_2dig
        lda PT2
        jsr cat_ptr
        ldy #0                  ; title, columns 7-22
@ti:    lda (CPTR),y
        sta PT3
        tya
        clc
        adc #7
        tay
        lda PT3
        sta (PSCR),y
        tya
        sec
        sbc #6
        tay
        cpy #16
        bne @ti
        ldy #20                 ; length m:ss, columns 33-37
        lda (CPTR),y
        pha
        iny
        lda (CPTR),y
        sta PT4
        pla
        ldy #32
        jsr put_2dig            ; minutes -> 32,33
        lda #':'-32
        ldy #34
        sta (PSCR),y
        lda PT4
        ldy #35
        jsr put_2dig            ; seconds -> 35,36
        lda PT2                 ; the highlighted one: an inverse bar
        cmp lsel
        bne @next
        ldy #39
@inv:   lda (PSCR),y
        ora #$80
        sta (PSCR),y
        dey
        bpl @inv
@next:  inc lrow
        lda lrow
        cmp #LROWS
        beq @x
        jmp @row
@x:     rts

.macro G0 str                   ; a 40-cell GR.0 line
        .repeat 40, I
        .if I < .strlen(str)
        .byte (.strat(str, I) - 32) & $3F
        .else
        .byte 0
        .endif
        .endrepeat
.endmacro
lt_head:    G0 " POKEY PLAYER  -  SONG LIST       OF"
lt_rule:    G0 "----------------------------------------"
lt_keys:    G0 " ARROWS/STICK MOVE  RETURN PLAY  ESC BACK"
