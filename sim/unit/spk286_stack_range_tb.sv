// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module spk286_stack_range_tb;
    logic [15:0] sp;
    wire push8_invalid, pop8_invalid;
    integer checks = 0;
    logic expected_push, expected_pop;
    spk286_stack_range dut (.*);
    task automatic verify;
        expected_push = 0; expected_pop = 0;
        for (integer n=1;n<=8;n++) begin
            if (16'(int'(sp)-2*n)==16'hFFFF) expected_push=1;
            if (16'(int'(sp)+2*(n-1))==16'hFFFF) expected_pop=1;
        end
        #1;
        if ({push8_invalid,pop8_invalid} !== {expected_push,expected_pop})
            $fatal(1,"modular word preflight sp=%h",sp);
        checks++;
    endtask
    initial begin
        for (integer offset=0;offset<65536;offset++) begin
            sp=16'(offset);verify();
        end
        $display("STACK_RANGE PASS: %0d independently enumerated modular word checks",checks);
        $finish;
    end
endmodule
