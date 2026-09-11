// 80286 Protected-Mode types shared by the PM0 foundation services.
// No 80386 descriptor classes or operand-size fields are represented here.
`timescale 1ns/1ps
package spk286_protected_pkg;
    // The package is compiled with several standalone lint tops.  Each top
    // intentionally consumes only the descriptor classes it needs.
    /* verilator lint_off UNUSEDPARAM */
    localparam logic [3:0] DESC_INVALID      = 4'd0;
    localparam logic [3:0] DESC_CODE         = 4'd1;
    localparam logic [3:0] DESC_DATA         = 4'd2;
    localparam logic [3:0] DESC_EXPAND_DOWN  = 4'd3;
    localparam logic [3:0] DESC_TSS_AVAIL   = 4'd4;
    localparam logic [3:0] DESC_TSS_BUSY    = 4'd5;
    localparam logic [3:0] DESC_CALL_GATE   = 4'd6;
    localparam logic [3:0] DESC_TASK_GATE   = 4'd7;
    localparam logic [3:0] DESC_INT_GATE    = 4'd8;
    localparam logic [3:0] DESC_TRAP_GATE   = 4'd9;
    localparam logic [3:0] DESC_LDT         = 4'd10;
    /* verilator lint_on UNUSEDPARAM */

endpackage
