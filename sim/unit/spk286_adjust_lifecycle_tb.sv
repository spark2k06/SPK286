`timescale 1ns/1ps
module spk286_adjust_lifecycle_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    integer checks=0, cases=0, retired_count=0, deliveries=0, data_count=0, write_count=0, acknowledgements=0;
    integer timeout_count, waits=0, delay_length=0;
    logic [11:0] saved_pc;
    logic [15:0] expected_flags, initial_ax, initial_flags, initial_sp;
    spk286 dut (.*);
    task automatic check(input logic condition,input string message);
        checks++;
        if(condition !== 1'b1) $fatal(1,"%s case=%0d IP=%h pc=%h AX=%h flags=%h SP=%h bus=%h/%h retired=%0d events=%0d",
            message,cases,debug_ip,debug_micro_pc,debug_gpr[15:0],debug_flags,debug_gpr[79:64],bus_status,address,retired_count,deliveries);
    endtask
    function automatic logic [15:0] word_at(input logic [15:0] offset);
        word_at={memory[offset+16'd1],memory[offset]};
    endfunction
    function automatic logic [15:0] zero_flags(input logic [15:0] ax,input logic [15:0] flags_value);
        logic [7:0] half_value;
        half_value=ax[7:0]>>1;
        zero_flags=flags_value & ~16'h08D5;
        zero_flags[2]=~^half_value; zero_flags[6]=half_value==0; zero_flags[7]=half_value[7];
    endfunction
    task automatic tick;
        #1; data_in=16'h0F0F;
        if(bus_valid && address<65536) data_in={memory[{address[15:1],1'b1}],memory[{address[15:1],1'b0}]};
        #4;
        if(bus_valid && ready && !reset) begin
            if(bus_status==0) acknowledgements++;
            if(bus_status==5 || bus_status==6) begin
                data_count++;
                if(bus_write) begin
                    write_count++;
                    if(address[0]) memory[address[15:0]]=data_out[15:8];
                    else begin
                        memory[address[15:0]]=data_out[7:0];
                        if(!bus_bhe_n) memory[address[15:0]+16'd1]=data_out[15:8];
                    end
                end
            end
        end
        clk=1; #5; clk=0; #1;
        if(instruction_retired) retired_count++;
        if(event_completed) deliveries++;
        check(!microcode_fault && debug_prefetch_count<=6 && !shutdown,"adjust control/queue invariants");
    endtask
    task automatic service;
        ready=bus_valid && waits>=delay_length;
        if(bus_valid && !ready) waits++; else waits=0;
        tick();
    endtask
    task automatic redirect_to(input logic [15:0] ip);
        redirect=1; ip_write_en=1; ip_write_data=ip; tick(); redirect=0; ip_write_en=0;
        check(!instruction_retired && !debug_micro_active && debug_prefetch_count==0,"redirect cancels microstate and queue");
        check(!dut.micro_executor.arithmetic_fault_q && !dut.micro_executor.adjust_valid && !dut.micro_executor.adjust_service.busy_q,"redirect clears arithmetic owned transient state");
    endtask
    task automatic setup(input logic [15:0] ax,input logic [15:0] flags_value,input logic [15:0] sp);
        execute_enable=0; reset=1; ready=0; intr=0; nmi=0; hold_request=0;
        gpr_write_en=0; segment_load_en=0; flags_write_en=0; redirect=0; ip_write_en=0; waits=0;
        tick(); reset=0;
        gpr_write_en=1; gpr_write_index=0; gpr_write_data=ax; tick();
        gpr_write_index=4; gpr_write_data=sp; tick(); gpr_write_en=0;
        flags_write_en=1; flags_write_mask=16'hFFFF; flags_write_data=flags_value; tick(); flags_write_en=0;
        segment_load_en=1; segment_load_index=1; segment_load_selector=0;
        redirect_to(16'h0100); segment_load_en=0;
        for(integer i=256;i<280;i++) memory[i]=8'h0F;
        memory[256]=8'h26; memory[257]=8'hD4; memory[258]=10;
        memory[512]=8'hF6; memory[513]=8'hD4; memory[514]=8'h0F; // NOT AH, independent of adjust state.
        for(integer vector_value=0;vector_value<14;vector_value++) begin
            memory[vector_value*4]=8'h00; memory[vector_value*4+1]=8'h04;
            memory[vector_value*4+2]=0; memory[vector_value*4+3]=0;
        end
        memory[1024]=8'h0F;
        for(integer i=8160;i<8200;i++) memory[i]=8'hA5;
        initial_ax=ax; initial_flags=flags_value; initial_sp=sp;
        retired_count=0; deliveries=0; data_count=0; write_count=0; acknowledgements=0; execute_enable=1;
    endtask
    task automatic wait_operation(input logic [spk286_microcode_pkg::MC_WORD_WIDTH-1:0] operation);
        timeout_count=0;
        while(!(debug_micro_active && debug_micro_instruction==operation) && timeout_count<200) begin service(); timeout_count++; end
        check(timeout_count<200 && retired_count==0 && deliveries==0,"reach requested adjust operation"); ready=0;
    endtask
    task automatic reach(input integer stage);
        setup(16'hBEEF,16'h0CD7,16'h2000);
        if(stage==0) begin
            timeout_count=0;
            while(debug_ip!=16'h0102 && timeout_count<200) begin service(); timeout_count++; end
            check(timeout_count<200,"radix byte acquisition boundary"); ready=0;
        end else begin
            wait_operation(spk286_microcode_pkg::MC_ADJUST);
            if(stage>=2 && stage<=4) begin
                tick(); check(dut.micro_executor.adjust_service.busy_q,"radix arithmetic request accepted");
                if(stage>=3) repeat(4) tick();
                if(stage>=4) repeat(4) tick();
                check(stage==4 ? dut.micro_executor.adjust_valid : dut.micro_executor.adjust_service.busy_q,"iteration/response boundary reached");
            end
            if(stage>=5) wait_operation(spk286_microcode_pkg::MC_WRITE_RESULT_DST);
            if(stage>=6) begin tick(); check(debug_micro_instruction==spk286_microcode_pkg::MC_COMMIT_FLAGS,"result precedes status commit"); end
            if(stage>=7) begin tick(); check(debug_micro_instruction==spk286_microcode_pkg::MC_CHECK_ARITHMETIC,"status precedes fault check"); end
            if(stage>=8) begin tick(); check(debug_micro_instruction==spk286_microcode_pkg::MC_END,"nonfault arithmetic reaches END"); end
        end
    endtask
    task automatic finish_normal(input logic redirected,input integer stage);
        timeout_count=0;
        while(retired_count==0 && timeout_count<200) begin service(); timeout_count++; check(!unsupported_opcode && !operand_blocked,"normal adjusted stream executable"); end
        check(retired_count==1 && deliveries==0 && data_count==0,"one retirement without a data bus request or event");
        if(redirected) check(debug_ip==16'h0202 && debug_gpr[15:0]==(stage>=6?16'hE809:16'h41EF) &&
                             debug_flags==(stage>=7?16'h0C17:16'h0CD7),"restart discards only uncommitted result/status and all fault state");
        else check(debug_ip==16'h0103 && debug_gpr[15:0]==16'h1709 && debug_flags==16'h0C17,"resumed adjust commits result and FLAGS once");
    endtask
    task automatic finish_event(input integer vector_value);
        timeout_count=0;
        while(deliveries==0 && timeout_count<700) begin service(); timeout_count++; end
        check(deliveries==1 && int'(debug_event_vector)==vector_value && debug_ip==16'h0400 && debug_cs==0 &&
              retired_count==0 && acknowledgements==0,"synchronous arithmetic/length exception completes before retirement or INTA");
        check(debug_gpr[15:0]==initial_ax && debug_gpr[79:64]==initial_sp-6 &&
              word_at(initial_sp-6)==16'h0100 && word_at(initial_sp-4)==0 && word_at(initial_sp-2)==expected_flags &&
              debug_flags==(expected_flags & ~16'h0300),"complete unmasked FLAGS/CS/first-prefix-IP frame and unchanged AX");
        check(write_count==(initial_sp[0]?6:3) && data_count==write_count+2,"exact odd/even frame traffic and two IVT words");
    endtask
    initial begin
        for(integer i=0;i<65536;i++) memory[i]=8'h0F;
        for(integer stage=0;stage<9;stage++) begin
            reach(stage); saved_pc=debug_micro_pc; execute_enable=0;
            repeat(7) begin service(); check(debug_micro_pc==saved_pc && retired_count==0 && deliveries==0 &&
                debug_gpr[15:0]==(stage>=6?16'h1709:16'hBEEF) && debug_flags==(stage>=7?16'h0C17:16'h0CD7),"pause holds arithmetic, conditional write, status and END boundaries"); end
            execute_enable=1; finish_normal(0,stage); cases++;
            reach(stage); redirect_to(16'h0200); finish_normal(1,stage); cases++;
            reach(stage); reset=1; ready=1; tick();
            check(!bus_valid && debug_gpr==0 && debug_flags==2 && debug_ip==16'hFFF0 && debug_cs_base==24'hFF0000 &&
                !dut.micro_executor.arithmetic_fault_q && !dut.micro_executor.adjust_valid && !dut.micro_executor.adjust_service.busy_q,"reset abandons every arithmetic boundary");
            reset=0; execute_enable=0; ready=0; tick();
            check(bus_valid && address==24'hFFFFF0 && bus_status==13,"reset resumes native reset fetch"); cases++;
        end
        // Defined #DE plus the pinned physical pre-frame status policy. Test
        // full saved bytes; the normal AAM undefined-bit mask cannot hide them.
        for(integer a=0;a<7;a++) for(integer f=0;f<3;f++) for(integer prefixes=0;prefixes<3;prefixes++) for(integer odd=0;odd<2;odd++) begin
            initial_ax=16'hA500 | (a==0?16'h0000:a==1?16'h0001:a==2?16'h0002:a==3?16'h007F:a==4?16'h0080:a==5?16'h00FE:16'h00FF);
            initial_flags=f==0?16'h0002:f==1?16'h0CD7:16'h02D7;
            setup(initial_ax,initial_flags,16'h2000+16'(odd)); delay_length=(a+f)%3;
            for(integer p=0;p<prefixes;p++) memory[256+p]=p==0?8'hF3:8'h36;
            memory[256+prefixes]=8'hD4; memory[257+prefixes]=0; memory[258+prefixes]=8'h0F;
            expected_flags=zero_flags(initial_ax,initial_flags); finish_event(0); cases++;
        end
        delay_length=0;
        // Cancel after fault status has committed but before event acceptance.
        setup(16'hBEEF,16'h0CD7,16'h2000); memory[258]=0;
        wait_operation(spk286_microcode_pkg::MC_CHECK_ARITHMETIC);
        check(dut.arithmetic_fault && debug_gpr[15:0]==16'hBEEF && debug_flags==16'h0406,"zero radix suppresses AX before the fault request");
        execute_enable=0; repeat(5) begin service(); check(deliveries==0 && data_count==0,"paused fault check cannot dispatch a frame"); end
        redirect_to(16'h0200); execute_enable=1;
        timeout_count=0; while(retired_count==0 && timeout_count<200) begin service(); timeout_count++; end
        check(retired_count==1 && deliveries==0 && data_count==0 && debug_gpr[15:0]==16'h41EF && debug_flags==16'h0406,"canceled fault candidate cannot escape into the next instruction"); cases++;
        // Demanding byte eleven faults before arithmetic, even with zero radix.
        setup(16'hBEEF,16'h0CD7,16'h2000);
        for(integer p=0;p<9;p++) memory[256+p]=8'h26;
        memory[265]=8'hD4; memory[266]=0;
        expected_flags=initial_flags; finish_event(13); cases++;
        // Pending asynchronous events remain owned while a synchronous #DE wins.
        setup(16'hBEEF,16'h02D7,16'h2000); memory[258]=0;
        wait_operation(spk286_microcode_pkg::MC_ADJUST); nmi=1; intr=1;
        expected_flags=zero_flags(initial_ax,initial_flags); finish_event(0);
        check(debug_nmi_pending,"zero-radix fault retains the pending NMI"); cases++;
        // AAD base zero is valid, and neither kind nor fault candidate leaks.
        setup(16'h010A,16'h0002,16'h2000);
        memory[256]=8'h37; // AAA -> 0200, AF/CF set.
        memory[257]=8'hD4; memory[258]=10; // AAM -> 0000.
        memory[259]=8'hD5; memory[260]=0; // AAD zero -> 0000, valid.
        memory[261]=8'hF6; memory[262]=8'hD0; // NOT AL -> 00FF.
        memory[263]=8'hA8; memory[264]=8'h0F; // TEST AL,0F.
        memory[265]=8'h0F;
        timeout_count=0; while(retired_count<5 && timeout_count<400) begin service(); timeout_count++; check(!unsupported_opcode,"mixed adjust/unary/TEST stream executable"); end
        check(retired_count==5 && deliveries==0 && data_count==0 && debug_ip==16'h0109 && debug_gpr[15:0]==16'h00FF && debug_flags==16'h0016,"mixed stream preserves result, status and fault ownership"); cases++;
        $display("ADJUST_LIFECYCLE PASS: %0d pause/cancel/reset/fault/frame/priority/stream cases; %0d checks",cases,checks);
        $finish;
    end
endmodule
