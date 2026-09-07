// Functional micro-operation service. Physical fetch/READY belongs to the BIU.
`timescale 1ns/1ps

module spk286_micro_executor (
    input  logic clk,
    input  logic reset,
    input  logic cancel,
    input  logic start,
    input  logic operation_valid,
    input  logic [spk286_microcode_pkg::MC_WORD_WIDTH-1:0] operation,
    output logic operation_done,
    input  logic byte_valid,
    input  logic [7:0] byte_data,
    output logic byte_ready,
    input  logic [2:0] destination,
    output logic gpr_write_en,
    output logic [2:0] gpr_write_index,
    output logic [15:0] gpr_write_data
);
    logic [15:0] tmp0_q;
    logic high_byte_q;
    logic fetch_word, move_word;
    assign fetch_word = operation_valid && !reset && !cancel && !start &&
                        operation == spk286_microcode_pkg::MC_FETCH_IMM16;
    assign move_word = operation_valid && !reset && !cancel && !start &&
                       operation == spk286_microcode_pkg::MC_MOVE;
    assign byte_ready = fetch_word;
    assign operation_done = move_word || (fetch_word && byte_valid && high_byte_q);
    assign gpr_write_en = move_word;
    assign gpr_write_index = destination;
    assign gpr_write_data = tmp0_q;

    always_ff @(posedge clk) begin
        if (reset || cancel || start) begin
            tmp0_q <= 16'h0000;
            high_byte_q <= 1'b0;
        end else if (fetch_word && byte_valid) begin
            if (high_byte_q) tmp0_q[15:8] <= byte_data;
            else tmp0_q[7:0] <= byte_data;
            high_byte_q <= !high_byte_q;
        end
    end
endmodule
