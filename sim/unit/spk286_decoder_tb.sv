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
            if (supported !== (i >= 184 && i <= 191)) $fatal(1, "opcode support %h", opcode);
            if (supported && (destination !== 3'(i - 184) ||
                entry !== spk286_microcode_pkg::MC_ENTRY_MOV_R16_IMM16))
                $fatal(1, "MOV decoder metadata %h", opcode);
            checks = checks + 1;
        end
        $display("DECODER PASS: %0d opcode checks; one shared MOV entry", checks);
        $finish;
    end
endmodule
