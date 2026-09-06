// Phase 1 architectural datapath and fetch boundary.
// Execution-facing controls will be driven by the future decoder/microsequencer.
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

    typedef enum logic [1:0] {
        FRONTEND_OPCODE = 2'd0,
        FRONTEND_IMMEDIATE_LOW = 2'd1,
        FRONTEND_IMMEDIATE_HIGH = 2'd2,
        FRONTEND_UNSUPPORTED = 2'd3
    } frontend_state_t;
    frontend_state_t frontend_state_q;
    logic [2:0] destination_q;
    logic [7:0] immediate_low_q, opcode_q;
    logic unsupported_q;
    logic internal_gpr_write_en, internal_ip_write_en;
    logic [2:0] internal_gpr_write_index;
    logic [15:0] internal_gpr_write_data, internal_ip_write_data;
    logic effective_gpr_write_en, effective_ip_write_en, effective_flags_write_en;
    logic [2:0] effective_gpr_write_index;
    logic [15:0] effective_gpr_write_data, effective_ip_write_data;

    function automatic logic is_mov_imm_opcode(input logic [7:0] opcode);
        is_mov_imm_opcode = (opcode >= 8'hB8) && (opcode <= 8'hBF);
    endfunction

    // A CS reload requires a coordinated IP write and fetch restart. Reject a
    // malformed controller transaction as a whole, without partial state writes.
    // This is an internal protocol error, not an architectural CPU exception.
    assign control_error = !reset && ((redirect && !ip_write_en) ||
                           (segment_load_en && segment_load_index == 2'd1 && !redirect));
    assign commit_allowed = !control_error;
    assign restart = redirect && commit_allowed;
    assign queue_flush = restart;

    // The Phase 1 state ports remain the setup/debug path. Once execution is
    // enabled, the frontend owns GPR/IP writeback, while an explicit redirect
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
    assign fetch_request_internal = execute_enable && !unsupported_q &&
                                    (queue_count <= 4'd4);
    assign fetch_response_ready = execute_enable ? queue_fill_ready : fetch_ready;

    spk286_registers registers (
        .clk(clk), .reset(reset),
        .read_a_index(gpr_read_a_index), .read_b_index(gpr_read_b_index),
        .read_a_byte(gpr_read_a_byte), .read_b_byte(gpr_read_b_byte),
        .read_a_data(gpr_read_a_data), .read_b_data(gpr_read_b_data),
        .write_en(effective_gpr_write_en && commit_allowed), .write_byte(gpr_write_byte),
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
        .fill_valid(fetch_response_valid), .fill_data(fetch_response_data),
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

    // Unsupported opcodes are inspected without being consumed. The
    // development trap therefore cannot accidentally execute as another form.
    always_comb begin
        queue_consume_ready = 1'b0;
        if (execute_enable && !unsupported_q && queue_consume_valid) begin
            case (frontend_state_q)
                FRONTEND_OPCODE: queue_consume_ready = is_mov_imm_opcode(queue_consume_data);
                FRONTEND_IMMEDIATE_LOW,
                FRONTEND_IMMEDIATE_HIGH: queue_consume_ready = 1'b1;
                default: queue_consume_ready = 1'b0;
            endcase
        end
    end

    assign internal_ip_write_en = queue_consume_valid && queue_consume_ready;
    assign internal_ip_write_data = debug_ip + 16'h0001;
    assign internal_gpr_write_en = execute_enable &&
                                   (frontend_state_q == FRONTEND_IMMEDIATE_HIGH) &&
                                   queue_consume_valid && queue_consume_ready;
    assign internal_gpr_write_index = destination_q;
    assign internal_gpr_write_data = {queue_consume_data, immediate_low_q};

    always_ff @(posedge clk) begin
        if (reset || restart) begin
            frontend_state_q <= FRONTEND_OPCODE;
            destination_q <= 3'd0;
            immediate_low_q <= 8'h00;
            opcode_q <= 8'h00;
            unsupported_q <= 1'b0;
            instruction_retired <= 1'b0;
        end else if (execute_enable) begin
            instruction_retired <= 1'b0;
            case (frontend_state_q)
                FRONTEND_OPCODE: begin
                    if (queue_consume_valid) begin
                        opcode_q <= queue_consume_data;
                        if (is_mov_imm_opcode(queue_consume_data)) begin
                            destination_q <= queue_consume_data[2:0];
                            frontend_state_q <= FRONTEND_IMMEDIATE_LOW;
                        end else begin
                            unsupported_q <= 1'b1;
                            frontend_state_q <= FRONTEND_UNSUPPORTED;
                        end
                    end
                end
                FRONTEND_IMMEDIATE_LOW: begin
                    if (queue_consume_valid && queue_consume_ready) begin
                        immediate_low_q <= queue_consume_data;
                        frontend_state_q <= FRONTEND_IMMEDIATE_HIGH;
                    end
                end
                FRONTEND_IMMEDIATE_HIGH: begin
                    if (queue_consume_valid && queue_consume_ready) begin
                        frontend_state_q <= FRONTEND_OPCODE;
                        instruction_retired <= 1'b1;
                    end
                end
                default: frontend_state_q <= FRONTEND_UNSUPPORTED;
            endcase
        end else begin
            instruction_retired <= 1'b0;
        end
    end

    assign debug_cs = debug_segment_selectors[16 +: 16];
    assign debug_cs_base = debug_segment_bases[24 +: 24];
    assign unsupported_opcode = unsupported_q;
    assign debug_opcode = opcode_q;
    assign debug_prefetch_count = queue_count;
    always_comb begin
        case (frontend_state_q)
            FRONTEND_OPCODE: debug_micro_pc = 12'h000;
            FRONTEND_IMMEDIATE_LOW: debug_micro_pc = 12'h001;
            FRONTEND_IMMEDIATE_HIGH: debug_micro_pc = 12'h002;
            default: debug_micro_pc = 12'h0FF;
        endcase
    end
    assign debug_bus_state = bus_valid ? 4'h1 : 4'h0;
    assign bus_status = bus_valid ? 4'hD : 4'hF;
    assign data_out = 16'h0000;
    assign data_oe = 1'b0;
    assign bus_write = 1'b0;
    assign bus_lock = 1'b0;
    assign hlda = 1'b0;
endmodule
