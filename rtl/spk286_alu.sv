// Pure word ALU. Operation encoding: ADD=0 OR=1 ADC=2 SBB=3 AND=4 SUB=5 XOR=6.
// Candidate flags have no architectural update authority; the caller masks them.
`timescale 1ns/1ps
module spk286_alu (
    input logic [2:0] operation,
    input logic [15:0] operand_a, operand_b,
    input logic carry_in,
    output logic [15:0] result, candidate_flags
);
    logic [16:0] extended_result;
    logic subtract, arithmetic, carry;
    assign subtract = operation == 3'd3 || operation == 3'd5;
    assign arithmetic = operation == 3'd0 || operation == 3'd2 || subtract;
    assign carry = carry_in && (operation == 3'd2 || operation == 3'd3);
    always_comb begin
        extended_result = subtract ? ({1'b0, operand_a} - {1'b0, operand_b} - {16'd0, carry}) :
                                     ({1'b0, operand_a} + {1'b0, operand_b} + {16'd0, carry});
        result = extended_result[15:0];
        case (operation)
            3'd1: result = operand_a | operand_b;
            3'd4: result = operand_a & operand_b;
            3'd6: result = operand_a ^ operand_b;
            default: begin end
        endcase
        candidate_flags = 16'h0000;
        candidate_flags[2] = ~^result[7:0];
        candidate_flags[6] = result == 16'h0000;
        candidate_flags[7] = result[15];
        if (arithmetic) begin
            candidate_flags[0] = extended_result[16];
            candidate_flags[4] = operand_a[4] ^ operand_b[4] ^ result[4];
            candidate_flags[11] = (operand_a[15] ^ result[15]) &
                                    (subtract ? (operand_a[15] ^ operand_b[15]) :
                                                ~(operand_a[15] ^ operand_b[15]));
        end
    end
endmodule
