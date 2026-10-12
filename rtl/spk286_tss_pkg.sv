// SPDX-License-Identifier: MIT
// Named offsets for the fixed 80286 task-state segment.
`timescale 1ns/1ps

package spk286_tss_pkg;
    localparam logic [15:0] TSS_MIN_LIMIT = 16'h002B;
    /* These named field offsets are part of the PM5 contract and are
       intentionally retained before every consumer lands. */
    /* verilator lint_off UNUSEDPARAM */
    localparam integer TSS_WORD_COUNT = 22;

    localparam logic [15:0] TSS_BACKLINK = 16'h0000;
    localparam logic [15:0] TSS_SP0      = 16'h0002;
    localparam logic [15:0] TSS_SS0      = 16'h0004;
    localparam logic [15:0] TSS_SP1      = 16'h0006;
    localparam logic [15:0] TSS_SS1      = 16'h0008;
    localparam logic [15:0] TSS_SP2      = 16'h000A;
    localparam logic [15:0] TSS_SS2      = 16'h000C;
    localparam logic [15:0] TSS_IP       = 16'h000E;
    localparam logic [15:0] TSS_FLAGS    = 16'h0010;
    localparam logic [15:0] TSS_AX       = 16'h0012;
    localparam logic [15:0] TSS_CX       = 16'h0014;
    localparam logic [15:0] TSS_DX       = 16'h0016;
    localparam logic [15:0] TSS_BX       = 16'h0018;
    localparam logic [15:0] TSS_SP       = 16'h001A;
    localparam logic [15:0] TSS_BP       = 16'h001C;
    localparam logic [15:0] TSS_SI       = 16'h001E;
    localparam logic [15:0] TSS_DI       = 16'h0020;
    localparam logic [15:0] TSS_ES       = 16'h0022;
    localparam logic [15:0] TSS_CS       = 16'h0024;
    localparam logic [15:0] TSS_SS       = 16'h0026;
    localparam logic [15:0] TSS_DS       = 16'h0028;
    localparam logic [15:0] TSS_LDT      = 16'h002A;
    /* verilator lint_on UNUSEDPARAM */
endpackage
