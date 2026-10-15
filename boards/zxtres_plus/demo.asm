; SPDX-License-Identifier: MIT
; SPK286 bring-up demo for the ZXTRES+ (boards/zxtres_plus/zxtres_demo_system.sv).
; A 64 KiB ROM at F000:0000. It runs self-checking 80286 instruction tests in
; real mode, a sieve benchmark timed with the hardware cycle counter, then
; enters protected mode, tests it, and stays there updating the screen.
;
; nasm -f bin -o demo.bin demo.asm
;
; A failing check shows its ROM offset on the screen; demo.lst maps it to
; the source line.

        cpu     286
        bits    16

%ifndef BENCH_ITERATIONS
%define BENCH_ITERATIONS 10
%endif

ROMSEG          equ 0xF000
VIDSEG          equ 0xB800

; I/O ports of the demo hardware.
PORT_POST       equ 0x80
PORT_CYCLES     equ 0xE0            ; a read latches bits 31:16 for 0xE2
PORT_CYCLES_HI  equ 0xE2
PORT_KHZ        equ 0xE4
PORT_FRAMES     equ 0xE6
PORT_LED        equ 0xE8
PORT_VERSION    equ 0xEA
PORT_SCRATCH    equ 0xEC

; Protected-mode selectors (GDT built at GDT_BASE).
SEL_CODE        equ 0x08            ; base 0F0000, the ROM
SEL_DATA        equ 0x10            ; base 000000, low RAM
SEL_EXT         equ 0x18            ; base 100000, RAM above 1 MiB
SEL_VIDEO       equ 0x20            ; base 0B8000, limit 0FFF

; One VGA frame is 800x525 dots at 25 MHz, 16.8 ms. Cycles in 5 frames / 84
; give the CPU clock in kHz.
MEASURE_FRAMES  equ 5
MEASURE_DIVISOR equ 84

F_CF    equ 0x0001
F_PF    equ 0x0004
F_AF    equ 0x0010
F_ZF    equ 0x0040
F_SF    equ 0x0080
F_OF    equ 0x0800
ARITH   equ F_OF|F_SF|F_ZF|F_AF|F_PF|F_CF
LOGIC   equ F_OF|F_SF|F_ZF|F_PF|F_CF   ; AF is undefined after logic and shifts

; Low RAM layout (DS = 0 in real mode, SEL_DATA in protected mode).
GDT_BASE        equ 0x0800
IDT_BASE        equ 0x0900
BUF1            equ 0x0A00
BUF2            equ 0x0A40
BUF3            equ 0x0A80
BUF4            equ 0x0AC0
SIEVE_FLAGS     equ 0x2000
SIEVE_SIZE      equ 8190
STACK_TOP       equ 0xFFF0

        absolute 0x0500
v_attr          resb 1
v_failed_now    resb 1
v_video_seg     resw 1
v_table         resw 1
v_count         resw 1
v_row           resw 1
v_index         resw 1
v_routine       resw 1
v_line          resw 1
v_failures      resw 1
v_total         resw 1
v_scratch       resw 2
v_ptr           resw 2
v_tmp           resw 1
v_tmp2          resw 1
v_tmp3          resw 1
v_bounds        resw 2
v_skip          resw 1
v_fault_count   resw 1
v_fault_ip      resw 1
v_count3        resw 1
v_count4        resw 1
v_khz           resw 1
v_c0            resw 2
v_cycles        resw 2
v_per_iter      resw 2
v_primes        resw 1
v_iter          resw 1
v_gdtr          resw 3
v_idtr          resw 3
v_gp_count      resw 1
v_gp_error      resw 1
v_gp_ip         resw 1
v_last_frame    resw 1
v_frame_acc     resw 1
v_seconds       resw 1
v_polls         resw 1
v_spinner       resw 1
v_led           resw 1
v_flags         resw 1

        section .text
        org     0

; ---------------------------------------------------------------------------
; Check helpers. A failing check returns from the test with CF=1 and AX set
; to its own ROM offset; the stack must be balanced wherever they are used.
%macro EXPECT 2
%%check:
        cmp     %1, %2
        je      %%ok
        mov     ax, %%check
        stc
        ret
%%ok:
%endmacro

; Compare the FLAGS bits in mask %1 with %2. Only FLAGS change.
%macro EXPECT_FLAGS 2
        pushf
        pop     word [v_flags]
        and     word [v_flags], %1
        EXPECT  word [v_flags], %2
%endmacro

%macro FAIL_HERE 0
%%check:
        mov     ax, %%check
        stc
        ret
%endmacro

%macro POST 1
        mov     al, %1
        out     PORT_POST, al
%endmacro

; PRINT row, column, attribute, string
%macro PRINT 4
        mov     di, ((%1) * 80 + (%2)) * 2
        mov     byte [v_attr], %3
        mov     si, %4
        call    puts
%endmacro

; ---------------------------------------------------------------------------
start:
        cli
        cld
        xor     ax, ax
        mov     ss, ax
        mov     sp, STACK_TOP
        mov     ds, ax
        mov     ax, VIDSEG
        mov     es, ax
        mov     [v_video_seg], ax
        POST    0x01

        ; Every exception and interrupt vector 0-31 reports itself.
        xor     bx, bx
        mov     si, stub_table
.ivt:   mov     ax, [cs:si]
        mov     [bx], ax
        mov     word [bx + 2], ROMSEG
        add     si, 2
        add     bx, 4
        cmp     bx, 32 * 4
        jb      .ivt

        mov     word [v_failures], 0
        mov     word [v_total], 0
        call    clear_screen
        mov     di, 0
        mov     byte [v_attr], 0x1F
        mov     cx, 80
        mov     al, ' '
.bar:   call    putc
        loop    .bar
        PRINT   0, 2, 0x1F, s_title
        PRINT   1, 2, 0x07, s_clock
        PRINT   3, 1, 0x0B, s_tests
        PRINT   14, 1, 0x0B, s_bench
        PRINT   17, 1, 0x0B, s_protected
        PRINT   23, 1, 0x08, s_footer

        ; CPU clock: nominal (from the hardware) and measured against VGA.
        POST    0x02
        mov     di, (1 * 80 + 21) * 2
        mov     byte [v_attr], 0x0E
        in      ax, PORT_KHZ
        call    put_khz
        call    measure_clock
        mov     [v_khz], ax
        mov     di, (1 * 80 + 41) * 2
        mov     byte [v_attr], 0x0E
        call    put_khz

        ; Real-mode instruction tests.
        mov     si, real_tests
        mov     cx, REAL_TEST_COUNT
        mov     bx, 4
        call    run_tests

        call    benchmark

        ; Protected mode: build the tables, switch, and test it there.
        POST    0xA0
        call    build_tables
        mov     word [0x0600], 0x1111       ; for the memory above 1 MiB test
        lgdt    [v_gdtr]
        lidt    [v_idtr]
        smsw    ax
        or      ax, 1
        lmsw    ax
        jmp     SEL_CODE:pm_entry
pm_entry:
        mov     ax, SEL_DATA
        mov     ds, ax
        mov     ss, ax
        mov     ax, SEL_VIDEO
        mov     es, ax
        mov     [v_video_seg], ax
        POST    0xA1
        mov     si, pm_tests
        mov     cx, PM_TEST_COUNT
        mov     bx, 18
        call    run_tests

        ; Summary, then the live loop.
        mov     di, (22 * 80 + 1) * 2
        cmp     word [v_failures], 0
        jne     .failed
        mov     byte [v_attr], 0x0A
        mov     si, s_all_passed_1
        call    puts
        mov     ax, [v_total]
        call    put_dec16
        mov     si, s_all_passed_2
        call    puts
        jmp     live
.failed:
        mov     byte [v_attr], 0x0C
        mov     ax, [v_failures]
        call    put_dec16
        mov     si, s_failed_1
        call    puts
        mov     ax, [v_total]
        call    put_dec16
        mov     si, s_failed_2
        call    puts
        jmp     live

; ---------------------------------------------------------------------------
; Test runner. CS:SI = table of (name, routine) word pairs, CX = count,
; BX = first screen row. Two tests per row. Each routine returns CF=0 on
; success, or CF=1 with AX = the ROM offset of the failed check.
run_tests:
        mov     [v_table], si
        mov     [v_count], cx
        mov     [v_row], bx
        mov     word [v_index], 0
.next:
        mov     ax, [v_index]
        cmp     ax, [v_count]
        jae     .done
        add     al, 0x10
        out     PORT_POST, al
        mov     si, [v_index]
        shl     si, 2
        add     si, [v_table]
        mov     ax, [cs:si + 2]
        mov     [v_routine], ax
        call    [v_routine]
        mov     [v_line], ax
        mov     ax, 0
        adc     ax, 0
        mov     [v_failed_now], al
        mov     ax, [v_video_seg]           ; tests may leave ES and DF changed
        mov     es, ax
        cld
        inc     word [v_total]

        ; Screen cell: row v_row + index / 2, column 1 or 41.
        mov     ax, [v_index]
        shr     ax, 1
        add     ax, [v_row]
        mov     bx, 80
        mul     bx
        test    byte [v_index], 1
        jz      .left
        add     ax, 40
.left:  inc     ax
        shl     ax, 1
        mov     di, ax
        cmp     byte [v_failed_now], 0
        jne     .fail
        mov     byte [v_attr], 0x0A
        mov     si, s_ok
        call    puts
        jmp     .name
.fail:  inc     word [v_failures]
        mov     byte [v_attr], 0x0C
        mov     si, s_fail
        call    puts
.name:  mov     byte [v_attr], 0x07
        mov     si, [v_index]
        shl     si, 2
        add     si, [v_table]
        mov     si, [cs:si]
        call    puts
        cmp     byte [v_failed_now], 0
        je      .counted
        mov     byte [v_attr], 0x0C
        mov     si, s_at_line
        call    puts
        mov     ax, [v_line]
        call    put_hex16
.counted:
        inc     word [v_index]
        jmp     .next
.done:  ret

; ---------------------------------------------------------------------------
; Real-mode tests.

t_move:
        mov     ax, 0x1234
        mov     bx, ax
        EXPECT  bx, 0x1234
        xchg    al, ah
        EXPECT  ax, 0x3412
        mov     si, 0x0010
        mov     bx, 0x1234
        lea     di, [bx + si + 0x20]
        EXPECT  di, 0x1264
        mov     word [v_scratch], 0xBEEF
        mov     cx, [v_scratch]
        EXPECT  cx, 0xBEEF
        mov     byte [v_scratch + 1], 0x5A
        EXPECT  word [v_scratch], 0x5AEF
        mov     bx, xlat_table
        mov     al, 3
        db      0x2E                        ; CS: for XLAT
        xlatb
        EXPECT  al, 0x40
        mov     al, 0x80
        cbw
        EXPECT  ax, 0xFF80
        cwd
        EXPECT  dx, 0xFFFF
        mov     ah, 0xD5                    ; SF ZF AF PF CF
        sahf
        lahf
        EXPECT  ah, 0xD7                    ; FLAGS bit 1 reads as 1
        clc
        ret

t_arith:
        mov     ax, 0x7FFF
        add     ax, 1
        EXPECT_FLAGS ARITH, F_OF|F_SF|F_AF|F_PF
        EXPECT  ax, 0x8000
        mov     ax, 0xFFFF
        add     ax, 1
        EXPECT_FLAGS ARITH, F_ZF|F_AF|F_PF|F_CF
        stc
        mov     ax, 0x1000
        adc     ax, 0x0FFF
        EXPECT_FLAGS ARITH, F_AF|F_PF
        EXPECT  ax, 0x2000
        mov     ax, 0
        sub     ax, 1
        EXPECT_FLAGS ARITH, F_SF|F_AF|F_PF|F_CF
        mov     ax, 0x8000
        sub     ax, 1
        EXPECT_FLAGS ARITH, F_OF|F_AF|F_PF
        EXPECT  ax, 0x7FFF
        stc
        mov     ax, 5
        sbb     ax, 5
        EXPECT_FLAGS ARITH, F_SF|F_AF|F_PF|F_CF
        EXPECT  ax, 0xFFFF
        mov     al, 0x40
        cmp     al, 0x41
        EXPECT_FLAGS ARITH, F_SF|F_AF|F_PF|F_CF
        EXPECT  al, 0x40
        mov     al, 0x7F
        add     al, 1
        EXPECT_FLAGS ARITH, F_OF|F_SF|F_AF
        mov     ax, 0xFFFF                  ; 32-bit add: 0001FFFF + 2
        mov     dx, 0x0001
        add     ax, 2
        adc     dx, 0
        EXPECT  ax, 0x0001
        EXPECT  dx, 0x0002
        clc
        ret

t_logic:
        mov     ax, 0xF0F0
        and     ax, 0x3C3C
        EXPECT_FLAGS LOGIC, F_PF
        EXPECT  ax, 0x3030
        or      ax, 0x8001
        EXPECT_FLAGS LOGIC, F_SF
        EXPECT  ax, 0xB031
        test    al, 0x01
        EXPECT_FLAGS LOGIC, 0
        xor     ax, ax
        mov     bx, 0x00FF
        not     bx                          ; leaves FLAGS from the XOR
        EXPECT_FLAGS LOGIC, F_ZF|F_PF
        EXPECT  bx, 0xFF00
        mov     cx, 1
        neg     cx
        EXPECT_FLAGS ARITH, F_SF|F_AF|F_PF|F_CF
        EXPECT  cx, 0xFFFF
        mov     cx, 0x8000
        neg     cx
        EXPECT_FLAGS ARITH, F_OF|F_SF|F_PF|F_CF
        EXPECT  cx, 0x8000
        mov     cx, 0
        neg     cx
        EXPECT_FLAGS ARITH, F_ZF|F_PF
        clc
        ret

t_incdec:
        stc
        mov     ax, 0xFFFF
        inc     ax                          ; CF is preserved
        EXPECT_FLAGS ARITH, F_ZF|F_AF|F_PF|F_CF
        clc
        mov     al, 0x7F
        inc     al
        EXPECT_FLAGS ARITH, F_OF|F_SF|F_AF
        clc
        mov     bx, 0x8000
        dec     bx
        EXPECT_FLAGS ARITH, F_OF|F_AF|F_PF
        EXPECT  bx, 0x7FFF
        clc
        mov     byte [v_scratch], 1
        dec     byte [v_scratch]
        EXPECT_FLAGS ARITH, F_ZF|F_PF
        mov     word [v_scratch], 0x00FF
        clc
        inc     word [v_scratch]
        EXPECT_FLAGS ARITH, F_AF|F_PF
        EXPECT  word [v_scratch], 0x0100
        clc
        ret

t_shift:
        mov     ax, 0x8001
        shl     ax, 1
        EXPECT_FLAGS LOGIC, F_OF|F_CF
        EXPECT  ax, 0x0002
        mov     ax, 0x8001
        shr     ax, 1
        EXPECT_FLAGS LOGIC, F_OF|F_PF|F_CF
        EXPECT  ax, 0x4000
        mov     ax, 0x8000
        sar     ax, 1
        EXPECT_FLAGS LOGIC, F_SF|F_PF
        EXPECT  ax, 0xC000
        mov     ax, 0x1234
        mov     cl, 4
        shl     ax, cl
        EXPECT_FLAGS F_CF, F_CF
        EXPECT  ax, 0x2340
        mov     ax, 0x1234
        shr     ax, 4                       ; 80186/286 immediate count
        EXPECT_FLAGS F_CF, 0
        EXPECT  ax, 0x0123
        mov     ax, 0x8001
        rol     ax, 1
        EXPECT_FLAGS F_CF, F_CF
        EXPECT  ax, 0x0003
        mov     ax, 0x0001
        ror     ax, 1
        EXPECT_FLAGS F_CF, F_CF
        EXPECT  ax, 0x8000
        clc
        mov     ax, 0x8000
        rcl     ax, 1
        EXPECT_FLAGS F_CF, F_CF
        EXPECT  ax, 0x0000
        stc
        rcl     ax, 1
        EXPECT_FLAGS F_CF, 0
        EXPECT  ax, 0x0001
        stc
        mov     al, 0
        rcr     al, 1
        EXPECT_FLAGS F_CF, 0
        EXPECT  al, 0x80
        mov     ax, 0x1234
        mov     cl, 8
        rol     ax, cl
        EXPECT  ax, 0x3412
        mov     ax, 0xF000
        sar     ax, 12
        EXPECT  ax, 0xFFFF
        clc
        ret

t_mul:
        mov     ax, 0x1234
        mov     bx, 0x0100
        mul     bx
        EXPECT_FLAGS F_OF|F_CF, F_OF|F_CF
        EXPECT  ax, 0x3400
        EXPECT  dx, 0x0012
        mov     al, 0x10
        mov     bl, 0x10
        mul     bl
        EXPECT_FLAGS F_OF|F_CF, F_OF|F_CF
        EXPECT  ax, 0x0100
        mov     al, 0x0F
        mov     bl, 0x0F
        mul     bl
        EXPECT_FLAGS F_OF|F_CF, 0
        EXPECT  ax, 0x00E1
        mov     ax, -3
        mov     bx, 7
        imul    bx
        EXPECT_FLAGS F_OF|F_CF, 0
        EXPECT  ax, 0xFFEB
        EXPECT  dx, 0xFFFF
        mov     al, 0x80
        mov     bl, 2
        imul    bl
        EXPECT_FLAGS F_OF|F_CF, F_OF|F_CF
        EXPECT  ax, 0xFF00
        mov     bx, 100
        imul    cx, bx, 300                 ; three-operand IMUL
        EXPECT_FLAGS F_OF|F_CF, 0
        EXPECT  cx, 30000
        imul    cx, bx, 400
        EXPECT_FLAGS F_OF|F_CF, F_OF|F_CF
        EXPECT  cx, 0x9C40
        mov     word [v_scratch], 0x1000
        imul    ax, word [v_scratch], -2
        EXPECT  ax, 0xE000
        clc
        ret

t_div:
        mov     dx, 1
        xor     ax, ax
        mov     bx, 3
        div     bx
        EXPECT  ax, 0x5555
        EXPECT  dx, 1
        mov     ax, 1000
        mov     bl, 7
        div     bl
        EXPECT  ax, 0x068E                  ; AH = 6, AL = 142
        mov     ax, -1000
        cwd
        mov     bx, 7
        idiv    bx
        EXPECT  ax, -142
        EXPECT  dx, -6
        mov     ax, -100
        mov     bl, 7
        idiv    bl
        EXPECT  ax, 0xFEF2                  ; AH = -2, AL = -14
        mov     ax, 0x7FFF
        cwd
        mov     bx, -1
        idiv    bx
        EXPECT  ax, 0x8001
        EXPECT  dx, 0
        clc
        ret

t_bcd:
        mov     al, 0x38
        add     al, 0x45
        daa
        EXPECT_FLAGS F_CF, 0
        EXPECT  al, 0x83
        mov     al, 0x99
        add     al, 0x01
        daa
        EXPECT_FLAGS F_CF|F_ZF, F_CF|F_ZF
        EXPECT  al, 0x00
        mov     al, 0x83
        sub     al, 0x38
        das
        EXPECT_FLAGS F_CF, 0
        EXPECT  al, 0x45
        mov     ax, 0x0009
        add     al, 0x05
        aaa
        EXPECT_FLAGS F_CF, F_CF
        EXPECT  ax, 0x0104
        mov     ax, 0x0102
        sub     al, 0x05
        aas
        EXPECT_FLAGS F_CF, F_CF
        EXPECT  ax, 0x0007
        mov     al, 79
        aam
        EXPECT  ax, 0x0709
        aad
        EXPECT  ax, 0x004F
        aam     16
        EXPECT  ax, 0x040F
        clc
        ret

t_string:
        xor     ax, ax
        mov     es, ax
        cld
        mov     di, BUF1
        mov     ax, 0x1122
        mov     cx, 8
        rep     stosw
        EXPECT  di, BUF1 + 16
        EXPECT  cx, 0
        mov     si, BUF1
        mov     di, BUF2
        mov     cx, 8
        rep     movsw
        EXPECT  si, BUF1 + 16
        mov     si, BUF1
        mov     di, BUF2
        mov     cx, 8
        repe    cmpsw
        EXPECT_FLAGS F_ZF, F_ZF
        EXPECT  cx, 0
        mov     byte [BUF2 + 5], 0x99
        mov     si, BUF1
        mov     di, BUF2
        mov     cx, 16
        repe    cmpsb
        EXPECT_FLAGS F_ZF, 0
        EXPECT  cx, 10
        EXPECT  si, BUF1 + 6
        mov     byte [BUF1 + 9], 0x77
        mov     al, 0x77
        mov     di, BUF1
        mov     cx, 16
        repne   scasb
        EXPECT_FLAGS F_ZF, F_ZF
        EXPECT  di, BUF1 + 10
        EXPECT  cx, 6
        mov     si, BUF1
        lodsb
        EXPECT  al, 0x22
        EXPECT  si, BUF1 + 1
        std
        mov     si, BUF1 + 3
        lodsb
        cld
        EXPECT  al, 0x11
        EXPECT  si, BUF1 + 2
        xor     cx, cx
        mov     di, BUF3
        mov     al, 0xAB
        rep     stosb                       ; CX = 0: nothing happens
        EXPECT  di, BUF3
        mov     si, rom_text
        mov     di, BUF3
        mov     cx, 4
        db      0x2E                        ; CS: source from the ROM
        rep     movsb
        EXPECT  word [BUF3], 0x5053         ; "SP"
        EXPECT  word [BUF3 + 2], 0x214B     ; "K!"
        clc
        ret

t_stack:
        mov     dx, sp
        mov     ax, 0x1111
        mov     bx, 0x2222
        mov     cx, 0x3333
        mov     si, 0x4444
        mov     di, 0x5555
        mov     bp, 0x6666
        pusha
        mov     bx, sp
        mov     ax, [ss:bx + 6]             ; the SP that PUSHA stored
        mov     [v_tmp], ax
        xor     ax, ax
        mov     bx, ax
        mov     cx, ax
        mov     si, ax
        mov     di, ax
        mov     bp, ax
        popa
        EXPECT  ax, 0x1111
        EXPECT  bx, 0x2222
        EXPECT  cx, 0x3333
        EXPECT  si, 0x4444
        EXPECT  di, 0x5555
        EXPECT  bp, 0x6666
        EXPECT  sp, dx
        EXPECT  word [v_tmp], dx
        push    word 0x1234
        push    byte -1
        pop     ax
        pop     bx
        EXPECT  ax, 0xFFFF
        EXPECT  bx, 0x1234
        mov     word [v_scratch], 0xCAFE
        push    word [v_scratch]
        pop     word [v_scratch + 2]
        EXPECT  word [v_scratch + 2], 0xCAFE
        stc
        pushf
        clc
        popf
        EXPECT_FLAGS F_CF, F_CF
        EXPECT  sp, dx
        clc
        ret

t_flow:
        mov     dx, sp
        xor     ax, ax
        call    near_proc
        EXPECT  ax, 0x1111
        xor     ax, ax
        call    ROMSEG:far_proc
        EXPECT  ax, 0x2222
        mov     bx, cs
        EXPECT  bx, ROMSEG
        push    word 0xAAAA
        push    word 0xBBBB
        call    ret4_proc
        EXPECT  sp, dx
        mov     cx, 10
        xor     ax, ax
.sum:   add     ax, cx
        loop    .sum
        EXPECT  ax, 55
        xor     cx, cx
        jcxz    .cx_zero
        FAIL_HERE
.cx_zero:
        mov     ax, -1
        cmp     ax, 1
        jge     .bad_branch                 ; signed: -1 < 1
        jbe     .bad_branch                 ; unsigned: FFFF > 1
        jl      .signed_ok
.bad_branch:
        FAIL_HERE
.signed_ok:
        mov     bx, near_proc
        xor     ax, ax
        call    bx
        EXPECT  ax, 0x1111
        xor     ax, ax
        call    [cs:proc_pointer]
        EXPECT  ax, 0x3333
        mov     cx, 5
        mov     si, 0
.scan:  inc     si
        cmp     si, 3
        loopne  .scan                       ; stops when SI = 3
        EXPECT  si, 3
        EXPECT  cx, 2
        clc
        ret

near_proc:
        mov     ax, 0x1111
        ret
near_proc2:
        mov     ax, 0x3333
        ret
far_proc:
        mov     ax, 0x2222
        retf
ret4_proc:
        ret     4

t_int:
        mov     word [0x60 * 4], int60_handler
        mov     word [0x60 * 4 + 2], ROMSEG
        mov     word [3 * 4], int3_handler
        mov     word [4 * 4], into_handler
        xor     ax, ax
        stc
        int     0x60                        ; the handler clears CF; IRET restores it
        EXPECT_FLAGS F_CF, F_CF
        EXPECT  ax, 0xC0DE
        mov     word [v_count3], 0
        int3
        EXPECT  word [v_count3], 1
        mov     word [v_count4], 0
        mov     al, 0x7F
        add     al, 1                       ; OF = 1
        into
        EXPECT  word [v_count4], 1
        xor     al, al                      ; OF = 0
        into
        EXPECT  word [v_count4], 1
        mov     word [3 * 4], exc_stub3
        mov     word [4 * 4], exc_stub4
        clc
        ret

int60_handler:
        mov     ax, 0xC0DE
        clc
        iret
int3_handler:
        inc     word [v_count3]
        iret
into_handler:
        inc     word [v_count4]
        iret

t_frame:
        mov     dx, sp
        mov     bp, 0x7777
        enter   8, 0
        mov     ax, dx
        sub     ax, sp
        mov     [v_tmp], ax
        mov     ax, [bp]
        mov     [v_tmp2], ax
        leave
        EXPECT  word [v_tmp], 10
        EXPECT  word [v_tmp2], 0x7777
        EXPECT  sp, dx
        EXPECT  bp, 0x7777
        enter   4, 1
        mov     ax, dx
        sub     ax, sp
        mov     [v_tmp], ax
        mov     ax, [bp - 2]
        mov     [v_tmp2], ax
        mov     [v_tmp3], bp
        leave
        EXPECT  word [v_tmp], 8
        mov     ax, [v_tmp2]
        EXPECT  ax, word [v_tmp3]           ; the level-1 frame pointer
        EXPECT  sp, dx
        EXPECT  bp, 0x7777
        ; BOUND: in range nothing happens; out of range raises INT 5 with
        ; the BOUND instruction itself as the return address.
        mov     word [5 * 4], fault_handler
        mov     word [v_bounds], 0
        mov     word [v_bounds + 2], 100
        mov     word [v_fault_count], 0
        mov     ax, 50
        bound   ax, [v_bounds]
        EXPECT  word [v_fault_count], 0
        mov     ax, 200
        mov     word [v_skip], .bound_end - .bound_insn
.bound_insn:
        bound   ax, [v_bounds]
.bound_end:
        EXPECT  word [v_fault_count], 1
        EXPECT  word [v_fault_ip], .bound_insn
        mov     word [5 * 4], exc_stub5
        clc
        ret

t_divfault:
        mov     word [0 * 4], fault_handler
        mov     word [v_fault_count], 0
        xor     bl, bl
        mov     ax, 100
        mov     word [v_skip], .div_end - .div_insn
.div_insn:
        div     bl
.div_end:
        EXPECT  word [v_fault_count], 1
        EXPECT  word [v_fault_ip], .div_insn ; 80286: the faulting DIV, not the next
        mov     ax, 0x8000
        cwd
        mov     bx, -1
        mov     word [v_skip], .idiv_end - .idiv_insn
.idiv_insn:
        idiv    bx                          ; -32768 / -1 overflows
.idiv_end:
        EXPECT  word [v_fault_count], 2
        EXPECT  word [v_fault_ip], .idiv_insn
        mov     word [0 * 4], exc_stub0
        clc
        ret

; Real-mode fault handler: records the return IP and skips v_skip bytes.
fault_handler:
        push    bp
        mov     bp, sp
        push    ax
        mov     ax, [bp + 2]
        mov     [v_fault_ip], ax
        mov     ax, [v_skip]
        add     [bp + 2], ax
        inc     word [v_fault_count]
        pop     ax
        pop     bp
        iret

t_cpuid:
        mov     ax, sp
        push    sp                          ; 8086: SP after the push
        pop     bx
        EXPECT  bx, ax
        pushf
        pop     ax
        or      ax, 0xF000
        push    ax
        popf
        pushf
        pop     ax
        and     ax, 0xF000                  ; 8086: F000, 80386: 7000
        EXPECT  ax, 0
        mov     ax, 1
        mov     cl, 33
        shl     ax, cl                      ; 8086: count 33, here 33 & 31
        EXPECT  ax, 2
        smsw    ax
        EXPECT  ax, 0xFFF0                  ; 80286 MSW after reset
        clc
        ret

t_io:
        mov     dx, PORT_SCRATCH
        mov     ax, 0xA55A
        out     dx, ax
        xor     ax, ax
        in      ax, dx
        EXPECT  ax, 0xA55A
        mov     al, 0x3C
        out     PORT_SCRATCH + 1, al
        in      ax, PORT_SCRATCH
        EXPECT  ax, 0x3C5A
        in      al, PORT_SCRATCH + 1
        EXPECT  al, 0x3C
        in      al, PORT_SCRATCH
        EXPECT  al, 0x5A
        mov     byte [BUF3], 1
        mov     byte [BUF3 + 1], 2
        mov     byte [BUF3 + 2], 3
        mov     si, BUF3
        mov     dx, PORT_SCRATCH
        mov     cx, 3
        rep     outsb
        in      ax, dx
        EXPECT  ax, 0x3C03
        xor     ax, ax
        mov     es, ax
        mov     di, BUF4
        mov     cx, 4
        rep     insw
        EXPECT  di, BUF4 + 8
        EXPECT  word [BUF4], 0x3C03
        EXPECT  word [BUF4 + 6], 0x3C03
        in      ax, PORT_VERSION
        EXPECT  ax, 0x0001
        clc
        ret

t_segments:
        mov     ax, 0x0040
        mov     es, ax
        mov     word [es:0x0010], 0x1357    ; physical 000410
        EXPECT  word [0x0410], 0x1357
        mov     bx, 0x0400
        mov     si, 0x0010
        EXPECT  word [bx + si], 0x1357
        mov     bp, 0x0400
        mov     di, 0x000E
        mov     ax, [bp + di + 2]           ; SS-relative
        EXPECT  ax, 0x1357
        mov     word [v_ptr], 0x5678
        mov     word [v_ptr + 2], 0x1234
        les     di, [v_ptr]
        mov     ax, es
        EXPECT  ax, 0x1234
        EXPECT  di, 0x5678
        lds     si, [v_ptr]
        mov     ax, ds
        xor     cx, cx
        mov     ds, cx
        EXPECT  ax, 0x1234
        EXPECT  si, 0x5678
        clc
        ret

; ---------------------------------------------------------------------------
; Benchmark: the BYTE (1981) sieve of Eratosthenes, 8191 flags.
benchmark:
        POST    0x80
        xor     ax, ax
        mov     es, ax
        call    read_cycles
        mov     [v_c0], ax
        mov     [v_c0 + 2], dx
        mov     word [v_iter], BENCH_ITERATIONS
.again: call    sieve
        mov     [v_primes], ax
        dec     word [v_iter]
        jnz     .again
        call    read_cycles
        sub     ax, [v_c0]
        sbb     dx, [v_c0 + 2]
        mov     [v_cycles], ax
        mov     [v_cycles + 2], dx
        mov     bx, BENCH_ITERATIONS
        call    div32
        mov     [v_per_iter], ax
        mov     [v_per_iter + 2], dx
        mov     ax, [v_video_seg]
        mov     es, ax

        mov     di, (15 * 80 + 3) * 2
        mov     byte [v_attr], 0x07
        mov     si, s_bench_primes
        call    puts
        mov     byte [v_attr], 0x0E
        mov     ax, [v_primes]
        call    put_dec16
        mov     byte [v_attr], 0x07
        mov     si, s_bench_total
        call    puts
        mov     byte [v_attr], 0x0E
        mov     ax, [v_cycles]
        mov     dx, [v_cycles + 2]
        call    put_dec32
        mov     byte [v_attr], 0x07
        mov     si, s_bench_cycles
        call    puts

        mov     di, (16 * 80 + 3) * 2
        mov     si, s_bench_per
        call    puts
        mov     byte [v_attr], 0x0E
        mov     ax, [v_per_iter]
        mov     dx, [v_per_iter + 2]
        call    put_dec32
        mov     byte [v_attr], 0x07
        mov     si, s_bench_cycles_eq
        call    puts
        ; Microseconds per iteration at the measured clock.
        mov     ax, [v_khz]
        add     ax, 500
        xor     dx, dx
        mov     bx, 1000
        div     bx
        mov     bx, ax                      ; MHz, rounded
        mov     ax, [v_per_iter]
        mov     dx, [v_per_iter + 2]
        call    div32
        mov     byte [v_attr], 0x0E
        call    put_dec32
        mov     byte [v_attr], 0x07
        mov     si, s_bench_us
        call    puts
        mov     byte [v_attr], 0x0C
        cmp     word [v_primes], 1899
        je      .primes_ok
        mov     si, s_bench_wrong
        call    puts
        inc     word [v_failures]
.primes_ok:
        inc     word [v_total]
        ret

; One sieve pass over SIEVE_FLAGS (ES = DS = 0); returns AX = primes found.
sieve:
        mov     di, SIEVE_FLAGS
        mov     cx, SIEVE_SIZE + 1
        mov     al, 1
        rep     stosb
        xor     dx, dx
        xor     si, si
.outer: cmp     byte [SIEVE_FLAGS + si], 0
        je      .next
        mov     ax, si
        add     ax, ax
        add     ax, 3                       ; prime = i + i + 3
        mov     bx, si
        add     bx, ax
.mark:  cmp     bx, SIEVE_SIZE
        ja      .marked
        mov     byte [SIEVE_FLAGS + bx], 0
        add     bx, ax
        jmp     .mark
.marked:
        inc     dx
.next:  inc     si
        cmp     si, SIEVE_SIZE
        jbe     .outer
        mov     ax, dx
        ret

; ---------------------------------------------------------------------------
; Protected mode.

; Copy the GDT to GDT_BASE, fill the IDT at IDT_BASE with the stubs, and
; prepare the GDTR and IDTR images.
build_tables:
        xor     ax, ax
        mov     es, ax
        mov     si, gdt_image
        mov     di, GDT_BASE
        mov     cx, (gdt_image_end - gdt_image) / 2
        db      0x2E
        rep     movsw
        mov     word [v_gdtr], gdt_image_end - gdt_image - 1
        mov     word [v_gdtr + 2], GDT_BASE
        mov     word [v_gdtr + 4], 0
        mov     si, stub_table
        mov     di, IDT_BASE
        mov     cx, 32
.gate:  mov     ax, [cs:si]
        stosw                               ; offset
        mov     ax, SEL_CODE
        stosw                               ; selector
        mov     ax, 0x8600
        stosw                               ; present DPL 0 interrupt gate
        xor     ax, ax
        stosw
        add     si, 2
        loop    .gate
        mov     word [v_idtr], 32 * 8 - 1
        mov     word [v_idtr + 2], IDT_BASE
        mov     word [v_idtr + 4], 0
        mov     ax, [v_video_seg]
        mov     es, ax
        ret

pm_enter_check:
        smsw    ax
        EXPECT  ax, 0xFFF1
        mov     ax, cs
        EXPECT  ax, SEL_CODE
        mov     ax, ds
        EXPECT  ax, SEL_DATA
        clc
        ret

pm_high_memory:
        mov     ax, SEL_EXT
        mov     es, ax
        mov     word [es:0x0600], 0x2222    ; physical 100600
        mov     ax, [es:0x0600]
        EXPECT  ax, 0x2222
        EXPECT  word [0x0600], 0x1111       ; physical 000600 untouched
        clc
        ret

pm_descriptors:
        mov     bx, SEL_VIDEO
        lsl     ax, bx
        EXPECT_FLAGS F_ZF, F_ZF
        EXPECT  ax, 0x0FFF
        lar     ax, bx
        EXPECT_FLAGS F_ZF, F_ZF
        EXPECT  ax, 0x9300
        verr    bx
        EXPECT_FLAGS F_ZF, F_ZF
        mov     bx, SEL_CODE
        verw    bx                          ; code is never writable
        EXPECT_FLAGS F_ZF, 0
        mov     bx, SEL_DATA
        verw    bx
        EXPECT_FLAGS F_ZF, F_ZF
        mov     bx, 0x0400                  ; beyond the GDT limit
        verr    bx
        EXPECT_FLAGS F_ZF, 0
        clc
        ret

pm_general_protection:
        mov     word [IDT_BASE + 13 * 8], gp_handler
        mov     word [v_gp_count], 0
        mov     ax, 0x0400
        mov     word [v_skip], .load_end - .load_insn
.load_insn:
        mov     ds, ax                      ; selector beyond the GDT limit
.load_end:
        mov     word [IDT_BASE + 13 * 8], exc_stub13
        EXPECT  word [v_gp_count], 1
        EXPECT  word [v_gp_error], 0x0400
        EXPECT  word [v_gp_ip], .load_insn
        mov     ax, ds
        EXPECT  ax, SEL_DATA                ; the faulting load changed nothing
        clc
        ret

; #GP handler (interrupt gate, error code on the stack).
gp_handler:
        push    bp
        mov     bp, sp
        push    ax
        mov     ax, [bp + 2]
        mov     [v_gp_error], ax
        mov     ax, [bp + 4]
        mov     [v_gp_ip], ax
        mov     ax, [v_skip]
        add     [bp + 4], ax
        inc     word [v_gp_count]
        pop     ax
        pop     bp
        add     sp, 2
        iret

; Live loop: count polls per VGA frame, show uptime, blink led[1].
live:
        POST    0xF0
        PRINT   21, 1, 0x0B, s_live
        mov     word [v_frame_acc], 0
        mov     word [v_seconds], 0
        mov     word [v_polls], 0
        mov     word [v_spinner], 0
        mov     word [v_led], 0
        in      ax, PORT_FRAMES
        mov     [v_last_frame], ax
.poll:  inc     word [v_polls]
        in      ax, PORT_FRAMES
        cmp     ax, [v_last_frame]
        je      .poll
        mov     [v_last_frame], ax

        mov     di, (21 * 80 + 35) * 2
        mov     byte [v_attr], 0x0E
        mov     ax, [v_seconds]
        xor     dx, dx
        mov     bx, 60
        div     bx
        call    put_2digits                 ; minutes (mod 100)
        mov     al, ':'
        call    putc
        mov     ax, dx
        call    put_2digits
        mov     di, (21 * 80 + 49) * 2
        mov     ax, [v_last_frame]
        call    put_dec5
        mov     di, (21 * 80 + 69) * 2
        mov     ax, [v_polls]
        call    put_dec5
        mov     word [v_polls], 0
        mov     di, (21 * 80 + 76) * 2
        mov     si, [v_spinner]
        inc     word [v_spinner]
        and     si, 3
        mov     al, [cs:spinner_chars + si]
        call    putc

        ; One second is 60 frames (59.5 Hz, close enough for a demo).
        inc     word [v_frame_acc]
        mov     ax, [v_frame_acc]
        cmp     ax, 30
        je      .half
        cmp     ax, 60
        jne     .poll
        mov     word [v_frame_acc], 0
        inc     word [v_seconds]
.half:  ; led[1]: blinks at 1 Hz when everything passed, stays lit otherwise.
        mov     ax, 1
        cmp     word [v_failures], 0
        jne     .led
        xor     ax, [v_led]
.led:   mov     [v_led], ax
        out     PORT_LED, al
        jmp     .poll

; ---------------------------------------------------------------------------
; Unexpected exceptions and interrupts: show the vector and the four words
; above it on the stack, then halt.
%assign vector 0
%rep 32
exc_stub %+ vector:
        push    byte vector
        jmp     unexpected
%assign vector vector + 1
%endrep

unexpected:
        mov     bp, sp
        smsw    ax
        test    al, 1
        jnz     .protected
        xor     ax, ax
        mov     ds, ax
        mov     ax, VIDSEG
        jmp     .segments
.protected:
        mov     ax, SEL_DATA
        mov     ds, ax
        mov     ax, SEL_VIDEO
.segments:
        mov     es, ax
        POST    0xEE
        cld
        mov     di, (24 * 80) * 2
        mov     byte [v_attr], 0x4F
        mov     si, s_unexpected
        call    puts
        mov     ax, [ss:bp]
        call    put_hex8
        mov     si, s_unexpected_stack
        call    puts
        mov     si, 2
.words: mov     ax, [ss:bp + si]
        call    put_hex16
        mov     al, ' '
        call    putc
        add     si, 2
        cmp     si, 10
        jbe     .words
.halt:  hlt
        jmp     .halt

; ---------------------------------------------------------------------------
; Output routines. ES:DI = screen position, [v_attr] = attribute.

putc:   push    ax
        mov     ah, [v_attr]
        stosw
        pop     ax
        ret

; CS:SI = zero-terminated string.
puts:   push    ax
.next:  cs lodsb
        test    al, al
        jz      .done
        call    putc
        jmp     .next
.done:  pop     ax
        ret

put_hex16:
        push    ax
        mov     al, ah
        call    put_hex8
        pop     ax
put_hex8:
        push    ax
        shr     al, 4
        call    .nibble
        pop     ax
        push    ax
        call    .nibble
        pop     ax
        ret
.nibble:
        and     al, 0x0F
        add     al, '0'
        cmp     al, '9'
        jbe     .digit
        add     al, 'A' - '9' - 1
.digit: jmp     putc

put_dec16:
        push    dx
        xor     dx, dx
        call    put_dec32
        pop     dx
        ret

; DX:AX unsigned.
put_dec32:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        mov     bx, 10
        xor     si, si
.divide:
        call    div32
        push    cx
        inc     si
        mov     cx, ax
        or      cx, dx
        jnz     .divide
.print: pop     ax
        add     al, '0'
        call    putc
        dec     si
        jnz     .print
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; AX as five digits with leading zeros.
put_dec5:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        mov     cx, 5
.divide:
        xor     dx, dx
        div     bx
        push    dx
        loop    .divide
        mov     cx, 5
.print: pop     ax
        add     al, '0'
        call    putc
        loop    .print
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; AX (0-99) as two digits.
put_2digits:
        push    ax
        aam
        xchg    al, ah
        add     al, '0'
        call    putc
        mov     al, ah
        add     al, '0'
        call    putc
        pop     ax
        ret

; AX kHz as "NN.NNN MHz".
put_khz:
        push    ax
        push    bx
        push    dx
        xor     dx, dx
        mov     bx, 1000
        div     bx
        call    put_dec16
        mov     al, '.'
        call    putc
        mov     ax, dx
        mov     bl, 100
        div     bl
        add     al, '0'
        call    putc
        mov     al, ah
        aam
        xchg    al, ah
        add     al, '0'
        call    putc
        mov     al, ah
        add     al, '0'
        call    putc
        mov     si, s_mhz
        call    puts
        pop     dx
        pop     bx
        pop     ax
        ret

clear_screen:
        xor     di, di
        mov     ax, 0x0720
        mov     cx, 80 * 25
        rep     stosw
        ret

; DX:AX / BX -> DX:AX quotient, CX remainder.
div32:  mov     cx, ax
        mov     ax, dx
        xor     dx, dx
        div     bx
        xchg    ax, cx
        div     bx
        xchg    dx, cx
        ret

; DX:AX = the 32-bit cycle counter.
read_cycles:
        in      ax, PORT_CYCLES
        push    ax
        in      ax, PORT_CYCLES_HI
        mov     dx, ax
        pop     ax
        ret

wait_frame:
        push    bx
        in      ax, PORT_FRAMES
        mov     bx, ax
.wait:  in      ax, PORT_FRAMES
        cmp     ax, bx
        je      .wait
        pop     bx
        ret

; Returns AX = CPU clock in kHz, measured over MEASURE_FRAMES VGA frames.
measure_clock:
        call    wait_frame
        call    read_cycles
        mov     [v_c0], ax
        mov     [v_c0 + 2], dx
        mov     cx, MEASURE_FRAMES
.frames:
        call    wait_frame
        loop    .frames
        call    read_cycles
        sub     ax, [v_c0]
        sbb     dx, [v_c0 + 2]
        mov     bx, MEASURE_DIVISOR
        call    div32
        ret

; ---------------------------------------------------------------------------
; Data.

real_tests:
        dw      n_move, t_move
        dw      n_arith, t_arith
        dw      n_logic, t_logic
        dw      n_incdec, t_incdec
        dw      n_shift, t_shift
        dw      n_mul, t_mul
        dw      n_div, t_div
        dw      n_bcd, t_bcd
        dw      n_string, t_string
        dw      n_stack, t_stack
        dw      n_flow, t_flow
        dw      n_int, t_int
        dw      n_frame, t_frame
        dw      n_divfault, t_divfault
        dw      n_cpuid, t_cpuid
        dw      n_io, t_io
        dw      n_segments, t_segments
REAL_TEST_COUNT equ ($ - real_tests) / 4

pm_tests:
        dw      n_pm_enter, pm_enter_check
        dw      n_pm_memory, pm_high_memory
        dw      n_pm_descriptors, pm_descriptors
        dw      n_pm_gp, pm_general_protection
PM_TEST_COUNT equ ($ - pm_tests) / 4

stub_table:
%assign vector 0
%rep 32
        dw      exc_stub %+ vector
%assign vector vector + 1
%endrep

; 80286 descriptors: limit, base 15:0, base 23:16, access, reserved.
gdt_image:
        dw      0, 0, 0, 0
        dw      0xFFFF, 0x0000
        db      0x0F, 0x9B
        dw      0
        dw      0xFFFF, 0x0000
        db      0x00, 0x93
        dw      0
        dw      0xFFFF, 0x0000
        db      0x10, 0x93
        dw      0
        dw      0x0FFF, 0x8000
        db      0x0B, 0x93
        dw      0
gdt_image_end:

proc_pointer:   dw near_proc2
xlat_table:     db 0x10, 0x20, 0x30, 0x40
rom_text:       db 'SPK!'
spinner_chars:  db '|/-\'

s_title:        db 'SPK286  80286-compatible soft CPU on the ZXTRES+ (Artix-7 XC7A100T)', 0
s_clock:        db 'CPU clock: nominal            measured', 0
s_mhz:          db ' MHz', 0
s_tests:        db 'Instruction tests (real mode)', 0
s_ok:           db '[ OK ] ', 0
s_fail:         db '[FAIL] ', 0
s_at_line:      db ' at ', 0
s_bench:        db 'Benchmark: sieve of Eratosthenes, 8191 flags (BYTE 1981)', 0
s_bench_primes: db 'primes found ', 0
s_bench_total:  db '   total ', 0
s_bench_cycles: db ' cycles for '
%defstr BENCH_ITERATIONS_TEXT BENCH_ITERATIONS
                db BENCH_ITERATIONS_TEXT, ' passes', 0
s_bench_per:    db 'one pass ', 0
s_bench_cycles_eq: db ' cycles = ', 0
s_bench_us:     db ' us', 0
s_bench_wrong:  db '  expected 1899 primes', 0
s_protected:    db 'Protected mode', 0
s_live:         db 'Running in protected mode: uptime         frame         polls/frame', 0
s_all_passed_1: db 'All ', 0
s_all_passed_2: db ' checks passed.', 0
s_failed_1:     db ' of ', 0
s_failed_2:     db ' checks FAILED.', 0
s_footer:       db 'Power cycle the ZXTRES+ to return to the ZX Spectrum core.', 0
s_unexpected:   db ' Unexpected exception ', 0
s_unexpected_stack: db 'h, stack: ', 0

n_move:         db 'MOV XCHG LEA XLAT CBW', 0
n_arith:        db 'ADD ADC SUB SBB CMP', 0
n_logic:        db 'AND OR XOR TEST NOT NEG', 0
n_incdec:       db 'INC DEC', 0
n_shift:        db 'Shifts and rotates', 0
n_mul:          db 'MUL IMUL (3-operand too)', 0
n_div:          db 'DIV IDIV', 0
n_bcd:          db 'DAA DAS AAA AAS AAM AAD', 0
n_string:       db 'String instructions, REP', 0
n_stack:        db 'PUSH POP PUSHA POPA', 0
n_flow:         db 'CALL RET JMP LOOP Jcc', 0
n_int:          db 'INT INT3 INTO IRET', 0
n_frame:        db 'ENTER LEAVE BOUND', 0
n_divfault:     db '#DE restarts the DIV', 0
n_cpuid:        db '80286, not 8086 or 386', 0
n_io:           db 'IN OUT INS OUTS', 0
n_segments:     db 'Segments, LDS LES, modes', 0
n_pm_enter:     db 'LGDT LIDT LMSW, far JMP', 0
n_pm_memory:    db '64 KiB above 1 MiB', 0
n_pm_descriptors: db 'LAR LSL VERR VERW', 0
n_pm_gp:        db '#GP on a bad selector', 0

; ---------------------------------------------------------------------------
; Reset vector: the first fetch is at FFFFF0, here F000:FFF0.
        times   0xFFF0 - ($ - $$) db 0xFF
reset:  jmp     ROMSEG:start
        times   0x10000 - ($ - $$) db 0xFF
