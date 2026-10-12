// SPDX-License-Identifier: MIT
// Stack address and SP commit service. Physical transfers belong to the operand/BIU.
`timescale 1ns/1ps
module spk286_stack (
    input logic request, push, adjust, operand_done,
    input logic [15:0] sp, adjustment,
    output logic [15:0] offset, next_sp,
    output logic write_sp
);
    assign offset = push ? sp - 16'd2 : sp;
    assign next_sp = sp + (adjust ? adjustment : (push ? 16'hFFFE : 16'd2));
    assign write_sp = adjust || (request && operand_done);
endmodule
