`timescale 1ns/1ps
module spk286_scalar_io_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory[0:1114111];
    integer checks=0,cases=0,retires=0,reads=0,writes=0,wait_count=0,wait_length=0;
    integer timeout_count,first_prefix_ip,expected_ip;
    integer io_count=0, expected_io_count=0, port_number=0;
    logic writing, word_width;
    logic [15:0] expected_ax;
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
        if(bus_valid && bus_status==9)data_in=io_count==0?16'h37C1:16'hA69D;
        #4;
        if(bus_valid && ready && !reset && (bus_status==9 || bus_status==10))begin
            check(io_count<expected_io_count,"no duplicate I/O transaction");
            check(int'(address)==port_number+io_count,"physical I/O address sequence includes A16 carry");
            check(bus_status==(writing?10:9) && bus_write==writing && data_oe==writing,"I/O direction and drive ownership");
            check(bus_bhe_n==(word_width ? io_count!=0 : !address[0]),"exact I/O byte lane");
            if(writing)check(data_out==(address[0]?16'h5A00:(io_count==1?16'h00A5:(word_width?16'hA55A:16'h005A))),"I/O write payload");
            io_count++;
        end
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
        waiting=0;wait_count=0;retires=0;reads=0;writes=0;io_count=0;tick();reset=0;
        for(integer i=0;i<8;i++)begin
            gpr_write_en=1;gpr_write_index=3'(i);gpr_write_data=i==4?16'h8000:(i==2?16'(port_number):16'hA55A);tick();
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
    task automatic code_setup(input integer opcode,input integer prefixes);
        for(integer i=0;i<16;i++)memory[65792+i]=8'hF4;
        for(integer i=0;i<prefixes;i++)memory[65792+i]=8'h3E;
        memory[65792+prefixes]=8'(opcode);
        if(opcode<232)memory[65793+prefixes]=8'(port_number);
        word_width=(opcode%2)!=0;writing=(opcode&2)!=0;
        expected_io_count=word_width && (port_number%2)!=0 ? 2:1;
        expected_ax=writing?16'hA55A:(word_width?((port_number%2)!=0?16'h9D37:16'h37C1):((port_number%2)!=0?16'hA537:16'hA5C1));
    endtask
    initial begin
        for(integer family=0;family<8;family++)
          for(integer port_case=0;port_case<7;port_case++)
            for(integer delay=0;delay<4;delay++)
              for(integer prefixes=0;prefixes<2;prefixes++)begin
                case(port_case)
                    0:port_number=0;1:port_number=1;2:port_number=2;3:port_number=255;
                    4:port_number=256;5:port_number=65534;6:port_number=65535;
                    default:$fatal(1,"port domain");
                endcase
                if(family<4)port_number=port_number%256;
                code_setup(family<4?228+family:232+family,prefixes);
                wait_length=delay;setup(16'h0002);run_boundary(0);
                check(retires==1 && debug_gpr[15:0]==expected_ax,"complete I/O result and byte-half preservation");
                check(io_count==expected_io_count && reads==0 && writes==0,"port access count and memory isolation");
                check(debug_flags==16'h0002 && debug_gpr[32+:16]==16'(port_number),"I/O preserves FLAGS and DX");
                check(debug_ip==16'h0100+16'(prefixes)+(family<4?16'd2:16'd1),"I/O byte consumption");
                execute_enable=0;repeat(3)service();check(io_count==expected_io_count && retires==1,"no replay after retirement");cases++;
              end
        // Pause after acceptance. The physical response can complete while
        // execution is paused, but no port access may replay when it resumes.
        for(integer direction=0;direction<2;direction++)begin
            port_number=65535;code_setup(direction==0?237:239,0);wait_length=2;setup(16'h0002);timeout_count=0;
            while(!(bus_valid && bus_status==(direction==0?9:10)) && timeout_count<500)begin service();timeout_count++;end
            check(timeout_count<500 && io_count==0,"port request accepted before READY");execute_enable=0;
            repeat(12)service();check(io_count==2 && retires==0,"physical I/O completes once while consumer paused");
            execute_enable=1;run_boundary(0);check(io_count==2 && debug_gpr[15:0]==expected_ax,"resume consumes captured I/O response");
            execute_enable=0;cases++;
        end
        // A completed first lane is an irreversible external event even when
        // reset aborts the remaining instruction and clears CPU state.
        port_number=65535;code_setup(239,0);wait_length=2;setup(16'h0002);timeout_count=0;
        while(io_count<1 && timeout_count<500)begin service();timeout_count++;end
        check(io_count==1,"first external write accepted");reset=1;execute_enable=0;ready=0;tick();reset=0;repeat(5)service();
        check(io_count==1 && retires==0,"reset does not undo or replay accepted I/O");cases++;
        // Overlength input faults before the irreversible port read.
        memory[52]=0;memory[53]=8'h20;memory[54]=0;memory[55]=8'h30;
        port_number=23;code_setup(228,9);expected_io_count=0;wait_length=1;setup(16'h0002);run_boundary(1);
        check(io_count==0 && retires==0 && debug_event_vector==13 && reads==2 && writes==3,"length fault before I/O side effect");
        check({memory[524288+32768-5],memory[524288+32768-6]}==16'h0100,"I/O length-fault restart prefix IP");cases++;
        check(cases==452,"complete scalar I/O domain");
        $display("SCALAR_IO PASS: %0d cases; %0d checks",cases,checks);$finish;
    end
endmodule
