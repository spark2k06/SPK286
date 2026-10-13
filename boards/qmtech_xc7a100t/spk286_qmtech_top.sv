// SPDX-License-Identifier: MIT
// SPK286 on the QMTECH XC7A100T core board (xc7a100tfgg676), built with
// openXC7 (build.sh). The 80286 bus leaves on the J2 and J3 headers at
// 3.3 V; gen_xdc.py writes the pin and clock constraints.
`timescale 1ns/1ps

module spk286_qmtech_top (
    input  logic        CLK,          // system CLK, twice the processor clock
    input  logic        CLK50,        // core board oscillator, bring-up only
    input  logic        RESET,
    inout  wire  [23:0] A,
    inout  wire  [15:0] D,
    inout  wire         BHE_N, S1_N, S0_N, M_IO, COD_INTA_N,
    output logic        LOCK_N,
    input  logic        READY_N,
    input  logic        HOLD,
    output logic        HLDA,
    input  logic        INTR, NMI,
    input  logic        PEREQ, BUSY_N, ERROR_N,
    output logic        PEACK_N,
    output logic        HALTED, SHUTDOWN,
    output logic        UART_TX,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic        UART_RX,      // reserved for a debug UART
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [1:0]  LED           // core board LEDs (polarity to be checked on the board)
);
    logic [23:0] a_out;
    logic [15:0] d_out;
    logic bhe_n, s1_n, s0_n, m_io, cod_inta_n, bus_oe, d_oe;

    spk286_native cpu (
        .clk(CLK), .reset(RESET), .timing_policy(2'd0),
        .a(a_out), .bhe_n(bhe_n), .s1_n(s1_n), .s0_n(s0_n), .m_io(m_io),
        .cod_inta_n(cod_inta_n), .bus_oe(bus_oe),
        .d_in(D), .d_out(d_out), .d_oe(d_oe),
        .lock_n(LOCK_N), .ready_n(READY_N), .hold(HOLD), .hlda(HLDA),
        .intr(INTR), .nmi(NMI), .pereq(PEREQ), .busy_n(BUSY_N), .error_n(ERROR_N),
        .peack_n(PEACK_N), .halted(HALTED), .shutdown(SHUTDOWN)
    );

    assign A = bus_oe ? a_out : 24'bz;
    assign {BHE_N, S1_N, S0_N, M_IO, COD_INTA_N} =
        bus_oe ? {bhe_n, s1_n, s0_n, m_io, cod_inta_n} : 5'bz;
    assign D = d_oe ? d_out : 16'bz;

    // Heartbeat from the local oscillator shows the FPGA is configured.
    logic [25:0] blink_q = '0;
    always_ff @(posedge CLK50) blink_q <= blink_q + 26'd1;

    assign UART_TX = 1'b1;
    assign LED = {HALTED, blink_q[25]};
endmodule
