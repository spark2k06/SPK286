// Streaming ModR/M/displacement acquisition and stable instruction EA context.
// The decoder and EA table are reusable; no opcode or bus sequencing lives here.
`timescale 1ns/1ps
module spk286_operand_decode (
    input  logic clk, reset, cancel, start,
    input  logic enable, rearm,
    input  logic byte_valid,
    input  logic [7:0] byte_data,
    output logic byte_ready,
    output logic done,
    output logic modrm_valid,
    input  logic [15:0] bx, bp, si, di,
    output logic [1:0] mode,
    output logic [2:0] reg_index, rm_index,
    output logic register_direct,
    output logic [15:0] displacement,
    output logic [15:0] effective_offset,
    output logic [1:0] segment_index
);
    localparam logic [2:0] MODRM = 3'd0, DISP_LOW = 3'd1, DISP_HIGH = 3'd2,
                           RESOLVE = 3'd3, COMPLETE = 3'd4;
    logic [2:0] state_q;
    logic [1:0] decoded_mode, decoded_size, size_q;
    logic [2:0] decoded_reg, decoded_rm;
    logic decoded_direct, ea_memory;
    logic [15:0] ea_offset;
    logic [1:0] ea_segment;
    logic allowed, reuse_q;
    spk286_modrm modrm (
        .encoded(byte_data), .mode(decoded_mode), .reg_index(decoded_reg),
        .rm_index(decoded_rm), .register_direct(decoded_direct), .displacement_bytes(decoded_size)
    );
    spk286_effective_address ea (
        .mode(mode), .rm_index(rm_index), .displacement(displacement),
        .bx(bx), .bp(bp), .si(si), .di(di), .offset(ea_offset),
        .segment_index(ea_segment), .memory_operand(ea_memory)
    );
    assign allowed = enable && !reset && !cancel && !start;
    assign byte_ready = allowed && (state_q == MODRM || state_q == DISP_LOW || state_q == DISP_HIGH);
    // RESOLVE captures the computed offset on the same edge that advances the
    // microsequencer. All instruction bytes are already stable at this boundary.
    assign done = allowed && (state_q == RESOLVE || (state_q == COMPLETE && reuse_q));
    assign modrm_valid = state_q != MODRM;
    always_ff @(posedge clk) begin
        if (reset || cancel || start) begin
            reuse_q <= 1'b0;
            state_q <= MODRM;
            mode <= 2'b00; reg_index <= 3'd0; rm_index <= 3'd0;
            register_direct <= 1'b0; displacement <= 16'h0000;
            effective_offset <= 16'h0000; segment_index <= 2'd3; size_q <= 2'd0;
        end else if (rearm && state_q == COMPLETE) begin
            // A decoded branch reuses the captured EA; no bytes or GPRs are reread.
            reuse_q <= 1'b1;
        end else if (allowed) begin
            if (state_q == COMPLETE && reuse_q) reuse_q <= 1'b0;
            if (byte_valid && byte_ready) begin
                case (state_q)
                    MODRM: begin
                        mode <= decoded_mode; reg_index <= decoded_reg; rm_index <= decoded_rm;
                        register_direct <= decoded_direct; size_q <= decoded_size;
                        state_q <= decoded_size == 0 ? RESOLVE : DISP_LOW;
                    end
                    DISP_LOW: begin
                        displacement <= size_q == 1 ? {{8{byte_data[7]}}, byte_data} : {8'h00, byte_data};
                        state_q <= size_q == 1 ? RESOLVE : DISP_HIGH;
                    end
                    DISP_HIGH: begin
                        displacement[15:8] <= byte_data;
                        state_q <= RESOLVE;
                    end
                    default: state_q <= state_q;
                endcase
            end else if (state_q == RESOLVE) begin
                effective_offset <= ea_offset;
                segment_index <= ea_memory ? ea_segment : 2'd3;
                state_q <= COMPLETE;
            end
        end
    end
endmodule
