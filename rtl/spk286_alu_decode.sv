// Instruction semantics resolved from captured opcode and ModR/M extension.
// Neither the pure ALU nor the executor interprets an x86 opcode.
`timescale 1ns/1ps
module spk286_alu_decode (
    input logic [7:0] opcode,
    input logic [2:0] group_extension,
    output logic [2:0] operation,
    output logic write_result,
    output logic [15:0] flags_mask, undefined_mask
);
    logic [2:0] kind;
    logic logical_operation;
    assign kind = opcode == 8'h81 || opcode == 8'h83 ? group_extension : opcode[5:3];
    assign operation = kind == 3'd7 ? 3'd5 : kind;
    assign write_result = kind != 3'd7;
    assign logical_operation = kind == 3'd1 || kind == 3'd4 || kind == 3'd6;
    assign flags_mask = logical_operation ? 16'h08C5 : 16'h08D5;
    assign undefined_mask = logical_operation ? 16'h0010 : 16'h0000;
endmodule
