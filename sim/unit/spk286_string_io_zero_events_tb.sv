// SPDX-License-Identifier: MIT
// Synthetic contract coverage for zero-count REP string I/O and pending events.
`timescale 1ns/1ps
module spk286_string_io_zero_events_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    integer checks=0,cases=0,retired_count=0,deliveries=0,writes=0,reads=0,acks=0;
    integer timeout_count,waits=0,delay_length=0,entry_address,entry_length,next_ip;
    logic [127:0] initial_gpr,expected_gpr,saved_gpr;
    logic [63:0] expected_segments,saved_segments;
    logic [15:0] initial_flags,saved_flags,expected_flags;
    integer iteration_boundaries=0;
    integer port_requests=0,port_cycles=0,saved_requests=0,port_halves=1,expected_elements=0;
    logic port_odd,port_writing,port_word;
    logic [11:0] saved_pc;
    logic changing_input=0;
    logic [15:0] sample_word;
    // Advance stimulus only after accepted physical transfers. Both halves of
    // an odd word use the same sample; READY waits cannot consume a sample.
    function automatic logic [15:0] input_sample(input integer element);
        input_sample=16'h5AA5 ^ (16'h172D * 16'(element+1));
    endfunction
    spk286 dut (.*);
    task automatic check(input logic condition,input string message);
        checks++;
        if(condition!==1'b1)$fatal(1,"%s case=%0d CS:IP=%h:%h pc=%h SP=%h retired=%0d events=%0d writes=%0d reads=%0d",message,cases,debug_cs,debug_ip,debug_micro_pc,debug_gpr[79:64],retired_count,deliveries,writes,reads);
    endtask
    function automatic logic [15:0] word_at(input logic [15:0] offset);
        word_at={memory[offset+16'd1],memory[offset]};
    endfunction
    task automatic tick;
        #1;data_in=16'h0F0F;
        if(bus_valid && address<65536)data_in={memory[{address[15:1],1'b1}],memory[{address[15:1],1'b0}]};
        if(bus_valid && bus_status==0)data_in=16'h2323;
        if(bus_valid && bus_status==9)data_in=address[0]?16'h3400:port_odd?16'h0012:16'h1234;
        if(bus_valid && bus_status==9 && changing_input)begin
            sample_word=input_sample(port_cycles/port_halves);
            data_in=address[0]?{sample_word[7:0],8'hD3}:port_odd && port_word?{8'hC7,sample_word[15:8]}:sample_word;
        end
        #4;
        if(dut.memory_request && dut.memory_request_ready && dut.io_transfer && !reset)port_requests++;
        if(bus_valid && ready && !reset)begin
            if(bus_status==9 || bus_status==10)begin
                check(port_cycles<port_requests*port_halves,"port transaction requires one accepted logical request");
                check(bus_status==(port_writing?10:9) && bus_write==port_writing && data_oe==port_writing,"port lifetime direction and drive");
                check(address==24'h009ABC+24'(port_odd)+24'(port_halves==2?port_cycles%2:0),"port address retained through pause and odd halves");
                if(port_writing)begin
                    if(address[0])check(data_out[15:8]==8'h34,"odd output payload");
                    else begin
                        check(data_out[7:0]==(port_halves==2?8'h12:8'h34),"low output payload");
                        if(!bus_bhe_n)check(data_out[15:8]==8'h12,"high output payload");
                    end
                end
                port_cycles++;
            end
            if(bus_status==0)acks++;
            if(bus_status==5)reads++;
            if(bus_status==6)begin
                writes++;
                if(address[0])memory[address[15:0]]=data_out[15:8];
                else begin
                    memory[address[15:0]]=data_out[7:0];
                    if(!bus_bhe_n)memory[address[15:0]+16'd1]=data_out[15:8];
                end
            end
        end
        if (execute_enable && dut.repeat_stepped && !reset && !redirect) iteration_boundaries++;
        clk=1;#5;clk=0;#1;
        if(instruction_retired)retired_count++;
        if(event_completed)deliveries++;
        check(!microcode_fault && debug_prefetch_count<=6 && !shutdown,"string control and queue invariants");
    endtask
    task automatic service;
        ready=bus_valid && waits>=delay_length;
        if(bus_valid && !ready)waits++;else waits=0;
        tick();
    endtask
    task automatic expected_progress(input integer variant,input integer count);
        expected_elements=count;expected_gpr=initial_gpr;expected_gpr[31:16]=16'(3-count);
        if(variant%4>=2)expected_gpr[111:96]=16'h0400+16'(count*(1+variant%2));
        else expected_gpr[127:112]=16'h0500+16'(count*(1+variant%2));
        expected_flags=initial_flags;
    endtask
    task automatic setup(input integer variant,input logic [15:0] flags_value,input logic [15:0] sp);
        execute_enable=0;reset=1;ready=0;intr=0;nmi=0;hold_request=0;
        gpr_write_en=0;segment_load_en=0;flags_write_en=0;redirect=0;ip_write_en=0;waits=0;
        tick();reset=0;
        initial_gpr={16'h0500,16'h0400,16'h7000,sp,16'h1357,16'h9ABC,16'h0003,16'hA634};
        port_odd=variant>=4;port_writing=variant%4>=2;port_word=variant%2!=0;port_halves=port_odd && port_word?2:1;
        initial_gpr[47:32]=16'h9ABC+16'(port_odd);
        expected_segments=0;initial_flags=flags_value;
        for(integer regno=0;regno<8;regno++)begin gpr_write_en=1;gpr_write_index=3'(regno);gpr_write_data=initial_gpr[regno*16+:16];tick();end
        gpr_write_en=0;flags_write_en=1;flags_write_mask=16'hFFFF;flags_write_data=flags_value;tick();flags_write_en=0;
        segment_load_en=1;segment_load_index=1;segment_load_selector=0;
        redirect=1;ip_write_en=1;ip_write_data=16'h0100;tick();redirect=0;ip_write_en=0;segment_load_en=0;
        for(integer i=256;i<280;i++)memory[i]=8'h0F;
        for(integer i=8160;i<8210;i++)memory[i]=8'hA5;
        for(integer i=1024;i<1050;i++)memory[i]=variant%2==1 && i%2==1?8'h12:8'h34;
        for(integer i=1280;i<1306;i++)memory[i]=8'hA5;
        memory[256]=8'hF3;memory[257]=8'h3E;
        memory[258]=8'(108+variant%4);
        memory[259]=8'hF4;
        memory[2048]=8'hF7;memory[2049]=8'hD0;memory[2050]=8'hF4;
        for(integer v=0;v<14;v++)begin memory[v*4]=0;memory[v*4+1]=6;memory[v*4+2]=8'h40;memory[v*4+3]=0;end
        memory[140]=0;memory[141]=6;memory[142]=8'h40;memory[143]=0;memory[2560]=8'hCF;memory[2561]=8'hF4;
        entry_length=9;
        case(variant%4)
            0:entry_address=int'(spk286_microcode_pkg::MC_ENTRY_STRING_INPUT_BYTE);
            1:entry_address=int'(spk286_microcode_pkg::MC_ENTRY_STRING_INPUT_WORD);
            2:entry_address=int'(spk286_microcode_pkg::MC_ENTRY_STRING_OUTPUT_BYTE);
            3:entry_address=int'(spk286_microcode_pkg::MC_ENTRY_STRING_OUTPUT_WORD);
        endcase
        expected_progress(variant,3);next_ip=32'h0103;
        retired_count=0;deliveries=0;writes=0;reads=0;acks=0;iteration_boundaries=0;port_requests=0;port_cycles=0;execute_enable=1;
    endtask
    task automatic reach(input integer variant,input integer step,input integer iteration);
        setup(variant,16'h08D7,16'h2000);timeout_count=0;
        while(!(debug_micro_active && int'(debug_micro_pc)==entry_address+step && (iteration==0 || iteration_boundaries==iteration)) && timeout_count<1000)begin service();timeout_count++;end
        check(timeout_count<1000 && retired_count==0 && deliveries==0,"reach string operation in initial or repeated iteration");ready=0;
    endtask
    task automatic verify_result(input integer variant);
        check(debug_ip==16'(next_ip) && debug_gpr==expected_gpr && debug_flags==expected_flags && debug_segment_selectors==expected_segments,"exact completed string state");
        check(port_requests==expected_elements && port_cycles==expected_elements*port_halves,"one irreversible port effect per completed element");
        if(variant%4<2)begin
            for(integer i=0;i<int'(expected_gpr[127:112])-1280;i++)check(memory[1280+i]==(variant%2==1 && i%2==1?8'h12:8'h34),"each completed element stored exactly once");
            check(memory[expected_gpr[127:112]]==8'hA5,"string does not write beyond final element");
        end
    endtask
    task automatic finish_normal(input integer variant,input integer retire_target,input integer delivery_target);
        timeout_count=0;
        while(retired_count<retire_target && timeout_count<1000)begin service();timeout_count++;check(!unsupported_opcode && !operand_blocked,"normal string continues through real dependencies");end
        check(retired_count==retire_target && deliveries==delivery_target,"one retirement for whole REP instruction");verify_result(variant);
    endtask
    task automatic wait_event(input integer target,input integer vector_value,input integer retired_value,input logic [15:0] frame_ip,input logic [15:0] frame_flags,input logic [15:0] sp);
        timeout_count=0;while(deliveries<target && timeout_count<1200)begin service();timeout_count++;end
        check(deliveries==target && int'(debug_event_vector)==vector_value && debug_ip==16'h0600 && debug_cs==16'h0040 && retired_count==retired_value,"iteration event identity and handler boundary");
        expected_gpr[79:64]=sp-6;
        check(debug_gpr==expected_gpr && debug_flags==(frame_flags & ~16'h0300),"iteration event preserves committed elements and remaining count");
        check(word_at(sp-6)==frame_ip && word_at(sp-4)==0 && word_at(sp-2)==frame_flags,"full unmasked REP event frame");
    endtask
    initial begin
        for(integer i=0;i<65536;i++)memory[i]=8'h0F;
        // These are synthetic contract probes, not physical event observations.
        for(integer variant=0;variant<8;variant++)begin
            for(integer event_kind=0;event_kind<5;event_kind++)begin
                delay_length=event_kind%3;
                setup(variant,(event_kind==2 || event_kind==3)?16'h0BD7:16'h0AD7,16'h2000);
                execute_enable=0;gpr_write_en=1;gpr_write_index=1;gpr_write_data=0;
                tick();gpr_write_en=0;execute_enable=1;
                expected_progress(variant,0);expected_gpr[31:16]=0;
                timeout_count=0;
                while(!(debug_micro_active && int'(debug_micro_pc)==entry_address) && timeout_count<500)begin service();timeout_count++;end
                check(timeout_count<500 && dut.context_active && retired_count==0 && deliveries==0,
                      "zero-count event injection follows accepted opcode and precedes empty branch");
                check(debug_ip==16'h0103 && !dut.repeat_boundary && !dut.string_request,
                      "zero-count branch observes next IP without a REP element boundary");
                check(reads==0 && writes==0 && port_cycles==0 && port_requests==0,"no element side effects before injected event");
                if(event_kind==0 || event_kind==3 || event_kind==4)nmi=1;
                if(event_kind==1 || event_kind==3 || event_kind==4)intr=1;
                wait_event(1,(event_kind==2 || event_kind==3)?1:(event_kind==1?35:2),1,
                           16'h0103,initial_flags,16'h2000);
                check(acks==(event_kind==1?2:0),"zero-count completion uses TF then NMI then INTR priority");
                check(iteration_boundaries==0 && reads==2 && writes==3 && port_cycles==0 && port_requests==0,
                      "only vector reads and complete frame writes occur; zero string elements");
                cases++;
            end
            // Negative observability control: an eligible event before target
            // acceptance saves prefix IP, but cannot adjudicate CX=0 completion.
            for(integer event_kind=0;event_kind<2;event_kind++)begin
                delay_length=1;setup(variant,16'h0AD7,16'h2000);
                execute_enable=0;gpr_write_en=1;gpr_write_index=1;gpr_write_data=0;
                tick();gpr_write_en=0;
                expected_progress(variant,0);expected_gpr[31:16]=0;
                check(!dut.context_active && !debug_micro_active && debug_ip==16'h0100,
                      "preceding-event control occurs before prefix/opcode acceptance");
                if(event_kind==0)nmi=1;else intr=1;
                execute_enable=1;
                wait_event(1,event_kind==0?2:35,0,16'h0100,initial_flags,16'h2000);
                check(acks==(event_kind==1?2:0) && reads==2 && writes==3 && port_cycles==0 && port_requests==0,
                      "preceding-event control has no element and saves target prefix IP");
                cases++;
            end
        end
        check(cases==56,"complete zero-count completion and preceding-event matrix");
        $display("STRING_ZERO_EVENTS PASS: %0d synthetic completion/priority/pre-instruction cases; %0d checks",cases,checks);
        $finish;
    end
endmodule
