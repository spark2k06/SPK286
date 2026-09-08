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
    output logic decode_operand,
    input  logic decode_done,
    input  logic decode_byte_ready,
    output logic operand_request, operand_write, operand_select_rm,
    output logic [15:0] operand_write_data,
    input  logic operand_done,
    input  logic [15:0] operand_read_data,
    input  logic operand_gpr_write_en,
    input  logic [2:0] operand_gpr_write_index,
    input  logic [15:0] operand_gpr_write_data,
    output logic gpr_write_en,
    output logic [2:0] gpr_write_index,
    output logic [15:0] gpr_write_data
);
    logic [15:0] tmp0_q;
    logic high_byte_q;
    logic fetch_word, move_word, allowed, read_operand;
    assign allowed = operation_valid && !reset && !cancel && !start;
    assign fetch_word = operation_valid && !reset && !cancel && !start &&
                        operation == spk286_microcode_pkg::MC_FETCH_IMM16;
    assign move_word = operation_valid && !reset && !cancel && !start &&
                       operation == spk286_microcode_pkg::MC_MOVE;
    assign decode_operand = allowed && operation == spk286_microcode_pkg::MC_DECODE_MODRM;
    assign operand_request = allowed &&
                             (operation == spk286_microcode_pkg::MC_READ_REG16 ||
                              operation == spk286_microcode_pkg::MC_READ_RM16 ||
                              operation == spk286_microcode_pkg::MC_WRITE_REG16 ||
                              operation == spk286_microcode_pkg::MC_WRITE_RM16);
    assign operand_write = operation == spk286_microcode_pkg::MC_WRITE_REG16 ||
                           operation == spk286_microcode_pkg::MC_WRITE_RM16;
    assign operand_select_rm = operation == spk286_microcode_pkg::MC_READ_RM16 ||
                               operation == spk286_microcode_pkg::MC_WRITE_RM16;
    assign operand_write_data = tmp0_q;
    assign read_operand = operand_request && !operand_write;
    assign byte_ready = fetch_word || decode_byte_ready;
    assign operation_done = move_word || (fetch_word && byte_valid && high_byte_q) ||
                            (decode_operand && decode_done) || (operand_request && operand_done);
    assign gpr_write_en = move_word || operand_gpr_write_en;
    assign gpr_write_index = move_word ? destination : operand_gpr_write_index;
    assign gpr_write_data = move_word ? tmp0_q : operand_gpr_write_data;

    always_ff @(posedge clk) begin
        if (reset || cancel || start) begin
            tmp0_q <= 16'h0000;
            high_byte_q <= 1'b0;
        end else if (fetch_word && byte_valid) begin
            if (high_byte_q) tmp0_q[15:8] <= byte_data;
            else tmp0_q[7:0] <= byte_data;
            high_byte_q <= !high_byte_q;
        end else if (read_operand && operand_done) begin
            tmp0_q <= operand_read_data;
        end
    end
endmodule
