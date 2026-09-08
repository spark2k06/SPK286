// Minimal instruction-form decoder. Destination metadata is independent of ROM.
`timescale 1ns/1ps

module spk286_decoder (
    input  logic [7:0] opcode,
    output logic supported,
    output logic [2:0] destination,
    output logic [spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] entry
);
    assign supported = opcode[7:3] == 5'b10111 || opcode == 8'h89 || opcode == 8'h8B;
    assign destination = opcode[2:0];
    // Instruction direction is expressed by the generated entry, not the sequencer.
    assign entry = opcode == 8'h89 ? spk286_microcode_pkg::MC_ENTRY_MOV_RM16_R16 :
                   (opcode == 8'h8B ? spk286_microcode_pkg::MC_ENTRY_MOV_R16_RM16 :
                    spk286_microcode_pkg::MC_ENTRY_MOV_R16_IMM16);
endmodule
