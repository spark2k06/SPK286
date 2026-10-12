// SPDX-License-Identifier: MIT
// Instruction metadata for direct flag controls. Architectural storage is shared.
`timescale 1ns/1ps
module spk286_flags_decode (
    input logic [7:0] opcode, ah,
    input logic carry,
    output logic [15:0] candidate, mask
);
    always_comb begin
        candidate = 16'd0;
        mask = 16'd0;
        case (opcode)
            8'hF5: begin mask = 16'h0001; candidate[0] = !carry; end
            8'hF8: mask = 16'h0001;
            8'hF9: begin mask = 16'h0001; candidate[0] = 1'b1; end
            8'hFC: mask = 16'h0400;
            8'hFD: begin mask = 16'h0400; candidate[10] = 1'b1; end
            8'h9E: begin mask = 16'h00D5; candidate = {8'd0, ah}; end
            default: begin end
        endcase
    end
endmodule
