// Instruction semantics resolved from captured opcode and ModR/M extension.
// Neither the pure ALU nor the executor interprets an x86 opcode.
`timescale 1ns/1ps
module spk286_alu_decode (
    input logic [7:0] opcode,
    input logic [2:0] group_extension,
    output logic [2:0] operation,
    output logic write_result, operand_byte,
    output logic [15:0] flags_mask, undefined_mask
);
    logic [2:0] kind;
    logic logical_operation, test_instruction;
    assign test_instruction = opcode == 8'h84 || opcode == 8'h85 || opcode == 8'hA8 || opcode == 8'hA9 || opcode == 8'hF6 || opcode == 8'hF7;
    assign kind = opcode[7:4] == 4'h4 ? (opcode[3] ? 3'd5 : 3'd0) : test_instruction ? 3'd4 : opcode == 8'h80 || opcode == 8'h81 || opcode == 8'h83 ? group_extension : opcode[5:3];
    assign operand_byte = ((opcode == 8'hC0 || opcode == 8'hD0 || opcode == 8'hD2)) || (test_instruction && !opcode[0]) || opcode == 8'h80 || (opcode[7:6] == 2'b00 && !opcode[0]);
    assign operation = kind == 3'd7 ? 3'd5 : kind;
    assign write_result = kind != 3'd7 && !test_instruction;
    assign logical_operation = kind == 3'd1 || kind == 3'd4 || kind == 3'd6;
    assign flags_mask = opcode[7:4] == 4'h4 ? 16'h08D4 : logical_operation ? 16'h08C5 : 16'h08D5;
    assign undefined_mask = logical_operation ? 16'h0010 : 16'h0000;
endmodule
