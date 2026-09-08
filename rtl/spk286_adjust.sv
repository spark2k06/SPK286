// Decimal/radix arithmetic service. No opcode, architectural register or bus owner.
`timescale 1ns/1ps
module spk286_adjust (
    input logic clk, reset, cancel, enable,
    input logic request_valid,
    output logic request_ready,
    input logic [2:0] kind,
    input logic [15:0] operand,
    input logic [7:0] radix,
    input logic carry_in, auxiliary_in,
    output logic response_valid,
    input logic response_ready,
    output logic [15:0] result, candidate_flags, flags_mask,
    output logic result_write, arithmetic_fault
);
    // 0 decimal add, 1 decimal subtract, 2 unpacked add, 3 unpacked subtract,
    // 4 unpack by radix, 5 pack by radix. These are functional selectors.
    logic busy_q, divide_q;
    logic [3:0] remaining_q;
    logic [7:0] factor_q, multiplier_q, accumulator_q, divisor_q, quotient_q;
    logic [7:0] remainder_q;
    logic [8:0] shifted_remainder;
    logic [7:0] next_remainder;
    logic [7:0] next_quotient, next_accumulator;
    logic low_adjust, high_adjust;
    logic [7:0] correction, decimal_result;
    logic [15:0] unpacked_result;
    function automatic [15:0] status(input logic [7:0] value);
        status = 16'd0;
        status[2] = ~^value;
        status[6] = value == 0;
        status[7] = value[7];
    endfunction
    assign request_ready = enable && !reset && !cancel && !busy_q && !response_valid;
    assign low_adjust = operand[3:0] > 9 || auxiliary_in;
    assign high_adjust = operand[7:0] > 8'h99 || carry_in;
    assign correction = (low_adjust ? 8'd6 : 8'd0) + (high_adjust ? 8'h60 : 8'd0);
    assign decimal_result = kind[0] ? operand[7:0] - correction : operand[7:0] + correction;
    assign unpacked_result = (low_adjust ? (kind[0] ? operand - 16'h0106 : operand + 16'h0106) : operand) & 16'hFF0F;
    assign shifted_remainder = {remainder_q, quotient_q[7]};
    assign next_remainder = 8'(shifted_remainder >= {1'b0, divisor_q} ? shifted_remainder - {1'b0, divisor_q} : shifted_remainder);
    assign next_quotient = {quotient_q[6:0], shifted_remainder >= {1'b0, divisor_q}};
    assign next_accumulator = accumulator_q + (multiplier_q[0] ? factor_q : 8'd0);
    always_ff @(posedge clk) begin
        if (reset || cancel) begin
            busy_q <= 0; divide_q <= 0; remaining_q <= 0;
            factor_q <= 0; multiplier_q <= 0; accumulator_q <= 0;
            divisor_q <= 0; quotient_q <= 0; remainder_q <= 0;
            response_valid <= 0; result <= 0; candidate_flags <= 0; flags_mask <= 0;
            result_write <= 0; arithmetic_fault <= 0;
        end else if (enable) begin
            if (response_valid && response_ready) response_valid <= 0;
            if (request_valid && request_ready) begin
                result_write <= 1; arithmetic_fault <= 0;
                if (kind < 2) begin
                    result <= {operand[15:8], decimal_result};
                    candidate_flags <= status(decimal_result);
                    candidate_flags[0] <= high_adjust || (kind[0] && low_adjust && operand[7:0] < 6);
                    candidate_flags[4] <= low_adjust;
                    flags_mask <= 16'h00D5; response_valid <= 1;
                end else if (kind < 4) begin
                    result <= unpacked_result;
                    candidate_flags <= low_adjust ? 16'h0011 : 16'd0;
                    flags_mask <= 16'h0011; response_valid <= 1;
                end else if (kind == 4 && radix == 0) begin
                    // Pinned physical zero-radix faults preserve AX and expose
                    // SZP from the initial unsigned half dividend before #DE.
                    result <= operand; result_write <= 0; arithmetic_fault <= 1;
                    candidate_flags <= status({1'b0, operand[7:1]});
                    // Fault frames expose the otherwise undefined CF/AF/OF.
                    // All pinned zero-radix captures clear these three bits.
                    flags_mask <= 16'h08D5; response_valid <= 1;
                end else if (kind == 4 || kind == 5) begin
                    busy_q <= 1; divide_q <= kind == 4; remaining_q <= 8;
                    divisor_q <= radix; quotient_q <= operand[7:0]; remainder_q <= 0;
                    factor_q <= radix; multiplier_q <= operand[15:8]; accumulator_q <= operand[7:0];
                end else begin
                    // Invalid functional selectors cannot silently write a value.
                    result <= operand; result_write <= 0; arithmetic_fault <= 1;
                    candidate_flags <= 0; flags_mask <= 0; response_valid <= 1;
                end
            end else if (busy_q) begin
                remaining_q <= remaining_q - 1'b1;
                if (divide_q) begin
                    quotient_q <= next_quotient; remainder_q <= next_remainder;
                end else begin
                    accumulator_q <= next_accumulator;
                    factor_q <= factor_q << 1; multiplier_q <= multiplier_q >> 1;
                end
                if (remaining_q == 1) begin
                    busy_q <= 0; response_valid <= 1; flags_mask <= 16'h00C4;
                    result <= divide_q ? {next_quotient, next_remainder} : {8'd0, next_accumulator};
                    candidate_flags <= status(divide_q ? next_remainder : next_accumulator);
                end
            end
        end
    end
endmodule
