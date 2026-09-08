`timescale 1ns/1ps
module spk286_effective_address_tb;
    logic [1:0] mode;
    logic [2:0] rm_index;
    logic [15:0] displacement, bx, bp, si, di;
    wire [15:0] offset;
    wire [1:0] segment_index;
    wire memory_operand;
    integer bases [0:7];
    integer expected, checks = 0;
    logic stack_default;
    spk286_effective_address dut (.*);
    initial begin
        // Independent integer arithmetic/table, distinct inputs, boundary carries.
        for (integer pattern = 0; pattern < 3; pattern = pattern + 1) begin
            bx = pattern == 0 ? 16'h0123 : (pattern == 1 ? 16'hFFFD : 16'h0000);
            bp = pattern == 0 ? 16'h2345 : (pattern == 1 ? 16'h8001 : 16'hFFFF);
            si = pattern == 0 ? 16'h4567 : (pattern == 1 ? 16'hFFFF : 16'h0001);
            di = pattern == 0 ? 16'h6789 : (pattern == 1 ? 16'h7FFF : 16'h8000);
            bases[0] = int'(bx) + int'(si); bases[1] = int'(bx) + int'(di);
            bases[2] = int'(bp) + int'(si); bases[3] = int'(bp) + int'(di);
            bases[4] = int'(si); bases[5] = int'(di); bases[6] = int'(bp); bases[7] = int'(bx);
            for (integer m = 0; m < 4; m = m + 1)
                for (integer rm = 0; rm < 8; rm = rm + 1)
                    // All disp8 representations plus specified disp16 boundaries.
                    for (integer d = 0; d < 261; d = d + 1) begin
                        mode = 2'(m); rm_index = 3'(rm);
                        if (d < 256) displacement = 16'(d < 128 ? d : d - 256);
                        else case (d)
                            256: displacement = 16'h0000;
                            257: displacement = 16'h0001;
                            258: displacement = 16'h7FFF;
                            259: displacement = 16'h8000;
                            260: displacement = 16'hFFFF;
                            default: $fatal(1, "test displacement");
                        endcase
                        if (m == 0 && rm != 6) displacement = 0;
                        expected = (m == 0 && rm == 6 ? 0 : bases[rm]) + int'(displacement);
                        if (m == 3) expected = 0;
                        stack_default = rm == 2 || rm == 3 || (rm == 6 && m != 0);
                        #1;
                        if (offset !== 16'(expected) || memory_operand !== (m != 3) ||
                            segment_index !== (stack_default ? 2'd2 : 2'd3))
                            $fatal(1, "EA mode=%d rm=%d disp=%h got=%h expected=%h segment=%d",
                                   m, rm, displacement, offset, 16'(expected), segment_index);
                        checks = checks + 1;
                    end
        end
        $display("EFFECTIVE_ADDRESS PASS: %0d address/segment checks", checks);
        $finish;
    end
endmodule
