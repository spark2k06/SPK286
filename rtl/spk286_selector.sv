// 80286 selector decomposition and complete 8-byte descriptor-table bounds.
// This service is pure combinational PM0 infrastructure. It does not fetch
// memory or commit architectural state.
`timescale 1ns/1ps

module spk286_selector (
    input  logic [15:0] selector,
    input  logic [15:0] table_limit,
    input  logic [23:0] table_base,
    output logic [12:0] index,
    output logic        table_indicator,
    output logic [1:0]  rpl,
    output logic        null_selector,
    output logic [20:0] descriptor_end,
    output logic        descriptor_limit_valid,
    output logic        descriptor_selector_valid,
    output logic [23:0] descriptor_address,
    output logic        descriptor_address_carry
);
    logic [19:0] descriptor_offset;
    logic [24:0] address_sum;

    always_comb begin
        index = selector[15:3];
        table_indicator = selector[2];
        rpl = selector[1:0];
        // Only GDT entry zero is null; LDT entry zero (TI=1) is usable.
        null_selector = selector[15:2] == 14'd0;

        // 13-bit index * 8 plus the final byte is deliberately carried in
        // 21 bits. A truncated 16-bit expression could wrap an invalid entry
        // back into the beginning of a table.
        descriptor_offset = {4'b0, selector[15:3], 3'b000};
        descriptor_end = {1'b0, descriptor_offset} + 21'd7;
        descriptor_limit_valid = descriptor_end <= {5'b0, table_limit};
        descriptor_selector_valid = !null_selector && descriptor_limit_valid;

        address_sum = {1'b0, table_base} + {5'b0, descriptor_offset};
        descriptor_address = address_sum[23:0];
        descriptor_address_carry = address_sum[24];
    end
endmodule
