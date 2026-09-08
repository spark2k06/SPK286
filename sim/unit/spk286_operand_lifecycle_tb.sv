`timescale 1ns/1ps
module spk286_operand_lifecycle_tb;
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
        data_in=16'h9090;
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
        memory[256]=wr?8'h89:8'h8B; memory[257]=wr?8'h06:8'h0E;
        memory[258]=8'h01; memory[259]=8'h10; memory[260]=8'h90;
        // New stream loads a different operand, exposing stale-response routing.
        memory[512]=8'h8B; memory[513]=8'h3E; memory[514]=8'h03; memory[515]=8'h10; memory[516]=8'h90;
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
        check(debug_flags==2 && debug_gpr[15:0]==16'hBEEF,"FLAGS/source preservation");
        if(redirected) begin
            check(debug_ip==16'h0204 && debug_gpr[127:112]==16'h1234 && debug_gpr[31:16]==0,
                  "new operand acquired independently; canceled load cannot write CX");
        end else begin
            check(debug_ip==16'h0104 && data_count==2,"old instruction resumes exactly once");
            if(!wr) check(debug_gpr[31:16]==16'hC35A,"resumed read uses complete word");
            else check({memory[4098],memory[4097]}==16'hBEEF && write_count==2,"resumed write has exactly two byte transfers");
        end
    endtask
    initial begin
        for(integer i=0;i<65536;i=i+1) memory[i]=8'h90;
        for(integer wr=0;wr<2;wr=wr+1)
            for(integer stage=0;stage<6;stage=stage+1) begin
                setup(1'(wr)); reach(stage); saved_pc=debug_micro_pc;
                // Freeze semantic execution, then let accepted physical data finish.
                execute_enable=0; ready=1;
                repeat(7) begin
                    tick(); check(debug_micro_pc==saved_pc && retired_count==0 && debug_gpr[31:16]==0,
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
                    check(data_count==4 && debug_gpr[31:16]==0,
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
        // Register-only forms cancel at writeback and END. At END an earlier
        // register commit remains visible, but the canceled instruction cannot retire.
        for(integer direction=0;direction<2;direction=direction+1)
            for(integer at_end=0;at_end<2;at_end=at_end+1) begin
                setup(0);
                memory[256]=direction==0?8'h89:8'h8B;
                memory[257]=direction==0?8'hC1:8'hC8; memory[258]=8'h90;
                timeout_count=0;
                while(!(debug_micro_active && debug_micro_pc==12'((direction==0?5:9)+at_end)) && timeout_count<150) begin
                    service(); timeout_count=timeout_count+1;
                end
                check(timeout_count<150 && retired_count==0 && data_count==0,"reach register writeback/END without a data cycle");
                check(debug_gpr[31:16]==(at_end!=0?16'hBEEF:16'h0000),"register commit precedes END only");
                ready=1; redirect_to(16'h0200); permit_data=1;
                timeout_count=0;
                while(!instruction_retired && timeout_count<150) begin service(); timeout_count=timeout_count+1; end
                check(retired_count==1 && debug_ip==16'h0204 && debug_gpr[127:112]==16'h1234 &&
                      debug_gpr[31:16]==(at_end!=0?16'hBEEF:16'h0000) && data_count==2,
                      "register cancellation suppresses simultaneous effects without rolling back prior commits");
                cases=cases+1;
            end
        $display("OPERAND_LIFECYCLE PASS: %0d pause/redirect/reset cases at six boundaries; %0d checks",cases,checks);
        $finish;
    end
endmodule
