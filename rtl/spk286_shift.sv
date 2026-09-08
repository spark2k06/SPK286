// Iterative mathematical shift/rotate service. No x86 opcode or architectural state.
`timescale 1ns/1ps
module spk286_shift (
    input logic clk, reset, cancel, enable,
    input logic request_valid,
    output logic request_ready,
    input logic [2:0] kind,
    input logic operand_byte, carry_in,
    input logic [15:0] operand,
    input logic [7:0] count,
    output logic response_valid,
    input logic response_ready,
    output logic [15:0] result, candidate_flags, flags_mask,
    output logic result_write
);
    logic busy_q, byte_q, carry_q, single_q, original_sign_q;
    logic [2:0] kind_q, unused_high_count;
    assign unused_high_count = count[7:5];
    logic [4:0] remaining_q;
    logic [15:0] value_q, next_value;
    logic next_carry, sign_bit, next_sign;
    assign request_ready = !reset && !cancel && !busy_q && !response_valid;
    assign sign_bit = byte_q ? value_q[7] : value_q[15];
    assign next_sign = byte_q ? next_value[7] : next_value[15];
    always_comb begin
        next_value = value_q;
        next_carry = carry_q;
        case (kind_q)
            3'd0, 3'd2, 3'd4: begin
                next_value = value_q << 1;
                next_value[0] = kind_q == 0 ? sign_bit : kind_q == 2 ? carry_q : 1'b0;
                next_carry = sign_bit;
            end
            3'd1, 3'd3, 3'd5, 3'd7: begin
                next_value = value_q >> 1;
                if (byte_q)
                    next_value[7] = kind_q == 1 ? value_q[0] : kind_q == 3 ? carry_q : kind_q == 7 ? sign_bit : 1'b0;
                else
                    next_value[15] = kind_q == 1 ? value_q[0] : kind_q == 3 ? carry_q : kind_q == 7 ? sign_bit : 1'b0;
                next_carry = value_q[0];
            end
            default: begin end
        endcase
        if (byte_q) next_value[15:8] = 8'd0;
    end
    always_ff @(posedge clk) begin
        if (reset || cancel) begin
            busy_q <= 0; byte_q <= 0; carry_q <= 0; single_q <= 0; original_sign_q <= 0;
            kind_q <= 0; remaining_q <= 0; value_q <= 0;
            response_valid <= 0; result <= 0; candidate_flags <= 0; flags_mask <= 0; result_write <= 0;
        end else if (enable) begin
            if (response_valid && response_ready) response_valid <= 0;
            if (request_valid && request_ready) begin
                byte_q <= operand_byte; kind_q <= kind; carry_q <= carry_in;
                value_q <= operand_byte ? {8'd0, operand[7:0]} : operand;
                remaining_q <= count[4:0]; single_q <= count[4:0] == 1;
                original_sign_q <= operand_byte ? operand[7] : operand[15];
                result_write <= count[4:0] != 0;
                if (count[4:0] == 0) begin
                    result <= operand_byte ? {8'd0, operand[7:0]} : operand;
                    candidate_flags <= 0; flags_mask <= 0; response_valid <= 1;
                end else busy_q <= 1;
            end else if (busy_q) begin
                value_q <= next_value; carry_q <= next_carry;
                remaining_q <= remaining_q - 5'd1;
                if (remaining_q == 1) begin
                    busy_q <= 0; response_valid <= 1; result <= next_value;
                    candidate_flags <= 0;
                    candidate_flags[0] <= next_carry;
                    if (kind_q < 4) begin
                        // Multi-count OF is undefined architecturally. Captures
                        // retain the final-step value for every nonzero rotate.
                        flags_mask <= 16'h0801;
                        candidate_flags[11] <= !kind_q[0] ? next_sign ^ next_carry :
                                               next_sign ^ (byte_q ? next_value[6] : next_value[14]);
                    end else begin
                        // Nonzero CL captures compare final-step OF even for
                        // multi-count shifts; AF remains unspecified and preserved.
                        flags_mask <= 16'h08C5;
                        candidate_flags[2] <= ~^next_value[7:0];
                        candidate_flags[6] <= next_value == 0;
                        candidate_flags[7] <= next_sign;
                        candidate_flags[11] <= kind_q == 4 ? next_sign ^ next_carry :
                                               kind_q == 5 ? single_q && original_sign_q : 1'b0;
                    end
                end
            end
        end
    end
endmodule
