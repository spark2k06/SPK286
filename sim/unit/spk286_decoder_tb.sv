`timescale 1ns/1ps

module spk286_decoder_tb;
    logic [7:0] opcode;
    wire supported;
    wire [2:0] destination, source_index;
    wire [spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] entry;
    integer checks = 0;
    spk286_decoder dut (.*);
    initial begin
        for (integer i = 0; i < 256; i = i + 1) begin
            opcode = 8'(i); #1;
            if (supported !== (i == 39 || i == 47 || i == 55 || i == 63 || i == 212 || i == 213 || i == 254 || i == 134 || i == 135 || i == 141 || (i >= 144 && i <= 151) || (i >= 160 && i <= 163) || i == 215 || i == 192 || i == 193 || (i >= 208 && i <= 211) || (i >= 64 && i < 80) || i == 152 || i == 153 || i == 158 || i == 159 || i == 245 || i == 248 || i == 249 || i == 252 || i == 253 || i == 132 || i == 133 || i == 168 || i == 169 || i == 246 || i == 247 || i == 156 || i == 157 || (i >= 204 && i <= 207) || i == 244 || i == 250 || i == 251 ||
                              (i >= 80 && i <= 95) || (i >= 112 && i <= 127) || i == 104 || i == 106 || i == 143 || i == 255 ||
                              i == 194 || i == 195 || (i >= 224 && i <= 227) || i == 232 || i == 233 || i == 235 ||
                              (i >= 176 && i <= 191) || i == 136 || i == 138 || i == 198 || i == 199 || i == 128 || i == 137 || i == 139 || i == 129 || i == 131 ||
                              (i < 64 && (i % 8 <= 5)))) $fatal(1, "opcode support %h", opcode);
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
            if (i >= 176 && i <= 183 && (destination !== 3'(i-176) || entry !== spk286_microcode_pkg::MC_ENTRY_MOV_R8_IMM8))
                $fatal(1,"byte MOV destination");
            if (i==136 && entry !== spk286_microcode_pkg::MC_ENTRY_MOV_RM8_R8) $fatal(1,"byte MOV r/m entry");
            if (i==138 && entry !== spk286_microcode_pkg::MC_ENTRY_MOV_R8_RM8) $fatal(1,"byte MOV register entry");
            if (i==198 && entry !== spk286_microcode_pkg::MC_ENTRY_MOV_RM8_IMM8) $fatal(1,"byte immediate MOV entry");
            if (i==199 && entry !== spk286_microcode_pkg::MC_ENTRY_MOV_RM16_IMM16) $fatal(1,"word immediate MOV entry");
            if (i==128 && entry !== spk286_microcode_pkg::MC_ENTRY_ALU_RM8_IMM8) $fatal(1,"byte ALU immediate entry");
            if (i<64 && i%8==0 && entry !== spk286_microcode_pkg::MC_ENTRY_ALU_RM8_R8) $fatal(1,"byte ALU r/m entry");
            if (i<64 && i%8==2 && entry !== spk286_microcode_pkg::MC_ENTRY_ALU_R8_RM8) $fatal(1,"byte ALU register entry");
            if (i<64 && i%8==4 && (entry !== spk286_microcode_pkg::MC_ENTRY_ALU_AL_IMM8 || destination != 0)) $fatal(1,"byte ALU accumulator entry");
            if ((i == 246 || i == 247) && entry !== spk286_microcode_pkg::MC_ENTRY_GROUP3_DISPATCH) $fatal(1,"group3 dispatch entry");
            if (i == 255 && entry !== spk286_microcode_pkg::MC_ENTRY_GROUP5_DISPATCH) $fatal(1,"group5 dispatch entry");
            if (i == 254 && entry !== spk286_microcode_pkg::MC_ENTRY_INC_DEC_RM8) $fatal(1,"byte unary entry");
            if ((i==39 || i==47 || i==55 || i==63 || i==212 || i==213) && (destination!=0 || source_index!=0 ||
                entry!=(i>=212?spk286_microcode_pkg::MC_ENTRY_ADJUST_RADIX:spk286_microcode_pkg::MC_ENTRY_ADJUST_DIRECT)))
                $fatal(1,"adjust source/destination/entry metadata");
            checks = checks + 1;
        end
        $display("DECODER PASS: %0d opcode checks; MOV and word ALU forms", checks);
        $finish;
    end
endmodule
