`timescale 1ns/1ps
module spk286_event_lifecycle_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory[0:1114111];
    integer checks=0, cases=0, ticks=0, retires=0, deliveries=0, acks=0, writes=0, timeout_count;
    integer wait_length=0, wait_count=0;
    // Real-mode instruction fetch wraps IP at FFFF. The no-wrap limit oracle
    // remains available with +real_mode_fetch_wrap=0.
    integer real_mode_fetch_wrap=1;
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
            // The INTA lock chain lasts through the first push or an aborted
            // entry. Exception replacement can replace that failed INTR entry with #GP/#DF;
            // semantic cancel releases the abandoned chain before dispatch.
            if (dut.event_cancel) chain=0;
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
    task automatic next_case;
`ifdef __ICARUS__
        if(cases==0 && trace_path!="") $dumpoff;
`endif
        execute_enable=0; cases=cases+1;
    endtask
    function automatic logic entry_stage(input integer stage);
        if(stage<12) entry_stage=debug_micro_active && debug_micro_pc==12'(spk286_microcode_pkg::MC_ENTRY_EVENT_ENTRY)+12'(stage);
        else if(stage==12) entry_stage=bus_valid && bus_write && address[0];
        else if(stage==13) entry_stage=bus_valid && bus_write && !address[0] && bus_bhe_n;
        else entry_stage=dut.stack_request && dut.memory_response_valid;
    endfunction
    function automatic logic return_stage(input integer stage);
        if(stage<5) return_stage=debug_micro_active && debug_micro_pc==12'(spk286_microcode_pkg::MC_ENTRY_INTERRUPT_RETURN)+12'(stage);
        else if(stage==5) return_stage=bus_valid && bus_status==5 && address[0];
        else if(stage==6) return_stage=bus_valid && bus_status==5 && !address[0] && bus_bhe_n;
        else return_stage=dut.stack_request && dut.memory_response_valid &&
                          debug_micro_pc==12'(spk286_microcode_pkg::MC_ENTRY_INTERRUPT_RETURN)+12'(stage-6);
    endfunction
    initial begin
        if ($value$plusargs("real_mode_fetch_wrap=%d",real_mode_fetch_wrap)) begin end
        check(real_mode_fetch_wrap==0 || real_mode_fetch_wrap==1,"valid declared real-mode fetch profile");
`ifdef __ICARUS__
        if($value$plusargs("trace=%s",trace_path)) begin $dumpfile(trace_path);$dumpvars(0,dut);end
`endif
        for(integer delay_value=0;delay_value<5;delay_value=delay_value+1) begin
            wait_length=delay_value;
            // The vector comes from the second low lane, even under HOLD.
            setup('h0202,'h0201); intr=1;
            timeout_count=0;
            while(acks<1 && timeout_count<500) begin service(); timeout_count=timeout_count+1; end
            check(acks==1,"first INTA accepted"); hold_request=1;
            while(!hlda && timeout_count<1000) begin service(); timeout_count=timeout_count+1; end
            check(hlda && acks==2 && first_push_done,"HOLD waits for both INTA and first odd frame word");
            repeat(4) service(); check(!bus_valid,"HLDA suspends new cycles"); hold_request=0;
            until_event(1,66);
            check(retires==0 && stackword('h01fb)==16'h0100 && stackword('h01fd)==16'h1000 && stackword('h01ff)==16'h0202,"INTR boundary frame");
            check(!bus_lock && acks==2,"no duplicate INTA"); next_case();

            setup(2,'h0200); memory[65792]=8'hFB; memory[65793]=8'hB8; memory[65794]=8'h78; memory[65795]=8'h56; memory[65796]=8'hF4; intr=1;
            until_event(1,66); check(retires==2 && debug_gpr[15:0]==16'h5678 && stackword('h01fa)==16'h0104,"STI shadow executes exactly following MOV"); next_case();

            setup(2,'h0200); memory[65792]=8'hFB; memory[65793]=8'hFA; memory[65794]=8'hF4; intr=1;
            until_retired(3); repeat(20) service();
            check(halted && deliveries==0 && acks==0 && !debug_flags[9],"STI CLI HLT keeps INTR masked"); next_case();

            setup(2,'h0200); memory[65792]=8'hFB; memory[65793]=8'hF4; intr=1;
            until_event(1,66); check(retires==2 && stackword('h01fa)==16'h0102 && !halted,"STI HLT wake saves next IP"); next_case();

            // Discriminators for the documented, provisional old-IF qualifier.
            setup('h0202,'h0200);memory[65792]=8'hFB;after_opcode();intr=1;
            until_event(1,66);check(retires==1 && stackword('h01fa)==16'h0101,"candidate STI with old IF one has no new shadow");next_case();
            setup(2,'h0200);memory[65792]=8'hFB;memory[65793]=8'hFB;intr=1;
            until_event(1,66);check(retires==2 && stackword('h01fa)==16'h0102,"candidate repeated STI expires first shadow");next_case();

            setup('h0102,'h0200);memory[65792]=8'hEB;memory[65793]=8'h10;
            until_event(1,1);check(retires==1 && stackword('h01fa)==16'h0112,"taken branch trap saves destination");next_case();
            setup('h0102,'h0200);memory[65792]=8'hCE;
            until_event(1,1);check(retires==1 && stackword('h01fa)==16'h0101,"untaken INTO preserves ordinary sampled trap");next_case();

            setup(2,'h0200); memory[65792]=8'h9D; putword(524800,'h0102);
            memory[65793]=8'hB8; memory[65794]=8'hEF; memory[65795]=8'hBE;
            until_event(1,1); check(retires==2 && debug_gpr[15:0]==16'hBEEF && stackword('h01fc)==16'h0104,"POPF newly set TF samples following instruction"); next_case();

            setup('h0102,'h0200); memory[65792]=8'h9D; putword(524800,2);
            until_event(1,1); check(retires==1 && stackword('h01fc)==16'h0101 && stackword('h0200)==2,"clearing sampled TF still traps with post-POPF FLAGS"); next_case();

            setup(2,'h0200); memory[65792]=8'h9D; putword(524800,'h0202); intr=1;
            until_event(1,66); check(retires==1 && stackword('h01fc)==16'h0101,"POPF IF has no STI shadow"); next_case();

            setup(2,'h0200); memory[65792]=8'hCF;
            putword(524800,'h0120); putword(524802,'h1000); putword(524804,'h0202); intr=1;
            until_event(1,66); check(retires==1 && stackword('h0200)==16'h0120,"IRET IF has no STI shadow"); next_case();

            setup('h0302,'h0200); after_opcode(); nmi=1; intr=1;
            until_event(1,1); check(retires==1 && debug_nmi_pending && acks==0,"TF precedes pending NMI and INTR after MOV");
            until_event(2,2); check(retires==1 && acks==0,"pending NMI precedes first handler instruction"); next_case();

            // One new edge is remembered while blocked; a held level is not.
            setup(2,'h0200); after_opcode(); nmi=1;
            until_event(1,2); check(retires==1 && debug_nmi_blocked,"NMI waits for current instruction");
            nmi=0; service(); nmi=1; service(); check(debug_nmi_pending,"second NMI edge latched while blocked");
            until_event(2,2); check(retires==2 && !debug_nmi_pending,"IRET releases pending NMI before resumed instruction");
            until_retired(4); repeat(15) service();
            check(deliveries==2 && halted && !debug_nmi_blocked,"held NMI cannot retrigger after second IRET"); next_case();

            // Synchronous destination #GP wins; the faulting instruction never retires.
            setup('h0102,'h0200); memory[65792]=8'h89; memory[65793]=8'h06; memory[65794]=8'hFF; memory[65795]=8'hFF;
            after_opcode(); nmi=1;
            until_event(1,13); check(retires==0 && stackword('h01fa)==16'h0100 && debug_nmi_pending,"precise source fault and retained NMI");
            until_event(2,2); check(retires==0,"fault does not create a false TF retirement trap"); next_case();

            // Invalid admitted group encodings remain #UD after far-memory admission.
            for(integer group_value=1;group_value<8;group_value=group_value+1) begin
                setup(2,'h0200); memory[65792]=8'h8F; memory[65793]=8'hC0+8'(group_value*8);
                until_event(1,6); check(retires==0 && stackword('h01fa)==16'h0100,"invalid POP group #UD start IP"); next_case();
            end
            setup(2,'h0200); memory[65792]=8'hFF; memory[65793]=8'hD8;
            until_event(1,6); check(retires==0,"far register form is invalid"); next_case();
            setup(2,'h0200); memory[65792]=8'hFF; memory[65793]=8'h1E;
            memory[65794]=8'h00; memory[65795]=8'h04;
            putword(262144+1024,'h0120); putword(262144+1026,'h1000); memory[65536+288]=8'hF4;
            until_retired(1);
            check(!unsupported_opcode && deliveries==0 && debug_ip==16'h0120 && debug_cs==16'h1000 &&
                  debug_gpr[79:64]==16'h01FC && stackword('h01FC)==16'h0104 && stackword('h01FE)==16'h1000 &&
                  debug_flags==2 && writes==2,"legal far memory CALL commits target and return link"); next_case();

            // A far CALL/RETF pair inside an NMI handler must retain NMI blocking;
            // only the following IRET releases the second captured NMI edge.
            setup(2,'h0200); after_opcode(); nmi=1; until_event(1,2);
            memory[65536+1040]=8'h9A; memory[65536+1041]=8'h00; memory[65536+1042]=8'h05;
            memory[65536+1043]=8'h00; memory[65536+1044]=8'h10; memory[65536+1045]=8'hCF;
            memory[65536+1280]=8'hCB;
            nmi=0; service(); nmi=1; service();
            until_retired(3);
            check(deliveries==1 && debug_nmi_pending && debug_nmi_blocked && debug_ip==16'h0415 &&
                  debug_gpr[79:64]==16'h01FA,"RETF preserves pending NMI inhibition through far call round trip");
            until_event(2,2); check(retires==4 && !debug_nmi_pending,"only IRET releases NMI after RETF"); next_case();
        end

        // Every possible external vector traverses actual INTA, including 2:
        // a vector number alone must not create NMI inhibition.
        for(integer vector_value=0;vector_value<256;vector_value=vector_value+1) begin
            wait_length=vector_value%5;setup('h0202,'h0200+(vector_value%2));
            ack_first=8'(vector_value^165);ack_second=8'(vector_value);intr=1;
            until_event(1,vector_value);
            check(acks==2 && retires==0 && !debug_nmi_blocked && debug_ip==16'(1024+vector_value*8),"all programmable INTA vectors preserve external event identity");next_case();
        end
        // An impossible INTR frame still completes the owned acknowledgement
        // pair and releases its LOCK chain when entry aborts; replacement
        // #GP/#DF delivery on this unusable stack eventually reaches shutdown.
        for(integer stack_value=1;stack_value<6;stack_value=stack_value+2) begin
            wait_length=2;setup('h0202,stack_value);intr=1;timeout_count=0;
            while(!shutdown && timeout_count<800) begin service();timeout_count=timeout_count+1;end
            check(shutdown && !halted && retires==0 && deliveries==0 && acks==2 && writes==stack_value-1 && debug_gpr[79:64]==1,"INTR shutdown preserves completed frame effects");
            chain=0;repeat(4) service();check(!bus_lock,"failed INTR entry releases acknowledgement lock chain");next_case();
        end

        // Pause every shared-entry stage. Responses can drain, architecture cannot advance.
        wait_length=2;
        for(integer stage=0;stage<15;stage=stage+1)
          for(integer action=0;action<3;action=action+1) begin
            setup(2,'h0201); memory[65792]=8'hCC;
            timeout_count=0;
            while(!entry_stage(stage) && timeout_count<700) begin service();timeout_count=timeout_count+1;end
            check(timeout_count<700,"reach each generated entry stage");
            execute_enable=0; saved_gpr=debug_gpr; saved_ip=debug_ip; saved_cs=debug_cs; saved_flags=debug_flags; saved_pc=debug_micro_pc;
            if(action==0) begin
                repeat(8) service();
                check(debug_gpr==saved_gpr && debug_ip==saved_ip && debug_cs==saved_cs && debug_flags==saved_flags && debug_micro_pc==saved_pc && retires==0 && deliveries==0,"paused event preserves committed state and context");
                execute_enable=1; until_event(1,3);
                check(retires==1 && stackword('h01fb)==16'h0101,"resume entry exactly once");
            end else if(action==1) begin
                memory[65824]=8'hBF;memory[65825]=8'hEF;memory[65826]=8'hBE;
                redirect=1; ip_write_en=1; ip_write_data=16'h0120; tick(); redirect=0; ip_write_en=0;
                check(!debug_micro_active && !dut.event_active && !event_completed && dut.micro_executor.temporary_valid_q==0 &&
                      !dut.micro_executor.flags_valid_q && !dut.micro_executor.target_valid_q,"debug cancel clears event dispatch and candidates");
                repeat(12) service();
                check(debug_gpr==saved_gpr && debug_cs==saved_cs && debug_flags==saved_flags && retires==0 && deliveries==0,"drained canceled word cannot commit stale event state");
                execute_enable=1; until_retired(1);
                check(debug_ip==16'h0123 && debug_gpr[127:112]==16'hBEEF && deliveries==0,"replacement stream after entry cancel");
            end else begin
                reset=1; waiting=0; chain=0; tick(); reset=0;
                check(debug_gpr==0 && debug_flags==2 && debug_cs_base==24'hFF0000 && debug_ip==16'hFFF0 && !dut.event_active && !event_completed && !bus_lock,"reset cancels each entry stage");
                repeat(5) service(); check(retires==0 && deliveries==0,"no late completion after reset");
            end
            next_case();
        end

        // IRET reads and context installation have the same pause/cancel/reset
        // coverage as entry, including both halves and held stack responses.
        wait_length=2;
        for(integer stage=0;stage<10;stage=stage+1)
          for(integer action=0;action<3;action=action+1) begin
            setup(2,'h0201);memory[65792]=8'hCF;
            putword(524801,'h0120);putword(524803,'h1030);putword(524805,'h0402);
            timeout_count=0;
            while(!return_stage(stage) && timeout_count<700) begin service();timeout_count=timeout_count+1;end
            check(timeout_count<700,"reach each IRET acquisition and commit stage");
            execute_enable=0;saved_gpr=debug_gpr;saved_ip=debug_ip;saved_cs=debug_cs;saved_flags=debug_flags;saved_pc=debug_micro_pc;
            if(action==0) begin
                repeat(8) service();
                check(debug_gpr==saved_gpr && debug_ip==saved_ip && debug_cs==saved_cs && debug_flags==saved_flags && debug_micro_pc==saved_pc && retires==0,"paused IRET preserves committed state");
                execute_enable=1;until_retired(1);
                check(debug_ip==16'h0120 && debug_cs==16'h1030 && debug_cs_base==24'h010300 && debug_flags==16'h0402 && debug_gpr[79:64]==16'h0207 && deliveries==0,"resumed IRET commits coherent context exactly once");
            end else if(action==1) begin
                memory[int'(debug_cs_base)+304]=8'hBF;memory[int'(debug_cs_base)+305]=8'hEF;memory[int'(debug_cs_base)+306]=8'hBE;
                redirect=1;ip_write_en=1;ip_write_data=16'h0130;tick();redirect=0;ip_write_en=0;
                repeat(12) service();
                check(debug_gpr==saved_gpr && debug_cs==saved_cs && debug_flags==saved_flags && retires==0 && deliveries==0 && dut.micro_executor.temporary_valid_q==0,"canceled IRET cannot install stale popped context");
                execute_enable=1;until_retired(1);
                check(debug_ip==16'h0133 && debug_gpr[127:112]==16'hBEEF,"replacement stream after IRET cancellation");
            end else begin
                reset=1;waiting=0;tick();reset=0;repeat(5) service();
                check(debug_gpr==0 && debug_flags==2 && debug_cs_base==24'hFF0000 && debug_ip==16'hFFF0 && retires==0 && deliveries==0,"reset cancels IRET at every stage");
            end
            next_case();
        end

        // Preserve a new edge coinciding with acceptance of an older pending NMI.
        setup(2,'h0200); execute_enable=0; nmi=1; service(); nmi=0; service();
        check(debug_nmi_pending,"paused NMI edge retained"); nmi=1; execute_enable=1;
        until_event(1,2); check(debug_nmi_pending,"simultaneous second edge survives acceptance");
        until_event(2,2); check(retires==1,"queued edge follows IRET without executing interrupted code"); next_case();

        // Candidate discriminator only: failed IRET/NMI needs physical 286
        // adjudication. Agreement here does not close the evidence gate.
        setup(2,'h0200); nmi=1; until_event(1,2); execute_enable=0;
        gpr_write_en=1;gpr_write_index=4;gpr_write_data=16'hFFFF;tick();gpr_write_en=0;
        nmi=0;service();nmi=1;service();execute_enable=1;
        until_event(2,13); check(retires==0 && !debug_nmi_blocked,"faulting IRET unblocks NMI without retirement");
        until_event(3,2); check(retires==0,"pending NMI follows faulting IRET delivery");next_case();

        // Debug cancellation drains both INTA cycles, discards the vector and
        // releases LOCK without issuing a frame for the abandoned request.
        for(integer acknowledged=0;acknowledged<2;acknowledged=acknowledged+1) begin
            setup('h0202,'h0200);intr=1;timeout_count=0;
            while(!(bus_valid && bus_status==0 && acks==acknowledged) && timeout_count<500) begin service();timeout_count=timeout_count+1;end
            check(timeout_count<500,"reach each INTA cancellation boundary");
            execute_enable=0; intr=0; redirect=1; ip_write_en=1; ip_write_data=16'h0120; tick();redirect=0;ip_write_en=0;
            // A canceled acknowledge intentionally has no first stack push.
            chain=0; waiting=0;
            repeat(30) begin ready=bus_valid; tick(); if(acks==2) chain=0; end
            check(acks==2 && !bus_lock && writes==0 && deliveries==0 && retires==0,"canceled INTA drains without frame/vector completion");next_case();
        end

        // Demanded code byte fault versus harmless speculative limit exhaustion.
        setup(2,'h0200); execute_enable=0; redirect=1; ip_write_en=1; ip_write_data=16'hFFFE; tick(); redirect=0;ip_write_en=0;
        memory[131070]=8'hB8; memory[131071]=8'h12;
        if(real_mode_fetch_wrap!=0) memory[65536]=8'h34;
        execute_enable=1;
        if(real_mode_fetch_wrap!=0) begin
            until_retired(1);
            check(deliveries==0 && debug_ip==1 && debug_gpr[15:0]==16'h3412 && writes==0 &&
                  debug_gpr[79:64]=='h0200,"PCAT real-mode IP wrap supplies the complete immediate without a fault/frame");
        end else begin
            until_event(1,13);
            check(retires==0 && debug_gpr[15:0]==16'hA500 && stackword('h01fa)==16'hFFFE,
                  "code fault saves opcode start without partial immediate");
        end
        next_case();
        setup(2,'h0200); execute_enable=0; redirect=1; ip_write_en=1; ip_write_data=16'hFFFD; tick(); redirect=0;ip_write_en=0;
        memory[131069]=8'hE9; memory[131070]=0; memory[131071]=1; execute_enable=1;
        until_retired(1); check(deliveries==0 && debug_ip==16'h0100,"taken branch cancels exhausted speculative fetch"); next_case();

        // A completed instruction's pending trap precedes demand for another
        // opcode, independently of a pause after retirement at the CS limit.
        for(integer pause_after=0;pause_after<2;pause_after=pause_after+1) begin
            setup('h0102,'h0200); execute_enable=0;
            memory[131071]=8'hFA;
            redirect=1;ip_write_en=1;ip_write_data=16'hFFFF;tick();redirect=0;ip_write_en=0;
            execute_enable=1;until_retired(1);
            if(pause_after!=0) begin execute_enable=0;repeat(6) service();execute_enable=1;end
            until_event(1,1);
            check(stackword('h01fa)==0 && retires==1,"pause preserves already owed trap before next opcode demand");next_case();
        end

        // Shutdown is not HLT; INTR cannot recover it, NMI and reset can.
        setup('h0202,1); memory[65792]=8'hCC;
        timeout_count=0; while(!shutdown && timeout_count<500) begin service();timeout_count=timeout_count+1;end
        check(shutdown && !halted && retires==0 && deliveries==0,"impossible frame enters shutdown"); intr=1;
        repeat(15) service(); check(acks==0 && shutdown,"shutdown ignores INTR");
        execute_enable=0; gpr_write_en=1;gpr_write_index=4;gpr_write_data=16'h0200;tick();gpr_write_en=0;execute_enable=1;nmi=1;
        until_event(1,2); check(!shutdown && !halted,"NMI recovers shutdown with usable stack");
        reset=1; waiting=0; chain=0; tick(); reset=0;
        check(!shutdown && !halted && !debug_nmi_pending && !debug_nmi_blocked && debug_cs_base==24'hFF0000 && debug_ip==16'hFFF0,"reset clears event state and restores special CS cache"); next_case();
        check(cases==468,"complete lifecycle scenario set");
        $display("EVENT_LIFECYCLE PASS: %0d scenarios; %0d checks",cases,checks);
        $finish;
    end
endmodule
