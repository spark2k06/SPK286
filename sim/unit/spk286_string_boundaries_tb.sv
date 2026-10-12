// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module spk286_string_boundaries_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    integer checks=0,cases=0,retired_count=0,deliveries=0,writes=0,reads=0,acks=0;
    integer timeout_count,waits=0,delay_length=0,entry_address,entry_length,next_ip;
    logic [127:0] initial_gpr,expected_gpr,saved_gpr;
    logic [63:0] expected_segments,saved_segments;
    logic [15:0] initial_flags,saved_flags,expected_flags;
    integer iteration_boundaries=0;
    logic [11:0] saved_pc;
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
        #4;
        if(bus_valid && ready && !reset)begin
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
    function automatic logic [15:0] flags_after(input integer variant);
        flags_after=(variant/2==1 || variant/2==4)?(initial_flags & ~16'h08D5)|16'h0044:initial_flags;
    endfunction
    task automatic expected_progress(input integer variant,input integer count);
        expected_gpr=initial_gpr;expected_gpr[31:16]=16'(3-count);
        if(variant/2==0 || variant/2==1 || variant/2==3)expected_gpr[111:96]=16'h0400+16'(count*(1+variant%2));
        if(variant/2!=3)expected_gpr[127:112]=16'h0500+16'(count*(1+variant%2));
        if(variant/2==3 && variant%2==1 && count!=0)expected_gpr[15:0]=16'h1234;
        expected_flags=count==0?initial_flags:flags_after(variant);
    endtask
    task automatic setup(input integer variant,input logic [15:0] flags_value,input logic [15:0] sp);
        execute_enable=0;reset=1;ready=0;intr=0;nmi=0;hold_request=0;
        gpr_write_en=0;segment_load_en=0;flags_write_en=0;redirect=0;ip_write_en=0;waits=0;
        tick();reset=0;
        initial_gpr={16'h0500,16'h0400,16'h7000,sp,16'h1357,16'h9ABC,16'h0003,16'hA634};
        expected_segments=0;initial_flags=flags_value;
        for(integer regno=0;regno<8;regno++)begin gpr_write_en=1;gpr_write_index=3'(regno);gpr_write_data=initial_gpr[regno*16+:16];tick();end
        gpr_write_en=0;flags_write_en=1;flags_write_mask=16'hFFFF;flags_write_data=flags_value;tick();flags_write_en=0;
        segment_load_en=1;segment_load_index=1;segment_load_selector=0;
        redirect=1;ip_write_en=1;ip_write_data=16'h0100;tick();redirect=0;ip_write_en=0;segment_load_en=0;
        for(integer i=256;i<280;i++)memory[i]=8'h0F;
        for(integer i=8160;i<8210;i++)memory[i]=8'hA5;
        for(integer i=1024;i<1050;i++)memory[i]=variant%2==1 && i%2==1?8'h12:8'h34;
        for(integer i=1280;i<1306;i++)memory[i]=variant/2==1 || variant/2==4?(variant%2==1 && i%2==1?(variant/2==4?8'hA6:8'h12):8'h34):8'hA5;
        memory[256]=8'hF3;memory[257]=8'h3E;
        memory[258]=8'(variant/2==0?164+variant%2:variant/2==1?166+variant%2:variant/2==2?170+variant%2:variant/2==3?172+variant%2:174+variant%2);
        memory[259]=8'hF4;
        memory[2048]=8'hF7;memory[2049]=8'hD0;memory[2050]=8'hF4;
        for(integer v=0;v<14;v++)begin memory[v*4]=0;memory[v*4+1]=6;memory[v*4+2]=8'h40;memory[v*4+3]=0;end
        memory[140]=0;memory[141]=6;memory[142]=8'h40;memory[143]=0;memory[2560]=8'hCF;memory[2561]=8'hF4;
        case(variant/2)
            0:begin entry_address=int'(spk286_microcode_pkg::MC_ENTRY_STRING_MOVE);entry_length=8;end
            1:begin entry_address=int'(spk286_microcode_pkg::MC_ENTRY_STRING_COMPARE);entry_length=11;end
            2:begin entry_address=int'(spk286_microcode_pkg::MC_ENTRY_STRING_STORE);entry_length=7;end
            3:begin entry_address=int'(spk286_microcode_pkg::MC_ENTRY_STRING_LOAD);entry_length=7;end
            4:begin entry_address=int'(spk286_microcode_pkg::MC_ENTRY_STRING_SCAN);entry_length=10;end
            default:$fatal(1,"unknown string variant");
        endcase
        expected_progress(variant,3);next_ip=32'h0103;
        retired_count=0;deliveries=0;writes=0;reads=0;acks=0;iteration_boundaries=0;execute_enable=1;
    endtask
    task automatic reach(input integer variant,input integer step,input integer iteration);
        setup(variant,16'h08D7,16'h2000);timeout_count=0;
        while(!(debug_micro_active && int'(debug_micro_pc)==entry_address+step && (iteration==0 || iteration_boundaries==iteration)) && timeout_count<1000)begin service();timeout_count++;end
        check(timeout_count<1000 && retired_count==0 && deliveries==0,"reach string operation in initial or repeated iteration");ready=0;
    endtask
    task automatic verify_result(input integer variant);
        check(debug_ip==16'(next_ip) && debug_gpr==expected_gpr && debug_flags==expected_flags && debug_segment_selectors==expected_segments,"exact completed string state");
        if(variant/2==0 || variant/2==2)begin
            for(integer i=0;i<int'(expected_gpr[127:112])-1280;i++)check(memory[1280+i]==(variant%2==1 && i%2==1?(variant/2==0?8'h12:8'hA6):8'h34),"each completed element stored exactly once");
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
    task automatic replace_register(input integer index,input logic [15:0] value);
        execute_enable=0;gpr_write_en=1;gpr_write_index=3'(index);gpr_write_data=value;tick();gpr_write_en=0;
        initial_gpr[index*16+:16]=value;execute_enable=1;
    endtask
    initial begin
        for(integer i=0;i<65536;i++)memory[i]=8'h0F;
        for(integer variant=0;variant<10;variant++)begin
            // Source/destination faults before any completed element and after
            // one accepted element, with even and odd complete exception frames.
            if(variant%2==1)for(integer side=0;side<2;side++)begin
                if((side==0 && (variant/2==0 || variant/2==1 || variant/2==3)) ||
                   (side==1 && variant/2!=3))begin
                    for(integer completed=0;completed<2;completed++)for(integer odd=0;odd<2;odd++)begin
                        delay_length=(variant+side+completed)%3;setup(variant,16'h08D7,16'h2000+16'(odd));
                        replace_register(side==0?6:7,completed==0?16'hFFFF:16'hFFFD);
                        if(completed!=0)begin memory[65533]=8'h34;memory[65534]=variant/2==4?8'hA6:8'h12;end
                        expected_gpr=initial_gpr;
                        if(variant/2==0)begin
                            expected_gpr[111:96]=initial_gpr[111:96]+16'(2*(completed+1));
                            expected_gpr[127:112]=initial_gpr[127:112]+16'(2*(completed+side));
                            expected_gpr[31:16]=16'(3-completed-1-side);
                        end else if(variant/2==1)begin
                            expected_gpr[111:96]=initial_gpr[111:96]+16'(2*(completed+1-side));
                            expected_gpr[127:112]=initial_gpr[127:112]+16'(2*(completed+1));
                            expected_gpr[31:16]=16'(3-completed-1+side);
                        end else if(variant/2==2 || variant/2==4)begin
                            expected_gpr[127:112]=initial_gpr[127:112]+16'(2*(completed+1));
                            expected_gpr[31:16]=16'(3-completed-(variant/2==2?2:1));
                        end else begin
                            expected_gpr[111:96]=initial_gpr[111:96]+16'(2*(completed+1));
                            expected_gpr[31:16]=16'(3-completed-1);
                            if(completed!=0)expected_gpr[15:0]=16'h1234;
                        end
                        expected_flags=completed!=0?flags_after(variant):initial_flags;
                        wait_event(1,13,0,16'h0100,expected_flags,16'h2000+16'(odd));
                        if(completed!=0 && (variant/2==0 || variant/2==2))
                            check(word_at(initial_gpr[127:112])==(variant/2==0?16'h1234:16'hA634),"accepted earlier store survives later string fault");
                        cases++;
                    end
                end
            end
            // HOLD can stop later bus work, but it must neither duplicate the
            // current accepted element nor bypass the pending operand dependency.
            delay_length=2;setup(variant,16'h08D7,16'h2000);
            timeout_count=0;while(!(dut.string_request && bus_valid) && timeout_count<500)begin service();timeout_count++;end
            check(timeout_count<500,"reach string transfer before HOLD");hold_request=1;timeout_count=0;
            while(!hlda && timeout_count<500)begin service();timeout_count++;end
            check(hlda,"HOLD granted at legal bus ownership boundary");
            repeat(6)begin service();check(hlda && !bus_valid,"HLDA blocks new string transfers");end
            hold_request=0;finish_normal(variant,1,0);cases++;
            // Explicit LOCK holds ownership through the repeated macro.
            setup(variant,16'h08D7,16'h2000);memory[259]=memory[258];memory[256]=8'hF0;memory[257]=8'hF3;memory[258]=8'h3E;memory[260]=8'hF4;next_ip=32'h0104;
            timeout_count=0;while(!(dut.string_request && bus_valid) && timeout_count<500)begin service();timeout_count++;end
            check(timeout_count<500,"reach locked string transfer");hold_request=1;timeout_count=0;
            while(retired_count==0 && timeout_count<1000)begin service();timeout_count++;check(!hlda && bus_lock,"LOCK excludes HOLD throughout REP body");end
            check(retired_count==1,"locked repeated instruction retires once");verify_result(variant);
            timeout_count=0;while(!hlda && timeout_count<100)begin service();timeout_count++;end
            check(hlda,"LOCK released at whole instruction completion");cases++;
            // MOV SS protects the following whole REP. STI protects INTR;
            // NMI and TF remain interruptible at a completed element boundary.
            for(integer shadow=0;shadow<2;shadow++)for(integer kind=0;kind<3;kind++)begin
                setup(variant,kind==2?16'h09D7:(shadow==0?16'h0AD7:16'h08D7),16'h2000);
                if(shadow==0)begin
                    replace_register(2,0);memory[256]=8'h8E;memory[257]=8'hD2;memory[258]=8'hF3;memory[259]=8'h3E;
                    memory[260]=8'(variant/2==0?164+variant%2:variant/2==1?166+variant%2:variant/2==2?170+variant%2:variant/2==3?172+variant%2:174+variant%2);memory[261]=8'hF4;
                end else begin
                    memory[259]=memory[258];memory[256]=8'hFB;memory[257]=8'hF3;memory[258]=8'h3E;memory[260]=8'hF4;
                end
                if(shadow!=0 && kind==2)begin
                    // With TF already set, STI itself traps first. Resume it
                    // through IRET before testing the following REP boundary.
                    initial_flags=initial_flags|16'h0200;expected_gpr=initial_gpr;
                    wait_event(1,1,1,16'h0101,initial_flags,16'h2000);
                end
                timeout_count=0;while(!(dut.string_request && bus_valid) && timeout_count<500)begin service();timeout_count++;end
                check(timeout_count<500,"reach protected repeated body");
                if(kind==0)nmi=1;if(kind==1)intr=1;
                if(shadow!=0)initial_flags=initial_flags|16'h0200;
                expected_progress(variant,shadow==0 || kind==1?3:1);
                wait_event(shadow!=0 && kind==2?2:1,kind==0?2:kind==1?35:1,shadow==0 || kind==1 || kind==2?2:1,
                           shadow==0?16'h0105:kind==1?16'h0104:16'h0101,expected_flags,16'h2000);cases++;
            end
            // Length limit is checked before the opcode can create an element.
            for(integer overlength=0;overlength<2;overlength++)begin
                setup(variant,16'h08D7,16'h2000);
                memory[265+overlength]=memory[258];memory[266+overlength]=8'hF4;
                for(integer i=0;i<9+overlength;i++)memory[256+i]=i==0?8'hF3:8'h3E;
                if(overlength!=0)begin expected_gpr=initial_gpr;wait_event(1,13,0,16'h0100,initial_flags,16'h2000);check(reads==2 && writes==3,"overlength string has only exception traffic");end
                else begin next_ip=32'h010A;finish_normal(variant,1,0);end
                cases++;
            end
            // A pending external event at entry saves the whole prefix context
            // without consuming CX or touching an element; IRET executes it once.
            for(integer kind=0;kind<2;kind++)begin
                setup(variant,16'h0AD7,16'h2000);timeout_count=0;
                while(!(debug_micro_active && int'(debug_micro_pc)==entry_address) && timeout_count<500)begin service();timeout_count++;end
                check(timeout_count<500,"reach REP entry boundary");if(kind==0)nmi=1;else intr=1;
                expected_progress(variant,0);wait_event(1,kind==0?2:35,0,16'h0100,initial_flags,16'h2000);
                nmi=0;intr=0;expected_progress(variant,3);finish_normal(variant,2,1);cases++;
            end
        end
        check(cases==148,"complete string fault, bus ownership and shadow boundary matrix");
        $display("STRING_BOUNDARIES PASS: %0d fault/READY/HOLD/LOCK/SS/STI/length/entry cases; %0d checks",cases,checks);$finish;
    end
endmodule
