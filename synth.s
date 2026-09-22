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
LOGPOS   = $0645        ; key logger: next slot (0-63)
LOGN     = $0646        ;   total changes logged (wraps)
LASTKB   = $0647        ;   last KBCODE seen
LASTSK   = $0648        ;   last SKSTAT & $0C seen
LOGBUF   = $0A40        ; 64 x (RTCLOK lo, VCOUNT, KBCODE, SKSTAT&$0C)
ZWF      = $8C          ; wait_frame: frame to wait past

; ---- looper: per-frame lanes, one byte per frame, up to 4096 frames ----
MLANE    = $5000        ; track 1 melody: 0 none, 1-96 note-on (n+1), $FE off
DLANE    = $6000        ; drums:  0 none, 1-8 drum (d+1)
PLANE    = $7000        ; track 1 preset: 0 none, 1-10 preset (p+1)
M2LANE   = $8000        ; track 2 melody (overdub), same codes as MLANE
P2LANE   = $9000        ; track 2 preset
LANEPGS  = $50          ; 20 KB cleared at record start
MAXLOOP  = $10          ; hi byte of the 4096-frame cap
LSTATE   = $0649        ; 0 empty 1 rec 2 play 3 dub (play+record drums) 4 stop
LCMD     = $064A        ; main -> VBI: 1 SPACE 2 TAB 3 clear 4 stop
LPOSLO   = $064B        ; loop position (frames)
LPOSHI   = $064C
LLENLO   = $064D        ; loop length (frames)
LLENHI   = $064E
LCELL    = $064F        ; progress 0-16 for the bar
LACCLO   = $0650        ; progress accumulator (16 per frame vs LLEN)
LACCHI   = $0651
LIVEM    = $0652        ; this frame's live melody event (lane code)
LIVED    = $0653        ; this frame's live drum (d+1)
LIVEP    = $0654        ; this frame's preset change (p+1), set by main
PRESREQ  = $0655        ; VBI -> main: playback wants preset ($FF none)
LASTLS   = $0656        ; main: loop state as drawn
LASTCELL = $0657
LOOPCNT  = $0658        ; +1 per loop wrap (liveness)
; loop voices: two 20-byte blocks, slot 0 = track 1, slot 1 = track 2
;   mono:   slot 0 -> POKEY1 ch3 (8-bit), slot 1 unused (track 2 -> lead)
;   stereo: slot 0 -> POKEY2 ch1+2 (16-bit), slot 1 -> POKEY2 ch3 (8-bit)
VB       = $0B40
VBS      = 20           ; block size / offset of slot 1
V_PRE    = VB+0         ; preset of the track's sound
V_NOTE   = VB+1
V_EST    = VB+2         ; envelope state (as ESTATE)
V_VLO    = VB+3
V_VHI    = VB+4
V_APOS   = VB+5
V_ATMR   = VB+6
V_IDX    = VB+7         ; note incl. chord
V_PAR    = VB+8         ; 12 bytes: preset params (copied from live)
V2EST    = V_EST        ; slot-0 aliases (tests, docs)
V2VHI    = V_VHI
V2PRE    = V_PRE
; drums: two 8-byte blocks, 0 = live (POKEY1 ch4), 8 = loop in stereo
; (POKEY2 ch4); in mono the loop's drums use block 0 too (a live hit wins)
DB       = $0B68
D_TMR    = DB+0
D_FRQ    = DB+1
D_DLT    = DB+2
D_CTL    = DB+3
D_VSH    = DB+4
D_CLK    = DB+5
D_SEQ    = DB+6             ; scripted drum: index into drseq (0 = envelope drum)
; POKEY register image, both chips: the VBI engines write here and
; pokey_out copies it at the end of the VBI (POKEY registers are write-only,
; so the image is what makes mirroring POKEY1 onto POKEY2 possible)
SH       = $0B78        ; 32 bytes = $D200-$D21F
SAUDF1   = SH+0
SAUDC1   = SH+1
SAUDF2   = SH+2
SAUDC2   = SH+3
SAUDF3   = SH+4
SAUDC3   = SH+5
SAUDF4   = SH+6
SAUDC4   = SH+7
POLY4B   = $0B98        ; 1 = a loop chord tone owns POKEY2 ch4 this frame
NOTE2CNT = $066D        ; +1 per slot-0 (track 1) note-on
T1USED   = $066E        ; track 1 has melody -> voice 2 owns ch3 in PLAY/DUB
DEMOIDX  = $066F        ; built-in demo loaded: 1..NDEMO, 0 = none
LASTDEMO = $0670        ; main: demo name as drawn
MUTEMEL  = $0671        ; 1 = loop plays drums only (melody tracks muted)
NOTE3CNT = $0672        ; +1 per slot-1 (track 2, stereo) note-on
STEREO   = $0673        ; 1 = a second POKEY answers at $D210 (auto-detected)
LASTSTE  = $0674        ; main: title as drawn
POLY4    = $0675        ; 1 = a held chord tone owns POKEY1 ch4 this frame
; song mode (driven by the PC's songfile.py): two lane banks of 2048 frames
LBANK    = $0676        ; $00 / $08: hi-byte offset of the playing bank
NEXTREQ  = $0677        ; PC -> VBI at the next wrap: 1 switch bank, 2 stop
NEXTLEN  = $0678        ; 2 bytes: the other bank's section length
NEXTT1   = $067A        ; ... and its T1USED
SECTCNT  = $067B        ; +1 per section switch / song end (last page-6 byte)
CH_AUTO  = 7            ; CHORD value: diatonic auto-chord (C major)
K_R      = $28          ; toggles AUTO held chords on the current preset
P2       = $10          ; POKEY2 register offset from POKEY1
RANDOM   = $D20A
K_Q      = $2F          ; toggles MUTEMEL
K_LT     = $36          ; '<' (PC '-' in Atari layout): previous demo
K_GT     = $37          ; '>' (PC '='): next demo
; demo loader ZP (main thread)
ZMUL     = $8D          ; 16-bit product / frame
ZSTEP    = $8F          ; frames per step (S)
ZNST     = $90          ; steps (N)
ZEV      = $91          ; event: step
ZNOTE    = $92          ;        note
ZDUR     = $93          ;        dur
ZLANE    = $94          ; lane page base (hi byte)
LS_EMPTY = 0
LS_REC   = 1
LS_PLAY  = 2
LS_DUB   = 3
LS_STOP  = 4
VP       = $F0          ; VBI-owned ZP pointer (lanes); documented exception
K_SPACE  = $21
K_TAB    = $2C
K_BKSP   = $34

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

.segment "XEXHDR2"
.import __HIMEM_START__, __HIMEM_LAST__
        .word __HIMEM_START__
        .word __HIMEM_LAST__-1

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
        lda #$FE                ; force first piano/loop draw
        sta LASTLIT
        sta LASTLS
        lda #$FF
        sta PRESREQ
        sta LASTDEMO
        sta LASTSTE

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
        ldx #VBS*2+16+32-1      ; loop voice + drum blocks + register image
        lda #0
@vz:    sta VB,x
        dex
        bpl @vz
        jsr detect_stereo
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
        jsr read_stick
        jsr read_console
        jsr main_tick
        jmp mainloop

main_tick:
        inc UICNT
        lda KEYSEQ
        cmp LASTSEQ
        beq @nk
        sta LASTSEQ
        lda KEYEV
        jsr handle_key
@nk:    lda PRESREQ             ; loop playback switched the sound
        cmp #$FF
        beq @ui
        tay
        ldx #$FF
        stx PRESREQ
        lda OCTAVE              ; keep the player's octave (on the stack:
        pha                     ;  select_preset's drawing uses the ZTs)
        tya
        jsr select_preset
        pla
        sta OCTAVE
        jsr set_octave
        lda #0                  ; ...which is playback, not a new change
        sta LIVEP
@ui:    jmp ui_update

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

; while waiting, log every change of the raw keyboard registers so a
; two-key test on the real keyboard shows exactly what POKEY reports
wait_frame:
        lda RTCLOK+2
        sta ZWF
@w:     lda KBCODE
        cmp LASTKB
        bne @log
        lda SKSTAT
        and #$0C
        cmp LASTSK
        beq @nx
@log:   lda KBCODE
        sta LASTKB
        lda SKSTAT
        and #$0C
        sta LASTSK
        lda LOGPOS
        asl a
        asl a
        tax
        lda RTCLOK+2
        sta LOGBUF,x
        lda VCOUNT
        sta LOGBUF+1,x
        lda LASTKB
        sta LOGBUF+2,x
        lda LASTSK
        sta LOGBUF+3,x
        inc LOGN
        lda LOGPOS
        clc
        adc #1
        and #63
        sta LOGPOS
@nx:    lda RTCLOK+2
        cmp ZWF
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

loop_space:
        lda LSTATE
        bne @go                 ; EMPTY -> fresh lanes before recording
        jsr clear_lanes
        lda #0
        sta DEMOIDX
@go:    lda #1
        sta LCMD
        rts
loop_tab:
        lda #2
        sta LCMD
        rts
toggle_chords:                  ; R: AUTO held chords on/off (this preset)
        lda P_CHORD
        cmp #CH_AUTO
        bne @on
        lda P_CHDSPD
        bne @on
        lda #0                  ; was AUTO+POLY -> chords off
        ldy #7
        bne @set
@on:    lda #CH_AUTO
        ldy #0
@set:   sta P_CHORD
        sty P_CHDSPD
        ldx PRESET              ; keep it in the live preset (RETURN undoes)
        ldy pbase,x
        sta live+8,y
        lda P_CHDSPD
        sta live+9,y
        ldx #8
        jsr draw_param
        ldx #9
        jmp draw_param

toggle_mute:
        lda #5
        sta LCMD
        rts

loop_clear:
        lda #3
        sta LCMD
        lda #0
        sta DEMOIDX
        rts

; ---- built-in demos: < > step through them; each loads and plays ---------
prev_demo:
        ldx DEMOIDX
        dex
        beq @w
        bpl load_demo
@w:     ldx #NDEMO
        bne load_demo
next_demo:
        ldx DEMOIDX
        cpx #NDEMO
        bcc @n
        ldx #0
@n:     inx
load_demo:                      ; X = demo 1..NDEMO
        stx DEMOIDX
        dex
        lda demo_lo,x
        sta ZPTR
        lda demo_hi,x
        sta ZPTR+1
        lda #3                  ; stop + empty the loop, wait for the VBI
        sta LCMD
        jsr wait_lcmd
        jsr clear_lanes
        lda ZPTR                ; skip the 8-char name
        clc
        adc #8
        sta ZPTR
        bcc @h
        inc ZPTR+1
@h:     jsr getb
        sta ZSTEP
        jsr getb
        sta ZNST
        jsr getb                ; P1 -> track 1 preset at frame 0
        sta PLANE
        jsr getb                ; P2 -> track 2 preset
        sta P2LANE
        lda #>MLANE
        jsr load_track
        sta T1USED              ; nonzero if track 1 had notes
        lda #>M2LANE
        jsr load_track
        ; drums: one byte per step
        lda #0
        sta ZEV
@d:     jsr getb
        beq @dn
        pha
        lda ZEV
        jsr step_frame
        lda #>DLANE
        jsr lane_at
        pla
        ldy #0
        sta (ZSCR),y
@dn:    inc ZEV
        lda ZEV
        cmp ZNST
        bne @d
        lda ZNST                ; LLEN = N*S
        jsr step_frame
        lda ZMUL
        sta LLENLO
        lda ZMUL+1
        sta LLENHI
        lda #LS_STOP            ; VBI ignores lanes until TAB plays them
        sta LSTATE
        lda #2
        sta LCMD
        rts

wait_lcmd:                      ; until the VBI has taken LCMD
        lda LCMD
        bne wait_lcmd
        rts

getb:   ldy #0                  ; A = next demo byte (flags from lda)
        lda (ZPTR),y
        inc ZPTR
        bne @x
        inc ZPTR+1
@x:     cmp #0
        rts

step_frame:                     ; ZMUL = A * ZSTEP
        sta ZT1
        lda #0
        sta ZMUL
        sta ZMUL+1
        ldx ZSTEP
@m:     clc
        lda ZMUL
        adc ZT1
        sta ZMUL
        bcc @c
        inc ZMUL+1
@c:     dex
        bne @m
        rts

lane_at:                        ; ZSCR = (A<<8) + ZMUL
        clc
        adc ZMUL+1
        sta ZSCR+1
        lda ZMUL
        sta ZSCR
        rts

load_track:                     ; A = lane page; events until $FF
        sta ZLANE               ; returns A = number of notes
        lda #0
        sta ZT2
@e:     jsr getb
        cmp #$FF
        beq @x
        sta ZEV
        jsr getb
        sta ZNOTE
        jsr getb
        sta ZDUR
        inc ZT2
        lda ZEV                 ; note-on at step*S
        jsr step_frame
        lda ZLANE
        jsr lane_at
        ldy #0
        ldx ZNOTE
        inx
        txa
        sta (ZSCR),y
        lda ZEV                 ; note-off 2 frames before (step+dur)*S
        clc
        adc ZDUR
        jsr step_frame
        lda ZMUL
        sec
        sbc #2
        sta ZMUL
        bcs @o
        dec ZMUL+1
@o:     lda ZLANE
        jsr lane_at
        ldy #0
        lda #$FE
        sta (ZSCR),y
        jmp @e
@x:     lda ZT2
        rts

clear_lanes:
        lda #>MLANE
        sta ZSCR+1
        lda #0
        sta ZSCR
        tay
        ldx #LANEPGS
@c:     sta (ZSCR),y
        iny
        bne @c
        inc ZSCR+1
        dex
        bne @c
        rts

; Second POKEY at $D210? With no stereo hardware $D21x mirrors POKEY1, so:
; run POKEY1, then put "$D21F" into init. Mirror -> POKEY1 itself is now in
; init and RANDOM freezes; real POKEY2 -> POKEY1's RANDOM keeps running.
; Safe on any Atari (a few microseconds of POKEY1 init at worst).
detect_stereo:
        lda #0
        sta STEREO              ; VBI stays off POKEY2 meanwhile
        php
        sei
        lda #3
        sta SKCTL
        lda #0
        sta SKCTL+P2
        ldx #8
@s:     lda RANDOM
        cmp RANDOM
        bne @st
        dex
        bne @s
        lda #3                  ; mono: POKEY1 back out of init
        sta SKCTL+P2
        sta SKCTL
        plp
        rts
@st:    lda #3
        sta SKCTL+P2
        sta SKCTL
        lda #$50                ; POKEY2 like POKEY1: ch1 1.79 MHz + 1/2 joined
        sta AUDCTL+P2
        lda #0
        ldx #7
@z:     sta AUDF1+P2,x
        dex
        bpl @z
        sta D_TMR+8
        lda #1
        sta STEREO
        plp
        rts

hush:
        jsr detect_stereo       ; ESC re-checks (e.g. stereo just enabled)
        lda #4                  ; stop the loop too
        sta LCMD
        lda #0
        sta ESTATE
        sta VOLHI
        sta VOLLO
        sta D_TMR
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
        ldx PRESET
        inx
        stx LIVEP               ; recorder: preset change this frame
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
@m:     lda LSTATE              ; PLAY + muted shows as DRUMS (name 5)
        cmp #LS_PLAY
        bne @m1
        ldx MUTEMEL
        beq @m1
        lda #5
@m1:    cmp LASTLS
        beq @lc
        sta LASTLS
        sta ZT1
        asl a
        asl a
        adc ZT1                 ; *5
        tax
        ldy #0
        lda #0
        sta ZATTR
        lda LSTATE
        cmp #LS_REC
        beq @lr
        cmp #LS_DUB
        bne @ls
@lr:    lda #$80                ; recording states in inverse
        sta ZATTR
@ls:    lda lsnames,x
        jsr asc2int
        ora ZATTR
        sta SCREEN+10*40+6,y
        inx
        iny
        cpy #5
        bne @ls
        lda #$FE
        sta LASTCELL
@lc:    lda LCELL
        cmp LASTCELL
        beq @mv
        sta LASTCELL
        ldx #0
@lb:    lda #G_O
        cpx LCELL
        bcs @lp
        lda #G_F
@lp:    sta SCREEN+10*40+12,x
        inx
        cpx #16
        bne @lb
@mv:    lda STEREO
        cmp LASTSTE
        beq @md
        sta LASTSTE
        ldx #0
        ldy #0
        lda STEREO
        beq @tw
        ldy #14
@tw:    lda titlewords,y
        jsr asc2int
        ora #$80
        sta SCREEN+17,x
        iny
        inx
        cpx #14
        bne @tw
@md:    lda DEMOIDX
        cmp LASTDEMO
        beq @vm
        sta LASTDEMO
        jsr draw_demo
@vm:    ; volume meter: row 9, cols 19-33
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

draw_demo:                      ; row 10 col 29: "< DEMOS  >" / "<NAME    >"
        ldx #0
        lda DEMOIDX
        bne @nm
@t:     lda qdemotxt,x
        jsr asc2int
        sta SCREEN+10*40+29,x
        inx
        cpx #10
        bne @t
        rts
@nm:    tax
        dex
        lda demo_lo,x
        sta ZPTR
        lda demo_hi,x
        sta ZPTR+1
        lda #'<'-32
        sta SCREEN+10*40+29
        lda #'>'-32
        sta SCREEN+10*40+38
        ldy #0
@c:     lda (ZPTR),y
        jsr asc2int
        ora #$80
        sta SCREEN+10*40+30,y
        iny
        cpy #8
        bne @c
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
        cmp #4                  ; CHD SPD: 0 = POLY (held chord)
        bne @sw0
        lda ZT3
        bne @b8
        ldx #0
@pt:    lda polytxt,x
        jsr asc2int
        sta (ZSCR),y
        iny
        inx
        cpx #4
        bne @pt
        jmp @pad
@sw0:   jmp @swp
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
        jsr loop_step
        jsr synth
        lda #0
        sta POLY4B
        ldx #VBS                ; track 2 first: track 1's chord tone may
        jsr lv_step             ;  then take its ch3 while it's silent
        ldx #0
        jsr lv_step
        jsr drum_step
        jsr pokey_out
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
        lda STEREO              ; key down: POKEY2 (no keyboard) must say up
        beq @kc
        lda SKSTAT+P2
        and #$04
        bne @kc
        lda #0                  ; it mirrors POKEY1: stereo was switched off
        sta STEREO
        sta D_TMR+8
@kc:    lda KBCODE
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
        lda #$FE                ; recorder: note-off this frame
        sta LIVEM
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
        clc
        adc #1
        sta LIVEM               ; recorder: note-on this frame
        lda #1
        sta GATE
        jmp note_start

note_play:                      ; A = note 0-95 from the loop
        sta NOTE
        sec
        sbc OCTBASE
        cmp #17
        bcc @lit
        lda #$FF
@lit:   sta LITKEY

note_start:
        inc NOTECNT
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

note_stop:                      ; loop note-off (a held live key wins)
        lda GATE
        bne @x
        lda #$FF
        sta LITKEY
        lda ESTATE
        beq @x
        lda #4
        sta ESTATE
@x:     rts

drum_trig:                      ; A = drum 0-7, live pad (or mono loop)
        tax
        inx
        stx LIVED               ; recorder: drum this frame
        ldx #0
drum_start:                     ; A = drum, X = block (0 live / 8 loop)
        tay
        sty DRUMLIT
        inc DRUMCNT
        lda dr_frq,y
        sta D_FRQ,x
        lda dr_dlt,y
        sta D_DLT,x
        lda dr_ctl,y
        sta D_CTL,x
        lda dr_vsh,y
        sta D_VSH,x
        lda dr_clk,y
        sta D_CLK,x
        lda dr_len,y
        sta D_TMR,x
        lda dr_seq,y            ; scripted (frame-by-frame register) drum?
        sta D_SEQ,x
        beq @e
        lda #$FF                ; "sounding" until its script ends
        sta D_TMR,x
@e:     rts

drum_step:                      ; VBI: block 0 on POKEY1 ch4, block 8 on POKEY2
        ldx #0
        ldy #$06
        jsr drum_one
        lda STEREO
        beq @m
        ldx #8
        ldy #$06+P2
        jsr drum_one
@m:     lda D_TMR
        ora D_TMR+8
        bne @x
        lda #$FF
        sta DRUMLIT
@x:     rts

drum_one:                       ; X = block, Y = AUDF register offset
        lda D_TMR,x
        bne @on
        jmp @off
@on:    lda D_SEQ,x
        beq @env
        sty VT0                 ; script: one (AUDF, AUDC) pair per frame,
        ldy D_SEQ,x             ;  AUDC 0 ends it
        lda drseq,y
        beq @send
        sta VT1
        lda drseq-1,y
        ldy VT0
        sta SAUDF1,y
        lda VT1
        sta SAUDC1,y
        inc D_SEQ,x
        inc D_SEQ,x
        rts
@send:  sta D_SEQ,x
        sta D_TMR,x
        ldy VT0
        sta SAUDC1,y
        rts
@env:   dec D_TMR,x
        lda D_CLK,x             ; attack transient: one frame of loud noise
        beq @body
        sta SAUDF1,y
        lda #$8F
        sta SAUDC1,y
        lda #0
        sta D_CLK,x
        rts
@body:  lda D_FRQ,x
        clc
        adc D_DLT,x
        bcc @nf
        lda #0
        sta D_DLT,x
        lda #$FF
@nf:    sta D_FRQ,x
        sta SAUDF1,y
        lda D_TMR,x             ; vol = min(TMR*4 >> VSH, 15)
        asl a
        asl a
        sty VT0
        ldy D_VSH,x
        beq @nv
@sh:    lsr a
        dey
        bne @sh
@nv:    ldy VT0
        cmp #16
        bcc @v
        lda #15
@v:     ora D_CTL,x
        sta SAUDC1,y
        rts
@off:   cpx #0                  ; idle block: a chord tone may own its ch4
        bne @o0
        lda POLY4
        jmp @o1
@o0:    lda POLY4B
@o1:    bne @o3
        lda #0
        sta SAUDC1,y
@o3:    rts

; ---------------------------------------------------------------------------
; looper (VBI). Commands arrive through LCMD; lanes are cleared by the main
; thread before it posts the first SPACE (state EMPTY = VBI never touches them)
loop_step:
        lda LCMD
        beq @run
        ldx #0
        stx LCMD
        jsr loop_cmd
@run:   lda LSTATE
        cmp #LS_REC
        beq lp_rec
        cmp #LS_PLAY
        beq lp_play
        cmp #LS_DUB
        beq lp_play
lp_clear:
        lda #0
        sta LIVEM
        sta LIVED
        sta LIVEP
        rts

lp_rec: jsr lp_ptr
        ldy #0
        lda LIVEM
        sta (VP),y
        beq @nm
        sta T1USED
@nm:    jsr lp_next
        lda LIVED
        sta (VP),y
        jsr lp_next
        lda LIVEP
        sta (VP),y
        jsr lp_clear
        inc LPOSLO
        bne @c
        inc LPOSHI
@c:     lda LPOSHI
        sta LCELL               ; recording: bar = fill of the 4096 cap
        cmp #MAXLOOP
        bcc @x
        jmp lp_close            ; cap reached: close and play
@x:     rts

lp_play:
        jsr lp_ptr
        ldy #0
        lda MUTEMEL             ; drums-only: skip both melody tracks
        bne @d
        lda (VP),y              ; track 1 melody -> voice 2
        beq @d
        cmp #$FE
        beq @off
        sec
        sbc #1
        ldx #0
        jsr lv_on
        jmp @d
@off:   ldx #0
        jsr lv_off
@d:     jsr lp_ptr
        jsr lp_next
        ldy #0
        lda STEREO              ; stereo: loop drums have their own channel
        beq @dm
        lda (VP),y
        beq @dsl
        sec
        sbc #1
        ldx #8
        jsr drum_start
        ldy #0
@dsl:   lda LIVED
        bne @dub
        beq @p
@dm:    lda LIVED               ; mono: a live hit wins this frame
        bne @dub
        lda (VP),y
        beq @p
        sec
        sbc #1
        jsr drum_trig
        lda #0
        sta LIVED               ; playback, not a new live hit
        beq @p
@dub:   ldx LSTATE
        cpx #LS_DUB
        bne @p
        sta (VP),y              ; overdub: stamp the live hit into the lane
@p:     jsr lp_next
        lda (VP),y              ; track 1 preset -> voice 2's sound
        beq @t2
        sec
        sbc #1
        ldx #0
        jsr lv_load
@t2:    jsr lp_next             ; track 2 melody -> lead (a live note wins)
        ldy #0
        lda LIVEM
        bne @m2dub
        lda MUTEMEL
        bne @q2
        lda (VP),y
        beq @q2
        ldx STEREO              ; stereo: track 2 has its own voice
        bne @m2st
        cmp #$FE
        beq @m2off
        sec
        sbc #1
        jsr note_play
        jmp @q2
@m2off: jsr note_stop
        jmp @q2
@m2st:  ldx #VBS
        cmp #$FE
        beq @m2so
        sec
        sbc #1
        jsr lv_on
        jmp @q2
@m2so:  jsr lv_off
        jmp @q2
@m2dub: ldx LSTATE              ; overdub: stamp the live note event
        cpx #LS_DUB
        bne @q2
        sta (VP),y
@q2:    jsr lp_next             ; track 2 preset -> the lead
        ldy #0
        lda LIVEP
        bne @q2dub
        lda MUTEMEL             ; drums-only: the player keeps their sound
        bne @adv
        lda (VP),y
        beq @adv
        sec
        sbc #1
        ldx STEREO              ; stereo: track 2's own voice, not the lead
        bne @p2st
        sta PRESREQ
        jmp @adv
@p2st:  ldx #VBS
        jsr lv_load
        jmp @adv
@q2dub: ldx LSTATE
        cpx #LS_DUB
        bne @adv
        sta (VP),y
@adv:   jsr lp_clear
        clc                     ; progress: +16/frame vs LLEN (Bresenham)
        lda LACCLO
        adc #16
        sta LACCLO
        bcc @a1
        inc LACCHI
@a1:    lda LACCLO
        cmp LLENLO
        lda LACCHI
        sbc LLENHI
        bcc @pos
        sta LACCHI
        lda LACCLO
        sbc LLENLO
        sta LACCLO
        inc LCELL
@pos:   inc LPOSLO
        bne @p2
        inc LPOSHI
@p2:    lda LPOSLO
        cmp LLENLO
        bne @x
        lda LPOSHI
        cmp LLENHI
        bne @x
        jmp lp_wrap
@x:     rts

lp_wrap:                        ; end of a pass: song mode may switch sections
        lda NEXTREQ
        beq lp_rewind
        cmp #2
        beq @stop
        lda LBANK
        eor #$08
        sta LBANK
        lda NEXTLEN
        sta LLENLO
        lda NEXTLEN+1
        sta LLENHI
        lda NEXTT1
        sta T1USED
        lda #0
        sta NEXTREQ
        inc SECTCNT
        jmp lp_rewind
@stop:  lda #0                  ; song over: stop at the seam
        sta NEXTREQ
        inc SECTCNT
        lda #LS_STOP
        sta LSTATE
        jsr lp_rewind
        jmp lp_hush

lp_rewind:
        lda #0
        sta LPOSLO
        sta LPOSHI
        sta LACCLO
        sta LACCHI
        sta LCELL
        inc LOOPCNT
        rts

lp_ptr: clc                     ; VP = MLANE + bank + LPOS
        lda LPOSLO
        sta VP
        lda LPOSHI
        adc #>MLANE
        adc LBANK
        sta VP+1
        rts

lp_next:                        ; next lane, same frame
        lda VP+1
        clc
        adc #$10
        sta VP+1
        rts

lp_close:                       ; end the first recording: LLEN = LPOS
        lda LPOSHI
        bne @ok
        lda LPOSLO
        cmp #30
        bcs @ok
        jmp lp_empty            ; under half a second: cancel
@ok:    lda LPOSLO
        sta LLENLO
        lda LPOSHI
        sta LLENHI
        lda GATE                ; key still held: end the note at the seam
        beq @go
        lda LPOSLO
        sec
        sbc #1
        sta VP
        lda LPOSHI
        sbc #0
        clc
        adc #>MLANE
        sta VP+1
        ldy #0
        lda (VP),y
        bne @go
        lda #$FE
        sta (VP),y
@go:    jsr lp_rewind
        lda #LS_PLAY
        sta LSTATE
        rts

lp_empty:
        lda #LS_EMPTY           ; (= 0)
        sta LSTATE
        sta LBANK               ; back to bank 0, no pending section
        sta NEXTREQ
lp_hush:
        lda #0
        sta LCELL
        sta V2EST
        sta V2VHI
        sta V_EST+VBS
        sta V_VHI+VBS
        lda GATE
        bne @x
        lda ESTATE
        beq @x
        lda #4
        sta ESTATE
@x:     rts

lp_mute:                        ; toggle drums-only; silence the loop's voices
        lda MUTEMEL
        eor #1
        sta MUTEMEL
        beq @x
        lda #0
        sta V2EST
        sta V2VHI
        sta V_EST+VBS
        sta V_VHI+VBS
        lda GATE                ; a held live note keeps sounding
        bne @x
        lda ESTATE
        beq @x
        lda #4
        sta ESTATE
@x:     rts

lp_dub: ldx PRESET              ; track 2 starts in the current sound
        inx
        stx LIVEP
        lda #LS_DUB
        sta LSTATE
        rts

loop_cmd:                       ; A = command
        cmp #1
        bne @tab
        ldx LSTATE              ; SPACE: rec / close / overdub toggle
        cpx #LS_EMPTY
        bne @s1
        jsr lp_rewind
        lda #0
        sta LOOPCNT
        sta LBANK               ; a fresh recording lives in bank 0
        sta T1USED
        sta V2EST
        sta V2VHI
        sta V_EST+VBS
        sta V_VHI+VBS
        ldx PRESET              ; the loop starts in the current sound
        inx
        stx LIVEP
        lda #LS_REC
        sta LSTATE
        rts
@s1:    cpx #LS_REC
        bne @s2
        jmp lp_close
@s2:    cpx #LS_PLAY
        bne @s3
        jmp lp_dub
@s3:    cpx #LS_DUB
        bne @s4
        lda #LS_PLAY
        sta LSTATE
        rts
@s4:    jsr lp_rewind           ; STOP: overdub from the top
        jmp lp_dub
@tab:   cmp #2
        bne @clr
        ldx LSTATE              ; TAB: play / stop
        cpx #LS_REC
        bne @t1
        jsr lp_close
        lda LSTATE
        cmp #LS_PLAY
        bne @tx
        lda #LS_STOP
        sta LSTATE
        jmp lp_hush
@t1:    cpx #LS_STOP
        bne @t2
        jsr lp_rewind
        lda #LS_PLAY
        sta LSTATE
        rts
@t2:    cpx #LS_EMPTY
        beq @tx
        lda #LS_STOP
        sta LSTATE
        jmp lp_hush
@tx:    rts
@clr:   cmp #5
        bne @c3
        jmp lp_mute
@c3:    cmp #3
        bne @stp
        jmp lp_empty
@stp:   ldx LSTATE              ; 4: stop if playing
        cpx #LS_PLAY
        beq @st
        cpx #LS_DUB
        bne @tx
@st:    lda #LS_STOP
        sta LSTATE
        rts

.segment "HIDATA"                ; (code runs from any segment)
; ---- loop voices: wave, ADSR, chord; X = block (0 or VBS) --------------
lv_load:                        ; A = preset: copy its live params
        sta V_PRE,x
        stx VT5
        tay
        lda pbase,y
        tay
        lda #NPARAM
        sta VT4
@c:     lda live,y
        sta V_PAR,x
        iny
        inx
        dec VT4
        bne @c
        ldx VT5
        rts

lv_on:                          ; A = note 0-95
        sta V_NOTE,x
        lda #1
        sta V_EST,x
        sta V_ATMR,x
        lda #$FF
        sta V_APOS,x
        cpx #0
        bne @t2
        inc NOTE2CNT
        rts
@t2:    inc NOTE3CNT
        rts

lv_off:
        lda V_EST,x
        beq @x
        lda #4
        sta V_EST,x
@x:     rts

v2_owns:                        ; Z clear (bne) when slot 0 owns POKEY1 ch3
        lda STEREO              ; stereo: never (it lives on POKEY2)
        bne @no
        lda MUTEMEL
        bne @no
        lda T1USED
        beq @no
        lda LSTATE
        cmp #LS_PLAY
        beq @yes
        cmp #LS_DUB
        beq @yes
@no:    lda #0
        rts
@yes:   lda #1
        rts

lv_step:                        ; VBI, X = block
        lda LSTATE
        cmp #LS_PLAY
        beq @pl
        cmp #LS_DUB
        bne @idle
@pl:    lda MUTEMEL
        bne @idle
        lda STEREO
        bne @st
        cpx #0                  ; mono: slot 0 on POKEY1 ch3 if track 1
        bne @x                  ;  has melody (else the layer keeps ch3)
        lda T1USED
        beq @x
        ldy #$04
        lda #0
        beq @go
@st:    ldy #P2                 ; stereo: slot 0 = POKEY2 ch1+2 16-bit,
        lda #1                  ;         slot 1 = POKEY2 ch3 8-bit
        cpx #0
        beq @go
        ldy #$04+P2
        lda #0
        beq @go
@idle:  lda STEREO              ; POKEY2 voices must not hang on stop
        beq @x
        lda #0
        cpx #0
        bne @i1
        sta SAUDC1+P2
        sta SAUDC2+P2
        rts
@i1:    sta SAUDC3+P2
@x:     rts
@go:    sty VT2                 ; AUDF register offset
        sta VT3                 ; 1 = 16-bit pair
        lda #0
        sta VT1                 ; 1 = render a held chord (lv_tones)
        lda V_PAR+8,x           ; chord
        beq @na
        sta VT0
        lda V_PAR+9,x           ; CHD SPD; 0 = POLY (held chord)
        bne @spd
        lda STEREO              ; stereo track 1: a real chord on POKEY2
        beq @fast
        cpx #0
        bne @fast
        inc VT1
        bne @na                 ; the root here, the tones in lv_tones
@fast:  lda #8                  ; no spare channels: a 1-frame arpeggio
@spd:   sta VT4
        lda V_ATMR,x
        beq @as
        dec V_ATMR,x
        bne @am
@as:    lda #9
        sec
        sbc VT4
        sta V_ATMR,x
        inc V_APOS,x
@am:    ldy VT0
        lda V_APOS,x
        cmp chord_len,y
        bcc @ai
        lda #0
        sta V_APOS,x
@ai:    cpy #CH_AUTO
        beq @au
        clc
        adc chord_start,y
        tay
        lda chord_ofs,y
        jmp @of
@au:    tay                     ; AUTO: the note's own diatonic triad
        beq @of
        sty VT5
        ldy V_NOTE,x
        lda notepc,y
        tay
        lda auto3,y
        dec VT5
        beq @of
        lda auto5,y
        jmp @of
@na:    lda #0
@of:    clc
        adc V_NOTE,x
        cmp #96
        bcc @nk
        lda #95
@nk:    sta V_IDX,x
        tay
        lda VT3
        bne @p16
        lda V_PAR,x             ; 8-bit @64 kHz tables
        cmp #1
        beq @bz
        cmp #3
        beq @rs
        lda lay64,y
        jmp @pf
@bz:    lda buzz64,y
        jmp @pf
@rs:    lda rasp64,y
@pf:    ldy VT2
        sta SAUDF1,y
        jmp @env
@p16:   lda V_PAR,x             ; 16-bit @1.79 MHz tables (as the lead)
        cmp #1
        beq @b16
        cmp #3
        beq @r16
        lda pure_lo,y
        sta VT0
        lda pure_hi,y
        jmp @w16
@b16:   lda buzz_lo,y
        sta VT0
        lda buzz_hi,y
        jmp @w16
@r16:   lda rasp_lo,y
        sta VT0
        lda rasp_hi,y
@w16:   ldy VT2
        sta SAUDF2,y
        lda VT0
        sta SAUDF1,y
        lda #0
        sta SAUDC1,y
@env:   lda V_EST,x             ; ADSR (same shape as the lead's)
        bne @ev
        jmp @vo
@ev:    cmp #1
        bne @e2
        ldy V_PAR+1,x
        clc
        lda V_VLO,x
        adc atk_lo,y
        sta V_VLO,x
        lda V_VHI,x
        adc atk_hi,y
        sta V_VHI,x
        cmp #15
        bcc @vo
        lda #15
        sta V_VHI,x
        lda #0
        sta V_VLO,x
        lda #2
        sta V_EST,x
        bne @vo
@e2:    cmp #2
        bne @e3
        ldy V_PAR+2,x
        sec
        lda V_VLO,x
        sbc dec_lo,y
        sta V_VLO,x
        lda V_VHI,x
        sbc dec_hi,y
        sta V_VHI,x
        bcc @ts
        cmp V_PAR+3,x
        bcs @vo
@ts:    lda #3
        sta V_EST,x
@e3:    cmp #3
        bne @e4
        lda V_PAR+3,x
        sta V_VHI,x
        lda #0
        sta V_VLO,x
        beq @vo
@e4:    ldy V_PAR+4,x
        sec
        lda V_VLO,x
        sbc dec_lo,y
        sta V_VLO,x
        lda V_VHI,x
        sbc dec_hi,y
        sta V_VHI,x
        bcs @vo
        lda #0
        sta V_VHI,x
        sta V_VLO,x
        sta V_EST,x
@vo:    ldy V_PAR,x
        lda wavebits,y
        ora V_VHI,x
        ldy VT2
        pha
        lda VT3
        bne @c16
        pla
        sta SAUDC1,y
        rts
@c16:   pla
        sta SAUDC2,y             ; the pair sounds on its high channel
        lda VT1
        beq @rt
        jmp lv_tones
@rt:    rts

.segment "CODE"

; stereo track 1 with a held (POLY) chord: the two chord tones on POKEY2
; ch3 (only while track 2 is silent) and ch4 (only while no loop drum rings),
; 8-bit in the track's wave at 3/4 of its envelope. X = 0.
lv_tones:
        ldy V_PAR+8
        cpy #CH_AUTO
        bne @fix
        ldy V_NOTE
        lda notepc,y
        tay
        lda auto3,y
        sta VT0
        lda auto5,y
        jmp @t
@fix:   lda poly1,y
        sta VT0
        lda poly2,y
@t:     sta VT1
        lda V_VHI
        lsr a
        lsr a
        sta VT4
        lda V_VHI
        sec
        sbc VT4
        ldy V_PAR
        ora wavebits,y
        sta VT4
        lda V_EST+VBS
        bne @t2
        lda VT0
        jsr lv_pitch
        sta SAUDF3+P2
        lda VT4
        sta SAUDC3+P2
@t2:    lda VT1
        cmp #$FF
        beq @x
        lda D_TMR+8
        bne @x
        lda VT1
        jsr lv_pitch
        sta SAUDF4+P2
        lda VT4
        sta SAUDC4+P2
        lda #1
        sta POLY4B
@x:     rts

lv_pitch:                       ; A = semitones above track 1's note -> AUDF
        clc
        adc V_NOTE
        cmp #96
        bcc @k
        lda #95
@k:     tay
        lda V_PAR
        cmp #1
        beq @bz
        cmp #3
        beq @rs
        lda lay64,y
        rts
@bz:    lda buzz64,y
        rts
@rs:    lda rasp64,y
        rts

; ---------------------------------------------------------------------------
synth:
        ; ---- chord arpeggio: NOTEIDX = NOTE + chord offset
        ldx P_CHORD
        beq @noarp
        lda P_CHDSPD            ; POLY: the lead holds the root, the chord
        beq @noarp              ;  tones sound on ch3/ch4 (poly_out)
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
@ain:   cpx #CH_AUTO
        beq @aut
        clc
        adc chord_start,x
        tay
        lda chord_ofs,y
        jmp @ofs
@aut:   tay                     ; AUTO: root, third, fifth of NOTE's triad
        beq @ofs
        ldx NOTE
        lda notepc,x
        tax
        lda auto3,x
        dey
        beq @ofs
        lda auto5,x
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

@out:   jsr coprime             ; buzz: vibrato/glide/sweep may land on a bad period
        lda VT2
        sta OUTLO
        sta SAUDF1
        lda VT3
        sta OUTHI
        sta SAUDF2

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
        sta SAUDC2
        lda #0
        sta SAUDC1

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
        lda #0
        sta POLY4
        lda P_CHORD             ; held chord (CHD SPD = POLY) replaces the layer
        beq @nply
        lda P_CHDSPD
        bne @nply
        jmp poly_out
@nply:  jsr v2_owns             ; loop's track 1 has ch3
        beq @lyr
        rts
@lyr:   ldx P_LAYER
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
@l3:    sta SAUDF3
        lda VOLHI               ; 3/4 volume
        lsr a
        lsr a
        sta VT0
        lda VOLHI
        sec
        sbc VT0
        ora #$A0
        sta SAUDC3
        rts
@echo:  lda ECHOPOS             ; the frame written 20 frames ago
        clc
        adc #11
        and #31
        tax
        ldy ECHON,x
        lda lay64,y
        sta SAUDF3
        lda ECHOV,x
        lsr a
        ora #$A0
        sta SAUDC3
        rts
@loff:  lda #0
        sta SAUDC3
        rts

.segment "HIDATA"
; held chord: two tones above the lead's root on POKEY1 ch3 + ch4, in the
; lead's wave (8-bit tables) at 3/4 of its envelope. ch3 yields to the
; loop's voice 2, ch4 to any drum on block 0.
poly_out:
        ldx P_CHORD
        cpx #CH_AUTO
        bne @fix
        ldy NOTE
        ldx notepc,y
        lda auto3,x
        sta VT0
        lda auto5,x
        jmp @t
@fix:   lda poly1,x
        sta VT0
        lda poly2,x
@t:     sta VT1
        lda VOLHI
        lsr a
        lsr a
        sta VT4
        lda VOLHI
        sec
        sbc VT4
        ldx P_WAVE
        ora wavebits,x
        sta VT4                 ; AUDC for both tones
        jsr v2_owns
        bne @t2
        lda VT0
        jsr poly_pitch
        sta SAUDF3
        lda VT4
        sta SAUDC3
@t2:    lda VT1
        cmp #$FF
        beq @x
        lda D_TMR
        bne @x
        lda VT1
        jsr poly_pitch
        sta SAUDF4
        lda VT4
        sta SAUDC4
        lda #1
        sta POLY4
@x:     rts

poly_pitch:                     ; A = semitones above NOTE -> 8-bit AUDF
        clc
        adc NOTE
        cmp #96
        bcc @k
        lda #95
@k:     tay
        lda P_WAVE
        cmp #1
        beq @bz
        cmp #3
        beq @rs
        lda lay64,y
        rts
@bz:    lda buzz64,y
        rts
@rs:    lda rasp64,y
        rts

; BUZZ (poly4) only has its pitch when (period+7) is coprime to 15; the
; tables guarantee that, but vibrato/glide/sweep move the period through the
; bad values (the pattern shortens: octave+ jumps, or silence when the gcd
; is 15). Nudge VT2/VT3 up 1-2 steps to the next good value. The residue
; needs no division: 256 == 16 == 1 (mod 15), so bytes and nibbles just add.
coprime:
        lda P_WAVE
        cmp #1
        bne @x
@again: lda VT2
        clc
        adc VT3
        bcc @n1
        adc #0                  ; carry = 256 == 1 (mod 15): +1
@n1:    clc
        adc #7
        bcc @n2
        adc #0
@n2:    pha
        lsr a
        lsr a
        lsr a
        lsr a
        sta VT0
        pla
        and #15
        clc
        adc VT0                 ; <= 30
        cmp #15
        bcc @n3
        sbc #15
@n3:    tax
        lda bad15,x
        beq @x
        inc VT2
        bne @again
        inc VT3
        jmp @again
@x:     rts
bad15:  .byte 1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1   ; r%3==0 or r%5==0 (15 == 0)

; End of VBI: the image -> POKEY1; in stereo, POKEY2 either gets the loop's
; own voices (PLAY/DUB) or, when it's otherwise idle, a mirror of POKEY1 with
; the lead a few cents flat on the right: a centered, slightly wide sound for
; solo playing. Recording is unaffected (it records notes, not registers).
pokey_out:
        ldx #7
@p1:    lda SH,x
        sta AUDF1,x
        dex
        bpl @p1
        lda STEREO
        beq @x
        lda LSTATE
        cmp #LS_PLAY
        beq @loop
        cmp #LS_DUB
        beq @loop
        ldx #7
@m:     lda SH,x
        sta AUDF1+P2,x
        dex
        bpl @m
        lda P_WAVE              ; buzz/rasp: no detune (it would break the poly
        cmp #1                  ;  pattern: silence or octave jumps); identical
        beq @x                  ;  copy = centered
        cmp #3
        beq @x
        clc                     ; lead period + period/256 (~7 cents flat)
        lda SAUDF1
        adc SAUDF2
        sta AUDF1+P2
        lda SAUDF2
        adc #0
        sta AUDF2+P2
@x:     rts
@loop:  ldx #7
@q:     lda SH+P2,x
        sta AUDF1+P2,x
        dex
        bpl @q
        rts

.segment "CODE"

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
.segment "HIDATA"
.include "tables.inc"
.include "demos.inc"

.segment "RODATA"

; waveform AUDC distortion bits: PURE BUZZ GRIT RASP NOISE HISS
wavebits:   .byte $A0,$C0,$40,$20,$80,$00

chord_start: .byte 0, 0,3,6,10,12,15, 0   ; AUTO: lead uses auto3/5; loop
chord_len:   .byte 1, 3,3,4,2,3,3, 3   ;  voices arpeggiate it as MAJOR
chord_ofs:   .byte 0,4,7, 0,3,7, 0,4,7,10, 0,12, 0,7,12, 0,3,6

layofs:     .byte <-12, 7, 12, 0        ; SUB FIFTH OCT-UP CHORUS
swsh:       .byte 0, 9,8,7,6,5,4,3      ; sweep |n| -> shift
vibtab:     .byte 0,1,2,1,0,3,4,3       ; 1/2 +half/+full, 3/4 -half/-full
octbase:    .byte 0, 0,12,24,36,48,60,72

; drums: KICK SNARE HAT OPEN TOM TOM2 CLAP CRASH
; noise at AUDF 0-1 sits mostly above what a TV speaker reproduces: the
; hats live at AUDF 3. vol = min(TMR*4 >> VSH, 15): VSH 0 = full until the
; last 3 frames (punch), 2 = linear fade from 15, 3 = long fade.
dr_frq:     .byte  6,  6,  3,  3,110, 70, 16,  4
dr_dlt:     .byte  5,  0,  0,  0,  5,  3,  0,  0
dr_ctl:     .byte $C0,$80,$80,$80,$A0,$A0,$80,$80
dr_vsh:     .byte  0,  0,  0,  2,  1,  1,  0,  3
dr_len:     .byte 16, 14,  7, 30, 16, 14, 10, 60
dr_clk:     .byte  8,  2,  0,  0,  8,  8,  0,  0     ; click AUDF (0 none)
dr_seq:     .byte  2,  0,  0,  0,  0,  0,  0,  0     ; script index (0 = envelope)
; scripted drums: (AUDF, AUDC) per frame, AUDC 0 ends. Kick = the classic
; POKEY "battery kick": DC pop (volume-only) -> pure beater click -> deep
; poly4 thud dropping in pitch and volume.
drseq:      .byte 0
            .byte $00,$1F       ; volume-only 15: the speaker "pop"
            .byte $20,$AF       ; pure tone, high: beater click
            .byte $D0,$CF       ; poly4 at ~20 Hz: the shell thud
            .byte $E0,$CB
            .byte $F0,$C8       ; sub-bass tail
            .byte $F8,$C4
            .byte $00,$00

cmdkeys:    .byte K_Z,K_X,K_UP,K_DOWN,K_LEFT,K_RIGHT,K_RET,K_ESC
            .byte K_SPACE,K_TAB,K_BKSP,K_LT,K_GT,K_Q,K_R
NCMD = 15
cmdlo:      .byte <(oct_down-1),<(oct_up-1),<(ed_up-1),<(ed_down-1)
            .byte <(ed_left-1),<(ed_right-1),<(reset_preset-1),<(hush-1)
            .byte <(loop_space-1),<(loop_tab-1),<(loop_clear-1),<(prev_demo-1),<(next_demo-1),<(toggle_mute-1),<(toggle_chords-1)
cmdhi:      .byte >(oct_down-1),>(oct_up-1),>(ed_up-1),>(ed_down-1)
            .byte >(ed_left-1),>(ed_right-1),>(reset_preset-1),>(hush-1)
            .byte >(loop_space-1),>(loop_tab-1),>(loop_clear-1),>(prev_demo-1),>(next_demo-1),>(toggle_mute-1),>(toggle_chords-1)
lsnames:    .byte "EMPTYREC  PLAY DUB  STOP DRUMS"
titlewords: .byte "8-BIT KEYBOARDSTEREO 2-POKEY"
qdemotxt:   .byte "< DEMOS  >"
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
ptype:      .byte 2,0,0,0,0,2, 1,1,2,4,3,1
pmin:       .byte 0,0,0,0,0,0, 0,1,0,0,0,0
pmax:       .byte 5,15,15,15,15,5, 7,7,7,7,14,7
pnlist_lo:  .byte <wavenm,0,0,0,0,<laynm, 0,0,<chordnm,0,0,0
pnlist_hi:  .byte >wavenm,0,0,0,0,>laynm, 0,0,>chordnm,0,0,0
wavenm:     .byte "PURE  BUZZ  GRIT  RASP  NOISE HISS  "
laynm:      .byte "OFF   SUB   FIFTH OCT UPCHORUSECHO  "
chordnm:    .byte "OFF   MAJOR MINOR 7TH   OCTAVEPOWER DIM   AUTO  "
polytxt:    .byte "POLY"
swtxt:      .byte "DOWN UP   OFF  "

static_text:
        .byte 0,0,$80, " POKEY SYNTH  -  8-BIT KEYBOARD    OCT  ",0
        .byte 9,1,0, "NOTE",0
        .byte 9,12,0, "VOLUME",0
        .byte 11,1,0, "DRUMS",0
        .byte 15,21,0, "R=CHORDS  Q=DRUMS",0
        .byte 16,1,$80, "SOUND EDITOR",0
        .byte 16,14,0, "ARROWS/STICK  RET=RESET",0
        .byte 10,1,0, "LOOP",0
        .byte 23,0,0, "Z/X OCT  SPACE REC  TAB PLAY  BKSP CLEAR",0
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
