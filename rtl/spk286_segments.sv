// SPDX-License-Identifier: MIT
// 80286 segment state. This port performs ordinary real-mode segment reloads;
// the protected-state owner supplies LOADALL cache commits.
`timescale 1ns/1ps

module spk286_segments (
    input  logic        clk,
    input  logic        reset,
    input  logic        load_en,
    input  logic [1:0]  load_index,
    input  logic [15:0] load_selector,
    input  logic        loadall_commit_en,
    input  logic [63:0] loadall_selectors,
    input  logic [95:0] loadall_bases,
    input  logic [63:0] loadall_limits,
    input  logic [31:0] loadall_access,
    input  logic [1:0]  read_index,
    input  logic [15:0] offset,
    output logic [15:0] selector,
    output logic [23:0] base,
    output logic [15:0] limit,
    output logic [7:0]  access_rights,
    output logic [23:0] physical_address,
    output logic [63:0] selector_state,
    output logic [95:0] base_state,
    output logic [63:0] limit_state,
    output logic [31:0] access_state
);
    // Low slice first: ES, CS, SS, DS (x86 segment register encoding).
    logic [63:0] selector_q;
    logic [95:0] base_q;
    logic [63:0] limit_q;
    logic [31:0] access_q;
    // Normalized valid, DPL 0, writable accessed data segment.
    localparam logic [7:0] REAL_MODE_ACCESS = 8'h93;

    assign selector = selector_q[read_index * 16 +: 16];
    assign base = base_q[read_index * 24 +: 24];
    assign limit = limit_q[read_index * 16 +: 16];
    assign access_rights = access_q[read_index * 8 +: 8];
    assign physical_address = base + {8'h00, offset};
    assign selector_state = selector_q;
    assign base_state = base_q;
    assign limit_state = limit_q;
    assign access_state = access_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            selector_q <= {16'h0000, 16'h0000, 16'hF000, 16'h0000};
            base_q <= {24'h000000, 24'h000000, 24'hFF0000, 24'h000000};
            limit_q <= {4{16'hFFFF}};
            access_q <= {4{REAL_MODE_ACCESS}};
        end else if (loadall_commit_en) begin
            selector_q <= loadall_selectors;
            base_q <= loadall_bases;
            limit_q <= loadall_limits;
            access_q <= loadall_access;
        end else if (load_en) begin
            selector_q[load_index * 16 +: 16] <= load_selector;
            base_q[load_index * 24 +: 24] <= {4'h0, load_selector, 4'h0};
            limit_q[load_index * 16 +: 16] <= 16'hFFFF;
            access_q[load_index * 8 +: 8] <= REAL_MODE_ACCESS;
        end
    end
endmodule
