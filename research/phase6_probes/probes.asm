; Project-owned NASM 16-bit probe payload. See PHASE6_CAPTURE_PROTOCOL.md.
; No DOS, BIOS, chipset, LOADALL or fixture-specific state dump is required.
cpu 286
bits 16
org 0

%ifndef FAMILY
%error FAMILY must be 1 (IRET), 2 (STI), or 3 (TF/fault)
%endif
%ifndef IRET_SP
%define IRET_SP 0xffff
%endif
%ifndef FLAGS_IMAGE
%define FLAGS_IMAGE 2
%endif
%ifndef REPEATED_STI
%define REPEATED_STI 0
%endif
%ifndef TARGET_OFFSET
%define TARGET_OFFSET 0xffff
%endif
%ifndef UD_TARGET
%define UD_TARGET 0
%endif
%ifndef RESTORE_TF
%define RESTORE_TF 0
%endif

; Post-observation dump: preserve all event frames above the current SP.
; PUSH SP saves pre-decrement SP on a 286. No IRET or external interrupt.
%macro TERMINAL_DUMP 0
    push sp
    pushf
    push ax
    push bx
    push cx
    push dx
    push bp
    push si
    push di
    mov [0x2080], dx              ; all nine diagnostic words completed
%endmacro

; Fixed offsets are part of the portable image contract, checked by build.py.
times 0x100-($-$$) db 0xcc
boot:
    cli
    mov ax, 0
    mov ds, ax
    mov es, ax
    mov ax, 0x3000
    mov ss, ax
    mov sp, 0x8000
    mov ax, 0xa286
    mov bx, 0xb286
    mov cx, 0xc286
    mov dx, 0xd286
    mov bp, 0x5286
    mov si, 0x6286
    mov di, 0x7286
    push word 2
    popf
    mov [0x2000], dx               ; boot completed; no stimulus before this
%if FAMILY = 1
    mov [0x2002], dx               ; first NMI armed
halt_first:
    hlt
    jmp short halt_first
%elif FAMILY = 2
    push word FLAGS_IMAGE
    popf
    mov [0x2002], dx               ; INTR phase-sweep reference, pins still low
    jmp near tested
%elif FAMILY = 3
    mov [0x2002], dx               ; optional NMI phase-sweep reference
    jmp near tf_setup
%else
%error invalid FAMILY
%endif

%if FAMILY = 3
times 0x1fc-($-$$) db 0xcc
tf_setup:
    push strict word FLAGS_IMAGE  ; force three bytes
    popf                         ; TF was zero; target follows immediately
%endif
times 0x200-($-$$) db 0xcc
tested:
%if FAMILY = 2
    sti
%if REPEATED_STI
    sti
%endif
    mov [0x2010], dx              ; marker whose completion discriminates STI
%elif FAMILY = 3
%if UD_TARGET
    db 0x8f, 0xc8                ; invalid POP /1, independent #UD companion
%else
    db 0x89, 0x06                ; MOV r/m16,AX, direct disp16 (not moffs)
    dw TARGET_OFFSET
%endif
    mov [0x2010], dx              ; reached only if target has no fault/trap
%else
    mov [0x20f0], dx              ; unreachable in A; diagnostic error
%endif
halt_target:
    TERMINAL_DUMP
halt_target_done:
    hlt
    jmp short halt_target_done

times 0x400-($-$$) db 0xcc
gp_handler:
    mov [0x2020], dx              ; first actual #GP handler instruction
%if RESTORE_TF
    push strict word 0x0102
    popf
    mov [0x2022], dx              ; explicitly restored TF control
%endif
halt_gp:
    TERMINAL_DUMP
halt_gp_done:
    hlt
    jmp short halt_gp_done        ; never IRET in this handler

times 0x500-($-$$) db 0xcc
db_handler:
    mov [0x2030], dx              ; first actual #1 handler instruction
halt_db:
    TERMINAL_DUMP
halt_db_done:
    hlt
    jmp short halt_db_done

times 0x600-($-$$) db 0xcc
nmi_first_handler:
%if FAMILY = 1
    mov bx, nmi_terminal_handler
    mov [0x0008], bx              ; next NMI uses separate terminal handler
    mov [0x2040], dx              ; first NMI executing, inhibition established
    mov sp, IRET_SP
    jmp near iret_attempt
%else
    mov [0x2042], dx              ; optional C NMI: observation stops here/HLT
halt_nmi_c:
    TERMINAL_DUMP
halt_nmi_c_done:
    hlt
    jmp short halt_nmi_c_done
%endif

times 0x640-($-$$) db 0xcc
iret_attempt:
    iret                         ; only IRET executed by A
    mov [0x20f0], dx              ; unreachable fall-through
    hlt

times 0x680-($-$$) db 0xcc
nmi_terminal_handler:
    mov [0x2042], dx              ; second NMI actually executing
halt_nmi:
    TERMINAL_DUMP
halt_nmi_done:
    hlt
    jmp short halt_nmi_done

times 0x700-($-$$) db 0xcc
intr_handler:
    mov [0x2050], dx              ; fixed INTR vector 0x40
halt_intr:
    TERMINAL_DUMP
halt_intr_done:
    hlt
    jmp short halt_intr_done

times 0x800-($-$$) db 0xcc
ud_handler:
    mov [0x2060], dx
halt_ud:
    TERMINAL_DUMP
halt_ud_done:
    hlt
    jmp short halt_ud_done

times 0x900-($-$$) db 0xcc
iret_success:
    mov [0x2070], dx
halt_success:
    TERMINAL_DUMP
halt_success_done:
    hlt
    jmp short halt_success_done

times 0xa00-($-$$) db 0xcc
unexpected_handler:
    mov [0x20f0], dx
halt_unexpected:
    TERMINAL_DUMP
halt_unexpected_done:
    hlt
    jmp short halt_unexpected_done
times 0x1000-($-$$) db 0xcc
