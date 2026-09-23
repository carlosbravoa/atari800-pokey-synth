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
CATN     = 8            ; 8 x 128 bytes: up to 42 songs
LOADING  = $0BC0        ; 1 = SIO owns POKEY: the VBI keeps its hands off
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
.else
CAT      = SONGS
.endif
CATENT   = 24           ; bytes per catalog entry
NBAR     = 6            ; voice meters
BARTOP   = 5            ; first meter row
BARROWS  = 9

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
scope_lms:                                              ; 20-22: the scope,
        .byte $4E,<SCOPEA,>SCOPEA                       ;  24 ANTIC E lines
        .res  22,$0E
        .byte $8E                                       ;  last line   +DLI
        .byte $42,<(SCREEN+23*40),>(SCREEN+23*40)       ; 23 keys
        .byte $41,<dlist,>dlist

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
        lda #0                  ; page-6 state up to the trampoline
        ldx #$7B
@z6:    sta $0600,x
        dex
        bpl @z6
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
        ldx #$27                ; $0B98-$0BBF: the synth's old song vars
        lda #0
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
        jsr scope_init
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
        lda CAT                 ; how many songs are in the bank
        sta NSONG
        lda #0
        jsr song_load

mainloop:
        jsr wait_frame
        inc DRAWN
        lda PARKREQ
        bne park_self
        jsr read_keys
        lda PENDN               ; the stream ended: roll on to the next song
        beq @p
        lda #0
        sta PENDN
        jsr next_song
@p:     lda PRESREQ             ; the song asked for a lead instrument
        cmp #$FF
        beq @d
        pha
        lda #$FF
        sta PRESREQ
        pla
        jsr set_preset
@d:     jsr draw_all
        jmp mainloop

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
        jsr drum_step
        jsr pokey_out
        jmp XITVBV

; ---- the sequencer: delta-timed events straight out of the song bank ------
seq_step:
        lda PLAYING
        beq seq_rts
        lda PAUSED
        bne seq_rts
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
        jmp seq_next
cm_dr1: sta LASTDR              ; 7: drum, POKEY2 ch4
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
cm_end: lda #0                  ; 13: end of song -> the main thread advances
        sta PLAYING
        lda #1
        sta ENDF
        sta PENDN
        jsr hush
        jmp seq_next
seq_next:                       ; one event done: take the next delta
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
            .byte <(cm_off-1),<(cm_end-1)
cmd_hi:     .byte >(cm_non-1),>(cm_nof-1),>(cm_v0n-1),>(cm_v0f-1)
            .byte >(cm_v1n-1),>(cm_v1f-1),>(cm_dr0-1),>(cm_dr1-1)
            .byte >(cm_pre-1),>(cm_p0-1),>(cm_p1-1),>(cm_par-1)
            .byte >(cm_off-1),>(cm_end-1)
SCMDN = 14

hush:                           ; every voice silent, envelopes reset
        lda #0
        sta GATE
        sta ESTATE
        sta VOLHI
        sta V_EST
        sta V_VHI
        sta V_EST+VBS
        sta V_VHI+VBS
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
        sta ENDF
        sta PENDN
        lda #60
        sta SECTMR
        jsr hush
        jsr clear_meters
        lda SONGN               ; PSCR = SONGS + 1 + index*24
        sta PT1
        lda #0
        sta PT2
        asl PT1
        rol PT2
        asl PT1
        rol PT2
        asl PT1
        rol PT2                 ; index*8
        lda PT1
        sta PT3
        lda PT2
        sta PT4
        asl PT1
        rol PT2                 ; index*16
        clc
        lda PT1
        adc PT3
        sta PT1
        lda PT2
        adc PT4
        sta PT2                 ; index*24
        clc
        lda PT1
        adc #<(CAT+1)
        sta PSCR
        lda PT2
        adc #>(CAT+1)
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
        lda dsec
        sta VP
        sta SPTR
        lda dsec+1
        sta VP+1
        sta SPTR+1
        lda STEREO              ; pick the command map for this machine
        beq @mono
        ldy #19
@cs:    lda map_st,y
        sta mapt,y
        dey
        bpl @cs
        bmi @st
@mono:  ldy #19
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
        beq @x
        sta KHELD
        jmp key_cmd
@up:    lda #$FF
        sta KHELD
@x:     rts

key_cmd:                        ; A = a new key press
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
        ldx #8                  ; 1-9 pick a song
@d:     cmp numkeys,x
        beq @pick
        dex
        bpl @d
        rts
@pick:  cpx NSONG
        bcs @r
        txa
        jmp song_load
@next:  jmp next_song
@prev:  jmp prev_song
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
        jsr draw_scope
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
        lda STEREO              ; 1 layer (mono: the bass voice lives here)
        bne @b1
        lda V_EST
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
        sta pcode+1
        lda V_PRE
        sta pcode+3
        lda V_PRE+VBS
        sta pcode+4
@cmp:   ldx #NBAR-1
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
; buffer over four frames (15 traces a second, inside the frame budget).
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

draw_scope:                     ; 4 frames a trace: clear, then 3 thirds
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
        cmp #4
        bne @x
        lda scback              ; show it, draw into the other one next
        sta scope_lms+2
        eor #(>SCOPEA ^ >SCOPEB)
        sta scback
        jsr sc_flip
        lda #0
        sta scstage
@x:     rts

sc_ends:    .byte 27, 54, SCN

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
        jmp @noise
@mono:  ldx V_IDX               ; 1: ch3, the loop voice or the lead's layer
        lda V_EST
        bne @mv
        ldx NOTEIDX
@mv:    lda SH+5
        ldy V_PAR
        jsr sc_voice
        inc PT4
        lda #0                  ; 2: nothing on a mono machine
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
        ldx #2
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
        lda #$FF                ; no previous sample yet
        sta scy
        rts

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
        lda scph
        clc
        adc scst
        sta scph
        lsr a
        lsr a
        ora scof
        tax
sm0:    lda sc_sine,x
        sta scsum
        lda scph+1
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
        lda scph+2
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

; ---- progress bar and clock ----------------------------------------------
draw_prog:
        lda PLAYING
        beq @x
        lda PAUSED
        bne @x
        inc pacc
        bne @chk
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
@c:     dec dcnt
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
        jsr disk_read
        bcc @x
        lda #0                  ; unreadable: no songs
        sta CAT
        lda #<text_err
        ldx #>text_err
        jsr print_list
@x:     rts

load_song:                      ; dsec/dcnt -> SONGS, "LOADING" meanwhile
        ldx #9
@sv:    lda SCREEN+2*40+16,x
        sta savst,x
        dex
        bpl @sv
        lda #<text_load
        ldx #>text_load
        jsr print_list
        lda #<SONGS
        sta dbuf
        lda #>SONGS
        sta dbuf+1
        jsr disk_read
        bcs @err
        ldx #9
@rs:    lda savst,x
        sta SCREEN+2*40+16,x
        dex
        bpl @rs
        clc
        rts
@err:   lda #<text_err
        ldx #>text_err
        jsr print_list
        sec
        rts
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

; psq op/track -> the engine's command number ($FF = not in this mode)
;   ops 0 note-on, 1 note-off, 2 drum, 3 preset, 4 param; index = op*4+track
map_st: .byte 0,2,4,$FF, 1,3,5,$FF, 6,7,6,6, 8,9,10,$FF, 11,11,11,11
map_mono:
        .byte 0,2,$FF,$FF, 1,3,$FF,$FF, 6,6,6,6, 8,9,$FF,$FF, 11,11,11,11

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

; DLI color bands: 0 status, 1 progress, 2 spacer, 3-11 meters (top to
; bottom), 12 labels, 13 percussion, 14 scope (PF0 graticule, PF1 trace,
; PF2 trace over graticule), 15 footer
dpf0:   .byte $00,$00,$00, $3C,$3A,$2A,$1C,$1A,$CC,$CA,$CA,$C8, $00,$00,$B4,$00
dpf1:   .byte $0E,$0C,$0E, $0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F,$0F, $0E,$0C,$BE,$0E
dpf2:   .byte $00,$B2,$00, $02,$02,$02,$02,$02,$02,$02,$02,$02, $00,$32,$BE,$00

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

glyph_codes: .byte G_FULL,G_HALF,G_DARK,G_PEAK,G_OFF,0
glyph_data:
        .byte $00,$55,$55,$55,$55,$55,$55,$00   ; meter cell, lit
        .byte $00,$00,$00,$00,$55,$55,$55,$00   ; meter cell, half
        .byte $00,$00,$00,$FF,$FF,$00,$00,$00   ; meter cell, unlit
        .byte $00,$AA,$AA,$00,$00,$00,$00,$00   ; peak marker
        .byte $00,$00,$00,$18,$18,$00,$00,$00   ; LED / progress, dark

text_all:
        .byte 0,4,$00,  "POKEY",0
        .byte 0,10,$C0, "PLAYER",0
        .byte 2,0,$00,  "SONG",0
        .byte 2,8,$00,  "OF",0
        .byte 2,30,$00, ":",0
        .byte 2,33,$00, "/",0
        .byte 2,36,$00, ":",0
        .byte 17,0,$00, "----------------------------------------",0
        .byte 17,14,$00," PERCUSSION ",0
        .byte 19,0,$00, "KICK SNAR HAT  OPEN TOM  TOM2 CLAP CRSH",0
        .byte 23,5,$00, "SPACE PAUSE  <> SONG  ESC STOP",0
        .byte $FF
text_st:
        .byte 2,16,$00, "STEREO",0
        .byte 14,3,$00, "LEAD",0
        .byte 14,9,$00, "LAYER",0
        .byte 14,15,$00,"DRUM",0
        .byte 14,21,$00,"BASS",0
        .byte 14,27,$00,"HARM",0
        .byte 14,33,$00,"DRUM",0
        .byte $FF
.ifdef DISK
text_load:
        .byte 2,16,$80, "LOADING   ",0
        .byte $FF
text_err:
        .byte 2,16,$80, "DISK ERROR",0
        .byte $FF
.endif
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
mapt:   .res 20
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
lastpk: .res NBAR
scof:   .res 3                  ; per voice: amplitude level * 64
scshp:  .res 3                  ; per voice: wave table page                  ; 0 clear + first half, 1 second half + swap
scph:   .res 3                  ; running phase per voice
scpb:   .res 3                  ; phase at the start of the trace
scst:   .res 3                  ; phase step per sample per voice
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
savst:  .res 10

; ===========================================================================
.segment "HIDATA"
.align 256
.include "scope.inc"            ; its tables must be page-aligned
.assert <sc_sine = 0 && <sc_square = 0, error, "scope tables must be page-aligned"
.include "tables.inc"

.ifndef DISK
.segment "SONGS"
.incbin "songbank.bin"
.endif
