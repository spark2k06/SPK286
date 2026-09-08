`timescale 1ns/1ps

module spk286_decoder_tb;
    logic [7:0] opcode;
    wire supported;
    wire [2:0] destination;
    wire [spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] entry;
    integer checks = 0;
    spk286_decoder dut (.*);
    initial begin
        for (integer i = 0; i < 256; i = i + 1) begin
            opcode = 8'(i); #1;
            if (supported !== ((i >= 184 && i <= 191) || i == 137 || i == 139 || i == 129 || i == 131 ||
                              (i < 64 && (i % 8 == 1 || i % 8 == 3 || i % 8 == 5)))) $fatal(1, "opcode support %h", opcode);
            if (i >= 184 && i <= 191 && (destination !== 3'(i - 184) ||
                entry !== spk286_microcode_pkg::MC_ENTRY_MOV_R16_IMM16))
                $fatal(1, "MOV decoder metadata %h", opcode);
            if (i == 137 && entry !== spk286_microcode_pkg::MC_ENTRY_MOV_RM16_R16)
                $fatal(1, "MOV RM destination entry");
            if (i == 139 && entry !== spk286_microcode_pkg::MC_ENTRY_MOV_R16_RM16)
                $fatal(1, "MOV REG destination entry");
            if (i < 64 && i % 8 == 1 && entry !== spk286_microcode_pkg::MC_ENTRY_ALU_RM16_R16)
                $fatal(1, "ALU RM destination entry");
            if (i < 64 && i % 8 == 3 && entry !== spk286_microcode_pkg::MC_ENTRY_ALU_R16_RM16)
                $fatal(1, "ALU REG destination entry");
            if (i < 64 && i % 8 == 5 && (entry !== spk286_microcode_pkg::MC_ENTRY_ALU_AX_IMM16 || destination != 0))
                $fatal(1, "ALU accumulator entry");
            if (i == 129 && entry !== spk286_microcode_pkg::MC_ENTRY_ALU_RM16_IMM16)
                $fatal(1, "ALU immediate word entry");
            if (i == 131 && entry !== spk286_microcode_pkg::MC_ENTRY_ALU_RM16_IMM8S)
                $fatal(1, "ALU sign extended immediate entry");
            checks = checks + 1;
        end
        $display("DECODER PASS: %0d opcode checks; MOV and word ALU forms", checks);
        $finish;
    end
endmodule
