// Real Mode PUSHA/POPA preflight. Even words may wrap between transfers;
// a word beginning at FFFF is illegal. ENTER checks each actual transfer.
`timescale 1ns/1ps
module spk286_stack_range (
    input logic [15:0] sp,
    output logic push8_invalid, pop8_invalid
);
    assign push8_invalid = sp[0] && sp < 16'd16;
    assign pop8_invalid = sp[0] && sp >= 16'hFFF1;
endmodule
