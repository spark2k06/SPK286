// Minimal instruction-form decoder. Destination metadata is independent of ROM.
`timescale 1ns/1ps

module spk286_decoder (
    input  logic [7:0] opcode,
    output logic supported,
    output logic [2:0] destination,
    output logic [spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] entry
);
    logic binary_word;
    assign binary_word = opcode[7:6] == 2'b00 &&
                         (opcode[2:0] == 3'd1 || opcode[2:0] == 3'd3 || opcode[2:0] == 3'd5);
    assign supported = opcode[7:3] == 5'b10111 || opcode == 8'h89 || opcode == 8'h8B ||
                       binary_word || opcode == 8'h81 || opcode == 8'h83;
    assign destination = binary_word ? 3'd0 : opcode[2:0];
    // Instruction direction is expressed by the generated entry, not the sequencer.
    assign entry = opcode == 8'h81 ? spk286_microcode_pkg::MC_ENTRY_ALU_RM16_IMM16 :
                   opcode == 8'h83 ? spk286_microcode_pkg::MC_ENTRY_ALU_RM16_IMM8S :
                   binary_word ? (opcode[2:0] == 3'd1 ? spk286_microcode_pkg::MC_ENTRY_ALU_RM16_R16 :
                                  opcode[2:0] == 3'd3 ? spk286_microcode_pkg::MC_ENTRY_ALU_R16_RM16 :
                                                       spk286_microcode_pkg::MC_ENTRY_ALU_AX_IMM16) :
                   opcode == 8'h89 ? spk286_microcode_pkg::MC_ENTRY_MOV_RM16_R16 :
                   (opcode == 8'h8B ? spk286_microcode_pkg::MC_ENTRY_MOV_R16_RM16 :
                    spk286_microcode_pkg::MC_ENTRY_MOV_R16_IMM16);
endmodule
