// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module spk286_segment_lifecycle_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory[0:1114111];
    integer checks=0, cases=0, ticks=0, retires=0, deliveries=0, acks=0, writes=0, timeout_count;
    integer wait_length=0, wait_count=0;
    logic waiting=0, chain=0, first_push_done=0;
    logic [23:0] held_address;
    logic [15:0] held_data;
    logic [3:0] held_status;
    logic held_bhe, held_write, held_lock;
    logic [127:0] saved_gpr;
    logic [15:0] saved_ip, saved_flags, saved_cs;
    logic [11:0] saved_pc;
    logic [7:0] ack_first=8'h99, ack_second=8'h42;
`ifdef __ICARUS__
    string trace_path;
`endif
    spk286 dut(.*);
    task automatic check(input logic ok,input string message);
        checks=checks+1;
        if(ok!==1'b1) $fatal(1,"%s case=%0d IP=%h CS=%h flags=%h SP=%h pc=%h retires=%0d events=%0d vector=%0d acks=%0d",
            message,cases,debug_ip,debug_cs,debug_flags,debug_gpr[79:64],debug_micro_pc,retires,deliveries,debug_event_vector,acks);
    endtask
    task automatic putword(input integer address_value,input integer word_value);
        memory[address_value]=8'(word_value); memory[address_value+1]=8'(word_value>>8);
    endtask
    function automatic logic [15:0] stackword(input integer offset);
        stackword={memory[524288+offset+1],memory[524288+offset]};
    endfunction
    task automatic tick;
        #1; data_in=16'h0F0F;
        if(bus_valid && address<24'd1114112) data_in={memory[{address[20:1],1'b1}],memory[{address[20:1],1'b0}]};
        if(bus_valid && bus_status==0) begin
            // READY-low vector changes are noise; only the accepted second
            // low byte is meaningful. High lanes deliberately disagree.
            data_in=acks==0 ? {8'hB7,ack_first} : {8'hE7,(ready ? ack_second : ~ack_second)};
            check(!data_oe && !bus_write && bus_bhe_n && address==0 && bus_lock,"physical INTA protocol and low vector lane");
        end
        #4;
        if(!reset) begin
            if(chain) check(bus_lock && !hlda && !(bus_valid && bus_status==13),"INTA chain retains bus through first push");
            if(bus_valid && ready && bus_status==0) begin acks=acks+1; chain=1; end
            if(bus_valid && ready && bus_write) begin
                writes=writes+1;
                if(address[0]) memory[address[20:0]]=data_out[15:8];
                else begin
                    memory[address[20:0]]=data_out[7:0];
                    if(!bus_bhe_n) memory[address+1]=data_out[15:8];
                    if(chain) begin chain=0; first_push_done=1; end
                end
            end
        end
        clk=1; #5; clk=0; #1; ticks=ticks+1;
        if(instruction_retired) retires=retires+1;
        if(event_completed) deliveries=deliveries+1;
        check(!microcode_fault && debug_prefetch_count<=6,"event lifecycle invariants");
    endtask
    task automatic service;
        #1;
        if(waiting) check(bus_valid && address==held_address && data_out==held_data && bus_status==held_status &&
                          bus_bhe_n==held_bhe && bus_write==held_write && bus_lock==held_lock,"READY holds complete transaction metadata");
        ready=bus_valid && wait_count>=wait_length;
        waiting=bus_valid && !ready;
        if(waiting) begin
            wait_count=wait_count+1; held_address=address; held_data=data_out; held_status=bus_status;
            held_bhe=bus_bhe_n; held_write=bus_write; held_lock=bus_lock;
        end else wait_count=0;
        tick();
    endtask
    task automatic setup(input integer flags_value,input integer stack_value);
        execute_enable=0; reset=1; ready=0; intr=0; nmi=0; hold_request=0;
        ack_first=8'h99;ack_second=8'h42;
        gpr_write_en=0; flags_write_en=0; segment_load_en=0; redirect=0; ip_write_en=0;
        waiting=0; chain=0; first_push_done=0; wait_count=0;
        tick(); reset=0;
        for(integer r=0;r<8;r=r+1) begin
            gpr_write_en=1; gpr_write_index=3'(r); gpr_write_data=r==4 ? 16'(stack_value) : 16'hA500+16'(r); tick();
        end
        gpr_write_en=0; flags_write_en=1; flags_write_mask=16'hFFFF; flags_write_data=16'(flags_value); tick(); flags_write_en=0;
        for(integer s=0;s<4;s=s+1) begin
            segment_load_en=1; segment_load_index=2'(s); segment_load_selector=s==1 ? 16'h1000 : (s==2 ? 16'h8000 : 16'h4000);
            redirect=s==1; ip_write_en=s==1; ip_write_data=16'h0100; tick();
        end
        segment_load_en=0; redirect=0; ip_write_en=0;
        for(integer a=256;a<320;a=a+1) memory[65536+a]=8'h0F;
        for(integer v=0;v<256;v=v+1) begin
            putword(v*4,'h0400+v*8); putword(v*4+2,'h1000);
            memory[65536+1024+v*8]=8'hCF;
            memory[65536+1024+v*8+1]=8'h0F;
        end
        memory[65792]=8'hB8; memory[65793]=8'h34; memory[65794]=8'h12; memory[65795]=8'hF4;
        retires=0; deliveries=0; acks=0; writes=0; execute_enable=1;
    endtask
    task automatic until_event(input integer target,input integer vector_value);
        timeout_count=0;
        while(deliveries<target && timeout_count<1600) begin service(); timeout_count=timeout_count+1; end
        check(deliveries==target && int'(debug_event_vector)==vector_value && !shutdown,"complete selected event");
        check(debug_cs==16'h1000 && debug_cs_base==24'h010000,"ordinary handler CS cache");
    endtask
    task automatic until_retired(input integer target);
        timeout_count=0;
        while(retires<target && timeout_count<1600) begin service(); timeout_count=timeout_count+1; end
        check(retires==target,"bounded instruction retirement");
    endtask
    task automatic after_opcode;
        timeout_count=0;
        while(!(debug_micro_active && debug_ip==16'h0101) && timeout_count<300) begin service();timeout_count=timeout_count+1;end
        check(timeout_count<300,"opcode context captured before event edge");
    endtask
    function automatic logic [15:0] absolute_word(input integer address_value);
        absolute_word={memory[address_value+1],memory[address_value]};
    endfunction
    task automatic wait_opcode(input logic [7:0] wanted);
        timeout_count=0;
        while(!(debug_micro_active && debug_opcode==wanted) && timeout_count<200)begin service();timeout_count++;end
        check(timeout_count<200,"capture segment instruction before asynchronous event");
    endtask
    task automatic set_ax(input logic [15:0] value);
        execute_enable=0;gpr_write_en=1;gpr_write_index=0;gpr_write_data=value;tick();gpr_write_en=0;execute_enable=1;
    endtask
    task automatic segment_stream(input integer pop,input integer flags_value,input integer prefix_count,input integer new_sp);
        setup(flags_value,'h0200);set_ax(16'h7000);
        for(integer p=0;p<prefix_count;p++)memory[65792+p]=p==0?8'hF3:8'h26;
        if(pop!=0)begin
            memory[65792+prefix_count]=8'h17;memory[65793+prefix_count]=8'h5C;memory[65794+prefix_count]=8'h0F;
            putword('h80200,'h7000);putword('h70202,new_sp);
            // The same offset in old SS must not feed the following POP SP.
            putword('h80202,'hDEAD);
        end else begin
            memory[65792+prefix_count]=8'h8E;memory[65793+prefix_count]=8'hD0;
            memory[65794+prefix_count]=8'hBC;putword(65795+prefix_count,new_sp);memory[65797+prefix_count]=8'h0F;
        end
    endtask
    task automatic check_new_frame(input integer flags_value,input integer new_sp,input integer next_ip,input integer expected_retires);
        check(retires==expected_retires && debug_gpr[79:64]==16'(new_sp-6) && debug_segment_selectors[47:32]==16'h7000 &&
              debug_segment_bases[71:48]==24'h070000,"SS cache and protected stack-pointer update precede event");
        check(absolute_word('h70000+new_sp-6)==16'(next_ip) && absolute_word('h70000+new_sp-4)==16'h1000 &&
              absolute_word('h70000+new_sp-2)==16'(flags_value),"event uses new SS:SP and complete unmasked frame");
        check(!dut.events.ss_shadow,"protected boundary releases SS shadow");
    endtask
    task automatic wait_cache_stage(input integer stage);
        timeout_count=0;
        while(!(debug_micro_active && debug_micro_instruction==spk286_microcode_pkg::MC_WRITE_SEG16_TMP0) && timeout_count<250)begin service();timeout_count++;end
        check(timeout_count<250 && retires==0,"segment cache write follows acquired source");
        if(stage!=0)begin service();check(debug_micro_instruction==spk286_microcode_pkg::MC_END && dut.events.ss_shadow,"successful SS commit arms shadow before END");end
    endtask
    initial begin
        for(integer i=0;i<1114112;i++)memory[i]=8'h0F;
        for(integer pop=0;pop<2;pop++)for(integer event_mode=0;event_mode<4;event_mode++)for(integer delay=0;delay<3;delay++)begin
            integer initial_status,desired_vector,new_sp,prefix_count,next_ip;
            wait_length=delay;prefix_count=delay==0?0:2;new_sp='h0300+(delay%2);
            initial_status=event_mode==0?2:event_mode==1?'h0202:event_mode==2?'h0102:'h0302;
            desired_vector=event_mode>=2?1:event_mode==0?2:66;
            segment_stream(pop,initial_status,prefix_count,new_sp);wait_opcode(pop!=0?8'h17:8'h8E);
            nmi=event_mode==0 || event_mode==3;intr=event_mode==1 || event_mode==3;
            until_event(1,desired_vector);next_ip='h0100+prefix_count+(pop!=0?2:5);
            check_new_frame(initial_status,new_sp,next_ip,2);
            check(acks==(event_mode==1?2:0),"SS shadow preserves NMI/TF/INTR arbitration and acknowledgement count");
            if(event_mode==3)check(debug_nmi_pending,"trap after protected instruction retains pending NMI");
            cases++;
        end
        // Pauses hold cache and shadow ownership; cancel/reset discard only the
        // transient state and retain any already committed architectural cache/SP.
        for(integer pop=0;pop<2;pop++)for(integer stage=0;stage<2;stage++)for(integer action=0;action<3;action++)begin
            wait_length=1;segment_stream(pop,2,2,'h0301);wait_cache_stage(stage);
            saved_gpr=debug_gpr;saved_flags=debug_flags;saved_pc=debug_micro_pc;
            if(action==0)begin
                execute_enable=0;nmi=1;
                repeat(6)begin service();check(debug_gpr==saved_gpr && debug_flags==saved_flags && debug_micro_pc==saved_pc &&
                    debug_segment_selectors[47:32]==(stage==0?16'h8000:16'h7000) && dut.events.ss_shadow==(stage!=0) && deliveries==0 && retires==0,"paused segment cache and shadow remain owned");end
                execute_enable=1;until_event(1,2);check_new_frame(2,'h0301,'h0102+(pop!=0?2:5),2);
            end else if(action==1)begin
                execute_enable=0;nmi=0;intr=0;redirect=1;ip_write_en=1;ip_write_data=16'h0200;tick();redirect=0;ip_write_en=0;
                check(!dut.events.ss_shadow && !dut.event_active && debug_gpr==saved_gpr &&
                    debug_segment_selectors[47:32]==(stage==0?16'h8000:16'h7000),"cancel preserves committed segment/SP and clears inhibition");
                memory[66048]=8'hB8;putword(66049,'hBEEF);memory[66051]=8'h0F;execute_enable=1;until_retired(1);
                check(debug_ip==16'h0203 && debug_gpr[15:0]==16'hBEEF && deliveries==0,"canceled cache write cannot escape into new stream");
            end else begin
                reset=1;ready=1;tick();check(debug_gpr==0 && debug_flags==2 && debug_cs_base==24'hFF0000 && debug_ip==16'hFFF0 &&
                    !dut.events.ss_shadow && !dut.internal_segment_write,"reset clears cache-write request and SS inhibition");
                reset=0;execute_enable=0;ready=0;tick();check(bus_valid && address==24'hFFFFF0,"segment reset resumes native reset fetch");
            end
            cases++;
        end
        for(integer delay=0;delay<2;delay++)begin
            wait_length=delay;
            // A failed source read cannot load SS or arm a shadow.
            setup('h0202,'h0200);set_ax(16'h7000);
            memory[65792]=8'h8E;memory[65793]=8'h16;memory[65794]=8'hFF;memory[65795]=8'hFF;memory[65796]=8'h0F;
            wait_opcode(8'h8E);nmi=1;until_event(1,13);
            check(retires==0 && debug_segment_selectors[47:32]==16'h8000 && !dut.events.ss_shadow && debug_nmi_pending &&
                stackword('h01fa)==16'h0100 && stackword('h01fe)==16'h0202,"faulting SS load keeps old cache and precise frame without inhibition");cases++;
            // A synchronous fault in the protected following instruction wins.
            segment_stream(0,'h0202,0,'h0300);
            memory[65794]=8'hA1;memory[65795]=8'hFF;memory[65796]=8'hFF;memory[65797]=8'h0F;
            wait_opcode(8'h8E);nmi=1;until_event(1,13);
            check_new_frame('h0202,'h0200,'h0102,1);check(debug_nmi_pending,"following fault retains pending NMI");cases++;
        end
        // Successful repeated SS loads renew the documented next-instruction
        // protection; a fault does not acquire that ownership.
        wait_length=1;segment_stream(0,2,0,'h0300);
        memory[65794]=8'h8E;memory[65795]=8'hD0;memory[65796]=8'hBC;putword(65797,'h0301);memory[65799]=8'h0F;
        wait_opcode(8'h8E);nmi=1;until_event(1,2);check_new_frame(2,'h0301,'h0107,3);cases++;
        // A later ordinary operand must consult the newly loaded DS cache.
        setup(2,'h0200);set_ax(16'h7000);
        memory[65792]=8'h26;memory[65793]=8'h8E;memory[65794]=8'hD8;
        memory[65795]=8'hA1;memory[65796]=8'h10;memory[65797]=8'h10;memory[65798]=8'h0F;
        putword('h71010,'hABCD);putword('h41010,'h5678);putword('h21010,'hDEAD);
        until_retired(2);check(debug_ip==16'h0106 && debug_gpr[15:0]==16'hABCD && debug_segment_selectors[63:48]==16'h7000 &&
            debug_flags==2 && deliveries==0,"new DS cache owns later operand and previous override expires");cases++;
        $display("SEGMENT_LIFECYCLE PASS: %0d shadow/pause/cancel/reset/fault/cache/stream cases; %0d checks",cases,checks);$finish;
    end
endmodule
