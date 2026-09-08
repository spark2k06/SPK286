`timescale 1ns/1ps
module spk286_adjust_tb;
    logic clk=0,reset=1,cancel=0,enable=1,request_valid=0,response_ready=0;
    logic [2:0] kind=0;
    logic [15:0] operand=0;
    logic [7:0] radix=0;
    logic carry_in=0,auxiliary_in=0;
    wire request_ready,response_valid,result_write,arithmetic_fault;
    wire [15:0] result,candidate_flags,flags_mask;
    logic [15:0] expected_result,expected_flags,expected_mask;
    logic expected_write,expected_fault;
    integer file_handle,fields,total,word_value,cycles,checks=0,cases=0;
    string path;
    spk286_adjust dut(.*);
    task automatic check(input logic condition,input string message);
        checks++;
        if(condition!==1'b1) $fatal(1,"%s case=%d result=%h expected=%h flags=%h/%h mask=%h/%h fault=%b/%b",message,cases,result,expected_result,candidate_flags,expected_flags,flags_mask,expected_mask,arithmetic_fault,expected_fault);
    endtask
    task automatic tick; #5;clk=1;#5;clk=0;#1; endtask
    task automatic scan; fields=$fscanf(file_handle,"%h",word_value);if(fields!=1)$fatal(1,"malformed adjust vector");endtask
    task automatic compare;
        check(response_valid && result==expected_result,"exact adjusted result and response");
        check(flags_mask==expected_mask && (candidate_flags&flags_mask)==expected_flags,"precise adjust FLAGS candidate and mask");
        check(result_write==expected_write && arithmetic_fault==expected_fault,"radix-zero fault disposition");
    endtask
    initial begin
        tick();reset=0;#1;
        if(!$value$plusargs("adjust_vectors=%s",path))$fatal(1,"missing adjust vectors");
        file_handle=$fopen(path,"r");if(file_handle==0)$fatal(1,"cannot open adjust vectors");scan();total=word_value;
        for(integer row=0;row<total;row++) begin
            scan();kind=3'(word_value);scan();operand=16'(word_value);scan();radix=8'(word_value);
            scan();carry_in=1'(word_value);scan();auxiliary_in=1'(word_value);
            scan();expected_result=16'(word_value);scan();expected_flags=16'(word_value);scan();expected_mask=16'(word_value);
            scan();expected_write=1'(word_value);scan();expected_fault=1'(word_value);
            check(request_ready && !response_valid,"ready for next mathematical request");request_valid=1;tick();request_valid=0;
            // All inputs may change after acceptance; only captured state is relevant.
            kind=7;operand=16'hDEAD;radix=0;carry_in=~carry_in;auxiliary_in=~auxiliary_in;
            cycles=0;
            while(!response_valid && cycles<20) begin
                check(!request_ready,"arithmetic progress owns the request");
                if(row%1021==0 && cycles==2) begin
                    enable=0;repeat(3)begin tick();check(!response_valid && !request_ready,"pause preserves in-flight radix computation");end
                    enable=1;
                end
                tick();cycles++;
            end
            check(cycles<20,"bounded arithmetic completion");compare();
            if(row%1021==0) begin
                repeat(3)begin tick();compare();end
                enable=0;response_ready=1;repeat(3)begin tick();compare();end
                enable=1;response_ready=0;
            end
            response_ready=1;tick();response_ready=0;check(!response_valid,"one consumed response");cases++;
        end
        $fclose(file_handle);check(cases==352256,"complete independent adjust domain");
        for(integer action=0;action<2;action++) for(integer step=0;step<10;step++) begin
            kind=4;operand=16'hABED;radix=7;request_valid=1;tick();request_valid=0;
            repeat(step)tick();enable=0;
            if(action==0)cancel=1;else reset=1;
            tick();cancel=0;reset=0;enable=1;#1;
            check(!response_valid && request_ready && !result_write && !arithmetic_fault,"reset/cancel discards calculation or held response");
            repeat(10)tick();check(!response_valid,"canceled result cannot arrive later");
        end
        enable=0;request_valid=1;repeat(3)begin tick();check(!request_ready && !response_valid,"paused service cannot accept request");end
        request_valid=0;enable=1;
        $display("ADJUST PASS: %0d independent vectors; %0d checks; snapshot, pause, backpressure, cancel and reset",cases,checks);
        $finish;
    end
endmodule
