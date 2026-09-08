`timescale 1ns/1ps
module spk286_modrm_tb;
    logic [7:0] encoded;
    wire [1:0] mode, displacement_bytes;
    wire [2:0] reg_index, rm_index;
    wire register_direct;
    integer expected_bytes, checks = 0;
    spk286_modrm dut (.*);
    initial begin
        for (integer m = 0; m < 4; m = m + 1)
            for (integer r = 0; r < 8; r = r + 1)
                for (integer rm = 0; rm < 8; rm = rm + 1) begin
                    encoded = 8'(m*64 + r*8 + rm); #1;
                    case (m)
                        0: expected_bytes = rm == 6 ? 2 : 0;
                        1: expected_bytes = 1;
                        2: expected_bytes = 2;
                        3: expected_bytes = 0;
                        default: $fatal(1, "test mode");
                    endcase
                    if (mode !== 2'(m) || reg_index !== 3'(r) || rm_index !== 3'(rm) ||
                        register_direct !== (m == 3) || displacement_bytes !== 2'(expected_bytes))
                        $fatal(1, "ModR/M %h metadata", encoded);
                    checks = checks + 1;
                end
        $display("MODRM PASS: %0d exhaustive encodings", checks);
        $finish;
    end
endmodule
