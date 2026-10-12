// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module spk286_data_lifecycle_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    integer checks=0, cases=0, retired_count=0, data_count=0, write_count=0;
    integer timeout_count;
    logic permit_data=0;
    logic [11:0] saved_pc;
    spk286 dut (.*);
    task automatic check(input logic condition,input string message);
        checks=checks+1;
        if(condition !== 1'b1) $fatal(1,"%s case=%d IP=%h pc=%h ea=%h bus=%h/%h retired=%d",
                                     message,cases,debug_ip,debug_micro_pc,debug_effective_offset,bus_status,address,retired_count);
    endtask
    task automatic tick;
        #1;
        data_in=16'h0F0F;
        if(bus_valid && address < 65536) data_in={memory[{address[15:1],1'b1}],memory[{address[15:1],1'b0}]};
        #4;
        if(bus_valid && ready && !reset && (bus_status==5 || bus_status==6)) begin
            data_count=data_count+1;
            if(bus_write) begin
                write_count=write_count+1;
                if(address[0]) memory[address[15:0]]=data_out[15:8];
                else begin
                    memory[address[15:0]]=data_out[7:0];
                    if(!bus_bhe_n) memory[address[15:0]+16'd1]=data_out[15:8];
                end
            end
        end
        clk=1; #5; clk=0; #1;
        if(instruction_retired) retired_count=retired_count+1;
        check(!microcode_fault && debug_prefetch_count<=6,"control/queue invariants");
    endtask
    task automatic service;
        ready=bus_valid && (bus_status==13 || permit_data); tick();
    endtask
    task automatic redirect_to(input logic [15:0] ip);
        redirect=1; ip_write_en=1; ip_write_data=ip; tick(); redirect=0; ip_write_en=0;
        check(!instruction_retired && !debug_micro_active && debug_prefetch_count==0,"cancel microstate and queue at redirect");
    endtask
    task automatic setup(input logic wr);
        execute_enable=0; reset=1; ready=0; gpr_write_en=0; segment_load_en=0; flags_write_en=0;
        redirect=0; ip_write_en=0; tick(); reset=0;
        gpr_write_en=1; gpr_write_index=0; gpr_write_data=16'hBEEF; tick(); gpr_write_en=0;
        segment_load_en=1; segment_load_index=1; segment_load_selector=0;
        redirect_to(16'h0100); segment_load_en=0;
        memory[256]=wr?8'hA3:8'hA1; memory[257]=8'h01;
        memory[258]=8'h10; memory[259]=8'h0F; memory[260]=8'h0F;
        // New stream loads a different operand, exposing stale-response routing.
        memory[512]=8'h8B; memory[513]=8'h3E; memory[514]=8'h03; memory[515]=8'h10; memory[516]=8'h0F;
        memory[4096]=8'h79; memory[4097]=8'h5A; memory[4098]=8'hC3;
        memory[4099]=8'h34; memory[4100]=8'h12; memory[4101]=8'h97;
        retired_count=0; data_count=0; write_count=0; permit_data=0; execute_enable=1;
    endtask
    task automatic reach(input integer stage);
        timeout_count=0;
        while(!((stage<3 && debug_ip==16'h0101+16'(stage)) ||
                (stage>=3 && bus_valid && (bus_status==5 || bus_status==6))) && timeout_count<150) begin
            service(); timeout_count=timeout_count+1;
        end
        check(timeout_count<150 && retired_count==0,"reach requested byte/data boundary");
        ready=0;
        if(stage>=4) begin ready=1; tick(); ready=0; check(address==24'h001002,"second odd subcycle"); end
        if(stage>=5) begin ready=1; tick(); ready=0; check(dut.memory_response_valid,"logical completion held"); end
    endtask
    task automatic finish(input logic wr,input logic redirected);
        permit_data=1; timeout_count=0;
        while(!instruction_retired && timeout_count<200) begin
            service(); timeout_count=timeout_count+1;
            check(!unsupported_opcode && !operand_blocked,"stream remains executable");
        end
        check(instruction_retired && retired_count==1,"one successful END after resume/restart");
        check(debug_flags==2 && debug_gpr[31:16]==0,"FLAGS/unrelated register preservation");
        if(redirected) begin
            check(debug_ip==16'h0204 && debug_gpr[127:112]==16'h1234 && debug_gpr[15:0]==16'hBEEF,
                  "new operand acquired independently; canceled load cannot write AX");
        end else begin
            check(debug_ip==16'h0103 && data_count==2,"old instruction resumes exactly once");
            if(!wr) check(debug_gpr[15:0]==16'hC35A,"resumed read uses complete word");
            else check({memory[4098],memory[4097]}==16'hBEEF && write_count==2,"resumed write has exactly two byte transfers");
        end
    endtask
    task automatic reach_exchange(input integer stage);
        setup(0);
        memory[256]=8'h87; memory[257]=8'h06; memory[258]=1; memory[259]=8'h10; memory[260]=8'h0F;
        permit_data=1; timeout_count=0;
        while(!(debug_micro_active && debug_micro_instruction==spk286_microcode_pkg::MC_WRITE_RM16) && timeout_count<200) begin
            service(); timeout_count++;
        end
        check(timeout_count<200 && data_count==2 && write_count==0 && debug_gpr[15:0]==16'hBEEF,
              "exchange acquires both operands before writes");
        permit_data=0; ready=0;
        if(stage>=1) begin
            timeout_count=0;
            while(!(bus_valid && bus_write) && timeout_count<200) begin service(); timeout_count++; end
            check(timeout_count<200 && address==24'h001001,"exchange first write held");
        end
        if(stage>=2) begin ready=1; tick(); ready=0; check(address==24'h001002,"exchange second byte held"); end
        if(stage>=3) begin ready=1; tick(); ready=0; check(dut.memory_response_valid,"exchange write response held"); end
        if(stage>=4) begin tick(); check(debug_micro_instruction==spk286_microcode_pkg::MC_WRITE_REG16_TMP1,"exchange register commit boundary"); end
        if(stage>=5) begin tick(); check(debug_gpr[15:0]==16'hC35A,"exchange architectural register already committed"); end
        check(retired_count==0,"exchange boundary precedes retirement");
    endtask
    initial begin
        for(integer i=0;i<65536;i=i+1) memory[i]=8'h0F;
        for(integer wr=0;wr<2;wr=wr+1)
            for(integer stage=0;stage<6;stage=stage+1) begin
                setup(1'(wr)); reach(stage); saved_pc=debug_micro_pc;
                // Freeze semantic execution, then let accepted physical data finish.
                execute_enable=0; ready=1;
                repeat(7) begin
                    tick(); check(debug_micro_pc==saved_pc && retired_count==0 && debug_gpr[15:0]==16'hBEEF,
                                  "pause holds micro-PC and read writeback across completion");
                end
                execute_enable=1;
                // Malformed external controls must also freeze semantic effects.
                redirect=1; ip_write_en=0;
                repeat(3) begin tick(); check(control_error && debug_micro_pc==saved_pc && retired_count==0,"invalid control freezes operand completion"); end
                redirect=0; finish(1'(wr),0); cases=cases+1;

                setup(1'(wr)); reach(stage); ready=0; redirect_to(16'h0200);
                finish(1'(wr),1);
                check(write_count==(wr!=0 && stage>=3?2:0),"redirect drains only already accepted writes");
                check(memory[4096]==8'h79 && memory[4099]==8'h34 && memory[4100]==8'h12,"drained write preserves neighbors/new operand");
                cases=cases+1;

                if(stage>=3) begin
                    setup(1'(wr)); reach(stage); ready=1; redirect_to(16'h0200);
                    finish(1'(wr),1);
                    check(write_count==(wr!=0?2:0),"READY coincident with redirect drains exactly the accepted word");
                    check(data_count==4 && debug_gpr[15:0]==16'hBEEF,
                          "two old and two new physical cycles; stale read never commits");
                    cases=cases+1;
                end

                setup(1'(wr)); reach(stage); reset=1; ready=1; tick();
                check(!bus_valid && !instruction_retired && debug_ip==16'hFFF0 && debug_cs_base==24'hFF0000 &&
                      debug_gpr==0 && debug_flags==2 && !operand_blocked,"reset cancels byte/data/response context");
                reset=0; execute_enable=0; ready=0; tick();
                check(bus_valid && address==24'hFFFFF0 && bus_status==13,"reset returns to native fetch vector");
                // A new architectural setup then executes a different word load.
                setup(0); redirect_to(16'h0200); finish(0,1); cases=cases+1;
            end
        for(integer stage=0;stage<6;stage++) begin
            reach_exchange(stage); saved_pc=debug_micro_pc;
            execute_enable=0; ready=1;
            repeat(7) begin
                tick(); check(debug_micro_pc==saved_pc && retired_count==0 &&
                              debug_gpr[15:0]==(stage==5?16'hC35A:16'hBEEF),
                              "exchange pause drains physical writes without semantic replay");
            end
            execute_enable=1; permit_data=1; timeout_count=0;
            while(!instruction_retired && timeout_count<200) begin service(); timeout_count++; end
            check(retired_count==1 && debug_gpr[15:0]==16'hC35A && {memory[4098],memory[4097]}==16'hBEEF &&
                  data_count==4 && write_count==2 && debug_flags==2,"exchange resumes and commits exactly once");
            cases++;

            reach_exchange(stage); ready=0; redirect_to(16'h0200); permit_data=1; timeout_count=0;
            while(!instruction_retired && timeout_count<200) begin service(); timeout_count++; end
            check(retired_count==1 && debug_ip==16'h0204 && debug_gpr[127:112]==16'h1234 &&
                  debug_gpr[15:0]==(stage==5?16'hC35A:16'hBEEF) && debug_flags==2,
                  "exchange cancellation preserves only prior architectural commits");
            check(write_count==(stage>=1?2:0) && data_count==(stage>=1?6:4) &&
                  {memory[4098],memory[4097]}==(stage>=1?16'hBEEF:16'hC35A),
                  "exchange cancellation drains only an accepted physical write");
            cases++;
        end
        // Direct address, ModR/M read, exchange, LEA and XLAT share one stream.
        setup(0);
        memory[259]=8'h8B; memory[260]=8'h3E; memory[261]=3; memory[262]=8'h10;
        memory[263]=8'h87; memory[264]=6; memory[265]=5; memory[266]=8'h10;
        memory[267]=8'h8D; memory[268]=8'h5F; memory[269]=8'hFF;
        memory[270]=8'hD7; memory[271]=8'h0F;
        memory[4102]=8'h46; memory[150]=8'h5A;
        permit_data=1; timeout_count=0;
        while(retired_count<5 && timeout_count<800) begin
            service(); timeout_count++;
            check(!unsupported_opcode && !operand_blocked,"mixed data stream remains executable");
            if(instruction_retired && retired_count==2)
                check(debug_gpr[127:112]==16'h1234,"new instruction discards old direct address");
        end
        check(retired_count==5 && debug_ip==16'h010F && debug_gpr[15:0]==16'h465A &&
              debug_gpr[63:48]==16'hFFFF && debug_gpr[127:112]==16'h1234 && debug_flags==2,
              "mixed data stream preserves dependencies and flags");
        check(data_count==9 && write_count==2 && {memory[4102],memory[4101]}==16'hC35A,
              "mixed data stream has exact physical traffic and exchange");
        cases++;
        $display("DATA_LIFECYCLE PASS: %0d pause/redirect/reset cases at six boundaries; %0d checks",cases,checks);
        $finish;
    end
endmodule
