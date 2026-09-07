// Minimal instruction-form decoder. Destination metadata is independent of ROM.
`timescale 1ns/1ps

module spk286_decoder (
    input  logic [7:0] opcode,
    output logic supported,
    output logic [2:0] destination,
    output logic [spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] entry
);
    assign supported = opcode[7:3] == 5'b10111;
    assign destination = opcode[2:0];
    // Valid only with supported. All eight encodings share this instruction form.
    assign entry = spk286_microcode_pkg::MC_ENTRY_MOV_R16_IMM16;
endmodule
