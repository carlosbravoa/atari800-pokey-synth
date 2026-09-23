; ---------------------------------------------------------------------------
; POKEY PLAYER boot sectors: the OS loads these 3 sectors to $0700 and calls
; $0706. We then read a binary-load (.xex) file stored contiguously from
; sector XSEC (XLEN bytes), place its segments and jump through RUNAD.
; mkdisk.py patches XSEC/XLEN. No INITAD support (the player has none).
; ---------------------------------------------------------------------------
DDEVIC  = $0300
DUNIT   = $0301
DCOMND  = $0302
DSTATS  = $0303
DBUFLO  = $0304
DBUFHI  = $0305
DAUX1   = $030A
DAUX2   = $030B
DSKINV  = $E453
RUNAD   = $02E0
COLOR2  = $02C6

BUF     = $0900         ; sector buffer (the player loads nothing there)
ZSEC    = $80           ; next sector
ZLEFT   = $82           ; bytes of the file still to read
ZPOS    = $84           ; position in BUF (128 = empty)
ZDST    = $86           ; segment write pointer
ZCNT    = $88           ; segment bytes left

.segment "BOOT"
        .byte 0                 ; flags
        .byte 3                 ; sectors
        .word $0700             ; load address
        .word bret              ; DOSINI
        jmp boot                ; $0706: the OS calls here
xsec:   .word 0                 ; $0709 (patched)
xlen:   .word 0                 ; $070B (patched)

bret:   clc
        rts

boot:   lda #$94                ; a blue screen while it loads
        sta COLOR2
        lda xsec
        sta ZSEC
        lda xsec+1
        sta ZSEC+1
        lda xlen
        sta ZLEFT
        lda xlen+1
        sta ZLEFT+1
        lda #128
        sta ZPOS
        jsr getb                ; $FFFF
        jsr getb
seg:    lda ZLEFT
        ora ZLEFT+1
        beq run
        jsr getb
        sta ZDST
        jsr getb
        sta ZDST+1
        and ZDST
        cmp #$FF
        beq seg                 ; a repeated $FFFF header
        jsr getb
        sta ZCNT
        jsr getb
        sta ZCNT+1
        sec                     ; count = end - start + 1
        lda ZCNT
        sbc ZDST
        sta ZCNT
        lda ZCNT+1
        sbc ZDST+1
        sta ZCNT+1
        inc ZCNT
        bne @cp
        inc ZCNT+1
@cp:    jsr getb
        ldy #0
        sta (ZDST),y
        inc ZDST
        bne @n
        inc ZDST+1
@n:     lda ZCNT
        bne @d
        dec ZCNT+1
@d:     dec ZCNT
        lda ZCNT
        ora ZCNT+1
        bne @cp
        jmp seg
run:    jmp (RUNAD)

getb:   ldx ZPOS                ; A = next byte of the file
        bpl @have
        jsr rdsec
        ldx #0
@have:  lda BUF,x
        inx
        stx ZPOS
        pha
        lda ZLEFT
        bne @l
        dec ZLEFT+1
@l:     dec ZLEFT
        pla
        rts

rdsec:  lda #$31                ; D1: read sector ZSEC into BUF (retry on error)
        sta DDEVIC
        lda #1
        sta DUNIT
        lda #$52
        sta DCOMND
        lda #<BUF
        sta DBUFLO
        lda #>BUF
        sta DBUFHI
        lda ZSEC
        sta DAUX1
        lda ZSEC+1
        sta DAUX2
        jsr DSKINV
        lda DSTATS
        bmi rdsec
        inc ZSEC
        bne @x
        inc ZSEC+1
@x:     rts
