`timescale 1ns/1ps
module spk286_stack_frame_lifecycle_tb;
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
    logic [127:0] expected_final_gpr;
    logic [15:0] saved_auxiliary, saved_allocation, saved_frame_address, saved_stack_cursor;
    logic [4:0] saved_counter;
    integer instruction_length, current_form, operand_reads;
    logic [15:0] expected_enter_sp;
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
        if(execute_enable && debug_micro_active && debug_opcode==8'hC8 && dut.micro_executor.stack_cursor_valid_q &&
            !dut.event_active && debug_micro_instruction!=spk286_microcode_pkg::MC_END)
            check(debug_gpr[64+:16]==expected_enter_sp,"ENTER preserves architectural SP until final cursor commit");
        if(!reset) begin
            if(bus_valid && ready && bus_status==5 && !dut.event_active) operand_reads++;

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
    task automatic set_register(input integer index,input integer value);
        execute_enable=0;gpr_write_en=1;gpr_write_index=3'(index);gpr_write_data=16'(value);tick();gpr_write_en=0;execute_enable=1;
    endtask
    function automatic logic [7:0] frame_opcode(input integer form);
        frame_opcode=form==0?8'h60:form==1?8'h61:form==2?8'hC8:form==3?8'hC9:8'h62;
    endfunction
    function automatic integer entry_address(input integer form);
        case(form)
            0:entry_address=int'(spk286_microcode_pkg::MC_ENTRY_PUSH_ALL);
            1:entry_address=int'(spk286_microcode_pkg::MC_ENTRY_POP_ALL);
            2:entry_address=int'(spk286_microcode_pkg::MC_ENTRY_ENTER_FRAME);
            3:entry_address=int'(spk286_microcode_pkg::MC_ENTRY_LEAVE_FRAME);
            default:entry_address=int'(spk286_microcode_pkg::MC_ENTRY_CHECK_BOUNDS);
        endcase
    endfunction
    task automatic frame_stream(input integer form,input integer status);
        setup(status,'h0201);set_register(5,form==3?'h0209:'h0411);
        current_form=form;operand_reads=0;expected_enter_sp=16'h0201;
        for(integer a='h80100;a<'h80400;a++)memory[a]=8'h5A;
        memory[65792]=8'hF3;memory[65793]=8'h3E;memory[65794]=frame_opcode(form);memory[65795]=8'h0F;
        expected_final_gpr=debug_gpr;instruction_length=form==2||form==4?6:3;
        case(form)
            0:expected_final_gpr[64+:16]=16'h01F1;
            1:begin
                for(integer n=0;n<8;n++)putword('h80201+n*2,'hB100+n);
                expected_final_gpr[0+:16]=16'hB107;expected_final_gpr[16+:16]=16'hB106;
                expected_final_gpr[32+:16]=16'hB105;expected_final_gpr[48+:16]=16'hB104;
                expected_final_gpr[64+:16]=16'h0211;expected_final_gpr[80+:16]=16'hB102;
                expected_final_gpr[96+:16]=16'hB101;expected_final_gpr[112+:16]=16'hB100;
            end
            2:begin
                putword(65795,'h0013);memory[65797]=8'h03;memory[65798]=8'h0F;
                putword('h8040F,'h8111);putword('h8040D,'h9222);
                putword('h4040F,'hDEAD);putword('h4040D,'hBEEF);
                expected_final_gpr[64+:16]=16'h01E6;expected_final_gpr[80+:16]=16'h01FF;
            end
            3:begin
                putword('h80209,'hBEEF);putword('h40209,'hDEAD);
                expected_final_gpr[64+:16]=16'h020B;expected_final_gpr[80+:16]=16'hBEEF;
            end
            4:begin
                memory[65795]=8'h06;putword(65796,'h0501);memory[65798]=8'h0F;
                putword('h40501,'h8000);putword('h40503,'h7FFF);
            end
        endcase
    endtask
    task automatic check_completed_frame(input integer status,input integer vector_value);
        logic [127:0] expected;
        integer sp;
        expected=expected_final_gpr;sp=int'(expected_final_gpr[64+:16]);expected[64+:16]=16'(sp-6);
        check(deliveries==1 && retires==1 && int'(debug_event_vector)==vector_value && debug_gpr==expected,"entire instruction completes before event and precise GPR/SP commit");
        check(stackword(sp-6)==16'h0100+16'(instruction_length) && stackword(sp-4)==16'h1000 && stackword(sp-2)==16'(status),"unmasked full frame after final stack result");
        if(current_form==0) check(stackword('h01F7)==16'h0201 && stackword('h01FF)==16'hA500 && stackword('h01F1)==16'hA507,
            "PUSHA stores original SP and ordered register values");
        if(current_form==2) check(stackword('h01FF)==16'h0411 && stackword('h01FD)==16'h8111 && stackword('h01FB)==16'h9222 && stackword('h01F9)==16'h01FF,
            "ENTER uses SS parent addresses and frame pointer in sequence");

    endtask
    task automatic wait_stage(input integer form,input integer stage);
        timeout_count=0;
        while(!(debug_micro_active && int'(debug_micro_pc)==entry_address(form)+stage) && timeout_count<1200)begin service();timeout_count++;end
        check(timeout_count<1200 && retires==0 && deliveries==0,"reach requested real microcode dependency");
    endtask
    initial begin
        for(integer i=0;i<1114112;i++)memory[i]=8'h0F;
        for(integer form=0;form<5;form++)for(integer mode=0;mode<4;mode++)for(integer delay=0;delay<3;delay++)begin
            integer status,vector_value;
            wait_length=delay;status=mode==0?2:mode==1?'h0202:mode==2?'h0102:'h0302;
            vector_value=mode>=2?1:mode==0?2:66;
            frame_stream(form,status);wait_opcode(frame_opcode(form));
            nmi=mode==0||mode==3;intr=mode==1||mode==3;
            until_event(1,vector_value);check_completed_frame(status,vector_value);
            check(acks==(mode==1?2:0),"instruction boundary preserves acknowledgement count");
            if(mode==3)check(debug_nmi_pending,"completed-instruction trap retains pending NMI");
            cases++;
        end
        for(integer form=0;form<5;form++)for(integer stage=0;stage<(form==0?20:form==1?17:form==2?25:form==3?6:9);stage++)for(integer action=0;action<3;action++)begin
            wait_length=1;frame_stream(form,2);wait_stage(form,stage);
            saved_gpr=debug_gpr;saved_flags=debug_flags;saved_pc=debug_micro_pc;
            saved_auxiliary=dut.micro_executor.auxiliary_q;saved_allocation=dut.micro_executor.allocation_q;
            saved_frame_address=dut.micro_executor.frame_address_q;saved_counter=dut.micro_executor.counter_q;saved_stack_cursor=dut.micro_executor.stack_cursor_q;
            execute_enable=0;
            if(action==0)begin
                nmi=1;
                repeat(6)begin
                    service();check(debug_gpr==saved_gpr && debug_flags==saved_flags && debug_micro_pc==saved_pc &&
                        dut.micro_executor.auxiliary_q==saved_auxiliary && dut.micro_executor.allocation_q==saved_allocation &&
                        dut.micro_executor.frame_address_q==saved_frame_address && dut.micro_executor.counter_q==saved_counter && dut.micro_executor.stack_cursor_q==saved_stack_cursor &&
                        retires==0 && deliveries==0,"pause freezes partial commits and every frame/loop temporary");
                end
                execute_enable=1;until_event(1,2);check_completed_frame(2,2);
            end else if(action==1)begin
                redirect=1;ip_write_en=1;ip_write_data=16'h0200;tick();redirect=0;ip_write_en=0;
                check(debug_gpr==saved_gpr && debug_flags==saved_flags && !dut.micro_executor.auxiliary_valid_q &&
                    !dut.micro_executor.allocation_valid_q && !dut.micro_executor.frame_address_valid_q && !dut.micro_executor.counter_valid_q && !dut.micro_executor.stack_cursor_valid_q &&
                    !dut.counter_branch_request && !dut.range_fault && !dut.bounds_fault,"cancel retains committed GPRs and removes transient branch/frame/fault ownership");
                memory[66048]=8'hB8;putword(66049,'hBEEF);memory[66051]=8'h0F;execute_enable=1;until_retired(1);
                check(debug_ip==16'h0203 && debug_gpr[15:0]==16'hBEEF && deliveries==0,"canceled frame state cannot enter subsequent instruction");
            end else begin
                reset=1;ready=1;tick();
                check(debug_gpr==0 && debug_flags==2 && debug_cs_base==24'hFF0000 && debug_ip==16'hFFF0 &&
                    !dut.micro_executor.counter_valid_q && !dut.micro_executor.auxiliary_valid_q,"reset clears architectural and loop state");
                reset=0;ready=0;tick();check(bus_valid && address==24'hFFFFF0,"native reset fetch after frame cancellation");
            end
            cases++;
        end
        for(integer fault_type=0;fault_type<8;fault_type++)for(integer pending=0;pending<2;pending++)for(integer delay=0;delay<2;delay++)begin
            integer form,original_sp,vector_value;
            form=fault_type<4?fault_type:4;wait_length=delay;frame_stream(form,'h0202);
            if(fault_type==0)set_register(4,15);
            if(fault_type==1)set_register(4,'hFFF1);
            if(fault_type==2)begin
                set_register(5,13);memory[65797]=8;
                for(integer n=0;n<6;n++)putword('h80001+2*n,'hB500+n);
            end
            if(fault_type==3)set_register(5,'hFFFF);
            if(fault_type==4)putword('h40501,'hA501);
            if(fault_type==5)putword(65796,'hFFFD);
            if(fault_type==6)memory[65795]=8'hC0;
            if(fault_type==7)putword('h40503,'hA4FF);
            saved_gpr=debug_gpr;original_sp=int'(debug_gpr[64+:16]);vector_value=fault_type==4||fault_type==7?5:fault_type==6?6:13;
            wait_opcode(frame_opcode(form));nmi=pending!=0;intr=pending!=0;until_event(1,vector_value);
            saved_gpr[64+:16]=16'(original_sp-6);
            check(retires==0 && debug_gpr==saved_gpr && stackword(original_sp-6)==16'h0100 &&
                stackword(original_sp-4)==16'h1000 && stackword(original_sp-2)==16'h0202,"preflight/bounds fault preserves original registers and first-prefix frame");
            if(fault_type==5 || fault_type==6) check(operand_reads==0,"BOUND four-byte preflight has no partial memory read");
            if(fault_type==2) check(stackword('h01F9)==16'hB503 && stackword('h01F7)==16'hB502 && stackword('h01F5)==16'hB501 && stackword('h01F3)==16'hB500,
                "ENTER fault retains completed parent writes below the original exception frame");
            check(acks==0 && (pending==0 || debug_nmi_pending),"synchronous frame fault precedes pending asynchronous events");
            cases++;
        end
        for(integer delay=0;delay<3;delay++)begin
            wait_length=delay;frame_stream(4,2);putword(65796,'hFFFE);putword('h4FFFE,'h8000);putword('h40000,'h7FFF);
            wait_opcode(8'h62);nmi=1;until_event(1,2);check_completed_frame(2,2);check(operand_reads==2,"BOUND even upper word wraps its offset");cases++;
        end
        for(integer level_value=0;level_value<2;level_value++)for(integer delay=0;delay<3;delay++)begin
            wait_length=delay;frame_stream(2,2);memory[65797]=8'(level_value);
            expected_final_gpr[64+:16]=16'('h01FF-2*level_value-'h13);
            wait_opcode(8'hC8);nmi=1;until_event(1,2);
            expected_final_gpr[64+:16]=expected_final_gpr[64+:16]-16'd6;
            check(retires==1 && debug_gpr==expected_final_gpr && stackword('h01FF)==16'h0411,
                "ENTER zero/one-level branch reaches correct frame and stack commits");
            if(level_value==1)check(stackword('h01FD)==16'h01FF,"ENTER level one pushes frame without parent read");
            cases++;
        end
        for(integer sp=1;sp<=5;sp+=2)for(integer delay=0;delay<2;delay++)begin
            wait_length=delay;frame_stream(0,2);set_register(4,sp);timeout_count=0;
            while(!shutdown && timeout_count<800)begin service();timeout_count++;end
            check(shutdown && retires==0 && deliveries==0 && writes==sp-1,"PUSHA tiny odd stack shuts down through existing exception-entry failure");cases++;
        end
        wait_length=1;frame_stream(0,2);saved_gpr=debug_gpr;
        memory[65792]=8'hF3;memory[65793]=8'h60;memory[65794]=8'hB8;putword(65795,'hBEEF);
        memory[65797]=8'hF5;memory[65798]=8'h61;memory[65799]=8'hC8;putword(65800,8);memory[65802]=1;
        memory[65803]=8'hC9;memory[65804]=8'h62;memory[65805]=6;putword(65806,'h0501);memory[65808]=8'h0F;
        putword('h40501,'hA4FF);putword('h40503,'hA501);until_retired(7);
        check(debug_gpr==saved_gpr && debug_flags==3 && debug_ip==16'h0110 && deliveries==0,"dependent save/restore/frame/bounds stream preserves flags and original SP");cases++;
        $display("STACK_FRAME_LIFECYCLE PASS: %0d event/pause/cancel/reset/fault/stream cases; %0d checks",cases,checks);$finish;
    end
endmodule
