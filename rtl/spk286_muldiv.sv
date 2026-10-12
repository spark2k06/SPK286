// SPDX-License-Identifier: MIT
// Captured iterative integer arithmetic; no opcode, register or bus owner.
`timescale 1ns/1ps
module spk286_muldiv (
    input logic clk, reset, cancel, enable, request_valid,
    output logic request_ready,
    input logic [1:0] kind,
    input logic operand_byte,
    input logic [31:0] dividend,
    input logic [15:0] source,
    output logic response_valid,
    input logic response_ready,
    output logic [15:0] result_low, result_high, candidate_flags, flags_mask,
    output logic result_write, arithmetic_fault
);
    // kind: unsigned product, signed product, unsigned quotient, signed quotient.
    logic busy_q, divide_q, signed_q, byte_q, negative_q, remainder_negative_q;
    logic zero_divisor_q;
    logic [5:0] remaining_q;
    logic [31:0] factor_q, product_q, quotient_q;
    logic [15:0] multiplier_q, divisor_q, remainder_q;
    logic [31:0] normalized_dividend, absolute_dividend, next_product, signed_product;
    logic [15:0] normalized_source, absolute_source;
    logic dividend_negative, source_negative;
    logic [16:0] shifted_remainder;
    logic [15:0] reduced_remainder;
    logic [31:0] next_quotient;
    logic [15:0] signed_quotient;
    logic [15:0] signed_remainder, high_product;
    logic subtract_divisor, overflow;
    logic [15:0] byte_shift, byte_trial, byte_step;
    logic [7:0] byte_remainder, byte_quotient, byte_corrected_remainder, byte_corrected_quotient;
    logic byte_remainder_wrap, byte_overflow_accept;
    // The captured 286 byte-IDIV overflow path retains an eight-step finite
    // quotient. Reuse product storage while the ordinary divider runs; no
    // new timing states or external dependencies are introduced.
    assign byte_shift = {product_q[14:0],1'b0};
    assign byte_trial = {divisor_q[7:0],8'd0};
    assign byte_step = byte_shift >= byte_trial ? byte_shift-byte_trial+16'd1 : byte_shift;
    assign byte_remainder = product_q[15:8] + {7'd0,remainder_negative_q};
    assign byte_remainder_wrap = byte_remainder == divisor_q[7:0];
    assign byte_quotient = product_q[7:0] + {7'd0,byte_remainder_wrap};
    assign byte_corrected_quotient = negative_q ? 8'd0-byte_quotient : byte_quotient;
    assign byte_corrected_remainder = byte_remainder_wrap ? 8'd0 :
                                     (remainder_negative_q ? 8'd0-byte_remainder : byte_remainder);
    assign byte_overflow_accept = signed_q && byte_q && negative_q && !zero_divisor_q &&
                                  overflow && byte_corrected_quotient == 8'h80;
    function automatic [15:0] status(input logic [15:0] value, input logic narrow);
        status = 16'd0;
        status[2] = ~^value[7:0];
        status[6] = narrow ? value[7:0] == 0 : value == 0;
        status[7] = narrow ? value[7] : value[15];
    endfunction
    assign request_ready = enable && !reset && !cancel && !busy_q && !response_valid;
    assign normalized_dividend = kind[1] ? (operand_byte ? {16'd0,dividend[15:0]} : dividend) :
                                          (operand_byte ? {24'd0,dividend[7:0]} : {16'd0,dividend[15:0]});
    assign normalized_source = operand_byte ? {8'd0,source[7:0]} : source;
    assign dividend_negative = kind[0] && (kind[1] ? (operand_byte ? dividend[15] : dividend[31]) : (operand_byte ? dividend[7] : dividend[15]));
    assign source_negative = kind[0] && (operand_byte ? source[7] : source[15]);
    assign absolute_dividend = dividend_negative ? ((32'd0-normalized_dividend) &
        (kind[1] ? (operand_byte ? 32'h0000FFFF : 32'hFFFFFFFF) : (operand_byte ? 32'h000000FF : 32'h0000FFFF))) : normalized_dividend;
    assign absolute_source = source_negative ? ((16'd0-normalized_source) & (operand_byte ? 16'h00FF : 16'hFFFF)) : normalized_source;
    assign next_product = product_q + (multiplier_q[0] ? factor_q : 32'd0);
    assign signed_product = negative_q ? 32'd0-next_product : next_product;
    assign high_product = byte_q ? {8'd0,signed_product[15:8]} : signed_product[31:16];
    assign shifted_remainder = {remainder_q,quotient_q[31]};
    assign subtract_divisor = shifted_remainder >= {1'b0,divisor_q};
    assign reduced_remainder = 16'(subtract_divisor ? shifted_remainder-{1'b0,divisor_q} : shifted_remainder);
    assign next_quotient = {quotient_q[30:0],subtract_divisor};
    assign signed_quotient = negative_q ? 16'd0-next_quotient[15:0] : next_quotient[15:0];
    assign signed_remainder = remainder_negative_q ? 16'd0-reduced_remainder[15:0] : reduced_remainder[15:0];
    assign overflow = signed_q ? next_quotient > (byte_q ? (negative_q ? 32'd128 : 32'd127) : (negative_q ? 32'd32768 : 32'd32767)) :
                                        next_quotient > (byte_q ? 32'd255 : 32'd65535);
    always_ff @(posedge clk) begin
        if (reset || cancel) begin
            busy_q<=0;divide_q<=0;signed_q<=0;byte_q<=0;negative_q<=0;remainder_negative_q<=0;zero_divisor_q<=0;remaining_q<=0;
            factor_q<=0;product_q<=0;quotient_q<=0;multiplier_q<=0;divisor_q<=0;remainder_q<=0;
            response_valid<=0;result_low<=0;result_high<=0;candidate_flags<=0;flags_mask<=0;result_write<=0;arithmetic_fault<=0;
        end else if (enable) begin
            if (response_valid && response_ready) response_valid<=0;
            if (request_valid && request_ready) begin
                busy_q<=1;divide_q<=kind[1];signed_q<=kind[0];byte_q<=operand_byte;
                negative_q<=dividend_negative ^ source_negative;remainder_negative_q<=dividend_negative;
                zero_divisor_q<=absolute_source==0;remaining_q<=kind[1] ? 6'd32 : (operand_byte ? 6'd8 : 6'd16);
                factor_q<=absolute_dividend;
                product_q<=kind==3 && operand_byte ? {16'd0,dividend[15:0] ^ {16{dividend_negative}}} : 32'd0;
                multiplier_q<=absolute_source;
                quotient_q<=absolute_dividend;divisor_q<=absolute_source;remainder_q<=0;
                result_write<=0;arithmetic_fault<=0;candidate_flags<=0;flags_mask<=0;
            end else if (busy_q) begin
                remaining_q<=remaining_q-6'd1;
                if (divide_q) begin
                    quotient_q<=next_quotient;remainder_q<=reduced_remainder[15:0];
                    if (signed_q && byte_q && remaining_q>24) product_q<={16'd0,byte_step};
                end
                else begin product_q<=next_product;factor_q<=factor_q<<1;multiplier_q<=multiplier_q>>1;end
                if (remaining_q==1) begin
                    busy_q<=0;response_valid<=1;
                    if (divide_q) begin
                        arithmetic_fault<=zero_divisor_q || (overflow && !byte_overflow_accept);
                        result_write<=!zero_divisor_q && (!overflow || byte_overflow_accept);
                        result_low<=byte_overflow_accept ? {byte_corrected_remainder,byte_corrected_quotient} :
                                    byte_q ? {signed_remainder[7:0],signed_quotient[7:0]} : signed_quotient[15:0];
                        result_high<=byte_q ? 16'd0 : signed_remainder;
                        // Intel defines no arithmetic FLAGS after DIV/IDIV.
                        // Preserve them; no historical undefined-bit claim.
                        candidate_flags<=0;flags_mask<=0;
                    end else begin
                        result_low<=signed_product[15:0];result_high<=byte_q ? 16'd0 : signed_product[31:16];
                        result_write<=1;arithmetic_fault<=0;candidate_flags<=status(high_product,byte_q);
                        // Physical captures expose SZP of the upper product.
                        candidate_flags[0]<=signed_q ? (byte_q ? signed_product != {{24{signed_product[7]}},signed_product[7:0]} : signed_product != {{16{signed_product[15]}},signed_product[15:0]}) : high_product != 0;
                        candidate_flags[11]<=signed_q ? (byte_q ? signed_product != {{24{signed_product[7]}},signed_product[7:0]} : signed_product != {{16{signed_product[15]}},signed_product[15:0]}) : high_product != 0;
                        flags_mask<=16'h08C5;
                    end
                end
            end
        end
    end
endmodule
