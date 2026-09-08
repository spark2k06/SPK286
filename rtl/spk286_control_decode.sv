// Captured instruction metadata -> functional stack/control selectors.
`timescale 1ns/1ps
module spk286_control_decode (
    input logic [7:0] opcode,
    input logic [2:0] group_extension,
    input logic condition_taken, zero,
    input logic [15:0] count,
    output logic push_enabled, push_return_ip, branch_taken, decrement_count, form_supported
);
    assign form_supported = opcode == 8'hC0 || opcode == 8'hC1 || opcode[7:2] == 6'b110100 ? group_extension != 3'd6 :
                            opcode == 8'hF6 || opcode == 8'hF7 ? group_extension == 3'd0 :
                            opcode == 8'hFF ? (group_extension == 3'd2 || group_extension == 3'd4 || group_extension == 3'd6) :
                            opcode != 8'h8F || group_extension == 3'd0;
    assign push_return_ip = opcode == 8'hFF && group_extension == 3'd2;
    assign push_enabled = opcode != 8'hFF || group_extension != 3'd4;
    assign decrement_count = opcode == 8'hE0 || opcode == 8'hE1 || opcode == 8'hE2;
    always_comb begin
        branch_taken = 1'b0;
        case (opcode)
            8'hE8, 8'hE9, 8'hEB, 8'hC2, 8'hC3: branch_taken = 1'b1;
            8'hFF: branch_taken = group_extension == 3'd2 || group_extension == 3'd4;
            8'hE0: branch_taken = count != 0 && !zero;
            8'hE1: branch_taken = count != 0 && zero;
            8'hE2: branch_taken = count != 0;
            8'hE3: branch_taken = count == 0;
            default: if (opcode[7:4] == 4'h7) branch_taken = condition_taken;
        endcase
    end
endmodule
