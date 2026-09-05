// Phase 1 architectural datapath and fetch boundary.
// Execution-facing controls will be driven by the future decoder/microsequencer.
`timescale 1ns/1ps

module spk286 (
    input  logic         clk,
    input  logic         reset,
    input  logic         ready,
    input  logic [15:0]  data_in,

    input  logic [2:0]   gpr_read_a_index,
    input  logic [2:0]   gpr_read_b_index,
    input  logic         gpr_read_a_byte,
    input  logic         gpr_read_b_byte,
    output logic [15:0]  gpr_read_a_data,
    output logic [15:0]  gpr_read_b_data,
    input  logic         gpr_write_en,
    input  logic         gpr_write_byte,
    input  logic [2:0]   gpr_write_index,
    input  logic [15:0]  gpr_write_data,
    input  logic         ip_write_en,
    input  logic [15:0]  ip_write_data,
    input  logic         flags_write_en,
    input  logic [15:0]  flags_write_data,
    input  logic [15:0]  flags_write_mask,
    input  logic         segment_load_en,
    input  logic [1:0]   segment_load_index,
    input  logic [15:0]  segment_load_selector,
    input  logic [1:0]   segment_read_index,
    input  logic [15:0]  segment_offset,
    output logic [15:0]  segment_selector,
    output logic [23:0]  segment_base,
    output logic [15:0]  segment_limit,
    output logic [7:0]   segment_access,
    output logic [23:0]  segment_address,
    input  logic         redirect,
    output logic         control_error,

    input  logic         fetch_request,
    output logic         fetch_request_ready,
    input  logic         fetch_ready,
    output logic         fetch_valid,
    output logic [15:0]  fetch_data,
    output logic [15:0]  fetch_ip,
    output logic [1:0]   fetch_count,
    output logic         fetch_blocked,

    output logic [23:0]  address,
    output logic [15:0]  data_out,
    output logic         data_oe,
    output logic         bus_valid,
    output logic         bus_write,
    output logic         bus_bhe_n,
    output logic [3:0]   bus_status,
    output logic         bus_lock,
    output logic         hlda,

    output logic [15:0]  debug_cs,
    output logic [23:0]  debug_cs_base,
    output logic [15:0]  debug_ip,
    output logic [15:0]  debug_flags,
    output logic [127:0] debug_gpr,
    output logic [63:0]  debug_segment_selectors,
    output logic [95:0]  debug_segment_bases,
    output logic [63:0]  debug_segment_limits,
    output logic [31:0]  debug_segment_access,
    output logic [16:0]  debug_fetch_cursor,
    output logic [11:0]  debug_micro_pc,
    output logic [3:0]   debug_bus_state
);
    logic commit_allowed;

    // A CS reload requires a coordinated IP write and fetch restart. Reject a
    // malformed controller transaction as a whole, without partial state writes.
    // This is an internal protocol error, not an architectural CPU exception.
    assign control_error = !reset && ((redirect && !ip_write_en) ||
                           (segment_load_en && segment_load_index == 2'd1 && !redirect));
    assign commit_allowed = !control_error;

    spk286_registers registers (
        .clk(clk), .reset(reset),
        .read_a_index(gpr_read_a_index), .read_b_index(gpr_read_b_index),
        .read_a_byte(gpr_read_a_byte), .read_b_byte(gpr_read_b_byte),
        .read_a_data(gpr_read_a_data), .read_b_data(gpr_read_b_data),
        .write_en(gpr_write_en && commit_allowed), .write_byte(gpr_write_byte),
        .write_index(gpr_write_index), .write_data(gpr_write_data),
        .ip_write_en(ip_write_en && commit_allowed), .ip_write_data(ip_write_data),
        .flags_write_en(flags_write_en && commit_allowed),
        .flags_write_data(flags_write_data), .flags_write_mask(flags_write_mask),
        .gpr_state(debug_gpr), .ip(debug_ip), .flags(debug_flags)
    );

    spk286_segments segments (
        .clk(clk), .reset(reset),
        .load_en(segment_load_en && commit_allowed),
        .load_index(segment_load_index), .load_selector(segment_load_selector),
        .read_index(segment_read_index), .offset(segment_offset),
        .selector(segment_selector), .base(segment_base), .limit(segment_limit),
        .access_rights(segment_access), .physical_address(segment_address),
        .selector_state(debug_segment_selectors), .base_state(debug_segment_bases),
        .limit_state(debug_segment_limits), .access_state(debug_segment_access)
    );

    spk286_fetch fetch (
        .clk(clk), .reset(reset), .ready(ready), .data_in(data_in),
        .code_base(debug_segment_bases[24 +: 24]),
        .code_limit(debug_segment_limits[16 +: 16]),
        .restart(redirect && commit_allowed), .restart_ip(ip_write_data),
        .request(fetch_request), .request_ready(fetch_request_ready),
        .response_ready(fetch_ready), .response_valid(fetch_valid),
        .response_data(fetch_data), .response_ip(fetch_ip), .response_count(fetch_count),
        .cursor(debug_fetch_cursor), .blocked(fetch_blocked),
        .bus_valid(bus_valid), .bus_bhe_n(bus_bhe_n), .address(address)
    );

    assign debug_cs = debug_segment_selectors[16 +: 16];
    assign debug_cs_base = debug_segment_bases[24 +: 24];
    assign debug_micro_pc = 12'h000;
    assign debug_bus_state = bus_valid ? 4'h1 : 4'h0;
    assign bus_status = bus_valid ? 4'hD : 4'hF;
    assign data_out = 16'h0000;
    assign data_oe = 1'b0;
    assign bus_write = 1'b0;
    assign bus_lock = 1'b0;
    assign hlda = 1'b0;
endmodule
