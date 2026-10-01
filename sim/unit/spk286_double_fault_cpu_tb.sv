`timescale 1ns/1ps
// H11 oracle: Intel 286 PRM 9.6.2 / B-8 / 11.6. Executable LOADALL
// enters the fixture; all exceptions then travel through normal CPU services.
module spk286_double_fault_cpu_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    integer checks=0,cases=0,ticks=0,events_seen=0,acks=0,writes=0,retires=0;
    integer faults=0,frame_writes=0;
    logic observe=0;
    logic [127:0] original_gpr;
    logic [15:0] source_flags;
    spk286 dut(.*);
    task automatic check(input logic ok,input string message);
        checks++;
        if(ok!==1'b1) $fatal(1,"DF_CPU %s case=%0d CS:IP=%h:%h SP=%h TR=%h vector=%d error=%b/%h shutdown=%b events=%0d faults=%0d pc=%h",
            message,cases,debug_cs,debug_ip,debug_gpr[79:64],debug_tr_selector,
            debug_event_vector,debug_event_error_valid,debug_event_error_code,shutdown,events_seen,faults,debug_micro_pc);
    endtask
    task automatic word_at(input integer a,input logic[15:0] v);
        memory[a]=v[7:0];memory[a+1]=v[15:8];
    endtask
    function automatic logic[15:0] word_read(input integer a);
        word_read={memory[a+1],memory[a]};
    endfunction
    task automatic cache(input integer a,input logic[15:0] base_addr,input logic[7:0] ar,input logic[15:0] limit_value);
        word_at(a,base_addr);word_at(a+2,{ar,8'd0});word_at(a+4,limit_value);
    endtask
    task automatic descriptor(input integer a,input logic[15:0] base_addr,input logic[7:0] ar);
        word_at(a,'h2B);word_at(a+2,base_addr);word_at(a+4,{ar,8'd0});word_at(a+6,0);
    endtask
    task automatic gate(input integer v,input logic[7:0] ar,input logic[15:0] selector,input logic[15:0] target);
        word_at('h1400+8*v,target);word_at('h1402+8*v,selector);
        word_at('h1404+8*v,{ar,8'd0});word_at('h1406+8*v,0);
    endtask
    task automatic tick;
        #1;
        ready=bus_valid && ticks%5!=2;
        data_in=0;
        if(bus_valid && !bus_write) begin
            if(address[0]) data_in={memory[address[15:0]],8'd0};
            else data_in={memory[{address[15:1],1'b1}],memory[{address[15:1],1'b0}]};
        end
        if(bus_valid && bus_status==0) data_in='hB720;
        if(observe) begin
            if(dut.event_request) events_seen++;
            if(dut.events.entry_failure) faults++;
        end
        if(bus_valid && ready && !reset) begin
            if(bus_status==0) acks++;
            if(bus_write) begin
                writes++;
                if(address[0]) memory[address[15:0]]=data_out[15:8];
                else begin
                    memory[address[15:0]]=data_out[7:0];
                    if(!bus_bhe_n) memory[address[15:0]+16'd1]=data_out[15:8];
                end
                if(address>='h1F00 && address<'h3000) frame_writes++;
            end
        end
        #4;clk=1;#5;clk=0;#1;ticks++;
        if(observe && instruction_retired) retires++;
    endtask
    task automatic setup(input logic[1:0] policy,input integer origin,input integer first_vector,input logic bad_df);
        integer deadline,pos;
        reset=1;execute_enable=0;observe=0;intr=0;nmi=0;hold_request=0;
        redirect=0;segment_load_en=0;ip_write_en=0;timing_policy_request=policy;
        repeat(3) tick();
        for(integer a=0;a<65536;a++) memory[a]=0;
        memory[0]='h0F;memory[1]='h05;
        source_flags=origin==4 ? 'h0246 : 'h0046;
        word_at('h806,origin==2 ? 'h0005 : 'h0001); // EM for #NM.
        word_at('h816,'h28);word_at('h818,source_flags);word_at('h81A,'h100);
        word_at('h81E,'h20);word_at('h820,'h20);word_at('h822,'h18);word_at('h824,'h20);
        for(integer r=0;r<8;r++) word_at('h826+2*r,16'h6000+16'(r));
        word_at('h82C,'h2000);
        cache('h836,0,'h93,'hFFFF);cache('h83C,0,'h9B,'hFFFF);
        cache('h842,0,'h93,'hFFFF);cache('h848,0,'h93,'hFFFF);
        cache('h84E,'h1000,0,'h37);cache('h85A,'h1400,0,'h1FF);
        cache('h860,'h4000,'h83,'h2B);
        descriptor('h1018,0,'h9B);word_at('h1018,'hFFFF);
        descriptor('h1020,0,'h93);word_at('h1020,'hFFFF);
        descriptor('h1028,'h4000,'h83);descriptor('h1030,'h5000,'h81);
        for(integer v=0;v<64;v++) gate(v,'h86,'h18,'h300);
        gate(first_vector,'h06,'h18,'h300); // not present -> #NP.
        gate(8,bad_df ? 'h05 : 'h85,'h30,0);
        if(origin==2) gate(7,'h93,'h18,'h300); // invalid IDT type -> #GP(3B).
        if(origin==5) gate(8,'h06,'h18,'h300); // software INT8, not #DF.
        word_at('h500E,'h400);word_at('h5010,'h0202);
        for(integer r=0;r<8;r++) word_at('h5012+2*r,16'h7000+16'(r));
        word_at('h501A,'h3000);word_at('h5022,'h20);word_at('h5024,'h18);
        word_at('h5026,'h20);word_at('h5028,'h20);word_at('h502A,0);
        for(integer a='h1FE0;a<'h2000;a++) memory[a]='hA5;
        word_at('h2FFE,'hA5A5);memory['h300]='h90;memory['h400]='h90;
        pos='h100;memory[pos]='hF3;pos++;
        if(origin==1) begin memory[pos]='h0F;memory[pos+1]='h0B;end
        else if(origin==5) begin memory[pos]='hCD;memory[pos+1]='h08;end
        else begin memory[pos]='hD8;memory[pos+1]='h06;word_at(pos+2,'hFFFF);end
        reset=0;segment_load_en=1;segment_load_index=1;segment_load_selector=0;
        redirect=1;ip_write_en=1;ip_write_data=0;tick();
        segment_load_en=0;redirect=0;ip_write_en=0;execute_enable=1;
        deadline=0;
        while(!(instruction_retired && debug_ip=='h100) && deadline<2000) begin tick();deadline++;end
        check(deadline<2000 && debug_protected_msw[0] && debug_tr_selector=='h28,"LOADALL fixture enters PM/current TSS");
        original_gpr=debug_gpr;
        events_seen=0;acks=0;writes=0;retires=0;faults=0;frame_writes=0;observe=1;
        if(origin==3) nmi=1;
        if(origin==4) intr=1;
    endtask
    task automatic until_result(input logic want_shutdown);
        integer deadline;
        deadline=0;
        while(!(want_shutdown ? shutdown : event_completed) && !unsupported_opcode && deadline<2400) begin tick();deadline++;end
        check(deadline<2400 && !unsupported_opcode && !microcode_fault,"bounded event chain");
    endtask
    task automatic df_task(input logic[1:0] policy);
        setup(policy,0,13,0);until_result(0);
        check(!shutdown && debug_event_vector==8 && debug_event_error_valid && debug_event_error_code==0 &&
              debug_tr_selector=='h30 && debug_ip=='h400 && debug_flags[14] &&
              debug_gpr[79:64]=='h2FFE && events_seen==2 && faults==1 && retires==0 && acks==0,
              "#GP then #NP enters dedicated #DF task once with zero error word");
        check(word_read('h5000)=='h28 && memory['h1035]=='h83 && memory['h102D]=='h83 &&
              word_read('h2FFE)==0 && frame_writes==1,"backlink/busy descriptors and exactly one zero push on target stack");
        check(word_read('h400E)=='h100 && word_read('h4010)==source_flags &&
              word_read('h4012)==original_gpr[15:0] && word_read('h401A)=='h2000 &&
              word_read('h4024)=='h18 && word_read('h4026)=='h20,"outgoing TSS contains original prefixed fault context");
        check(word_read('h1FFE)=='hA5A5 && word_read('h1FF8)=='hA5A5,"failed early entry leaves source frame untouched");
        execute_enable=0;cases++;
    endtask
    task automatic benign(input logic[1:0] policy,input integer origin);
        integer first_vector,final_vector,expected_error;
        first_vector=origin==1 ? 6 : origin==2 ? 7 : origin==3 ? 2 : origin==4 ? 32 : 8;
        final_vector=origin==2 ? 13 : 11;
        expected_error=first_vector*8+2+(origin>=2 && origin<=4 ? 1 : 0);
        setup(policy,origin,first_vector,0);until_result(0);
        check(!shutdown && debug_event_vector==8'(final_vector) && debug_event_error_valid &&
              debug_event_error_code==16'(expected_error) && events_seen==2 && faults==1 && retires==0 &&
              debug_ip=='h300 && debug_gpr[79:64]=='h1FF8,"benign/software/external origin delivers second exception instead of #DF");
        check(word_read('h1FF8)==16'(expected_error) && word_read('h1FFA)=='h100 &&
              word_read('h1FFC)=='h18 && word_read('h1FFE)==source_flags && frame_writes==4 &&
              acks==(origin==4 ? 2 : 0),"exact restart frame, retained EXT and no duplicate INTA");
        execute_enable=0;cases++;
    endtask
    task automatic shutdown_recovery(input logic[1:0] policy,input logic fail_nmi);
        setup(policy,0,13,1);until_result(1);
        repeat(5) tick();
        check(shutdown && !halted && !bus_valid && bus_status==4 && address[1]==0 &&
              frame_writes==0 && events_seen==2 && faults==2 && retires==0,"failed #DF enters CPU shutdown with A1 low and no frame");
        intr=1;repeat(10) tick();check(shutdown && acks==0,"shutdown ignores INTR");intr=0;
        gate(2,fail_nmi ? 'h06 : 'h86,'h18,'h300);nmi=1;tick();nmi=0;
        if(fail_nmi) begin
            until_result(1);repeat(5) tick();gate(2,'h86,'h18,'h300);
            nmi=1;repeat(5) tick();nmi=0;repeat(8) tick();
            check(shutdown && events_seen==3 && !event_completed && debug_protected_msw[0],"failed recovery NMI requires RESET despite repaired gate/new edge");
        end else begin
            until_result(0);check(!shutdown && debug_ip=='h300 && debug_event_vector==2 &&
                !debug_event_error_valid && debug_protected_msw[0] && debug_gpr[79:64]=='h1FFA,
                "successful NMI recovery retains PE and has ordinary no-error frame");
        end
        reset=1;tick();reset=0;execute_enable=0;
        check(!shutdown && !dut.event_active && !debug_nmi_blocked && !debug_nmi_pending &&
              debug_protected_msw=='hFFF0 && debug_cs_base=='hFF0000 && debug_ip=='hFFF0,
              "RESET clears chain, recovery lock and protected mode");cases++;
    endtask
    task automatic lifecycle(input logic[1:0] policy,input logic cancel_chain);
        integer deadline,old_events;
        logic[127:0] saved_gpr;
        setup(policy,0,13,0);deadline=0;
        while(!(dut.events.entry_failure) && deadline<1000) begin tick();deadline++;end
        check(deadline<1000 && debug_event_vector==13,"reach #NP during #GP delivery before acceptance");
        execute_enable=0;saved_gpr=debug_gpr;old_events=events_seen;repeat(7) tick();
        check(events_seen==old_events && debug_event_vector==13 && debug_gpr==saved_gpr &&
              !shutdown && frame_writes==0,"pause prevents pending replacement and architectural writes");
        if(cancel_chain) begin
            memory['h400]='hB8;word_at('h401,'hBEEF);
            redirect=1;ip_write_en=1;ip_write_data='h400;tick();redirect=0;ip_write_en=0;
            execute_enable=1;deadline=0;
            while(!(instruction_retired && debug_gpr[15:0]=='hBEEF) && deadline<1000) begin tick();deadline++;end
            check(deadline<1000 && !shutdown && !dut.event_active && debug_ip=='h403 &&
                  debug_gpr[79:64]=='h2000 && events_seen==1 && faults==0 && retires==1,
                  "redirect cancels failed service and runs replacement stream without stale #DF");
        end else begin
            execute_enable=1;until_result(0);
            check(debug_event_vector==8 && debug_tr_selector=='h30 && debug_gpr[79:64]=='h2FFE &&
                  events_seen==2 && frame_writes==1,"resume enters dedicated #DF task exactly once");
        end
        execute_enable=0;cases++;
    endtask
    task automatic handler_fault(input logic[1:0] policy);
        setup(policy,1,6,0);gate(6,'h86,'h18,'h300);gate(13,'h86,'h18,'h400);
        memory['h300]='hD8;memory['h301]='h06;word_at('h302,'hFFFF);
        until_result(0);check(debug_event_vector==6 && debug_ip=='h300,"first handler entered successfully");
        tick();until_result(0);
        check(!shutdown && debug_event_vector==13 && debug_ip=='h400 && events_seen==2 && faults==0 &&
              debug_gpr[79:64]=='h1FF2 && word_read('h1FF2)==0 && word_read('h1FF4)=='h300,
              "fault in handler instruction stream is a new #GP, not #DF");
        execute_enable=0;cases++;
    endtask
    task automatic df_stack_failure(input logic[1:0] policy);
        setup(policy,0,13,0);word_at('h501A,1);until_result(1);repeat(5) tick();
        check(debug_tr_selector=='h30 && debug_ip=='h400 && debug_gpr[79:64]==1 &&
              debug_event_vector==8 && faults==2 && events_seen==2 && frame_writes==0 &&
              word_read('h400E)=='h100 && word_read('h5000)=='h28,
              "fault pushing #DF error after task handoff shuts down and retains completed TSS effects");
        check(!bus_valid && bus_status==4 && address[1]==0,"post-handoff shutdown has A1 low");
        nmi=1;tick();nmi=0;
        check(!shutdown && dut.event_active && debug_event_vector==2,
              "SS handoff shadow does not prevent post-task shutdown recovery NMI acceptance");
        until_result(1);
        check(shutdown && events_seen==3 && faults==3 && frame_writes==0,
              "recovery NMI on the still-invalid target stack fails into reset-only shutdown");
        execute_enable=0;cases++;
    endtask
    task automatic nmi_origin_recovery(input logic[1:0] policy);
        setup(policy,3,2,1);gate(11,'h06,'h18,'h300);until_result(1);
        nmi=0;repeat(5) tick();
        check(shutdown && !debug_nmi_blocked && events_seen==3 && faults==3 && frame_writes==0,
              "NMI/#NP/#DF failure clears original NMI block for shutdown recovery");
        gate(2,'h86,'h18,'h300);nmi=1;tick();nmi=0;until_result(0);
        check(!shutdown && debug_event_vector==2 && events_seen==4 && debug_nmi_blocked &&
              debug_ip=='h300 && debug_gpr[79:64]=='h1FFA && debug_protected_msw[0],
              "fresh NMI exits shutdown after an NMI-origin failed chain");
        execute_enable=0;cases++;
    endtask
    initial begin
        for(integer policy=0;policy<=2;policy+=2) begin
            df_task(2'(policy));
            for(integer origin=1;origin<=5;origin++) benign(2'(policy),origin);
            shutdown_recovery(2'(policy),0);shutdown_recovery(2'(policy),1);
            lifecycle(2'(policy),0);lifecycle(2'(policy),1);handler_fault(2'(policy));
            df_stack_failure(2'(policy));
            nmi_origin_recovery(2'(policy));
        end
        $display("DOUBLE_FAULT_CPU PASS: %0d checks / %0d cases",checks,cases);$finish;
    end
endmodule
