// Minimal instruction-form decoder. Destination metadata is independent of ROM.
`timescale 1ns/1ps

module spk286_decoder (
    input  logic [7:0] opcode,
    output logic supported,
    output logic [2:0] destination,
    output logic [spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] entry
);
    logic binary_word, stack_control;
    assign stack_control = opcode[7:4] == 4'h5 || opcode[7:4] == 4'h7 ||
                           opcode == 8'h68 || opcode == 8'h6A || opcode == 8'h8F || opcode == 8'hFF ||
                           opcode == 8'hC2 || opcode == 8'hC3 || opcode[7:2] == 6'b111000 ||
                           opcode == 8'hE8 || opcode == 8'hE9 || opcode == 8'hEB;
    assign binary_word = opcode[7:6] == 2'b00 &&
                         (opcode[2:0] == 3'd1 || opcode[2:0] == 3'd3 || opcode[2:0] == 3'd5);
    assign supported = stack_control || opcode[7:3] == 5'b10111 || opcode == 8'h89 || opcode == 8'h8B ||
                       binary_word || opcode == 8'h81 || opcode == 8'h83;
    assign destination = binary_word ? 3'd0 : opcode[2:0];
    // Instruction direction is expressed by the generated entry, not the sequencer.
    assign entry = opcode[7:3] == 5'b01010 ? spk286_microcode_pkg::MC_ENTRY_PUSH_R16 :
                   opcode[7:3] == 5'b01011 ? spk286_microcode_pkg::MC_ENTRY_POP_R16 :
                   opcode == 8'h68 ? spk286_microcode_pkg::MC_ENTRY_PUSH_IMM16 :
                   opcode == 8'h6A ? spk286_microcode_pkg::MC_ENTRY_PUSH_IMM8S :
                   opcode == 8'h8F ? spk286_microcode_pkg::MC_ENTRY_POP_RM16 :
                   opcode == 8'hFF ? spk286_microcode_pkg::MC_ENTRY_GROUP5_NEAR :
                   opcode == 8'hE8 ? spk286_microcode_pkg::MC_ENTRY_CALL_REL16 :
                   opcode == 8'hE9 ? spk286_microcode_pkg::MC_ENTRY_JMP_REL16 :
                   opcode == 8'hEB || opcode[7:4] == 4'h7 ? spk286_microcode_pkg::MC_ENTRY_BRANCH_REL8 :
                   opcode[7:2] == 6'b111000 ? spk286_microcode_pkg::MC_ENTRY_LOOP_REL8 :
                   opcode == 8'hC2 ? spk286_microcode_pkg::MC_ENTRY_RET_IMM16 :
                   opcode == 8'hC3 ? spk286_microcode_pkg::MC_ENTRY_RET_NEAR :
                   opcode == 8'h81 ? spk286_microcode_pkg::MC_ENTRY_ALU_RM16_IMM16 :
                   opcode == 8'h83 ? spk286_microcode_pkg::MC_ENTRY_ALU_RM16_IMM8S :
                   binary_word ? (opcode[2:0] == 3'd1 ? spk286_microcode_pkg::MC_ENTRY_ALU_RM16_R16 :
                                  opcode[2:0] == 3'd3 ? spk286_microcode_pkg::MC_ENTRY_ALU_R16_RM16 :
                                                       spk286_microcode_pkg::MC_ENTRY_ALU_AX_IMM16) :
                   opcode == 8'h89 ? spk286_microcode_pkg::MC_ENTRY_MOV_RM16_R16 :
                   (opcode == 8'h8B ? spk286_microcode_pkg::MC_ENTRY_MOV_R16_RM16 :
                    spk286_microcode_pkg::MC_ENTRY_MOV_R16_IMM16);
endmodule
