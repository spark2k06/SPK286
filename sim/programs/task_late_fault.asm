; SPDX-License-Identifier: MIT
; CPU-only reset ROM: deterministic late task-switch probes, no BIOS/OS dependency.
; NASM -f bin -DFAULT_STAGE=0..6 -DENTRY=0..3 -DTASK_HANDLER=0..1.
bits 16
cpu 286
org 0
%ifndef FAULT_STAGE
%define FAULT_STAGE 3
%endif
%ifndef ENTRY
%define ENTRY 0
%endif
%ifndef TASK_HANDLER
%define TASK_HANDLER 0
%endif
%ifndef INCOMING_LDTR
%define INCOMING_LDTR 0x50
%endif
%ifndef INCOMING_CS
%define INCOMING_CS 0x30
%endif
%ifndef INCOMING_SS
%define INCOMING_SS 0x38
%endif
%ifndef LDT_ZERO_CODE
%define LDT_ZERO_CODE 0
%endif
%ifndef LDT_ZERO_STACK
%define LDT_ZERO_STACK 0
%endif
%ifndef BOOT_LLDT
%define BOOT_LLDT -1
%endif
%ifndef ABSENT
%define ABSENT 1
%endif
%macro descriptor 3
    dw %2, (%1 & 0xffff)
    db ((%1 >> 16) & 0xff), %3
    dw 0
%endmacro
%macro tss 6
    dw 0, 0, 0, 0, 0, 0, 0, %1, 2
    dw 0xbeef, 0xcafe, 0x1234, 0x5678, 0x0f00, 0x9abc, 0xdef0, 0x2468
    dw %2, %3, %4, %5, %6
%endmacro
%macro idt_gate 2
%if TASK_HANDLER
    dw 0, 0x28, 0x8500, 0
%else
    dw %1, 8, 0x8600, 0
%endif
%endmacro

start:
    cli
    cld
    mov ax, cs
    mov ds, ax
    xor ax, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x3f00
    mov si, tables
    mov di, 0x1000
    mov cx, tables_end-tables
    rep movsb
    lgdt [gdtr]
    lidt [idtr]
    mov ax, 1
    lmsw ax
    jmp 8:protected_start
protected_start:
    mov ax, 0x60
    mov ds, ax
    mov es, ax
    mov ax, 0x10
    mov ss, ax
    mov sp, 0x0f00
    mov ax, 0x18
    ltr ax
    mov ax, 0x50
    lldt ax
%if BOOT_LLDT >= 0
    mov ax, BOOT_LLDT
    lldt ax
    sldt [0x301a]
    mov word [0x301c], 0x4c44
%endif
    mov word [0x3000], 0x5255 ; RUN
    mov ax, 0x1111
%if ENTRY = 0
    call 0x20:0
%elif ENTRY = 1
    jmp 0x20:0
%elif ENTRY = 2
    int 0x20
%else
    mov word [0x1200], 0x20
    push word 0x4002
    popf
    iret
%endif
    mov bx, 0xffff
    jmp report
incoming:
    mov bx, 0
    jmp report
%macro handler 1
handler%1:
    mov bx, %1
    jmp report
%endmacro
handler 8
handler 10
handler 11
handler 12
handler 13
task_handler:
    mov bx, 0xff ; actual vector is in the pre-delivery snapshot
report:
    cli
    mov bp, sp
    mov dx, ds
    mov cx, es
    mov si, ss
    mov di, 0x60
    mov ds, di
    mov [0x3002], bx
    mov [0x3004], ax
    mov [0x3006], dx
    mov [0x3008], cx
    mov [0x300a], si
    mov [0x300c], bp
    str [0x300e]
    sldt [0x3010]
    smsw [0x3012]
%if !TASK_HANDLER
%if FAULT_STAGE != 0 || BOOT_LLDT >= 4
    mov ax, [ss:bp]
    mov [0x3014], ax ; error
    mov ax, [ss:bp+2]
    mov [0x3016], ax ; IP
    mov ax, [ss:bp+4]
    mov [0x3018], ax ; CS
%endif
%endif
    mov word [0x3000], 0x444f ; DONE, written last
stop:
    hlt
    jmp stop

gdtr: dw 0x6f
      dd 0x1000
idtr: dw 0x107
      dd 0x1800

tables:
    dq 0
    descriptor 0xf0000, 0xffff, 0x9b ; 08 bootstrap/handler code
    descriptor 0x4000, 0x1fff, 0x93 ; 10 outgoing stack
    descriptor 0x1200, 0x2b, 0x81   ; 18 outgoing TSS
%if ENTRY = 3
    descriptor 0x1300, 0x2b, 0x83   ; nested IRET requires busy target
%else
    descriptor 0x1300, 0x2b, 0x81   ; 20 incoming TSS
%endif
    descriptor 0x1400, 0x2b, 0x81   ; 28 exception-handler TSS
%if FAULT_STAGE = 3
    descriptor 0xf0000, 0xffff, (ABSENT*0x1a+(1-ABSENT)*0x92)
%elif FAULT_STAGE = 6
    descriptor 0xf0000, 0x10, 0x9a
%else
    descriptor 0xf0000, 0xffff, 0x9a ; 30 incoming code
%endif
%if FAULT_STAGE = 2
    descriptor 0x5000, 0x1fff, (ABSENT*0x12+(1-ABSENT)*0x90)
%else
    descriptor 0x5000, 0x1fff, 0x92 ; 38 incoming stack
%endif
%if FAULT_STAGE = 4
    descriptor 0x6000, 0x1fff, (ABSENT*0x12+(1-ABSENT)*0x98)
%else
    descriptor 0x6000, 0x1fff, 0x92 ; 40 incoming ES
%endif
%if FAULT_STAGE = 5
    descriptor 0x7000, 0x1fff, (ABSENT*0x12+(1-ABSENT)*0x98)
%else
    descriptor 0x7000, 0x1fff, 0x92 ; 48 incoming DS
%endif
    descriptor 0x1a00, 0x0f, 0x82   ; 50 incoming LDT
    dq 0
    descriptor 0, 0xffff, 0x93      ; 60 flat RAM reporting
    descriptor 0x8000, 0x1fff, 0x93 ; 68 reporter stack
    times 0x200-($-tables) db 0
    times 0x2c db 0 ; outgoing TSS at 1200
    times 0x300-($-tables) db 0
%if FAULT_STAGE = 7
    tss incoming, 0x40, 0x30, 0x38, 0x48, 4 ; illegal incoming LDTR.TI
%elif FAULT_STAGE = 1
    tss incoming, 0x40, 0x30, 0x38, 0x48, 0x60 ; data instead of LDT
%else
    tss incoming, 0x40, INCOMING_CS, INCOMING_SS, 0x48, INCOMING_LDTR
%endif
    times 0x400-($-tables) db 0
    tss task_handler, 0x60, 8, 0x68, 0x60, 0
    times 0x800-($-tables) db 0
%rep 8
    dq 0
%endrep
    idt_gate handler8, 8
    dq 0
    idt_gate handler10, 10
    idt_gate handler11, 11
    idt_gate handler12, 12
    idt_gate handler13, 13
    times 0x900-($-tables) db 0
    dw 0, 0x20, 0x8500, 0 ; IDT[20] entry task gate
    times 0xa00-($-tables) db 0
%if LDT_ZERO_CODE
    descriptor 0xf0000, 0xffff, 0x9a
%elif LDT_ZERO_STACK
    descriptor 0x5000, 0x1fff, 0x92
%else
    descriptor 0x6000, 0x1fff, 0x92
%endif
    descriptor 0x7000, 0x1fff, 0x92
tables_end:
    times 0xfff0-($-$$) db 0xff
    jmp 0xf000:start
    times 0x10000-($-$$) db 0xff
