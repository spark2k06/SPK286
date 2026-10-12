// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module spk286_shift_tb;
    logic clk = 0, reset = 1, cancel = 0, enable = 1;
    logic request_valid = 0, response_ready = 0, operand_byte, carry_in;
    logic [2:0] kind;
    logic [15:0] operand;
    logic [7:0] count;
    wire request_ready, response_valid, result_write;
    wire [15:0] result, candidate_flags, flags_mask;
    integer file_handle, fields, word_value, total, cases = 0, checks = 0;
    integer expected_value, expected_flags, expected_mask, expected_write, expected_steps, steps;
    string path;
    spk286_shift dut (.*);
    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1) $fatal(1, "%s case=%0d result=%h expected=%h flags=%h mask=%h", message, cases, result, expected_value, candidate_flags, flags_mask);
    endtask
    task automatic tick;
        #1; clk = 1; #1; clk = 0; #1;
    endtask
    task automatic scan;
        fields = $fscanf(file_handle, "%h", word_value);
        if (fields != 1) $fatal(1,"malformed shift vector");
    endtask
    initial begin
        if (!$value$plusargs("shift_vectors=%s",path)) $fatal(1,"missing shift vectors");
        file_handle = $fopen(path,"r");
        if (file_handle == 0) $fatal(1,"cannot open shift vectors");
        tick(); reset = 0; scan(); total = word_value;
        for (integer i = 0; i < total; i = i + 1) begin
            scan(); kind = 3'(word_value); scan(); operand_byte = word_value == 8;
            scan(); operand = 16'(word_value); scan(); count = 8'(word_value);
            expected_steps = int'(count[4:0]); scan(); carry_in = word_value != 0;
            scan(); expected_value = word_value; scan(); expected_flags = word_value;
            scan(); expected_mask = word_value; scan(); expected_write = word_value;
            #1; check(request_ready && !response_valid,"idle request ownership");
            request_valid = 1; tick(); request_valid = 0;
            // Inputs are free to change after acceptance; pending arithmetic owns its snapshot.
            operand = ~operand; kind = ~kind; count = ~count; carry_in = ~carry_in; operand_byte = !operand_byte;
            if (i % 1021 == 0) begin
                enable = 0;
                repeat (3) begin tick(); check(response_valid == (expected_steps == 0),"pause preserves arithmetic progress"); end
                enable = 1;
            end
            steps = 0;
            while (!response_valid && steps < 33) begin
                check(!request_ready,"busy shift has one owner");
                tick(); steps = steps + 1;
            end
            check(response_valid && steps == expected_steps,"masked count drives real arithmetic work");
            check(result == 16'(expected_value),"independent shift result");
            check(flags_mask == 16'(expected_mask),"defined and selected physical flag policy");
            check(((candidate_flags ^ 16'(expected_flags)) & flags_mask) == 0,"independent shift flags");
            check(result_write == (expected_write != 0),"zero count suppresses write disposition");
            if (i % 1021 == 0) begin
                repeat (3) begin
                    tick(); check(response_valid && !request_ready && result == 16'(expected_value),"response waits without replay");
                end
            end
            response_ready = 1; tick(); response_ready = 0;
            check(!response_valid && request_ready,"single response consumption");
            cases = cases + 1;
        end
        $fclose(file_handle);
        check(cases == 154112,"complete independent shift vector set");
        for (integer stop = 0; stop < 2; stop = stop + 1) begin
            operand = 16'hf013; count = 31; kind = 2; carry_in = 1; operand_byte = 0;
            request_valid = 1; tick(); request_valid = 0; repeat (4) tick();
            if (stop == 0) cancel = 1; else reset = 1;
            tick(); cancel = 0; reset = 0;
            repeat (35) begin tick(); check(!response_valid && request_ready,"cancel/reset prevents stale arithmetic response"); end
        end
        $display("SHIFT PASS: %0d independent vectors; %0d checks; pause, backpressure, cancellation and reset",cases,checks);
        $finish;
    end
endmodule
