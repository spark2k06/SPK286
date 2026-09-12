// Captured instruction metadata -> functional stack/control selectors.
`timescale 1ns/1ps
module spk286_control_decode (
    input logic [7:0] opcode,
    input logic extended_opcode,
    input logic [2:0] group_extension,
    input logic condition_taken, zero,
    input logic [15:0] count,
    output logic push_enabled, push_return_ip, branch_taken, decrement_count, form_supported,
    output logic [spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] dispatch_entry,
    output logic [2:0] adjust_kind,
    output logic [1:0] muldiv_kind,
    output logic [1:0] segment_index,
    output logic string_byte, string_compare,
    output logic dispatch_valid
);
    assign muldiv_kind = group_extension[1:0];
    assign string_byte = !opcode[0];
    assign string_compare = opcode[7:1] == 7'b1010011 || opcode[7:1] == 7'b1010111;
    assign segment_index = opcode == 8'hC5 ? 2'd3 : opcode == 8'hC4 ? 2'd0 : opcode == 8'h9A || (opcode == 8'hFF && group_extension == 3'd3) ? 2'd1 : opcode == 8'h8C || opcode == 8'h8E ? group_extension[1:0] : opcode[4:3];
    assign adjust_kind = opcode == 8'h2F ? 3'd1 : opcode == 8'h37 ? 3'd2 : opcode == 8'h3F ? 3'd3 : opcode == 8'hD4 ? 3'd4 : opcode == 8'hD5 ? 3'd5 : 3'd0;
    assign form_supported = extended_opcode && opcode == 8'h00 ? (group_extension <= 3'd5) :
                            extended_opcode && opcode == 8'h01 ? (group_extension <= 3 || group_extension == 3'd4 || group_extension == 3'd6) :
                            extended_opcode && (opcode == 8'h02 || opcode == 8'h03 || opcode == 8'h06) ? 1'b1 :
                            opcode == 8'h8C ? group_extension < 4 :
                            opcode == 8'h8E ? group_extension < 4 && group_extension != 1 : opcode == 8'hC0 || opcode == 8'hC1 || opcode[7:2] == 6'b110100 ? group_extension != 3'd6 :
                            opcode == 8'hFE ? group_extension < 2 :
                            opcode == 8'hF6 || opcode == 8'hF7 ? group_extension != 1 :
                            opcode == 8'hFF ? group_extension != 3'd7 :
                            opcode != 8'h8F || group_extension == 3'd0;
    always_comb begin
        dispatch_valid = 1'b1;
        dispatch_entry = '0;
        if (extended_opcode && opcode == 8'h00) begin
            case (group_extension)
                3'd0: dispatch_entry = spk286_microcode_pkg::MC_ENTRY_SYSTEM_STORE_LDTR;
                3'd1: dispatch_entry = spk286_microcode_pkg::MC_ENTRY_SYSTEM_STORE_TR;
                3'd2: dispatch_entry = spk286_microcode_pkg::MC_ENTRY_SYSTEM_LOAD_LDTR;
                3'd3: dispatch_entry = spk286_microcode_pkg::MC_ENTRY_SYSTEM_LOAD_TR;
                3'd4: dispatch_entry = spk286_microcode_pkg::MC_ENTRY_SYSTEM_VERIFY_READ;
                3'd5: dispatch_entry = spk286_microcode_pkg::MC_ENTRY_SYSTEM_VERIFY_WRITE;
                default: dispatch_valid = 1'b0;
            endcase
        end else if (extended_opcode && opcode == 8'h01) begin
            case (group_extension)
                3'd0: dispatch_entry = spk286_microcode_pkg::MC_ENTRY_SYSTEM_STORE_GDTR;
                3'd1: dispatch_entry = spk286_microcode_pkg::MC_ENTRY_SYSTEM_STORE_IDTR;
                3'd2: dispatch_entry = spk286_microcode_pkg::MC_ENTRY_SYSTEM_LOAD_GDTR;
                3'd3: dispatch_entry = spk286_microcode_pkg::MC_ENTRY_SYSTEM_LOAD_IDTR;
                3'd4: dispatch_entry = spk286_microcode_pkg::MC_ENTRY_SYSTEM_STORE_MSW;
                3'd6: dispatch_entry = spk286_microcode_pkg::MC_ENTRY_SYSTEM_LOAD_MSW;
                default: dispatch_valid = 1'b0;
            endcase
        end else if (extended_opcode && opcode == 8'h02) begin
            dispatch_entry = spk286_microcode_pkg::MC_ENTRY_SYSTEM_LOAD_ACCESS;
        end else if (extended_opcode && opcode == 8'h03) begin
            dispatch_entry = spk286_microcode_pkg::MC_ENTRY_SYSTEM_LOAD_LIMIT;
        end else if (opcode == 8'hF6 || opcode == 8'hF7) begin
            case (group_extension)
                3'd0: dispatch_entry = opcode[0] ? spk286_microcode_pkg::MC_ENTRY_ALU_RM16_IMM16 : spk286_microcode_pkg::MC_ENTRY_ALU_RM8_IMM8;
                3'd2: dispatch_entry = opcode[0] ? spk286_microcode_pkg::MC_ENTRY_NOT_RM16 : spk286_microcode_pkg::MC_ENTRY_NOT_RM8;
                3'd3: dispatch_entry = opcode[0] ? spk286_microcode_pkg::MC_ENTRY_NEG_RM16 : spk286_microcode_pkg::MC_ENTRY_NEG_RM8;
                3'd4, 3'd5, 3'd6, 3'd7: dispatch_entry = opcode[0] ? spk286_microcode_pkg::MC_ENTRY_MULDIV_RM16 : spk286_microcode_pkg::MC_ENTRY_MULDIV_RM8;
                default: dispatch_valid = 1'b0;
            endcase
        end else if (opcode == 8'hFF) begin
            case (group_extension)
                3'd0, 3'd1: dispatch_entry = spk286_microcode_pkg::MC_ENTRY_INC_DEC_RM16;
                3'd2, 3'd4, 3'd6: dispatch_entry = spk286_microcode_pkg::MC_ENTRY_GROUP5_NEAR;
                3'd3: dispatch_entry = spk286_microcode_pkg::MC_ENTRY_CALL_FAR_RM;
                3'd5: dispatch_entry = spk286_microcode_pkg::MC_ENTRY_JMP_FAR_RM;
                default: dispatch_valid = 1'b0;
            endcase
        end else dispatch_valid = 1'b0;
    end
    assign push_return_ip = opcode == 8'hFF && group_extension == 3'd2;
    assign push_enabled = opcode != 8'hFF || group_extension != 3'd4;
    assign decrement_count = opcode == 8'hE0 || opcode == 8'hE1 || opcode == 8'hE2;
    always_comb begin
        branch_taken = 1'b0;
        case (opcode)
            8'hE8, 8'hE9, 8'hEB, 8'hC2, 8'hC3: branch_taken = 1'b1;
            8'hFF: branch_taken = group_extension == 3'd2 || group_extension == 3'd4;
            8'hE0: branch_taken = count != 0 && !zero;
            8'hE1: branch_taken = count != 0 && zero;
            8'hE2: branch_taken = count != 0;
            8'hE3: branch_taken = count == 0;
            default: if (opcode[7:4] == 4'h7) branch_taken = condition_taken;
        endcase
    end
endmodule
