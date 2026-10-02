// One logical byte/word service, shared by REG and RM. Byte register
// encoding selects AL..BL/AH..BH independently of word-register encoding.
// Register access completes locally; memory completes through the BIU response.
`timescale 1ns/1ps
module spk286_operand #(parameter bit USE_PARALLEL_RANGE = 1'b0) (
    input  logic clk, reset, cancel,
    input  logic request_valid, request_write, request_check, request_byte, select_rm,
    input  logic [15:0] write_data,
    output logic done, unlimited_memory_done,
    output logic [15:0] read_data,
    input  logic [127:0] register_state,
    input  logic [2:0] reg_index, rm_index,
    input  logic register_direct,
    input  logic [23:0] physical_address,
    input  logic [15:0] offset, segment_limit,
    input  logic segment_expand_down, parallel_within_limit,
    output logic blocked,
    output logic gpr_write_en, gpr_write_byte,
    output logic [2:0] gpr_write_index,
    output logic [15:0] gpr_write_data,
    output logic memory_request,
    input  logic memory_request_ready,
    output logic memory_write, memory_byte,
    output logic [23:0] memory_address,
    output logic [15:0] memory_write_data,
    input  logic memory_response_valid,
    output logic memory_response_ready,
    output logic timing_wait,
    input  logic [15:0] memory_read_data
);
    logic pending_q, is_memory, allowed, within_limit;
    logic [2:0] register_index, word_index;
    logic [15:0] register_word;
    assign register_index = select_rm ? rm_index : reg_index;
    assign is_memory = select_rm && !register_direct;
    assign within_limit = USE_PARALLEL_RANGE ? parallel_within_limit : segment_expand_down ?
                          (offset > segment_limit &&
                           (request_byte || offset != 16'hFFFF)) :
                          (offset < segment_limit ||
                           (request_byte && offset == segment_limit));
    assign allowed = request_valid && !reset && !cancel && !blocked;
    assign memory_request = allowed && is_memory && !pending_q && within_limit && !request_check;
    assign memory_write = request_write;
    assign memory_byte = request_byte;
    assign memory_address = physical_address;
    assign memory_write_data = write_data;
    assign memory_response_ready = allowed && pending_q;
    // Observe only genuine memory-service stalls: BIU admission or an
    // outstanding response. Register accesses, checks, limit faults,
    // cancellation and the response-acceptance cycle are not waits.
    assign timing_wait = allowed && is_memory &&
                         ((!pending_q && !request_check && within_limit && !memory_request_ready) ||
                          (pending_q && !memory_response_valid));
    assign done = allowed && ((request_check && (!is_memory || within_limit) && !pending_q) || (!is_memory && !pending_q) || (pending_q && memory_response_valid));
    // Completion predicate for a valid memory request with unlimited range.
    // The caller must establish request_valid, is_memory and within_limit.
    // Retain cancellation, blocking and the existing pending/response handshake.
    assign unlimited_memory_done = !reset && !cancel && !blocked &&
                                   ((request_check && !pending_q) ||
                                    (pending_q && memory_response_valid));
    assign word_index = request_byte ? {1'b0, register_index[1:0]} : register_index;
    assign register_word = register_state[word_index * 16 +: 16];
    assign read_data = is_memory ? memory_read_data : (request_byte ?
                       {8'd0, (register_index[2] ? register_word[15:8] : register_word[7:0])} : register_word);
    assign gpr_write_en = done && request_write && !is_memory && !request_check;
    assign gpr_write_index = register_index;
    assign gpr_write_byte = request_byte;
    assign gpr_write_data = write_data;
    always_ff @(posedge clk) begin
        if (reset || cancel) begin
            pending_q <= 1'b0;
            blocked <= 1'b0;
        end else begin
            if (allowed && is_memory && !within_limit) blocked <= 1'b1;
            if (memory_request && memory_request_ready) pending_q <= 1'b1;
            if (memory_response_ready && memory_response_valid) pending_q <= 1'b0;
        end
    end
endmodule
