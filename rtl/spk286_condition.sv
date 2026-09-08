// Intel 80286 condition-code predicates; no architectural state or opcode decode.
`timescale 1ns/1ps
module spk286_condition (
    input logic [3:0] condition_code,
    input logic carry, parity, zero, sign_flag, overflow,
    output logic taken
);
    logic base_condition;
    always_comb begin
        case (condition_code[3:1])
            3'd0: base_condition = overflow;
            3'd1: base_condition = carry;
            3'd2: base_condition = zero;
            3'd3: base_condition = carry || zero;
            3'd4: base_condition = sign_flag;
            3'd5: base_condition = parity;
            3'd6: base_condition = sign_flag != overflow;
            3'd7: base_condition = zero || (sign_flag != overflow);
            default: base_condition = 1'b0;
        endcase
    end
    assign taken = base_condition ^ condition_code[0];
endmodule
