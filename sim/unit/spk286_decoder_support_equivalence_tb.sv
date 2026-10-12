// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module spk286_decoder_support_equivalence_tb;
    logic [7:0] opcode;
    logic extended_opcode;
    wire new_supported, old_supported, new_invalid, old_invalid;
    wire [2:0] new_destination, old_destination, new_source, old_source;
    wire [spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] new_entry, old_entry;
    spk286_decoder candidate (.opcode(opcode), .extended_opcode(extended_opcode),
        .supported(new_supported), .invalid_opcode(new_invalid),
        .destination(new_destination), .source_index(new_source), .entry(new_entry));
    spk286_decoder_reference reference_decoder (.opcode(opcode), .extended_opcode(extended_opcode),
        .supported(old_supported), .invalid_opcode(old_invalid),
        .destination(old_destination), .source_index(old_source), .entry(old_entry));
    integer supported_normal = 0;
    integer supported_extended = 0;
    initial begin
        for (int map = 0; map < 2; map++) begin
            extended_opcode = 1'(map);
            for (int byte_value = 0; byte_value < 256; byte_value++) begin
                opcode = 8'(byte_value);
                #1;
                if ({new_supported, new_invalid, new_destination, new_source, new_entry} !==
                    {old_supported, old_invalid, old_destination, old_source, old_entry})
                    $fatal(1, "Decoder metadata mismatch map=%0d opcode=%h", map, opcode);
                if (new_supported) begin
                    if (extended_opcode) supported_extended++;
                    else supported_normal++;
                end
            end
        end
        if (supported_normal != 242 || supported_extended != 6)
            $fatal(1, "Unexpected support census normal=%0d extended=%0d", supported_normal, supported_extended);
        $display("DECODER_SUPPORT_EQUIVALENCE PASS: 512 complete metadata checks, normal=242 extended=6");
        $finish;
    end
endmodule
