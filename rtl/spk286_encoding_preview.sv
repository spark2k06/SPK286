// SPDX-License-Identifier: MIT
// Side-effect-free instruction-byte qualification for a retained target.
// Opcode selection, prefixes, groups and ModR/M reuse functional decoders;
// trailing-byte requirements are generated from canonical microcode.
`ifndef SPK286_ENCODING_PREVIEW_SV
`define SPK286_ENCODING_PREVIEW_SV
`timescale 1ns/1ps
module spk286_encoding_preview (
    input logic clk, reset, cancel, start, enable,
    input logic byte_valid,
    input logic [7:0] byte_data,
    input logic abort_fetch,
    output logic byte_ready,
    output logic complete, valid_length,
    output logic invalid_opcode, unsupported, overlength, fetch_fault,
    output logic [3:0] length
);
    localparam logic [1:0] OPCODE = 2'd0, MODRM = 2'd1, TAIL = 2'd2;
    logic [1:0] state_q;
    logic active_q, accept_byte, is_prefix, extended_opcode;
    logic context_active, segment_override, lock_prefix;
    logic [1:0] segment_index, repeat_kind;
    logic [3:0] byte_count;
    logic [7:0] opcode_q;
    logic extended_q, dispatch_q;
    logic [2:0] tail_q;
    logic [3:0] remaining_q;
    logic decode_supported, decode_invalid;
    logic [2:0] destination, source_index;
    logic [spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] entry, dispatch_entry;
    logic [6:0] shape, child_shape;
    logic [1:0] mode, displacement_bytes;
    logic [2:0] reg_index, rm_index;
    logic register_direct, form_supported, dispatch_valid;
    logic push_enabled, push_return_ip, branch_taken, decrement_count;
    logic [2:0] adjust_kind;
    logic [1:0] muldiv_kind, decoded_segment;
    logic string_byte, string_compare;
    logic [3:0] opcode_tail, modrm_tail;

    spk286_instruction_context instruction_context (
        .clk(clk), .reset(reset), .cancel(cancel || start), .complete(1'b0),
        .consume(accept_byte), .prefix_accept(state_q == OPCODE && is_prefix),
        .byte_data(byte_data), .is_prefix(is_prefix), .active(context_active),
        .segment_override(segment_override), .lock_prefix(lock_prefix),
        .extended_opcode(extended_opcode), .segment_index(segment_index),
        .repeat_kind(repeat_kind), .byte_count(byte_count)
    );
    spk286_decoder #(.SYNTAX_ONLY(1'b1)) decoder (
        .opcode(byte_data), .extended_opcode(extended_opcode),
        .supported(decode_supported), .invalid_opcode(decode_invalid),
        .destination(destination), .source_index(source_index), .entry(entry)
    );
    spk286_modrm modrm (
        .encoded(byte_data), .mode(mode), .reg_index(reg_index), .rm_index(rm_index),
        .register_direct(register_direct), .displacement_bytes(displacement_bytes)
    );
    spk286_control_decode #(.SYNTAX_ONLY(1'b1)) control_decode (
        .opcode(opcode_q), .extended_opcode(extended_q), .group_extension(reg_index),
        .condition_taken(1'b0), .zero(1'b0), .count(16'd0),
        .push_enabled(push_enabled), .push_return_ip(push_return_ip),
        .branch_taken(branch_taken), .decrement_count(decrement_count),
        .form_supported(form_supported), .dispatch_entry(dispatch_entry),
        .adjust_kind(adjust_kind), .muldiv_kind(muldiv_kind),
        .segment_index(decoded_segment), .string_byte(string_byte),
        .string_compare(string_compare), .dispatch_valid(dispatch_valid)
    );
    assign shape = entry[6:0];
    assign child_shape = dispatch_entry[6:0];
    // The identical FETCH_PORT selector is used by the functional executor.
    assign opcode_tail = {1'b0, shape[2:0]} + {3'd0, shape[4] && !byte_data[3]};
    assign modrm_tail = {2'd0, displacement_bytes} +
                        (dispatch_q ? {1'b0, child_shape[2:0]} : {1'b0, tail_q});
    assign byte_ready = enable && active_q && !complete && !reset && !cancel && !start &&
                        !abort_fetch && byte_count < 4'd10;
    assign accept_byte = byte_valid && byte_ready;
    always_ff @(posedge clk) begin
        if (reset || cancel || start) begin
            active_q <= start && !reset && !cancel;
            state_q <= OPCODE;
            opcode_q <= 8'd0; extended_q <= 1'b0; dispatch_q <= 1'b0;
            tail_q <= 3'd0; remaining_q <= 4'd0;
            complete <= 1'b0; valid_length <= 1'b0;
            invalid_opcode <= 1'b0; unsupported <= 1'b0;
            overlength <= 1'b0; fetch_fault <= 1'b0; length <= 4'd0;
        end else if (enable && active_q && !complete) begin
            if (abort_fetch) begin
                complete <= 1'b1; fetch_fault <= 1'b1; length <= byte_count;
            end else if (byte_count == 4'd10) begin
                // A ten-byte complete encoding finishes on its tenth edge;
                // this path applies only when another byte would be needed.
                complete <= 1'b1; overlength <= 1'b1; length <= byte_count;
            end else if (accept_byte) begin
                length <= byte_count + 4'd1;
                case (state_q)
                    OPCODE: begin
                        if (!is_prefix) begin
                            opcode_q <= byte_data; extended_q <= extended_opcode;
                            tail_q <= opcode_tail[2:0]; dispatch_q <= shape[3];
                            if (decode_invalid || !decode_supported || !shape[6]) begin
                                complete <= 1'b1; invalid_opcode <= decode_invalid;
                                unsupported <= !decode_invalid;
                            end else if (shape[5]) state_q <= MODRM;
                            else if (opcode_tail != 0) begin
                                remaining_q <= opcode_tail; state_q <= TAIL;
                            end else begin complete <= 1'b1; valid_length <= 1'b1; end
                        end
                    end
                    MODRM: begin
                        if (!form_supported || dispatch_q && (!dispatch_valid || !child_shape[6] || child_shape[3] || child_shape[4])) begin
                            complete <= 1'b1; unsupported <= 1'b1;
                        end else if (modrm_tail != 0) begin
                            remaining_q <= modrm_tail; state_q <= TAIL;
                        end else begin complete <= 1'b1; valid_length <= 1'b1; end
                    end
                    TAIL: begin
                        remaining_q <= remaining_q - 4'd1;
                        if (remaining_q == 4'd1) begin complete <= 1'b1; valid_length <= 1'b1; end
                    end
                    default: begin complete <= 1'b1; unsupported <= 1'b1; end
                endcase
            end
        end
    end
    // Reused functional decoders expose architectural selectors unused here.
    wire unused = &{1'b0, context_active, segment_override, lock_prefix, segment_index,
                    repeat_kind, destination, source_index, mode, rm_index, register_direct,
                    push_enabled, push_return_ip, branch_taken, decrement_count, adjust_kind,
                    muldiv_kind, decoded_segment, string_byte, string_compare, child_shape[5],
                    entry[spk286_microcode_pkg::MC_ADDR_WIDTH-1:7],
                    dispatch_entry[spk286_microcode_pkg::MC_ADDR_WIDTH-1:7]};
endmodule
`endif
