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
            if (supported !== ((i >= 184 && i <= 191) || i == 137 || i == 139)) $fatal(1, "opcode support %h", opcode);
            if (i >= 184 && i <= 191 && (destination !== 3'(i - 184) ||
                entry !== spk286_microcode_pkg::MC_ENTRY_MOV_R16_IMM16))
                $fatal(1, "MOV decoder metadata %h", opcode);
            if (i == 137 && entry !== spk286_microcode_pkg::MC_ENTRY_MOV_RM16_R16)
                $fatal(1, "MOV RM destination entry");
            if (i == 139 && entry !== spk286_microcode_pkg::MC_ENTRY_MOV_R16_RM16)
                $fatal(1, "MOV REG destination entry");
            checks = checks + 1;
        end
        $display("DECODER PASS: %0d opcode checks; three MOV forms", checks);
        $finish;
    end
endmodule
