// Standalone CPU: decoder -> generated microcode -> functional datapath service.
// Architectural state, prefetch storage and physical fetch retain separate owners.
`timescale 1ns/1ps

module spk286 (
    input  logic         clk,
    input  logic         reset,
    input  logic         ready,
    input  logic [15:0]  data_in,
    input  logic         execute_enable,

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
    output logic         unsupported_opcode,
    output logic [7:0]   debug_opcode,
    output logic         instruction_retired,
    output logic         microcode_fault,

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
    output logic [11:0]  debug_micro_entry,
    output logic [spk286_microcode_pkg::MC_WORD_WIDTH-1:0] debug_micro_instruction,
    output logic         debug_micro_active,
    output logic [3:0]   debug_prefetch_count,
    output logic [3:0]   debug_bus_state
);
    logic commit_allowed;
    logic restart;
    logic [23:0] fetch_address;
    logic fetch_bus_valid, fetch_bus_bhe_n;
    logic fetch_response_ready;
    logic fetch_request_internal, fetch_request_ready_internal;
    logic fetch_response_valid;
    logic [15:0] fetch_response_data, fetch_response_ip;
    logic [1:0] fetch_response_count;

    logic queue_flush, queue_fill_ready;
    logic queue_consume_valid, queue_consume_ready;
    logic [7:0] queue_consume_data;
    logic [3:0] queue_count;

    logic [2:0] destination_q;
    logic [7:0] opcode_q;
    logic unsupported_q;
    logic execution_allowed, decode_supported, decode_ready, micro_start;
    logic [2:0] decode_destination;
    logic [spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] decode_entry, micro_pc, micro_entry;
    logic [spk286_microcode_pkg::MC_WORD_WIDTH-1:0] micro_word;
    logic micro_active, micro_valid, micro_end, operation_valid, operation_done;
    logic executor_done, executor_byte_ready;
    logic internal_gpr_write_en, internal_ip_write_en;
    logic [2:0] internal_gpr_write_index;
    logic [15:0] internal_gpr_write_data, internal_ip_write_data;
    logic effective_gpr_write_en, effective_ip_write_en, effective_flags_write_en;
    logic [2:0] effective_gpr_write_index;
    logic [15:0] effective_gpr_write_data, effective_ip_write_data;

    // A CS reload requires a coordinated IP write and fetch restart. Reject a
    // malformed controller transaction as a whole, without partial state writes.
    // This is an internal protocol error, not an architectural CPU exception.
    assign control_error = !reset && ((redirect && !ip_write_en) ||
                           (segment_load_en && segment_load_index == 2'd1 && !redirect));
    assign commit_allowed = !control_error;
    assign restart = redirect && commit_allowed;
    assign queue_flush = restart;
    assign execution_allowed = execute_enable && commit_allowed && !reset && !restart;

    // The Phase 1 state ports remain the setup/debug path. Once execution is
    // enabled, the microcode path owns GPR/IP writeback, while an explicit redirect
    // still has priority for the architectural IP and CS cache transaction.
    assign effective_gpr_write_en = execute_enable ? internal_gpr_write_en : gpr_write_en;
    assign effective_gpr_write_index = execute_enable ? internal_gpr_write_index : gpr_write_index;
    assign effective_gpr_write_data = execute_enable ? internal_gpr_write_data : gpr_write_data;
    assign effective_ip_write_en = restart ? ip_write_en :
                                   (execute_enable ? internal_ip_write_en : ip_write_en);
    assign effective_ip_write_data = restart ? ip_write_data :
                                     (execute_enable ? internal_ip_write_data : ip_write_data);
    assign effective_flags_write_en = execute_enable ? 1'b0 : flags_write_en;

    // Keep two bytes of bus capacity available. This lets the current fetch
    // service preserve both bytes of every word response without a second
    // response staging slot in the instruction queue.
    assign fetch_request_internal = execute_enable && !unsupported_q && !microcode_fault &&
                                    (queue_count <= 4'd4);
    assign fetch_response_ready = execute_enable ? queue_fill_ready : fetch_ready;

    spk286_registers registers (
        .clk(clk), .reset(reset),
        .read_a_index(gpr_read_a_index), .read_b_index(gpr_read_b_index),
        .read_a_byte(gpr_read_a_byte), .read_b_byte(gpr_read_b_byte),
        .read_a_data(gpr_read_a_data), .read_b_data(gpr_read_b_data),
        .write_en(effective_gpr_write_en && commit_allowed),
        .write_byte(execute_enable ? 1'b0 : gpr_write_byte),
        .write_index(effective_gpr_write_index), .write_data(effective_gpr_write_data),
        .ip_write_en(effective_ip_write_en && commit_allowed), .ip_write_data(effective_ip_write_data),
        .flags_write_en(effective_flags_write_en && commit_allowed),
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
        .restart(restart), .restart_ip(ip_write_data),
        .request(execute_enable ? fetch_request_internal : fetch_request),
        .request_ready(fetch_request_ready_internal),
        .response_ready(fetch_response_ready), .response_valid(fetch_response_valid),
        .response_data(fetch_response_data), .response_ip(fetch_response_ip),
        .response_count(fetch_response_count),
        .cursor(debug_fetch_cursor), .blocked(fetch_blocked),
        .bus_valid(fetch_bus_valid), .bus_bhe_n(fetch_bus_bhe_n), .address(fetch_address)
    );

    spk286_prefetch_queue prefetch_queue (
        .clk(clk), .reset(reset), .flush(queue_flush),
        .fill_valid(fetch_response_valid && execute_enable), .fill_data(fetch_response_data),
        .fill_count(fetch_response_count), .fill_ready(queue_fill_ready),
        .consume_valid(queue_consume_valid), .consume_data(queue_consume_data),
        .consume_ready(queue_consume_ready), .count(queue_count)
    );

    assign fetch_request_ready = fetch_request_ready_internal;
    assign fetch_valid = fetch_response_valid;
    assign fetch_data = fetch_response_data;
    assign fetch_ip = fetch_response_ip;
    assign fetch_count = fetch_response_count;
    assign bus_valid = fetch_bus_valid;
    assign bus_bhe_n = fetch_bus_bhe_n;
    assign address = fetch_address;

    spk286_decoder decoder (
        .opcode(queue_consume_data), .supported(decode_supported),
        .destination(decode_destination), .entry(decode_entry)
    );

    spk286_microcode_rom microcode_rom (
        .address(micro_pc), .word(micro_word), .valid(micro_valid)
    );

    assign micro_end = micro_word == spk286_microcode_pkg::MC_END;
    assign operation_done = micro_end || executor_done;
    assign micro_start = decode_ready && !unsupported_q && queue_consume_valid && decode_supported;

    spk286_microsequencer #(
        .ADDRESS_WIDTH(spk286_microcode_pkg::MC_ADDR_WIDTH),
        .ROM_DEPTH(spk286_microcode_pkg::MC_DEPTH)
    ) microsequencer (
        .clk(clk), .reset(reset), .cancel(restart), .enable(execution_allowed),
        .start(micro_start), .start_entry(decode_entry), .start_ready(decode_ready),
        .rom_valid(micro_valid), .rom_end(micro_end), .operation_done(operation_done),
        .operation_valid(operation_valid), .active(micro_active),
        .micro_pc(micro_pc), .micro_entry(micro_entry),
        .retired(instruction_retired), .fault(microcode_fault)
    );

    spk286_micro_executor micro_executor (
        .clk(clk), .reset(reset), .cancel(restart), .start(micro_start),
        .operation_valid(operation_valid), .operation(micro_word), .operation_done(executor_done),
        .byte_valid(queue_consume_valid), .byte_data(queue_consume_data), .byte_ready(executor_byte_ready),
        .destination(destination_q), .gpr_write_en(internal_gpr_write_en),
        .gpr_write_index(internal_gpr_write_index), .gpr_write_data(internal_gpr_write_data)
    );

    // Decode and the executor share one byte-consumption interface. Unsupported
    // opcodes stay at its head. Redirect/control errors suppress both consumers.
    assign queue_consume_ready = micro_start || executor_byte_ready;

    assign internal_ip_write_en = queue_consume_valid && queue_consume_ready;
    assign internal_ip_write_data = debug_ip + 16'h0001;

    always_ff @(posedge clk) begin
        if (reset || restart) begin
            destination_q <= 3'd0;
            opcode_q <= 8'h00;
            unsupported_q <= 1'b0;
        end else if (decode_ready && !unsupported_q && queue_consume_valid) begin
            opcode_q <= queue_consume_data;
            if (decode_supported) destination_q <= decode_destination;
            else unsupported_q <= 1'b1;
        end
    end

    assign debug_cs = debug_segment_selectors[16 +: 16];
    assign debug_cs_base = debug_segment_bases[24 +: 24];
    assign unsupported_opcode = unsupported_q;
    assign debug_opcode = opcode_q;
    assign debug_prefetch_count = queue_count;
    assign debug_micro_pc = 12'(micro_pc);
    assign debug_micro_entry = 12'(micro_entry);
    assign debug_micro_instruction = micro_word;
    assign debug_micro_active = micro_active;
    assign debug_bus_state = bus_valid ? 4'h1 : 4'h0;
    assign bus_status = bus_valid ? 4'hD : 4'hF;
    assign data_out = 16'h0000;
    assign data_oe = 1'b0;
    assign bus_write = 1'b0;
    assign bus_lock = 1'b0;
    assign hlda = 1'b0;
endmodule
