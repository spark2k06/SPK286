// Architectural storage; instruction policy and ALU flag generation live upstream.
`timescale 1ns/1ps

module spk286_registers (
    input  logic         clk,
    input  logic         reset,
    input  logic [2:0]   read_a_index,
    input  logic [2:0]   read_b_index,
    input  logic         read_a_byte,
    input  logic         read_b_byte,
    output logic [15:0]  read_a_data,
    output logic [15:0]  read_b_data,
    input  logic         write_en,
    input  logic         write_byte,
    input  logic [2:0]   write_index,
    input  logic [15:0]  write_data,
    input  logic         ip_write_en,
    input  logic [15:0]  ip_write_data,
    input  logic         flags_write_en,
    input  logic [15:0]  flags_write_data,
    input  logic [15:0]  flags_write_mask,
    output logic [127:0] gpr_state,
    output logic [15:0]  ip,
    output logic [15:0]  flags
);
    // Low word first: AX, CX, DX, BX, SP, BP, SI, DI (x86 register encoding).
    logic [127:0] gpr_q;
    logic [15:0] ip_q, flags_q;
    logic [15:0] effective_flags_mask;

    function automatic [15:0] read_register(input logic [127:0] state,
                                           input logic [2:0] index,
                                           input logic byte_access);
        if (byte_access)
            read_register = {8'h00, state[{index[1:0], index[2]} * 8 +: 8]};
        else
            read_register = state[index * 16 +: 16];
    endfunction

    assign effective_flags_mask = flags_write_mask & 16'h7FD5;
    assign read_a_data = read_register(gpr_q, read_a_index, read_a_byte);
    assign read_b_data = read_register(gpr_q, read_b_index, read_b_byte);
    assign gpr_state = gpr_q;
    assign ip = ip_q;
    assign flags = flags_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            // GPR zeroes are a deterministic project choice, not an Intel guarantee.
            gpr_q <= 128'h0;
            ip_q <= 16'hFFF0;
            flags_q <= 16'h0002;
        end else begin
            if (write_en) begin
                if (write_byte)
                    gpr_q[{write_index[1:0], write_index[2]} * 8 +: 8] <= write_data[7:0];
                else
                    gpr_q[write_index * 16 +: 16] <= write_data;
            end
            if (ip_write_en) ip_q <= ip_write_data;
            if (flags_write_en)
                flags_q <= (flags_q & ~effective_flags_mask) |
                           (flags_write_data & effective_flags_mask);
        end
    end
endmodule
