// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module spk286_muldiv_tb;
    logic clk=0,reset=1,cancel=0,enable=1,request_valid=0,response_ready=0;
    logic [1:0] kind=0;
    logic operand_byte=0;
    logic [31:0] dividend=0;
    logic [15:0] source=0;
    wire request_ready,response_valid,result_write,arithmetic_fault;
    wire [15:0] result_low,result_high,candidate_flags,flags_mask;
    logic [15:0] expected_low,expected_high,expected_flags,expected_mask;
    logic expected_write,expected_fault;
    integer file_handle,fields,total,word_value,cycles,checks=0,cases=0;
    string path;
    spk286_muldiv dut(.*);
    task automatic check(input logic condition,input string message);
        checks++;
        if(condition!==1'b1) $fatal(1,"%s case=%d result=%h/%h expected=%h/%h flags=%h/%h mask=%h/%h fault=%b/%b",message,cases,result_low,result_high,expected_low,expected_high,candidate_flags,expected_flags,flags_mask,expected_mask,arithmetic_fault,expected_fault);
    endtask
    task automatic tick; #5;clk=1;#5;clk=0;#1; endtask
    task automatic scan; fields=$fscanf(file_handle,"%h",word_value);if(fields!=1)$fatal(1,"malformed integer vector");endtask
    task automatic compare;
        check(response_valid && (!expected_write || (result_low==expected_low && result_high==expected_high)),"exact integer result and response");
        check(flags_mask==expected_mask && (candidate_flags&flags_mask)==expected_flags,"precise integer FLAGS candidate and mask");
        check(result_write==expected_write && arithmetic_fault==expected_fault,"precise quotient-overflow/zero-divisor disposition");
    endtask
    initial begin
        tick();reset=0;#1;
        if(!$value$plusargs("muldiv_vectors=%s",path))$fatal(1,"missing integer vectors");
        file_handle=$fopen(path,"r");if(file_handle==0)$fatal(1,"cannot open integer vectors");scan();total=word_value;
        for(integer row=0;row<total;row++) begin
            scan();kind=2'(word_value);scan();operand_byte=1'(word_value);scan();dividend=32'(word_value);scan();source=16'(word_value);
            scan();expected_low=16'(word_value);scan();expected_high=16'(word_value);
            scan();expected_flags=16'(word_value);scan();expected_mask=16'(word_value);
            scan();expected_write=1'(word_value);scan();expected_fault=1'(word_value);
            check(request_ready && !response_valid,"ready for next mathematical request");request_valid=1;tick();request_valid=0;
            // All inputs may change after acceptance; only captured state is relevant.
            kind=0;operand_byte=~operand_byte;dividend=32'hDEADCAFE;source=0;
            cycles=0;
            while(!response_valid && cycles<40) begin
                check(!request_ready,"arithmetic progress owns the request");
                if((row%1021==0 || (expected_write && expected_low[7:0]==8'h80)) && cycles==2) begin
                    enable=0;repeat(3)begin tick();check(!response_valid && !request_ready,"pause preserves in-flight division computation");end
                    enable=1;
                end
                tick();cycles++;
            end
            check(cycles<40,"bounded arithmetic completion");compare();
            if(row%1021==0 || (expected_write && expected_low[7:0]==8'h80)) begin
                repeat(3)begin tick();compare();end
                enable=0;response_ready=1;repeat(3)begin tick();compare();end
                enable=1;response_ready=0;
            end
            response_ready=1;tick();response_ready=0;check(!response_valid,"one consumed response");cases++;
        end
        $fclose(file_handle);check(cases==284500,"complete independent integer domain");
        for(integer action=0;action<2;action++) for(integer step=0;step<35;step++) begin
            kind=3;operand_byte=0;dividend=32'hA1234567;source=16'hCE81;request_valid=1;tick();request_valid=0;
            repeat(step)tick();enable=0;
            if(action==0)cancel=1;else reset=1;
            tick();cancel=0;reset=0;enable=1;#1;
            check(!response_valid && request_ready && !result_write && !arithmetic_fault,"reset/cancel discards calculation or held response");
            repeat(40)tick();check(!response_valid,"canceled result cannot arrive later");
        end
        enable=0;request_valid=1;repeat(3)begin tick();check(!request_ready && !response_valid,"paused service cannot accept request");end
        request_valid=0;enable=1;
        $display("MULDIV PASS: %0d independent vectors; %0d checks; snapshot, pause, backpressure, cancel and reset",cases,checks);
        $finish;
    end
endmodule
