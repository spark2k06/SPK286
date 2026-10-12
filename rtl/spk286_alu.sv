// SPDX-License-Identifier: MIT
// Pure byte/word ALU. Operation encoding: ADD=0 OR=1 ADC=2 SBB=3 AND=4 SUB=5 XOR=6.
// Candidate flags have no architectural update authority; the caller masks them.
`timescale 1ns/1ps
module spk286_alu (
    input logic [2:0] operation,
    input logic [15:0] operand_a, operand_b,
    input logic carry_in, operand_byte,
    output logic [15:0] result, candidate_flags
);
    logic [16:0] extended_result;
    logic subtract, arithmetic, carry;
    logic [15:0] a, b;
    logic sign_a, sign_b, sign_result;
    assign a = operand_byte ? {8'd0, operand_a[7:0]} : operand_a;
    assign b = operand_byte ? {8'd0, operand_b[7:0]} : operand_b;
    assign sign_a = operand_byte ? a[7] : a[15];
    assign sign_b = operand_byte ? b[7] : b[15];
    assign subtract = operation == 3'd3 || operation == 3'd5;
    assign arithmetic = operation == 3'd0 || operation == 3'd2 || subtract;
    assign carry = carry_in && (operation == 3'd2 || operation == 3'd3);
    always_comb begin
        extended_result = subtract ? ({1'b0, a} - {1'b0, b} - {16'd0, carry}) :
                                     ({1'b0, a} + {1'b0, b} + {16'd0, carry});
        result = operand_byte ? {8'd0, extended_result[7:0]} : extended_result[15:0];
        case (operation)
            3'd1: result = a | b;
            3'd4: result = a & b;
            3'd6: result = a ^ b;
            default: begin end
        endcase
        sign_result = operand_byte ? result[7] : result[15];
        candidate_flags = 16'h0000;
        candidate_flags[2] = ~^result[7:0];
        candidate_flags[6] = result == 16'h0000;
        candidate_flags[7] = sign_result;
        if (arithmetic) begin
            candidate_flags[0] = operand_byte ? extended_result[8] : extended_result[16];
            candidate_flags[4] = operand_a[4] ^ operand_b[4] ^ result[4];
            candidate_flags[11] = (sign_a ^ sign_result) &
                                    (subtract ? (sign_a ^ sign_b) :
                                                ~(sign_a ^ sign_b));
        end
    end
endmodule
