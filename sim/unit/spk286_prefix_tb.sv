`timescale 1ns/1ps
module spk286_prefix_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory[0:1114111];
    integer checks=0,cases=0,retires=0,reads=0,writes=0,wait_count=0,wait_length=0;
    integer timeout_count,first_prefix_ip,expected_ip;
    logic waiting=0;
    logic [23:0] held_address;
    logic [15:0] held_data;
    logic [3:0] held_status;
    logic held_bhe,held_write;
    spk286 dut(.*);
    task automatic check(input logic okay,input string why);
        checks++;
        if(okay!==1'b1)$fatal(1,"%s case=%0d ip=%h first=%h opcode=%h bytes=%d event=%d reads/writes=%0d/%0d",why,cases,debug_ip,debug_instruction_ip,debug_opcode,dut.instruction_bytes,debug_event_vector,reads,writes);
    endtask
    task automatic tick;
        #1;data_in=16'hF4F4;
        if(bus_valid && address<1114112)data_in={memory[{address[20:1],1'b1}],memory[{address[20:1],1'b0}]};
        if(bus_valid && address[0])data_in[7:0]=8'hE7;
        if(bus_valid && bus_bhe_n)data_in[15:8]=8'h51;
        #4;
        if(bus_valid && ready && !reset && (bus_status==5 || bus_status==6))begin
            if(bus_write)begin
                writes++;
                if(address[0])memory[address[20:0]]=data_out[15:8];
                else begin memory[address[20:0]]=data_out[7:0];if(!bus_bhe_n)memory[address+1]=data_out[15:8];end
            end else reads++;
        end
        clk=1;#5;clk=0;#1;
        if(instruction_retired)retires++;
        check(!microcode_fault && debug_prefetch_count<=6,"microcode/queue bounds");
    endtask
    task automatic service;
        #1;
        if(waiting)check(bus_valid && address==held_address && data_out==held_data && bus_status==held_status && bus_bhe_n==held_bhe && bus_write==held_write,"READY transaction stability");
        ready=bus_valid && wait_count>=wait_length;
        waiting=bus_valid && !ready;
        if(waiting)begin
            held_address=address;held_data=data_out;held_status=bus_status;held_bhe=bus_bhe_n;held_write=bus_write;wait_count++;
        end else wait_count=0;
        tick();
    endtask
    task automatic setup(input logic [15:0] flags);
        execute_enable=0;reset=1;ready=0;intr=0;nmi=0;hold_request=0;
        redirect=0;ip_write_en=0;gpr_write_en=0;flags_write_en=0;segment_load_en=0;
        waiting=0;wait_count=0;retires=0;reads=0;writes=0;tick();reset=0;
        for(integer i=0;i<8;i++)begin
            gpr_write_en=1;gpr_write_index=3'(i);gpr_write_data=i==4?16'h8000:16'hA55A;tick();
        end
        gpr_write_en=0;flags_write_en=1;flags_write_mask=16'hffff;flags_write_data=flags;tick();flags_write_en=0;
        for(integer i=0;i<4;i++)begin
            segment_load_en=1;segment_load_index=2'(i);
            segment_load_selector=i==1?16'h1000:(i==2?16'h8000:(i==3?16'h4000:16'h2000));
            redirect=i==1;ip_write_en=i==1;ip_write_data=16'h0100;tick();
        end
        segment_load_en=0;redirect=0;ip_write_en=0;execute_enable=1;
    endtask
    task automatic run_boundary(input logic event_expected);
        timeout_count=0;
        while(!(event_expected?event_completed:instruction_retired) && timeout_count<1000)begin service();timeout_count++;end
        check(timeout_count<1000,"bounded completion under bounded READY");
    endtask
    initial begin
        // Vectors #GP and NMI share a valid destination, independent of DUT outcomes.
        memory[52]=0;memory[53]=8'h20;memory[54]=0;memory[55]=8'h30;
        memory[8]=0;memory[9]=8'h20;memory[10]=0;memory[11]=8'h30;
        for(integer prefix_count=0;prefix_count<=10;prefix_count++)
          for(integer delay=0;delay<4;delay++)begin
            for(integer i=0;i<20;i++)memory[65792+i]=8'hF4;
            for(integer i=0;i<prefix_count;i++)memory[65792+i]=i%3==0?8'hF3:(i%3==1?8'h2E:8'h36);
            memory[65792+prefix_count]=8'hB0;memory[65793+prefix_count]=8'h42;
            wait_length=delay;setup(16'h0002);
            run_boundary(prefix_count>=9);
            if(prefix_count<9)begin
                check(retires==1 && debug_gpr[15:0]==16'hA542,"byte result and preserved high half");
                check(debug_ip==16'h0102+16'(prefix_count) && writes==0 && reads==0,"all prefixes count toward instruction length");
            end else begin
                check(retires==0 && debug_event_vector==13 && debug_event_kind==1,"overlength is real #GP without retirement");
                check(debug_gpr[15:0]==16'hA55A && debug_gpr[64+:16]==16'h7FFA,"fault commits only its frame");
                check({memory[524288+32768-5],memory[524288+32768-6]}==16'h0100,"restart IP includes the first prefix");
                check({memory[524288+32768-3],memory[524288+32768-4]}==16'h1000 && {memory[524288+32768-1],memory[524288+32768-2]}==16'h0002,"fault frame CS/FLAGS");
                check(debug_cs==16'h3000 && debug_ip==16'h2000,"fault vector transaction");
            end
            execute_enable=0;cases++;
          end
        // Eleven-byte immediate ALU form: the second immediate byte is
        // unavailable architecturally, so no operand read or result is allowed.
        for(integer i=0;i<5;i++)memory[65792+i]=8'h3E;
        memory[65797]=8'h81;memory[65798]=8'h06;memory[65799]=0;memory[65800]=8'h02;
        memory[65801]=1;memory[65802]=0;memory[65803]=8'hF4;memory[262656]=8'h7F;memory[262657]=0;
        wait_length=3;setup(16'h0002);run_boundary(1);
        check(retires==0 && debug_event_vector==13 && reads==2 && writes==3,"overlength prevents operand data access");
        check(memory[262656]==8'h7f && memory[262657]==0,"overlength has no ALU write");
        execute_enable=0;cases++;
        // A pending edge during prefixes cannot split the instruction; the
        // completed instruction's following IP is saved on NMI entry.
        for(integer edge_position=1;edge_position<=4;edge_position++)begin
            for(integer i=0;i<4;i++)memory[65792+i]=8'hF3;
            memory[65796]=8'hB0;memory[65797]=8'h81;memory[65798]=8'hF4;
            wait_length=edge_position%4;setup(16'h0002);timeout_count=0;
            while(dut.instruction_bytes<4'(edge_position) && timeout_count<500)begin service();timeout_count++;end
            check(timeout_count<500,"prefix reached");nmi=1;service();nmi=0;
            run_boundary(1);
            check(retires==1 && debug_gpr[15:0]==16'hA581 && debug_event_vector==2,"NMI waits for prefixed completion");
            check({memory[524288+32768-5],memory[524288+32768-6]}==16'h0106,"NMI following IP is not a prefix restart");
            execute_enable=0;cases++;
        end
        // Consecutive instructions must not inherit a segment override.
        memory[65792]=8'h26;memory[65793]=8'h8A;memory[65794]=8'h06;memory[65795]=0;memory[65796]=8'h02;
        memory[65797]=8'h8A;memory[65798]=8'h26;memory[65799]=0;memory[65800]=8'h02;memory[65801]=8'hF4;
        memory[131584]=8'h17;memory[262656]=8'h83;wait_length=3;setup(16'h0002);
        run_boundary(0);check(debug_gpr[15:0]==16'hA517,"ES override");service();run_boundary(0);
        check(debug_gpr[15:0]==16'h8317 && reads==2 && writes==0,"prefix context cleared at retirement");
        execute_enable=0;cases++;
        // LOCK holds bus ownership over an RMW read/write gap. HOLD is
        // released only after the instruction has committed its byte result.
        memory[65792]=8'hF0;memory[65793]=8'h80;memory[65794]=8'h06;memory[65795]=0;memory[65796]=8'h02;memory[65797]=1;memory[65798]=8'hF4;
        memory[262656]=8'h7f;wait_length=2;setup(16'h0002);timeout_count=0;
        while(reads==0 && timeout_count<500)begin service();timeout_count++;end
        check(reads==1 && writes==0 && bus_lock,"LOCK read accepted");hold_request=1;
        while(!instruction_retired && timeout_count<1000)begin service();timeout_count++;check(!hlda,"HOLD cannot split locked RMW");end
        check(retires==1 && writes==1 && memory[262656]==8'h80,"locked byte operation exactly once");
        execute_enable=0;repeat(5)service();check(hlda,"HOLD eventually granted after lock release");hold_request=0;cases++;
        check(cases==51,"complete prefix/lifetime scenarios");
        $display("PREFIX PASS: %0d scenarios; %0d checks",cases,checks);$finish;
    end
endmodule
