`timescale 1ns/1ps
// Public CPU boundary: a complete legal ten-byte encoding must not become a
// demand for byte11 while RAW completion clears its prefix context.
module spk286_length_boundary_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:1048575];
    integer checks=0,cases=0,retires=0,writes=0,wait_count=0,wait_length=0;
    integer timeout_count;
    logic waiting=0;
    logic [23:0] held_address;
    logic [15:0] held_data;
    logic [3:0] held_status;
    logic held_bhe,held_write;
    spk286 dut(.*);
    task automatic check(input logic okay,input string why);
        begin
            checks=checks+1;
            if(okay!==1'b1) $fatal(1,"RAW_LENGTH_BOUNDARY_FAILED %s case=%0d ip=%04h vector=%0d retires=%0d",
                                  why,cases,debug_ip,debug_event_vector,retires);
        end
    endtask
    task automatic tick;
        begin
            #1; data_in=16'hF4F4;
            if(bus_valid && address<24'h100000)
                data_in={memory[{address[19:1],1'b1}],memory[{address[19:1],1'b0}]};
            #4;
            if(bus_valid && ready && !reset && bus_write) begin
                check(address<24'h100000,"write remains within the fixture RAM");
                writes=writes+1;
                if(address[0]) memory[address[19:0]]=data_out[15:8];
                else begin
                    memory[address[19:0]]=data_out[7:0];
                    if(!bus_bhe_n) memory[address[19:0]+20'd1]=data_out[15:8];
                end
            end
            clk=1; #5; clk=0; #1;
            if(instruction_retired) retires=retires+1;
            check(!microcode_fault&&!control_error&&!unsupported_opcode&&!shutdown,
                  "normal CPU services stay valid");
        end
    endtask
    task automatic service;
        begin
            #1;
            if(waiting) check(bus_valid&&address==held_address&&data_out==held_data&&
                bus_status==held_status&&bus_bhe_n==held_bhe&&bus_write==held_write,
                "offered bus cycle is stable through READY waits");
            ready=bus_valid&&wait_count>=wait_length;
            waiting=bus_valid&&!ready;
            if(waiting) begin
                held_address=address; held_data=data_out; held_status=bus_status;
                held_bhe=bus_bhe_n; held_write=bus_write; wait_count=wait_count+1;
            end else wait_count=0;
            tick();
        end
    endtask
    task automatic setup(input logic [15:0] flags);
        begin
            execute_enable=0; reset=1; ready=0; intr=0; nmi=0; hold_request=0;
            redirect=0; ip_write_en=0; gpr_write_en=0; flags_write_en=0; segment_load_en=0;
            waiting=0; wait_count=0; retires=0; writes=0; tick(); reset=0;
            for(integer i=0;i<8;i=i+1) begin
                gpr_write_en=1; gpr_write_index=3'(i);
                gpr_write_data=i==4?16'h8000:16'hA55A; tick();
            end
            gpr_write_en=0; flags_write_en=1; flags_write_mask=16'hFFFF;
            flags_write_data=flags; tick(); flags_write_en=0;
            for(integer i=0;i<4;i=i+1) begin
                segment_load_en=1; segment_load_index=2'(i);
                segment_load_selector=i==1?16'h1000:(i==2?16'h8000:(i==3?16'h4000:16'h2000));
                redirect=i==1; ip_write_en=i==1; ip_write_data=16'h0100; tick();
            end
            segment_load_en=0; redirect=0; ip_write_en=0; execute_enable=1;
        end
    endtask
    task automatic image(input integer prefix_count);
        begin
            for(integer i=0;i<20;i=i+1) memory[20'h10100+20'(i)]=8'hF4;
            for(integer i=0;i<prefix_count;i=i+1) memory[20'h10100+20'(i)]=8'h3E;
            memory[20'h10100+20'(prefix_count)]=8'hC7;
            memory[20'h10101+20'(prefix_count)]=8'h06;
            memory[20'h10102+20'(prefix_count)]=8'h20;
            memory[20'h10103+20'(prefix_count)]=8'h07;
            memory[20'h10104+20'(prefix_count)]=8'h34;
            memory[20'h10105+20'(prefix_count)]=8'h12;
            memory[20'h10106+20'(prefix_count)]=8'hB8;
            memory[20'h10107+20'(prefix_count)]=8'h78;
            memory[20'h10108+20'(prefix_count)]=8'h56;
            memory[20'h40720]=8'hB2; memory[20'h40721]=8'hA1;
        end
    endtask
    task automatic await_event(input integer vector,input logic [15:0] frame_ip);
        begin
            timeout_count=0;
            while(!event_completed&&timeout_count<1500) begin service(); timeout_count=timeout_count+1; end
            check(timeout_count<1500&&debug_event_vector==8'(vector),"expected event completes");
            check({memory[20'h87FFB],memory[20'h87FFA]}==frame_ip,
                  "event frame IP belongs to the correct instruction boundary");
            check(debug_cs==16'h3000&&debug_ip==16'h2000,"event vector transaction completes");
        end
    endtask
    initial begin
        for(integer vector=1;vector<=13;vector=vector+1) begin
            memory[vector*4]=0; memory[vector*4+1]=8'h20;
            memory[vector*4+2]=0; memory[vector*4+3]=8'h30;
        end
        memory[20'h32000]=8'hF4; memory[20'h32001]=8'hF4;
        for(integer delay=0;delay<4;delay=delay+1) begin
            image(4); wait_length=delay; setup(16'h0002); timeout_count=0;
            // Continue through both following instructions. Stopping at the
            // first retirement would miss the original ghost length fault.
            while((!halted||retires<3)&&timeout_count<1500) begin
                service(); timeout_count=timeout_count+1;
                check(!event_completed,"legal ten-byte completion must not raise a following #GP");
            end
            check(timeout_count<1500&&debug_gpr[15:0]==16'h5678&&retires==3,
                  "legal ten-byte store then MOV then HLT executes continuously");
            check({memory[20'h40721],memory[20'h40720]}==16'h1234&&writes==1,
                  "legal ten-byte operand store commits exactly once");
            execute_enable=0; cases=cases+1;

            image(5); wait_length=delay; setup(16'h0002); await_event(13,16'h0100);
            check(retires==0&&debug_gpr[15:0]==16'hA55A&&writes==3,
                  "eleven-byte encoding faults before any normal retirement");
            check({memory[20'h40721],memory[20'h40720]}==16'hA1B2,
                  "eleven-byte store never reaches its operand");
            execute_enable=0; cases=cases+1;
        end
        image(4); wait_length=2; setup(16'h0102); await_event(1,16'h010A);
        check(retires==1&&{memory[20'h40721],memory[20'h40720]}==16'h1234&&
              debug_gpr[15:0]==16'hA55A,"trap follows complete ten-byte store before successor");
        execute_enable=0; cases=cases+1;

        image(4); wait_length=3; setup(16'h0002); timeout_count=0;
        while(!instruction_retired&&timeout_count<1500) begin service(); timeout_count=timeout_count+1; end
        check(timeout_count<1500,"ten-byte instruction reaches the public retirement boundary");
        nmi=1; service(); nmi=0; await_event(2,16'h010A);
        check(retires==1&&debug_gpr[15:0]==16'hA55A,"NMI preserves the following instruction boundary");
        execute_enable=0; cases=cases+1;
        check(cases==10,"all bounded length/READY/event cases complete");
        $display("LENGTH_BOUNDARY PASS: %0d cases; %0d checks",cases,checks); $finish;
    end
endmodule
