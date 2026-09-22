; ---------------------------------------------------------------------------
; POKEY SYNTH — a playable keyboard synthesizer for the Atari 8-bit,
; NTSC 800XL-class. ca65 assembler.
;
; Keys (GarageBand "musical typing" layout):
;   A S D F G H J K L ;   white notes C D E F G A B C D E
;   W E   T Y U   O P     black notes
;   Z / X                 octave down / up
;   1-9, 0                instrument presets
;   C V B N M , . /       drum pads (kick snare hat open tom tom2 clap crash)
;   arrows / joystick     sound editor: up/down pick, left/right change
;   RETURN                restore the preset's factory sound
;   ESC                   silence everything
;   OPTION / SELECT       next / previous preset (F8 / F7 on the board)
;
; Voices:
;   lead  = POKEY ch1+2 joined 16-bit @ 1.79 MHz (in tune over 8 octaves),
;           ADSR envelope, 6 waveforms, vibrato, chord arpeggio, pitch sweep,
;           glide.
;   layer = ch3 8-bit @ 64 kHz: sub octave / fifth / octave up / chorus / echo.
;   drums = ch4 envelope engine (noise + swept tones).
;
; The keyboard is polled by the VBI straight from POKEY (KBCODE + SKSTAT
; "key held" bit) with the OS key IRQ disabled, so notes sustain while the
; key is held and release when it's let go. Every new key press is posted to
; the main thread (KEYEV/KEYSEQ) for the UI.
;
; VBI/DLI touch page 6 (and the $0A00 echo ring) only, never main-thread
; zero page. Hot-swap mailbox is deploy.py-compatible:
;   FRAME $0617, PARKREQ $063D, trampoline $0680/$067C/$067F.
; ---------------------------------------------------------------------------

; ---- OS / hardware ----
POKMSK  = $10
RTCLOK  = $12
ATRACT  = $4D
SAVMSC  = $58
VDSLST  = $0200
SDMCTL  = $022F
SDLSTL  = $0230
STICK0  = $0278
COLOR0  = $02C4
COLOR1  = $02C5
COLOR2  = $02C6
COLOR3  = $02C7
COLOR4  = $02C8
NOCLIK  = $02DB
CHBAS   = $02F4
CH      = $02FC

COLPF0  = $D016
COLPF1  = $D017
COLPF2  = $D018
COLPF3  = $D019
CONSOL  = $D01F
AUDF1   = $D200
AUDC1   = $D201
AUDF2   = $D202
AUDC2   = $D203
AUDF3   = $D204
AUDC3   = $D205
AUDF4   = $D206
AUDC4   = $D207
AUDCTL  = $D208
KBCODE  = $D209
IRQEN   = $D20E
SKCTL   = $D20F
SKSTAT  = $D20F
WSYNC   = $D40A
VCOUNT  = $D40B
NMIEN   = $D40E

SETVBV  = $E45C
XITVBV  = $E462

; ---- fixed layout ----
CHSET   = $3C00
SCREEN  = $4000
ECHON   = $0A00         ; 32-frame echo ring: note index
ECHOV   = $0A20         ;                     volume

; glyph codes (lowercase slots, unused by the UI text) — screen dumps read
; the piano as w/x/b/d letters
G_W     = 'w'           ; white key body
G_X     = 'x'           ; white key, right gap
G_B     = 'b'           ; white | black key (black to the right)
G_C     = 'c'           ;   ... black key lit
G_D     = 'd'           ; black key | white (black to the left)
G_E     = 'e'           ;   ... black key lit
G_F     = 'f'           ; meter: full cell
G_H     = 'h'           ; meter: half cell
G_O     = 'o'           ; meter: empty cell

PIANOX  = 5             ; first screen column of the piano
KT_DRUM = $20
KT_ARROW= $30

K_UP    = $0E           ; '-'  (CTRL = cursor up)
K_DOWN  = $0F           ; '='
K_LEFT  = $06           ; '+'
K_RIGHT = $07           ; '*'
K_Z     = $17
K_X     = $16
K_RET   = $0C
K_ESC   = $1C

REPT_FIRST = 16
REPT_NEXT  = 4

; ---- zero page (main thread only) ----
ZPTR    = $80
ZSCR    = $82
ZT1     = $84
ZT2     = $85
ZT3     = $86
ZT4     = $87
ZI      = $88
ZINV    = $89
ZCOL    = $8A
ZATTR   = $8B

; ---- page-6 state (peekable) ----
PRESET   = $0600        ; 0-9 current instrument
OCTAVE   = $0601        ; 1-7
OCTBASE  = $0602        ; (OCTAVE-1)*12, read by the VBI at note-on
EDSEL    = $0603        ; editor selection 0-11
KEYEV    = $0604        ; last new key press (KBCODE&$3F), VBI -> main
KEYSEQ   = $0605        ; +1 per posted key event
LASTSEQ  = $0606        ; main: last KEYSEQ handled
HELD     = $0607        ; key currently held ($FF none)
HOLDCNT  = $0608        ; frames held (arrow auto-repeat)
LITKEY   = $0609        ; note offset lit on the piano ($FF none)
NOTE     = $060A        ; base note index 0-95 (0 = C1)
ESTATE   = $060B        ; envelope: 0 off 1 attack 2 decay 3 sustain 4 release
VOLLO    = $060C
VOLHI    = $060D        ; current volume 0-15
CURNLO   = $060E        ; lead period after glide (16-bit)
CURNHI   = $060F
SWPLO    = $0610        ; sweep period (absolute, while sweep is on)
SWPHI    = $0611
OUTLO    = $0612        ; final 16-bit period written to AUDF1/2
OUTHI    = $0613
ARPPOS   = $0614
ARPTMR   = $0615
VPH      = $0616        ; vibrato phase 0-7
FRAME    = $0617        ; deploy.py compat
VTMR     = $0618
NOTEIDX  = $0619        ; note incl. chord offset (what's sounding)
GLFRESH  = $061A        ; 1 = next frame snaps pitch (note from silence)
REMKEY   = $061B        ; remote test mailbox: key code to "hold" ...
REMHOLD  = $061C        ; ... for this many frames (PC pokes REMKEY first)
DTMR     = $061D        ; drum engine
DFRQ     = $061E
DDLT     = $061F
DCTL     = $0620
DVSH     = $0621
DRUMLIT  = $0622        ; drum sounding ($FF none)
NOTECNT  = $0623        ; +1 per note-on
DRUMCNT  = $0624        ; +1 per drum hit
KEYCNT   = $0625        ; +1 per key press
ECHOPOS  = $0626
GATE     = $0627        ; 1 while a note key is held
SWPON    = $0628
VT0      = $0629        ; VBI temps
VT1      = $062A
VT2      = $062B
VT3      = $062C
VT4      = $062D
VT5      = $062E
LITCOL   = $062F        ; lit-key color (preset hue)
PARAMS   = $0630        ; 12 bytes, live sound of the current preset
P_WAVE   = PARAMS+0
P_ATK    = PARAMS+1
P_DEC    = PARAMS+2
P_SUS    = PARAMS+3
P_REL    = PARAMS+4
P_LAYER  = PARAMS+5
P_VIB    = PARAMS+6
P_VIBSPD = PARAMS+7
P_CHORD  = PARAMS+8
P_CHDSPD = PARAMS+9
P_SWEEP  = PARAMS+10    ; 7 = off, <7 down, >7 up
P_GLIDE  = PARAMS+11
PREVSTK  = $063C
PARKREQ  = $063D        ; deploy.py mailbox
REPTMR   = $063E
LASTLIT  = $063F        ; main: piano as last drawn
LASTDRUM = $0640
DISPNOTE = $0641
PREVCON  = $0642
UICNT    = $0643        ; main: +1 per UI frame (liveness)

NPARAM   = 12
PSTRIDE  = 13           ; preset row: 12 params + octave

; hot-swap trampoline (same layout as the other workspace games)
TRAMP    = $0680
TRAMPVEC = $067C
TRAMPFLG = $067F
RTISTUB  = $0690

; ===========================================================================
.segment "XEXHDR"
.import __MAIN_START__, __MAIN_LAST__
        .word $FFFF
        .word __MAIN_START__
        .word __MAIN_LAST__-1

.segment "XEXTRL"
        .word $02E0, $02E1
        .word start

; ===========================================================================
.segment "DLIST"
dlist:
        .byte $70,$70,$70
        .byte $42,<SCREEN,>SCREEN                   ; row 0  title (GR.0)
        .byte $47,<(SCREEN+40),>(SCREEN+40)         ; row 1  big name (mode 7)
        .byte $C2,<(SCREEN+80),>(SCREEN+80)         ; row 2  black labels + DLI
        .byte $44,<(SCREEN+120),>(SCREEN+120)       ; rows 3-7 piano (mode 4)
        .byte $04,$04,$04
        .byte $84                                   ;   row 7 + DLI
        .res  16,$02                                ; rows 8-23 GR.0
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
        ; silence + lead pair: ch1 @1.79 MHz joined with ch2 (16-bit)
        ldx #7
@snd:   sta AUDF1,x
        dex
        bpl @snd
        lda #$50
        sta AUDCTL
        lda #3
        sta SKCTL
        ; poll the keyboard ourselves: key + break IRQs off (no click, no CH)
        sei
        lda POKMSK
        and #$3F
        sta POKMSK
        sta IRQEN
        cli
        lda #$FF
        sta NOCLIK
        sta CH

        ; ROM font -> RAM charset, then overlay the piano/meter glyphs
        lda #$E0
        sta ZPTR+1
        lda #0
        sta ZPTR
        sta ZSCR
        lda #>CHSET
        sta ZSCR+1
        ldx #4
        ldy #0
@cp:    lda (ZPTR),y
        sta (ZSCR),y
        iny
        bne @cp
        inc ZPTR+1
        inc ZSCR+1
        dex
        bne @cp
        ldx #0
@gl:    stx ZI
        lda glyph_codes,x
        beq @gld
        sta ZSCR                ; ZSCR = CHSET + code*8
        lda #0
        sta ZSCR+1
        asl ZSCR
        rol ZSCR+1
        asl ZSCR
        rol ZSCR+1
        asl ZSCR
        rol ZSCR+1
        lda ZSCR+1
        clc
        adc #>CHSET
        sta ZSCR+1
        txa
        asl a
        asl a
        asl a
        tax                     ; glyph_data offset
        ldy #0
@gb:    lda glyph_data,x
        sta (ZSCR),y
        inx
        iny
        cpy #8
        bne @gb
        ldx ZI
        inx
        bne @gl
@gld:
        ; page-6 state (up to the trampoline) and the echo ring
        lda #0
        ldx #$7B
@z6:    sta $0600,x
        dex
        bpl @z6
        ldx #$3F
@ze:    sta ECHON,x
        dex
        bpl @ze

        ; live presets <- factory
        ldx #0                  ; 130 bytes: count up (bpl would stop at 128)
@lp:    lda factory,x
        sta live,x
        inx
        cpx #10*PSTRIDE
        bne @lp

        ; hot-swap trampoline + RTI stub
        ldx #7
@tr:    lda tramp_code,x
        sta TRAMP,x
        dex
        bpl @tr
        lda #$40
        sta RTISTUB

        lda #$FF
        sta HELD
        sta LITKEY
        sta DRUMLIT
        sta LASTDRUM
        sta DISPNOTE
        sta PREVCON
        lda #$0F
        sta PREVSTK
        lda #$FE                ; force first piano draw
        sta LASTLIT

        lda #$0E                ; GR.0 text luminance
        sta COLOR1
        lda #$92                ; GR.0 background: deep blue
        sta COLOR2
        lda #$00
        sta COLOR3
        sta COLOR4

        lda #<SCREEN
        sta SAVMSC
        lda #>SCREEN
        sta SAVMSC+1
        lda #<dlist
        sta SDLSTL
        lda #>dlist
        sta SDLSTL+1
        lda #>CHSET
        sta CHBAS

        jsr cls
        lda #<static_text
        ldx #>static_text
        jsr print_list
        lda #0
        jsr select_preset       ; draws name, presets, editor, octave
        jsr draw_drums

        lda #<dli
        sta VDSLST
        lda #>dli
        sta VDSLST+1
        lda #7
        ldx #>vbi
        ldy #<vbi
        jsr SETVBV
        lda #$C0
        sta NMIEN
        lda #$22
        sta SDMCTL

; ---------------------------------------------------------------------------
mainloop:
        jsr wait_frame
        lda PARKREQ
        bne park_self
        inc UICNT
        lda KEYSEQ
        cmp LASTSEQ
        beq @nk
        sta LASTSEQ
        lda KEYEV
        jsr handle_key
@nk:    jsr read_stick
        jsr read_console
        jsr ui_update
        jmp mainloop

park_self:
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
        sta PARKREQ
        sei
        lda POKMSK
        ora #$C0
        sta POKMSK
        sta IRQEN
        cli
        jmp TRAMP

wait_frame:
        lda RTCLOK+2
@w:     cmp RTCLOK+2
        beq @w
        rts

; ---------------------------------------------------------------------------
; main-thread key handling (A = KBCODE&$3F of a new press)
handle_key:
        ldx #NCMD-1
@c:     cmp cmdkeys,x
        beq @go
        dex
        bpl @c
        ldx #9
@n:     cmp numkeys,x
        beq @pr
        dex
        bpl @n
        rts
@pr:    txa
        jmp select_preset
@go:    lda cmdhi,x
        pha
        lda cmdlo,x
        pha
        rts

oct_down:
        lda OCTAVE
        cmp #2
        bcc @x
        dec OCTAVE
        jsr set_octave
@x:     rts

oct_up:
        lda OCTAVE
        cmp #7
        bcs @x
        inc OCTAVE
        jsr set_octave
@x:     rts

ed_up:
        ldx EDSEL
        dex
        bpl ed_move
        ldx #NPARAM-1
        bne ed_move
ed_down:
        ldx EDSEL
        inx
        cpx #NPARAM
        bcc ed_move
        ldx #0
ed_move:
        lda EDSEL
        stx EDSEL
        tax
        jsr draw_param          ; old row loses its marker
        ldx EDSEL
        jmp draw_param

ed_left:
        lda #$FF
        bne ed_change
ed_right:
        lda #1
ed_change:
        sta ZT1
        ldx EDSEL
        lda PARAMS,x
        clc
        adc ZT1
        bmi @no
        cmp pmin,x
        bcc @no
        beq @ok
        cmp pmax,x
        beq @ok
        bcs @no
@ok:    sta PARAMS,x
        sta ZT2
        ldy PRESET              ; remember the edit in the live preset
        lda pbase,y
        clc
        adc EDSEL
        tay
        lda ZT2
        sta live,y
        jmp draw_param
@no:    rts

reset_preset:
        ldx PRESET
        lda pbase,x
        tay
        ldx #PSTRIDE
@c:     lda factory,y
        sta live,y
        iny
        dex
        bne @c
        lda PRESET
        jmp select_preset

hush:
        lda #0
        sta ESTATE
        sta VOLHI
        sta VOLLO
        sta DTMR
        sta GATE
        ldx #$1F
@e:     sta ECHOV,x
        dex
        bpl @e
        lda #$FF
        sta LITKEY
        rts

; A = preset 0-9: load its live sound, octave and color; redraw
select_preset:
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
        lda live,y              ; 13th byte: the preset's home octave
        sta OCTAVE
        ldx PRESET
        lda pcolor,x
        sta COLOR0
        sta LITCOL
        jsr set_octave
        jsr draw_name
        jsr draw_presets
        lda #$FE
        sta LASTLIT             ; lit color changed: redraw piano
        jmp draw_editor

set_octave:
        ldx OCTAVE
        lda octbase,x
        sta OCTBASE
        lda OCTAVE
        ora #$10                ; internal code of digit
        ora #$80
        sta SCREEN+38
        rts

; ---------------------------------------------------------------------------
read_stick:
        lda STICK0
        and #$0F
        cmp PREVSTK
        beq @held
        sta PREVSTK
        ldx #REPT_FIRST
        stx REPTMR
        bne @fire
@held:  cmp #$0F
        beq @no
        dec REPTMR
        bne @no
        ldx #REPT_NEXT
        stx REPTMR
@fire:  cmp #14
        bne @d
        jmp ed_up
@d:     cmp #13
        bne @l
        jmp ed_down
@l:     cmp #11
        bne @r
        jmp ed_left
@r:     cmp #7
        bne @no
        jmp ed_right
@no:    rts

read_console:                   ; OPTION next, SELECT previous (edge)
        lda CONSOL
        and #7
        cmp PREVCON
        beq @no
        sta PREVCON
        tax
        and #4
        bne @sel
        ldx PRESET              ; OPTION pressed
        inx
        cpx #10
        bcc @go
        ldx #0
        beq @go
@sel:   txa
        and #2
        bne @no
        ldx PRESET              ; SELECT pressed
        dex
        bpl @go
        ldx #9
@go:    txa
        jmp select_preset
@no:    rts

; ---------------------------------------------------------------------------
ui_update:
        lda LITKEY
        cmp LASTLIT
        beq @d
        sta LASTLIT
        jsr draw_piano
@d:     lda DRUMLIT
        cmp LASTDRUM
        beq @n
        sta LASTDRUM
        jsr draw_drums
@n:     lda #$FF
        ldx ESTATE
        beq @n1
        lda NOTE
@n1:    cmp DISPNOTE
        beq @m
        sta DISPNOTE
        jsr draw_note
@m:     ; volume meter: row 9, cols 19-33
        ldx #0
@mc:    lda #G_O
        cpx VOLHI
        bcs @ms
        lda #G_F
@ms:    sta SCREEN+9*40+19,x
        inx
        cpx #15
        bne @mc
        rts

draw_note:                      ; row 9 col 6: "C#4" or "---"
        lda DISPNOTE
        cmp #$FF
        bne @on
        lda #'-'-32
        sta SCREEN+9*40+6
        sta SCREEN+9*40+7
        sta SCREEN+9*40+8
        rts
@on:    ldx #1
@dv:    cmp #12
        bcc @dd
        sbc #12
        inx
        bne @dv
@dd:    asl a
        tay
        lda notenames,y
        sec
        sbc #32
        sta SCREEN+9*40+6
        lda notenames+1,y
        sec
        sbc #32
        sta SCREEN+9*40+7
        txa
        ora #$10
        sta SCREEN+9*40+8
        rts

; ---- piano: rows 3-7 (mode 4), labels rows 2 (black) and 8 (white) ----
draw_piano:
        ldx #0
@k:     stx ZI
        lda #0
        sta ZINV
        lda whiteoff,x
        cmp LITKEY
        bne @ni
        lda #$80
        sta ZINV
@ni:    txa                     ; col = PIANOX + 3*i
        sta ZCOL
        asl a
        adc ZCOL
        adc #PIANOX
        tay
        ; column 0: black key to the left?
        lda #G_W
        cpx #0
        beq @c0
        lda blkoff-1,x
        cmp #$FF
        beq @c0w
        cmp LITKEY
        beq @c0l
        lda #G_D
        bne @c0
@c0l:   lda #G_E
        bne @c0
@c0w:   lda #G_W
@c0:    ora ZINV
        sta SCREEN+3*40,y
        sta SCREEN+4*40,y
        sta SCREEN+5*40,y
        lda #G_W
        ora ZINV
        sta SCREEN+6*40,y
        sta SCREEN+7*40,y
        ; column 1: plain white; the white-key label sits under it
        iny
        lda #G_W
        ora ZINV
        sta SCREEN+3*40,y
        sta SCREEN+4*40,y
        sta SCREEN+5*40,y
        sta SCREEN+6*40,y
        sta SCREEN+7*40,y
        lda whitelbl,x
        sec
        sbc #32
        ora ZINV
        sta SCREEN+8*40,y
        ; column 2: black key to the right?
        iny
        lda blkoff,x
        cmp #$FF
        beq @c2w
        cmp LITKEY
        beq @c2l
        lda #0
        sta ZT1
        lda #G_B
        bne @c2
@c2l:   lda #$80
        sta ZT1
        lda #G_C
        bne @c2
@c2w:   lda #' '-32
        sta SCREEN+2*40,y
        lda #G_X
        ora ZINV
        sta SCREEN+3*40,y
        sta SCREEN+4*40,y
        sta SCREEN+5*40,y
        jmp @low
@c2:    ora ZINV
        sta SCREEN+3*40,y
        sta SCREEN+4*40,y
        sta SCREEN+5*40,y
        lda blacklbl,x          ; black-key label above its left half
        sec
        sbc #32
        ora ZT1
        sta SCREEN+2*40,y
@low:   lda #G_X
        ora ZINV
        sta SCREEN+6*40,y
        sta SCREEN+7*40,y
        ldx ZI
        inx
        cpx #10
        beq @done
        jmp @k
@done:  rts

; ---- drums: rows 11-12, 8 pads of 7 chars at col 9 + (i&3)*8 ----
draw_drums:
        ldx #0
@p:     stx ZI
        lda #0
        cpx DRUMLIT
        bne @n
        lda #$80
@n:     sta ZATTR
        txa
        lsr a
        lsr a
        clc
        adc #11
        tay                     ; row
        txa
        and #3
        asl a
        asl a
        asl a
        adc #9
        jsr set_scr             ; Y=row, A=col
        lda ZI
        asl a
        asl a
        asl a
        tax                     ; drum name offset (8 per)
        ldy #0
@c:     lda drumnames,x
        jsr asc2int
        ora ZATTR
        sta (ZSCR),y
        inx
        iny
        cpy #7
        bne @c
        ldx ZI
        inx
        cpx #8
        bne @p
        rts

; ---- presets: rows 13-15, 4 per row, 10 chars each ----
draw_presets:
        ldx #0
@p:     stx ZI
        lda #0
        cpx PRESET
        bne @n
        lda #$80
@n:     sta ZATTR
        txa
        lsr a
        lsr a
        clc
        adc #13
        tay
        txa
        and #3
        sta ZT1
        asl a
        asl a
        adc ZT1
        asl a                   ; *10
        jsr set_scr
        ldy #0
        lda #' '
        jsr @put
        ldx ZI
        lda presetkey,x
        jsr @put
        lda #' '
        jsr @put
        lda ZI
        asl a
        asl a
        asl a
        tax
@c:     lda pnames,x
        jsr @put
        inx
        cpy #10
        bne @c
        ldx ZI
        inx
        cpx #10
        bne @p
        rts
@put:   jsr asc2int
        ora ZATTR
        sta (ZSCR),y
        iny
        rts

; ---- big instrument name: row 1 (mode 7, 20 chars) ----
draw_name:
        ldx #19
        lda #0
@cl:    sta SCREEN+40,x
        dex
        bpl @cl
        ldx PRESET
        lda presetkey,x
        sec
        sbc #32
        ora #$40                ; PF1 (white) digit
        sta SCREEN+40+5
        txa
        asl a
        asl a
        asl a
        tax
        ldy #0
@c:     lda pnames,x
        sec
        sbc #32                 ; PF0 = preset color
        sta SCREEN+40+7,y
        inx
        iny
        cpy #8
        bne @c
        rts

; ---- sound editor: rows 17-22, params 0-5 left column, 6-11 right ----
draw_editor:
        ldx #0
@e:     stx ZI
        jsr draw_param
        ldx ZI
        inx
        cpx #NPARAM
        bne @e
        rts

draw_param:                     ; X = param index (clobbers ZT*, ZATTR)
        stx ZT4
        txa
        ldy #17
        cmp #6
        bcc @lft
        sbc #6
        clc
        adc #17
        tay
        lda #20
        bne @sc
@lft:   txa
        clc
        adc #17
        tay
        lda #0
@sc:    jsr set_scr
        ; marker + name (inverse when selected)
        lda #0
        sta ZATTR
        ldy #0
        lda #' '
        ldx ZT4
        cpx EDSEL
        bne @mk
        lda #$80
        sta ZATTR
        lda #'>'
@mk:    jsr asc2int
        sta (ZSCR),y
        iny
        lda ZT4
        asl a
        asl a
        asl a
        tax                     ; label offset (8 per)
@nm:    lda plabels,x
        jsr asc2int
        ora ZATTR
        sta (ZSCR),y
        inx
        iny
        cpy #8
        bne @nm
        lda #0
        sta (ZSCR),y            ; col 8 space
        iny                     ; Y = 9: value field (11 chars)
        ldx ZT4
        lda PARAMS,x
        sta ZT3
        lda ptype,x
        beq @b16
        cmp #1
        beq @b8
        cmp #2
        beq @nam
        jmp @swp
@b16:   ; "NN ffffhooo"
        lda ZT3
        jsr put_2dig
        lda #0
        sta (ZSCR),y
        iny
        ldx #0
@b1:    txa
        asl a                   ; cell value 2x
        sta ZT2
        lda #G_O
        ldx ZT2
        inx
        cpx ZT3                 ; 2x+1 < v -> full ; 2x+1 == v -> half
        bcc @full
        bne @put
        lda #G_H
        bne @put
@full:  lda #G_F
@put:   sta (ZSCR),y
        iny
        lda ZT2
        lsr a
        tax
        inx
        cpx #8
        bne @b1
        rts
@b8:    ; " N fffffff "
        lda ZT3
        jsr put_2dig
        lda #0
        sta (ZSCR),y
        iny
        ldx #0
@b2:    lda #G_O
        cpx ZT3
        bcs @p2
        lda #G_F
@p2:    sta (ZSCR),y
        iny
        inx
        cpx #7
        bne @b2
        lda #0
        sta (ZSCR),y
        rts
@nam:   ; 6-char name from the param's list, then pad
        ldx ZT4
        lda pnlist_lo,x
        sta ZPTR
        lda pnlist_hi,x
        sta ZPTR+1
        lda ZT3
        asl a
        adc ZT3
        asl a                   ; *6
        sta ZT2
        ldx #6
@n1:    sty ZT1
        ldy ZT2
        lda (ZPTR),y
        inc ZT2
        ldy ZT1
        jsr asc2int
        sta (ZSCR),y
        iny
        dex
        bne @n1
        jmp @pad
@swp:   ; sweep: OFF / UP n / DOWN n
        lda ZT3
        sec
        sbc #7
        beq @off
        bcs @up
        eor #$FF
        adc #1                  ; carry clear here -> +1 = negate
        sta ZT3
        ldx #0                  ; "DOWN "
        beq @sw
@up:    sta ZT3
        ldx #5                  ; "UP   "
@sw:    lda swtxt,x
        jsr asc2int
        sta (ZSCR),y
        iny
        inx
        cpy #14
        bne @sw
        cpx #15                 ; OFF: no digit
        beq @pad
        lda ZT3
        ora #$10
        sta (ZSCR),y
        iny
        jmp @pad
@off:   ldx #10                 ; "OFF  "
        bne @sw
@pad:   lda #0
@pd:    cpy #20
        bcs @pz
        sta (ZSCR),y
        iny
        bne @pd
@pz:    rts

put_2dig:                       ; A = 0-15 -> two digits at (ZSCR),y
        ldx #0
        cmp #10
        bcc @one
        sbc #10
        ldx #1
@one:   pha
        txa
        beq @sp
        ora #$10
        bne @t
@sp:    lda #0
@t:     sta (ZSCR),y
        iny
        pla
        ora #$10
        sta (ZSCR),y
        iny
        rts

; ---------------------------------------------------------------------------
; text helpers
cls:
        lda #<SCREEN
        sta ZSCR
        lda #>SCREEN
        sta ZSCR+1
        ldx #4
        lda #0
        tay
@c:     sta (ZSCR),y
        iny
        bne @c
        inc ZSCR+1
        dex
        bne @c
        rts

set_scr:                        ; Y = row, A = col -> ZSCR
        clc
        adc rowlo,y
        sta ZSCR
        lda rowhi,y
        adc #0
        sta ZSCR+1
        rts

asc2int:                        ; ATASCII -> screen code
        cmp #32
        bcc @lo
        cmp #96
        bcs @x
        sbc #31                 ; carry clear: -32
        rts
@lo:    adc #64
@x:     rts

; list of records: row, col, attr, "text", 0 ... terminated by row $FF
print_list:
        sta ZPTR
        stx ZPTR+1
@rec:   ldy #0
        lda (ZPTR),y
        cmp #$FF
        beq @end
        pha
        iny
        lda (ZPTR),y
        sta ZT1
        iny
        lda (ZPTR),y
        sta ZATTR
        pla
        tay
        lda ZT1
        jsr set_scr
        lda ZPTR                ; ZPTR += 3 -> text
        clc
        adc #3
        sta ZPTR
        bcc @t
        inc ZPTR+1
@t:     ldy #0
@ch:    lda (ZPTR),y
        beq @eos
        jsr asc2int
        ora ZATTR
        sta (ZSCR),y
        iny
        bne @ch
@eos:   iny
        tya
        clc
        adc ZPTR
        sta ZPTR
        bcc @rec
        inc ZPTR+1
        bne @rec
@end:   rts

; ===========================================================================
; VBI: keyboard poll, lead synth, layer, drums. Page 6 + echo ring only.
vbi:
        inc FRAME
        lda #0
        sta ATRACT
        jsr kb_poll
        jsr synth
        jsr drum_step
        jmp XITVBV

kb_poll:
        lda REMHOLD             ; remote test key overrides the hardware
        beq @hw
        dec REMHOLD
        lda REMKEY
        and #$3F
        jmp @down
@hw:    lda SKSTAT
        and #$04
        bne @up
        lda KBCODE
        and #$3F
@down:  cmp HELD
        beq @same
        sta HELD
        ldx #0
        stx HOLDCNT
        jmp key_press
@same:  tax                     ; arrows auto-repeat
        lda keytype,x
        cmp #KT_ARROW
        bne @r
        inc HOLDCNT
        lda HOLDCNT
        cmp #24
        bcc @r
        lda #20
        sta HOLDCNT
        txa
        jmp post_key
@r:     rts
@up:    lda HELD
        cmp #$FF
        beq @r
        lda #$FF
        sta HELD
        lda GATE
        beq @r
        lda #0
        sta GATE
        lda #$FF
        sta LITKEY
        lda ESTATE
        beq @r
        lda #4
        sta ESTATE
        rts

post_key:                       ; A = code (preserved)
        sta KEYEV
        inc KEYSEQ
        rts

key_press:                      ; A = code of a new press
        inc KEYCNT
        jsr post_key
        tax
        lda keytype,x
        cmp #KT_DRUM
        bcc note_on
        cmp #KT_DRUM+8
        bcs @x
        and #7
        jmp drum_trig
@x:     rts

note_on:                        ; A = key offset 0-16
        sta LITKEY
        clc
        adc OCTBASE
        cmp #96
        bcc @ok
        lda #95
@ok:    sta NOTE
        inc NOTECNT
        lda #1
        sta GATE
        lda ESTATE
        bne @act
        lda #1
        sta GLFRESH             ; from silence: no glide
        bne @trig
@act:   lda #0
        sta GLFRESH
        lda P_GLIDE
        beq @trig
        lda ESTATE              ; glide + still sounding = legato
        cmp #4
        bne @leg
@trig:  lda #1
        sta ESTATE
        lda #0
        sta SWPON
        sta VPH
        lda #$FF
        sta ARPPOS
        lda #1
        sta ARPTMR
        sta VTMR
@leg:   rts

drum_trig:                      ; A = drum 0-7
        tax
        stx DRUMLIT
        inc DRUMCNT
        lda dr_frq,x
        sta DFRQ
        lda dr_dlt,x
        sta DDLT
        lda dr_ctl,x
        sta DCTL
        lda dr_vsh,x
        sta DVSH
        lda dr_len,x
        sta DTMR
        rts

drum_step:
        lda DTMR
        beq @off
        dec DTMR
        lda DFRQ
        clc
        adc DDLT
        bcc @nf
        lda #0
        sta DDLT
        lda #$FF
@nf:    sta DFRQ
        sta AUDF4
        lda DTMR                ; vol = min(TMR*4 >> VSH, 15)
        asl a
        asl a
        ldx DVSH
        beq @nv
@sh:    lsr a
        dex
        bne @sh
@nv:    cmp #16
        bcc @v
        lda #15
@v:     ora DCTL
        sta AUDC4
        rts
@off:   lda #0
        sta AUDC4
        lda #$FF
        sta DRUMLIT
        rts

; ---------------------------------------------------------------------------
synth:
        ; ---- chord arpeggio: NOTEIDX = NOTE + chord offset
        ldx P_CHORD
        beq @noarp
        lda ARPTMR
        beq @astep
        dec ARPTMR
        bne @asame
@astep: lda #9
        sec
        sbc P_CHDSPD
        sta ARPTMR
        inc ARPPOS
@asame: lda ARPPOS
        cmp chord_len,x
        bcc @ain
        lda #0
        sta ARPPOS
@ain:   clc
        adc chord_start,x
        tay
        lda chord_ofs,y
        jmp @ofs
@noarp: lda #0
@ofs:   clc
        adc NOTE
        cmp #96
        bcc @nok
        lda #95
@nok:   sta NOTEIDX

        ; ---- target period for this wave (VT0/VT1)
        tax
        lda P_WAVE
        cmp #1
        beq @buzz
        cmp #3
        beq @rasp
        lda pure_lo,x
        sta VT0
        lda pure_hi,x
        jmp @tgt
@buzz:  lda buzz_lo,x
        sta VT0
        lda buzz_hi,x
        jmp @tgt
@rasp:  lda rasp_lo,x
        sta VT0
        lda rasp_hi,x
@tgt:   sta VT1

        ; ---- glide: CURN += (target-CURN) >> GLIDE
        lda GLFRESH
        bne @snap
        ldx P_GLIDE
        beq @snap
        sec
        lda VT0
        sbc CURNLO
        sta VT2
        lda VT1
        sbc CURNHI
        sta VT3
@gs:    lda VT3
        cmp #$80
        ror VT3
        ror VT2
        dex
        bne @gs
        lda VT2
        ora VT3
        beq @snap
        clc
        lda CURNLO
        adc VT2
        sta CURNLO
        lda CURNHI
        adc VT3
        sta CURNHI
        jmp @swp
@snap:  lda VT0
        sta CURNLO
        lda VT1
        sta CURNHI
        lda #0
        sta GLFRESH

        ; ---- sweep: absolute period that slides exponentially (VT2/VT3 = P)
@swp:   lda P_SWEEP
        sec
        sbc #7
        bne @sw1
        sta SWPON
        lda CURNLO
        sta VT2
        lda CURNHI
        sta VT3
        jmp @vib
@sw1:   sta VT4                 ; signed: + up, - down
        lda SWPON
        bne @sw2
        inc SWPON
        lda CURNLO
        sta SWPLO
        lda CURNHI
        sta SWPHI
@sw2:   lda VT4
        bpl @sp
        eor #$FF
        clc
        adc #1
@sp:    tax
        lda swsh,x
        tax
        lda SWPLO
        sta VT2
        lda SWPHI
        sta VT3
@ss:    lsr VT3
        ror VT2
        dex
        bne @ss
        lda VT2
        ora VT3
        bne @tn
        inc VT2
@tn:    lda VT4
        bmi @sdn
        sec                     ; up: period shrinks
        lda SWPLO
        sbc VT2
        sta VT2
        lda SWPHI
        sbc VT3
        sta VT3
        bcc @cmin
        bne @sst
        lda VT2
        cmp #16
        bcs @sst
@cmin:  lda #16
        sta VT2
        lda #0
        sta VT3
        beq @sst
@sdn:   clc                     ; down: period grows
        lda SWPLO
        adc VT2
        sta VT2
        lda SWPHI
        adc VT3
        sta VT3
        bcc @sst
        lda #$FF
        sta VT2
        sta VT3
@sst:   lda VT2
        sta SWPLO
        lda VT3
        sta SWPHI

        ; ---- vibrato: P +/- (P>>7)*depth (or half) on an 8-step triangle
@vib:   ldx P_VIB
        bne @von
        jmp @out
@von:
        lda VTMR
        beq @vst
        dec VTMR
        bne @vc
@vst:   lda #8
        sec
        sbc P_VIBSPD
        sta VTMR
        inc VPH
@vc:    lda VT2                 ; VT0/VT1 = P >> 7
        asl a
        lda VT3
        rol a
        sta VT0
        lda #0
        rol a
        sta VT1
        lda #0
        sta VT4
        sta VT5
@va:    clc
        lda VT4
        adc VT0
        sta VT4
        lda VT5
        adc VT1
        sta VT5
        dex
        bne @va
        lda VPH
        and #7
        tax
        lda vibtab,x
        beq @out
        cmp #3
        bcc @vf
        sbc #2                  ; 3 -> 1 (neg half), 4 -> 2 (neg full)
        tax
        lda #1
        sta VT1                 ; VT1 = negative flag
        txa
        jmp @vh
@vf:    ldx #0
        stx VT1
@vh:    cmp #1
        bne @vfull
        lsr VT5
        ror VT4
@vfull: lda VT1
        bne @vneg
        clc
        lda VT2
        adc VT4
        sta VT2
        lda VT3
        adc VT5
        sta VT3
        bcc @out
        lda #$FF
        sta VT2
        sta VT3
        bne @out
@vneg:  sec
        lda VT2
        sbc VT4
        sta VT2
        lda VT3
        sbc VT5
        sta VT3
        bcs @out
        lda #16
        sta VT2
        lda #0
        sta VT3

@out:   lda VT2
        sta OUTLO
        sta AUDF1
        lda VT3
        sta OUTHI
        sta AUDF2

        ; ---- ADSR envelope
        lda ESTATE
        bne @eon
        jmp @edone
@eon:   cmp #1
        bne @e2
        ldx P_ATK
        clc
        lda VOLLO
        adc atk_lo,x
        sta VOLLO
        lda VOLHI
        adc atk_hi,x
        sta VOLHI
        cmp #15
        bcc @edone
        lda #15
        sta VOLHI
        lda #0
        sta VOLLO
        lda #2
        sta ESTATE
        bne @edone
@e2:    cmp #2
        bne @e3
        ldx P_DEC
        sec
        lda VOLLO
        sbc dec_lo,x
        sta VOLLO
        lda VOLHI
        sbc dec_hi,x
        sta VOLHI
        bcc @tosus
        cmp P_SUS
        bcs @edone
@tosus: lda #3
        sta ESTATE
@e3:    cmp #3
        bne @e4
        lda P_SUS               ; sustain follows the editor live
        sta VOLHI
        lda #0
        sta VOLLO
        beq @edone
@e4:    ldx P_REL
        sec
        lda VOLLO
        sbc dec_lo,x
        sta VOLLO
        lda VOLHI
        sbc dec_hi,x
        sta VOLHI
        bcs @edone
        lda #0
        sta VOLHI
        sta VOLLO
        sta ESTATE
@edone: ldx P_WAVE
        lda VOLHI
        ora wavebits,x
        sta AUDC2
        lda #0
        sta AUDC1

        ; ---- layer voice (ch3) + echo ring
        ldx ECHOPOS
        lda NOTEIDX
        sta ECHON,x
        lda VOLHI
        sta ECHOV,x
        inx
        txa
        and #31
        sta ECHOPOS
        ldx P_LAYER
        beq @loff
        cpx #5
        beq @echo
        lda NOTEIDX
        clc
        adc layofs-1,x
        bpl @l1
        lda NOTEIDX             ; sub below C1: stay on the note
@l1:    cmp #96
        bcc @l2
        lda #95
@l2:    tay
        lda lay64,y
        cpx #4                  ; chorus: detune one step
        bne @l3
        cmp #64
        bcc @l3
        sbc #1                  ; carry set here: -1
@l3:    sta AUDF3
        lda VOLHI               ; 3/4 volume
        lsr a
        lsr a
        sta VT0
        lda VOLHI
        sec
        sbc VT0
        ora #$A0
        sta AUDC3
        rts
@echo:  lda ECHOPOS             ; the frame written 20 frames ago
        clc
        adc #11
        and #31
        tax
        ldy ECHON,x
        lda lay64,y
        sta AUDF3
        lda ECHOV,x
        lsr a
        ora #$A0
        sta AUDC3
        rts
@loff:  lda #0
        sta AUDC3
        rts

; ---------------------------------------------------------------------------
; DLI: piano colors for rows 3-7, GR.0 colors again from row 8
dli:
        pha
        txa
        pha
        tya
        pha
        lda VCOUNT
        cmp #40
        bcs @gr
        ldx LITCOL
        ldy #$0E
        lda #$04
        sta WSYNC
        sta COLPF0              ; black keys
        stx COLPF1              ; lit black key
        sty COLPF2              ; white keys
        stx COLPF3              ; lit white key
        jmp @x
@gr:    ldx COLOR1
        ldy COLOR2
        sta WSYNC
        stx COLPF1
        sty COLPF2
@x:     pla
        tay
        pla
        tax
        pla
        rti

; ===========================================================================
.segment "RODATA"

.include "tables.inc"

; waveform AUDC distortion bits: PURE BUZZ GRIT RASP NOISE HISS
wavebits:   .byte $A0,$C0,$40,$20,$80,$00

chord_start: .byte 0, 0,3,6,10,12,15
chord_len:   .byte 1, 3,3,4,2,3,3
chord_ofs:   .byte 0,4,7, 0,3,7, 0,4,7,10, 0,12, 0,7,12, 0,3,6

layofs:     .byte <-12, 7, 12, 0        ; SUB FIFTH OCT-UP CHORUS
swsh:       .byte 0, 9,8,7,6,5,4,3      ; sweep |n| -> shift
vibtab:     .byte 0,1,2,1,0,3,4,3       ; 1/2 +half/+full, 3/4 -half/-full
octbase:    .byte 0, 0,12,24,36,48,60,72

; drums: KICK SNARE HAT OPEN TOM TOM2 CLAP CRASH
dr_frq:     .byte 16, 10,  0,  1,110, 70, 24,  2
dr_dlt:     .byte  6,  0,  0,  0,  5,  3,  0,  0
dr_ctl:     .byte $C0,$80,$80,$80,$A0,$A0,$80,$80
dr_vsh:     .byte  1,  1,  0,  3,  1,  1,  0,  4
dr_len:     .byte 12, 12,  3, 24, 16, 14,  8, 60

cmdkeys:    .byte K_Z,K_X,K_UP,K_DOWN,K_LEFT,K_RIGHT,K_RET,K_ESC
NCMD = 8
cmdlo:      .byte <(oct_down-1),<(oct_up-1),<(ed_up-1),<(ed_down-1)
            .byte <(ed_left-1),<(ed_right-1),<(reset_preset-1),<(hush-1)
cmdhi:      .byte >(oct_down-1),>(oct_up-1),>(ed_up-1),>(ed_down-1)
            .byte >(ed_left-1),>(ed_right-1),>(reset_preset-1),>(hush-1)
numkeys:    .byte $1F,$1E,$1A,$18,$1D,$1B,$33,$35,$30,$32   ; 1..9, 0
presetkey:  .byte "1234567890"

; piano geometry: white key i -> note offset / black key right of i
whiteoff:   .byte 0,2,4,5,7,9,11,12,14,16
blkoff:     .byte 1,3,$FF,6,8,10,$FF,13,15,$FF
whitelbl:   .byte "ASDFGHJKL;"
blacklbl:   .byte "WE",0,"TYU",0,"OP",0

notenames:  .byte "C-C#D-D#E-F-F#G-G#A-A#B-"

drumnames:  .byte "C KICK  V SNARE B HAT   N OPEN  M TOM   , TOM2  . CLAP  / CRASH "

; presets: 8-char names, colors
pnames:     .byte "PIANO   ORGAN   FLUTE   STRINGS BASS    CHIPARP SYNTH   "
            .byte "BELL    LASER   UFO     "
pcolor:     .byte $1C,$3A,$BC,$5A,$86,$DA,$4A,$0E,$36,$CA
pbase:      .byte 0,13,26,39,52,65,78,91,104,117

; factory sounds, 13 bytes each:
;  WAVE ATK DEC SUS REL LAYER VIB VSPD CHORD CSPD SWEEP GLIDE | OCTAVE
factory:
        .byte 0, 0, 9, 0, 6,  0, 0,4, 0,7, 7,0, 4      ; 1 PIANO
        .byte 0, 0, 0,13, 1,  3, 0,4, 0,7, 7,0, 4      ; 2 ORGAN
        .byte 0, 5, 3,11, 4,  0, 2,5, 0,7, 7,0, 5      ; 3 FLUTE
        .byte 0, 9, 0,12, 8,  4, 1,4, 0,7, 7,0, 4      ; 4 STRINGS
        .byte 1, 0, 6, 7, 2,  0, 0,4, 0,7, 7,0, 2      ; 5 BASS
        .byte 0, 0, 0,12, 2,  0, 0,4, 1,7, 7,0, 4      ; 6 CHIPARP
        .byte 1, 1, 5,10, 3,  1, 2,5, 0,7, 7,2, 3      ; 7 SYNTH
        .byte 0, 0,12, 0,12,  5, 0,4, 0,7, 7,0, 5      ; 8 BELL
        .byte 0, 0, 6, 0, 2,  0, 0,4, 0,7, 1,0, 6      ; 9 LASER
        .byte 0, 3, 0,12, 6,  5, 7,6, 0,7, 8,0, 5      ; 0 UFO

; editor: labels (8), value types (0 bar16, 1 bar8, 2 names, 3 sweep)
plabels:    .byte "WAVE    ATTACK  DECAY   SUSTAIN RELEASE LAYER   "
            .byte "VIBRATO VIB SPD CHORD   CHD SPD SWEEP   GLIDE   "
ptype:      .byte 2,0,0,0,0,2, 1,1,2,1,3,1
pmin:       .byte 0,0,0,0,0,0, 0,1,0,1,0,0
pmax:       .byte 5,15,15,15,15,5, 7,7,6,7,14,7
pnlist_lo:  .byte <wavenm,0,0,0,0,<laynm, 0,0,<chordnm,0,0,0
pnlist_hi:  .byte >wavenm,0,0,0,0,>laynm, 0,0,>chordnm,0,0,0
wavenm:     .byte "PURE  BUZZ  GRIT  RASP  NOISE HISS  "
laynm:      .byte "OFF   SUB   FIFTH OCT UPCHORUSECHO  "
chordnm:    .byte "OFF   MAJOR MINOR 7TH   OCTAVEPOWER DIM   "
swtxt:      .byte "DOWN UP   OFF  "

static_text:
        .byte 0,0,$80, " POKEY SYNTH  -  8-BIT KEYBOARD    OCT  ",0
        .byte 9,1,0, "NOTE",0
        .byte 9,12,0, "VOLUME",0
        .byte 11,1,0, "DRUMS",0
        .byte 15,21,0, "< PICK: KEYS 1-9,0",0
        .byte 16,1,$80, "SOUND EDITOR",0
        .byte 16,14,0, "ARROWS/STICK: PICK, SET",0
        .byte 23,0,0, "Z/X OCTAVE  RETURN RESET  ESC SILENCE",0
        .byte $FF

; screen row address tables
rowlo:  .repeat 24, I
        .byte <(SCREEN + I*40)
        .endrepeat
rowhi:  .repeat 24, I
        .byte >(SCREEN + I*40)
        .endrepeat

; hot-swap trampoline code (copied to $0680)
tramp_code:
        .byte $AD,$7F,$06       ; LDA TRAMPFLG
        .byte $F0,$FB           ; BEQ *-3
        .byte $6C,$7C,$06       ; JMP (TRAMPVEC)

; custom glyphs: codes, 0-terminated, then 8 bytes each in the same order
glyph_codes: .byte G_W,G_X,G_B,G_C,G_D,G_E,G_F,G_H,G_O,0
glyph_data:
        .byte $FF,$FF,$FF,$FF,$FF,$FF,$FF,$FF   ; w  white
        .byte $FC,$FC,$FC,$FC,$FC,$FC,$FC,$FC   ; x  white | gap
        .byte $D5,$D5,$D5,$D5,$D5,$D5,$D5,$D5   ; b  W B B B
        .byte $EA,$EA,$EA,$EA,$EA,$EA,$EA,$EA   ; c  W L L L
        .byte $57,$57,$57,$57,$57,$57,$57,$57   ; d  B B B W
        .byte $AB,$AB,$AB,$AB,$AB,$AB,$AB,$AB   ; e  L L L W
        .byte $00,$7E,$7E,$7E,$7E,$7E,$7E,$00   ; f  meter full
        .byte $00,$70,$70,$70,$70,$70,$70,$00   ; h  meter half
        .byte $00,$00,$00,$18,$18,$00,$00,$00   ; o  meter empty

; ===========================================================================
.segment "DATA"
live:   .res 10*PSTRIDE
