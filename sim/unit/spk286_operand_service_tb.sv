// SPDX-License-Identifier: MIT
// Exercise the logical operand API directly, independently of MOV and TMP0.
`timescale 1ns/1ps
module spk286_operand_service_tb;
    logic request_byte=0; wire gpr_write_byte, memory_byte;
    logic clk=0, reset=1, cancel=0;
    logic request_valid=0, request_write=0, select_rm=0;
    logic [15:0] write_data=0;
    wire done, unlimited_memory_done;
    wire [15:0] read_data;
    logic [127:0] register_state;
    logic [2:0] reg_index=0, rm_index=0;
    logic register_direct=1;
    logic [23:0] physical_address=24'h102001;
    logic [15:0] offset=16'h2001, segment_limit=16'hFFFF;
    logic segment_expand_down=1'b0;
    logic parallel_within_limit=1'b0;
    wire blocked, gpr_write_en;
    wire [2:0] gpr_write_index;
    wire [15:0] gpr_write_data;
    wire memory_request, memory_write;
    logic memory_request_ready=0;
    wire [23:0] memory_address;
    wire [15:0] memory_write_data;
    logic memory_response_valid=0;
    wire memory_response_ready;
    wire timing_wait;
    logic [15:0] memory_read_data=0;
    integer checks=0, requests=0, responses=0, commits=0;
    logic [127:0] before_state;
    logic request_check = 0;
    spk286_operand dut (.*);

    task automatic check(input logic condition, input string message);
        checks=checks+1;
        if(condition !== 1'b1) $fatal(1,"%s requests=%0d responses=%0d",message,requests,responses);
    endtask
    task automatic tick;
        #5;
        if(!reset && !cancel) begin
            if(memory_request && memory_request_ready) requests=requests+1;
            if(memory_response_valid && memory_response_ready) responses=responses+1;
            if(gpr_write_en) begin
                register_state[gpr_write_index*16 +: 16]=gpr_write_data;
                commits=commits+1;
            end
        end
        clk=1; #5; clk=0; #1;
    endtask
    task automatic local_access(input logic rm, input logic wr, input logic [15:0] value);
        select_rm=rm; request_write=wr; write_data=value; request_valid=1; #1;
        check(done && !memory_request && !memory_response_ready && !timing_wait && !blocked,"local access is bus independent");
        check(read_data==register_state[(rm?int'(rm_index):int'(reg_index))*16 +: 16],"operand identity selects register");
        check(gpr_write_en==wr && gpr_write_index==(rm?rm_index:reg_index),"write direction independent of identity");
        before_state=register_state;
        if(wr) before_state[(rm?int'(rm_index):int'(reg_index))*16 +: 16]=value;
        tick(); request_valid=0; #1;
        check(register_state==before_state && !gpr_write_en && !done,"only requested architectural register commits");
    endtask
    task automatic memory_access(input logic wr, input logic [15:0] value);
        integer old_requests, old_responses;
        old_requests=requests; old_responses=responses;
        register_direct=0; select_rm=1; request_write=wr; write_data=value;
        request_valid=1; memory_request_ready=0;
        repeat(3) begin
            #1;
            check(memory_request && timing_wait && !done && !gpr_write_en && !memory_response_ready,"unaccepted logical request stalls");
            check(memory_address==physical_address && memory_write==wr && memory_write_data==value,"logical metadata has no lane splitting");
            tick();
        end
        memory_request_ready=1; tick();
        repeat(3) begin
            check(!memory_request && timing_wait && !done && requests==old_requests+1,"pending operation cannot resubmit");
            tick();
        end
        // Semantic pause while a complete response arrives. The responder holds
        // validity until acceptance; no executor temporary participates here.
        request_valid=0; memory_response_valid=1; memory_read_data=16'hC17E;
        repeat(3) begin
            tick(); check(!done && !memory_response_ready && responses==old_responses,"response held across pause");
        end
        request_valid=1; #1;
        check(done && !timing_wait && memory_response_ready && !memory_request && !gpr_write_en,"whole-word completion resumes once");
        if(!wr) check(read_data==16'hC17E,"read returns responder word");
        tick(); request_valid=0; memory_response_valid=0; #1;
        check(requests==old_requests+1 && responses==old_responses+1,"one request and one completion per memory operation");
    endtask
    initial begin
        register_state={16'h7777,16'h6666,16'h5555,16'h4444,16'h3333,16'h2222,16'h1111,16'h0000};
        tick(); reset=0;
        for(integer r=0;r<8;r=r+1) begin
            reg_index=3'(r); rm_index=3'(7-r);
            local_access(0,0,0); local_access(1,0,0);
            local_access(0,1,16'hA500+16'(r)); local_access(1,1,16'h5A00+16'(r));
        end
        check(commits==16 && requests==0 && responses==0,"local commits require no memory service");
        // Read RM, read REG, then write an independently supplied word to RM.
        // This is an API sequence, not an added instruction or arithmetic unit.
        reg_index=3'd2; rm_index=3'd5;
        memory_access(0,0); local_access(0,0,0); memory_access(1,16'h6DB2);
        local_access(0,1,16'hE489);
        // Whole-width precheck: last legal word, short segment and FFFF overflow.
        offset=16'hFFFE; physical_address=24'h10FFEE; memory_access(1,16'h9678);
        for(integer edge_case=0;edge_case<2;edge_case=edge_case+1) begin
            offset=edge_case==0?16'hFFFF:16'h0001;
            segment_limit=edge_case==0?16'hFFFF:16'h0001;
            for(integer wr=0;wr<2;wr=wr+1) begin
                cancel=1; tick(); cancel=0;
                request_valid=1; request_write=1'(wr); select_rm=1; register_direct=0; #1;
                check(!memory_request && !done && !gpr_write_en,"invalid whole word rejected before acceptance");
                tick(); request_valid=0; offset=0; segment_limit=16'hFFFF;
                repeat(3) begin tick(); check(blocked && !memory_request && !done,"blocked remains sticky without a request"); end
                check(requests==3 && responses==3,"blocked word produced zero logical transactions");
                cancel=1; tick(); cancel=0; #1; check(!blocked,"redirect clears blocked state");
                offset=edge_case==0?16'hFFFF:16'h0001;
                segment_limit=edge_case==0?16'hFFFF:16'h0001;
            end
        end
        // Cancellation wins on the same edge as semantic response consumption.
        offset=0; segment_limit=16'hFFFF; request_valid=1; request_write=0;
        memory_request_ready=1; tick(); memory_response_valid=1; cancel=1; #1;
        check(!done && !memory_response_ready && !memory_request && !gpr_write_en,"cancel suppresses coincident response consumption");
        tick(); request_valid=0; memory_response_valid=0; cancel=0; tick();
        check(responses==3 && requests==4 && commits==17,"canceled response cannot become a semantic effect");
        // Validate a future POP destination without issuing a bus access or write.
        request_check=1;request_valid=1;request_write=1;select_rm=1;register_direct=0;
        offset=16'hFFFE;segment_limit=16'hFFFF;#1;
        check(done && !memory_request && !gpr_write_en,"valid precheck completes without memory or GPR effects");
        tick();offset=16'hFFFF;#1;
        check(!done && !memory_request,"precheck rejects overflowing destination word");
        tick();check(blocked && requests==4 && commits==17,"precheck blocks before any transfer");
        cancel=1;tick();cancel=0;request_valid=0;request_check=0;
        $display("OPERAND_SERVICE PASS: independent REG/RM direction, repeated context, backpressure, limits and cancellation; %0d checks",checks);
        $finish;
    end
endmodule
