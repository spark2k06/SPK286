// SPK286 Phase 0 reset and first-fetch skeleton.
//
// This module is intentionally not a CPU implementation. It establishes the
// minimum observable contract needed to validate the development toolchain:
// deterministic reset state and the first 80286-style code-fetch request.

`timescale 1ns/1ps

module spk286 (
    input  logic        clk,
    input  logic        reset,
    input  logic        ready,

    output logic [23:0] address,
    output logic [15:0] data_out,
    output logic        data_oe,
    output logic        bus_valid,
    output logic        bus_write,
    output logic        bus_bhe_n,
    output logic [3:0]  bus_status,
    output logic        bus_lock,
    output logic        hlda,

    output logic [15:0] debug_cs,
    output logic [23:0] debug_cs_base,
    output logic [15:0] debug_ip,
    output logic [15:0] debug_flags,
    output logic [11:0] debug_micro_pc,
    output logic [3:0]  debug_bus_state
);

    localparam logic [15:0] RESET_CS = 16'hF000;
    localparam logic [23:0] RESET_CS_BASE = 24'hFF0000;
    localparam logic [15:0] RESET_IP = 16'hFFF0;
    localparam logic [15:0] RESET_FLAGS = 16'h0002;
    localparam logic [3:0] BUS_STATUS_CODE = 4'hD;

    typedef enum logic {
        FETCH_PHASE,
        PASSIVE_PHASE
    } bus_phase_t;

    logic [15:0] cs_q;
    logic [23:0] cs_base_q;
    logic [15:0] ip_q;
    logic [15:0] flags_q;
    bus_phase_t phase_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            cs_q <= RESET_CS;
            cs_base_q <= RESET_CS_BASE;
            ip_q <= RESET_IP;
            flags_q <= RESET_FLAGS;
            phase_q <= FETCH_PHASE;
        end else if ((phase_q == FETCH_PHASE) && ready) begin
            phase_q <= PASSIVE_PHASE;
        end
    end

    always_comb begin
        address = 24'h000000;
        data_out = 16'h0000;
        data_oe = 1'b0;
        bus_valid = 1'b0;
        bus_write = 1'b0;
        bus_bhe_n = 1'b1;
        bus_status = 4'h0;
        bus_lock = 1'b0;
        hlda = 1'b0;

        if (phase_q == FETCH_PHASE) begin
            bus_valid = 1'b1;
            bus_bhe_n = 1'b0;
            bus_status = BUS_STATUS_CODE;
            address = cs_base_q + {8'h00, ip_q};
        end
    end

    assign debug_cs = cs_q;
    assign debug_cs_base = cs_base_q;
    assign debug_ip = ip_q;
    assign debug_flags = flags_q;
    assign debug_micro_pc = 12'h000;
    assign debug_bus_state = (phase_q == FETCH_PHASE) ? 4'h1 : 4'h0;

endmodule
