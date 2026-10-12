// SPDX-License-Identifier: MIT
// Instruction semantics resolved from captured opcode and ModR/M extension.
// Neither the pure ALU nor the executor interprets an x86 opcode.
`timescale 1ns/1ps
module spk286_alu_decode (
    input logic [7:0] opcode,
    input logic [2:0] group_extension,
    output logic [2:0] operation,
    output logic write_result, operand_byte, reverse_operands,
    output logic [15:0] flags_mask, undefined_mask
);
    logic string_compare;
    assign string_compare = opcode[7:1] == 7'b1010011 || opcode[7:1] == 7'b1010111;
    logic [2:0] kind;
    logic logical_operation, adjust_instruction, test_instruction, inc_dec, unary_not, unary_neg;
    assign adjust_instruction = opcode == 8'h27 || opcode == 8'h2F || opcode == 8'h37 || opcode == 8'h3F || opcode == 8'hD4 || opcode == 8'hD5;
    assign inc_dec = opcode[7:4] == 4'h4 || opcode == 8'hFE || (opcode == 8'hFF && group_extension < 2);
    assign unary_not = (opcode == 8'hF6 || opcode == 8'hF7) && group_extension == 2;
    assign unary_neg = (opcode == 8'hF6 || opcode == 8'hF7) && group_extension == 3;
    assign reverse_operands = unary_neg;
    assign test_instruction = opcode == 8'h84 || opcode == 8'h85 || opcode == 8'hA8 || opcode == 8'hA9 || ((opcode == 8'hF6 || opcode == 8'hF7) && group_extension == 0);
    assign kind = string_compare ? 3'd7 : unary_not ? 3'd6 : unary_neg ? 3'd5 : inc_dec ? ((opcode[7:4] == 4'h4 ? opcode[3] : group_extension[0]) ? 3'd5 : 3'd0) : test_instruction ? 3'd4 : opcode == 8'h80 || opcode == 8'h81 || opcode == 8'h83 ? group_extension : opcode[5:3];
    assign operand_byte = (string_compare && !opcode[0]) || opcode == 8'hF6 || opcode == 8'hFE || ((opcode == 8'hC0 || opcode == 8'hD0 || opcode == 8'hD2)) || (test_instruction && !opcode[0]) || opcode == 8'h80 || (opcode[7:6] == 2'b00 && !opcode[0]);
    assign operation = kind == 3'd7 ? 3'd5 : kind;
    assign write_result = adjust_instruction || (kind != 3'd7 && !test_instruction);
    assign logical_operation = kind == 3'd1 || kind == 3'd4 || kind == 3'd6;
    assign flags_mask = unary_not ? 16'h0000 : inc_dec ? 16'h08D4 : logical_operation ? 16'h08C5 : 16'h08D5;
    assign undefined_mask = !unary_not && logical_operation ? 16'h0010 : 16'h0000;
endmodule
