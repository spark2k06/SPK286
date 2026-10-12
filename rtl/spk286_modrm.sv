// SPDX-License-Identifier: MIT
// 16-bit 80286 ModR/M metadata. No opcode or physical bus semantics.
`timescale 1ns/1ps

module spk286_modrm (
    input  logic [7:0] encoded,
    output logic [1:0] mode,
    output logic [2:0] reg_index,
    output logic [2:0] rm_index,
    output logic       register_direct,
    output logic [1:0] displacement_bytes
);
    assign mode = encoded[7:6];
    assign reg_index = encoded[5:3];
    assign rm_index = encoded[2:0];
    assign register_direct = mode == 2'b11;
    assign displacement_bytes = (mode == 2'b01) ? 2'd1 :
                                ((mode == 2'b10 || encoded[7:6] == 2'b00 &&
                                  encoded[2:0] == 3'b110) ? 2'd2 : 2'd0);
endmodule
