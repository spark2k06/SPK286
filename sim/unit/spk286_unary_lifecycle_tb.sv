`timescale 1ns/1ps
module spk286_unary_lifecycle_tb;
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
    task automatic setup;
        execute_enable=0; reset=1; ready=0; gpr_write_en=0; segment_load_en=0; flags_write_en=0;
        redirect=0; ip_write_en=0; tick(); reset=0;
        gpr_write_en=1; gpr_write_index=0; gpr_write_data=16'hBEEF; tick(); gpr_write_en=0;
        segment_load_en=1; segment_load_index=1; segment_load_selector=0;
        redirect_to(16'h0100); segment_load_en=0;
        memory[256]=8'hF7; memory[257]=8'h1E; memory[258]=8'h01; memory[259]=8'h10; memory[260]=8'h0F;
        // New stream loads a different operand, exposing stale-response routing.
        memory[512]=8'hF6; memory[513]=8'hD4; memory[514]=8'h0F;
        memory[4096]=8'h79; memory[4097]=8'h5A; memory[4098]=8'hC3;
        memory[4099]=8'h34; memory[4100]=8'h12; memory[4101]=8'h97;
        retired_count=0; data_count=0; write_count=0; permit_data=0; execute_enable=1;
    endtask
    task automatic wait_operation(input logic [spk286_microcode_pkg::MC_WORD_WIDTH-1:0] operation);
        timeout_count=0;
        while(!(debug_micro_active && debug_micro_instruction==operation) && timeout_count<200) begin service(); timeout_count++; end
        check(timeout_count<200 && retired_count==0,"reach requested unary micro-operation"); ready=0;
    endtask
    task automatic wait_data(input logic wr);
        timeout_count=0;
        while(!(bus_valid && (bus_status==5 || bus_status==6) && bus_write==wr) && timeout_count<200) begin service(); timeout_count++; end
        check(timeout_count<200 && address==24'h001001,"first odd unary transaction held"); ready=0;
    endtask
    task automatic reach(input integer stage);
        setup();
        if(stage<3) begin
            timeout_count=0;
            while(debug_ip!=16'h0101+16'(stage) && timeout_count<200) begin service(); timeout_count++; end
            check(timeout_count<200,"unary byte acquisition boundary"); ready=0;
        end else begin
            wait_operation(spk286_microcode_pkg::MC_DISPATCH_DECODED);
            check(debug_ip==16'h0104 && debug_effective_offset==16'h1001,"dispatch follows complete ModRM/displacement acquisition");
            if(stage>=4) begin
                tick(); check((debug_micro_instruction==spk286_microcode_pkg::MC_DECODE_MODRM ||
                               debug_micro_instruction==spk286_microcode_pkg::MC_DECODE_UNARY_RM8 ||
                               debug_micro_instruction==spk286_microcode_pkg::MC_DECODE_UNARY_RM16) &&
                              debug_micro_pc!=debug_micro_entry && dut.operand_decode.modrm_valid &&
                              debug_effective_offset==16'h1001,"generic branch retains cached context");
            end
            if(stage>=5) wait_data(0);
            if(stage==6 || stage==7) begin ready=1; tick(); ready=0; check(address==24'h001002,"second odd unary read held"); end
            if(stage==7) begin ready=1; tick(); ready=0; check(dut.memory_response_valid,"unary read response held"); end
            if(stage>=8) begin permit_data=1; wait_operation(spk286_microcode_pkg::MC_ALU); permit_data=0; end
            if(stage>=9) wait_operation(spk286_microcode_pkg::MC_WRITE_RESULT_RM16);
            if(stage>=10) wait_data(1);
            if(stage>=11) begin ready=1; tick(); ready=0; check(address==24'h001002,"second odd unary write held"); end
            if(stage>=12) begin ready=1; tick(); ready=0; check(dut.memory_response_valid,"unary write response held"); end
            if(stage>=13) begin tick(); check(debug_micro_instruction==spk286_microcode_pkg::MC_COMMIT_FLAGS,"unary FLAGS follows data completion"); end
            if(stage>=14) begin tick(); check(debug_micro_instruction==spk286_microcode_pkg::MC_END && debug_flags==16'h0017,"unary FLAGS committed before END"); end
        end
    endtask
    task automatic finish(input logic redirected);
        permit_data=1; timeout_count=0;
        while(!instruction_retired && timeout_count<200) begin
            service(); timeout_count++;
            check(!unsupported_opcode && !operand_blocked,"unary stream remains executable");
        end
        check(retired_count==1,"one unary retirement after resume/restart");
        if(redirected) check(debug_ip==16'h0202 && debug_gpr[15:0]==16'h41EF,"fresh byte operation has independent source and context");
        else check(debug_ip==16'h0104 && debug_gpr[15:0]==16'hBEEF && debug_flags==16'h0017 &&
                   data_count==4 && write_count==2 && {memory[4098],memory[4097]}==16'h3CA6,"resumed unary operand and FLAGS commit exactly once");
    endtask
    initial begin
        for(integer i=0;i<65536;i++) memory[i]=8'h0F;
        for(integer stage=0;stage<15;stage++) begin
            reach(stage); saved_pc=debug_micro_pc; execute_enable=0; ready=1;
            repeat(7) begin
                tick(); check(debug_micro_pc==saved_pc && retired_count==0 && debug_gpr[15:0]==16'hBEEF &&
                              debug_flags==(stage==14?16'h0017:16'h0002),"unary pause preserves semantic state while accepted bus cycles drain");
            end
            execute_enable=1; finish(0); cases++;

            reach(stage); ready=0; redirect_to(16'h0200); finish(1);
            check(debug_flags==(stage==14?16'h0017:16'h0002) && write_count==(stage>=10?2:0) &&
                  {memory[4098],memory[4097]}==(stage>=10?16'h3CA6:16'hC35A),"unary cancellation preserves only completed FLAGS and accepted writes");
            cases++;

            reach(stage); reset=1; ready=1; tick();
            check(!bus_valid && !instruction_retired && debug_ip==16'hFFF0 && debug_cs_base==24'hFF0000 &&
                  debug_gpr==0 && debug_flags==2 && !operand_blocked,"reset cancels dispatch, cached EA and unary temporaries");
            reset=0; execute_enable=0; ready=0; tick();
            check(bus_valid && address==24'hFFFFF0 && bus_status==13,"unary reset returns to native fetch vector");
            setup(); redirect_to(16'h0200); finish(1); cases++;
        end
        // Owned invalid FE extensions fault at ModR/M, before any displacement/data.
        for(integer mode=0;mode<4;mode++) for(integer extension=2;extension<8;extension++) begin
            setup(); memory[256]=8'hFE; memory[257]=8'(mode*64+extension*8+6);
            timeout_count=0;
            while(!dut.invalid_form && timeout_count<100) begin service(); timeout_count++; end
            execute_enable=0;
            check(timeout_count<100 && dut.fault_vector==6 && debug_ip==16'h0102 && retired_count==0 &&
                  data_count==0 && write_count==0 && debug_gpr[15:0]==16'hBEEF && debug_flags==2,"invalid FE faults without displacement or operand effects");
            cases++;
        end
        // New group dispatch and old TEST/indirect stack dispatch share one stream.
        setup(); execute_enable=0;
        gpr_write_en=1; gpr_write_index=4; gpr_write_data=16'h2000; tick(); gpr_write_en=0;
        memory[256]=8'hF6; memory[257]=8'hD0; // NOT AL: BE10.
        memory[258]=8'hF7; memory[259]=8'hD8; // NEG AX: 41F0.
        memory[260]=8'hFE; memory[261]=8'hC4; // INC AH: 42F0.
        memory[262]=8'hFF; memory[263]=8'hC8; // DEC AX: 42EF.
        memory[264]=8'hF7; memory[265]=8'hC0; memory[266]=8'hFF; memory[267]=8'h0F; // TEST AX,0FFF.
        memory[268]=8'hFF; memory[269]=8'h36; memory[270]=8'h01; memory[271]=8'h10; // PUSH word [1001].
        memory[272]=8'h5B; memory[273]=8'h0F; // POP BX.
        execute_enable=1; permit_data=1; timeout_count=0;
        while(retired_count<7 && timeout_count<700) begin service(); timeout_count++; check(!unsupported_opcode && !operand_blocked,"mixed unary/TEST/stack stream executable"); end
        check(retired_count==7 && debug_ip==16'h0111 && debug_gpr[15:0]==16'h42EF && debug_gpr[63:48]==16'hC35A &&
              debug_gpr[79:64]==16'h2000 && debug_flags==16'h0012 && data_count==4 && write_count==1,"mixed dispatch stream preserves dependencies and exact traffic");
        cases++;
        $display("UNARY_LIFECYCLE PASS: %0d dispatch/operand/commit/reset/invalid/stream cases; %0d checks",cases,checks);
        $finish;
    end
endmodule
