`timescale 1ns/1ps

module spk286_microcode_rom_tb;
    localparam integer W = spk286_microcode_pkg::MC_ADDR_WIDTH;
    localparam logic [W-1:0] MOV_ENTRY = spk286_microcode_pkg::MC_ENTRY_MOV_R16_IMM16;
    logic [W-1:0] address;
    wire [spk286_microcode_pkg::MC_WORD_WIDTH-1:0] word;
    wire valid;
    integer checks = 0;
    spk286_microcode_rom dut (.*);
    task automatic check_word(input logic [W-1:0] pc,
                              input logic [spk286_microcode_pkg::MC_WORD_WIDTH-1:0] expected);
        address = pc; #1;
        if (!valid || word !== expected) $fatal(1, "ROM pc=%h word=%h expected=%h", pc, word, expected);
        checks = checks + 1;
    endtask
    initial begin
        if (int'(MOV_ENTRY) + 2 >= spk286_microcode_pkg::MC_DEPTH) $fatal(1, "MOV entry out of range");
        check_word(MOV_ENTRY, spk286_microcode_pkg::MC_FETCH_IMM16);
        check_word(MOV_ENTRY + W'(1), spk286_microcode_pkg::MC_MOVE);
        check_word(MOV_ENTRY + W'(2), spk286_microcode_pkg::MC_END);
        check_word(spk286_microcode_pkg::MC_ENTRY_MOV_RM16_R16, spk286_microcode_pkg::MC_DECODE_MODRM);
        check_word(spk286_microcode_pkg::MC_ENTRY_MOV_RM16_R16 + W'(1), spk286_microcode_pkg::MC_READ_REG16);
        check_word(spk286_microcode_pkg::MC_ENTRY_MOV_RM16_R16 + W'(2), spk286_microcode_pkg::MC_WRITE_RM16);
        check_word(spk286_microcode_pkg::MC_ENTRY_MOV_RM16_R16 + W'(3), spk286_microcode_pkg::MC_END);
        check_word(spk286_microcode_pkg::MC_ENTRY_MOV_R16_RM16, spk286_microcode_pkg::MC_DECODE_MODRM);
        check_word(spk286_microcode_pkg::MC_ENTRY_MOV_R16_RM16 + W'(1), spk286_microcode_pkg::MC_READ_RM16);
        check_word(spk286_microcode_pkg::MC_ENTRY_MOV_R16_RM16 + W'(2), spk286_microcode_pkg::MC_WRITE_REG16);
        check_word(spk286_microcode_pkg::MC_ENTRY_MOV_R16_RM16 + W'(3), spk286_microcode_pkg::MC_END);
        for (integer i = spk286_microcode_pkg::MC_DEPTH; i < (1 << W); i = i + 1) begin
            address = W'(i); #1;
            if (valid || word !== spk286_microcode_pkg::MC_INVALID) $fatal(1, "unused ROM address is executable");
            checks = checks + 1;
        end
        $display("MICROCODE_ROM PASS: %0d semantic/range checks", checks);
        $finish;
    end
endmodule
