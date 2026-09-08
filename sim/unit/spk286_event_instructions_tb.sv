`timescale 1ns/1ps
module spk286_event_instructions_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory[0:1114111], code[0:7];
    integer total, fields, value, file_handle, cases=0, checks=0;
    integer initial_ip, initial_flags, initial_sp, initial_ss, expected_cs, expected_ip, expected_flags, expected_sp;
    integer expected_retired, expected_event, expected_halt, expected_shutdown;
    integer memory_count, addresses[0:63], expected_bytes[0:63];
    integer transfers, transfer_index, directions[0:31], locations[0:31], values[0:31], lanes[0:31];
    integer wait_length, waits, timeout_count, retires, events_seen;
    logic waiting;
    logic [23:0] held_address;
    logic [15:0] held_data;
    logic [3:0] held_status;
    logic held_bhe, held_write;
    string path;
    spk286 dut (.*);
    task automatic check(input logic condition, input string message);
        checks=checks+1;
        if (condition !== 1'b1) $fatal(1,"%s case=%0d op=%h IP=%h CS=%h SP=%h flags=%h micro=%h event=%d/%d shutdown=%b transfer=%0d/%0d",
            message,cases,code[0],debug_ip,debug_cs,debug_gpr[64+:16],debug_flags,
            debug_micro_pc,debug_event_kind,debug_event_vector,shutdown,transfer_index,transfers);
    endtask
    task automatic scan;
        fields=$fscanf(file_handle,"%h",value);
        if (fields!=1) $fatal(1,"malformed event vector");
    endtask
    task automatic tick;
        #1;
        data_in=16'h9090;
        if (bus_valid && address<24'd1114112)
            data_in={memory[{address[20:1],1'b1}],memory[{address[20:1],1'b0}]};
        if (address[0]) data_in[7:0]=8'hA3;
        if (bus_bhe_n) data_in[15:8]=8'hC7;
        #4;
        if (bus_valid && ready && !reset && (bus_status==5 || bus_status==6)) begin
            check(transfer_index<transfers,"no unmodeled data transfer");
            check(int'(address)==locations[transfer_index],"ordered physical address");
            check(int'(bus_write)==directions[transfer_index] && int'(bus_bhe_n)==lanes[transfer_index],"direction and byte lanes");
            check(data_oe==bus_write,"data drive ownership");
            if (bus_write) begin
                if (address[0]) begin
                    check(data_out[15:8]==8'(values[transfer_index]>>8),"odd lower word byte");
                    memory[address[20:0]]=data_out[15:8];
                end else begin
                    check(data_out[7:0]==8'(values[transfer_index]),"lower physical lane");
                    memory[address[20:0]]=data_out[7:0];
                    if (!bus_bhe_n) begin
                        check(data_out==16'(values[transfer_index]),"complete aligned write word");
                        memory[address+1]=data_out[15:8];
                    end
                end
            end
            transfer_index=transfer_index+1;
        end
        clk=1; #5; clk=0; #1;
        if (instruction_retired) retires=retires+1;
        if (event_completed) events_seen=events_seen+1;
        check(!microcode_fault && debug_prefetch_count<=6,"microcode and queue invariants");
    endtask
    task automatic service;
        #1;
        if (waiting) check(bus_valid && address==held_address && data_out==held_data &&
                           bus_status==held_status && bus_bhe_n==held_bhe && bus_write==held_write,"stable READY owner");
        ready=bus_valid && waits>=wait_length;
        waiting=bus_valid && !ready;
        if (waiting) begin
            waits=waits+1; held_address=address; held_data=data_out;
            held_status=bus_status; held_bhe=bus_bhe_n; held_write=bus_write;
        end else waits=0;
        tick();
    endtask
    task automatic setup;
        reset=1; execute_enable=0; ready=0; redirect=0; ip_write_en=0;
        segment_load_en=0; flags_write_en=0; gpr_write_en=0;
        retires=0; events_seen=0; transfer_index=0; waits=0; waiting=0;
        tick(); reset=0;
        for (integer r=0;r<8;r=r+1) begin
            gpr_write_en=1; gpr_write_index=3'(r); gpr_write_data=r==4 ? 16'(initial_sp) : 16'hA500+16'(r); tick();
        end
        gpr_write_en=0;
        flags_write_en=1; flags_write_mask=16'hFFFF; flags_write_data=16'(initial_flags); tick(); flags_write_en=0;
        for (integer s=0;s<4;s=s+1) begin
            segment_load_en=1; segment_load_index=2'(s);
            segment_load_selector=s==1 ? 16'h1000 : (s==2 ? 16'(initial_ss) : 16'h4000);
            redirect=s==1; ip_write_en=s==1; ip_write_data=16'(initial_ip); tick();
        end
        segment_load_en=0; redirect=0; ip_write_en=0; execute_enable=1;
    endtask
    initial begin
        if (!$value$plusargs("event_vectors=%s",path)) $fatal(1,"missing event vectors");
        file_handle=$fopen(path,"r");
        if (file_handle==0) $fatal(1,"cannot open event vectors");
        scan(); total=value;
        for (integer c=0;c<total;c=c+1) begin
            scan(); check(value>0 && value<=8,"instruction length");
            for (integer b=0;b<8;b=b+1) begin scan(); code[b]=8'(value); end
            scan(); initial_ip=value; scan(); initial_flags=value; scan(); initial_sp=value; scan(); initial_ss=value;
            scan(); expected_cs=value; scan(); expected_ip=value; scan(); expected_flags=value; scan(); expected_sp=value;
            scan(); expected_retired=value; scan(); expected_event=value; scan(); expected_halt=value; scan(); expected_shutdown=value;
            scan(); wait_length=value; scan(); memory_count=value; check(memory_count<=64,"memory vector capacity");
            for (integer m=0;m<memory_count;m=m+1) begin
                scan(); addresses[m]=value; scan(); memory[addresses[m]]=8'(value); scan(); expected_bytes[m]=value;
            end
            for (integer b=0;b<8;b=b+1) memory[65536+initial_ip+b]=code[b];
            scan(); transfers=value; check(transfers<=32,"transfer capacity");
            for (integer t=0;t<transfers;t=t+1) begin
                scan(); directions[t]=value; scan(); locations[t]=value; scan(); values[t]=value; scan(); lanes[t]=value;
            end
            setup(); timeout_count=0;
            while (!instruction_retired && !event_completed && !shutdown && timeout_count<800) begin
                service(); timeout_count=timeout_count+1;
                check(!unsupported_opcode,"admitted instruction");
            end
            check(timeout_count<800,"bounded architectural completion");
            check(retires==expected_retired,"fault versus instruction retirement");
            check(events_seen==(expected_event==256 ? 0 : 1),"explicit event completion");
            if (expected_event!=256) check(int'(debug_event_vector)==expected_event,"selected vector");
            check(int'(halted)==expected_halt && int'(shutdown)==expected_shutdown,"halt/shutdown outcome");
            check(debug_cs==16'(expected_cs) && debug_ip==16'(expected_ip) && debug_flags==16'(expected_flags),"exact CS IP FLAGS");
            check(debug_gpr[64+:16]==16'(expected_sp),"ordered committed SP");
            for (integer r=0;r<8;r=r+1)
                if (r!=4) check(debug_gpr[r*16+:16]==16'hA500+16'(r),"unrelated GPR preservation");
            check(debug_cs_base=={4'd0,debug_cs,4'd0} && debug_segment_limits==64'hFFFFFFFFFFFFFFFF,"real CS cache and limits");
            check(transfer_index==transfers,"complete physical access sequence");
            for (integer m=0;m<memory_count;m=m+1)
                check(memory[addresses[m]]==8'(expected_bytes[m]),"complete frame and neighboring RAM");
            execute_enable=0;
            repeat (4) service();
            check(retires==expected_retired && events_seen==(expected_event==256 ? 0 : 1),"completion pulses do not repeat under pause");
            cases=cases+1;
        end
        check(cases==total && total==1932,"complete event model set");
        $fclose(file_handle);
        $display("EVENT_INSTRUCTIONS PASS: %0d cases; %0d checks",cases,checks);
        $finish;
    end
endmodule
