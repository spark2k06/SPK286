`timescale 1ns/1ps
module spk286_event_streams_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory[0:1114111];
    integer tags[0:1114111];
    integer addresses[0:4095], expected_bytes[0:4095];
    integer directions[0:63], locations[0:63], values[0:63], lanes[0:63];
    integer file_handle, fields, value, total, cases=0, checks=0, histories=0;
    integer initial_flags, initial_sp, wait_length, waits, memory_count, count;
    integer expected_regs[0:7], expected_cs, expected_ip, expected_flags;
    integer expected_retire, expected_kind, expected_vector, expected_halt;
    integer expected_pending, expected_blocked, expected_shadow, expected_acks;
    integer transfers, transfer_index, acks, retires, deliveries, timeout_count;
    logic waiting, held_bhe, held_write, held_lock;
    logic [23:0] held_address;
    logic [15:0] held_data;
    logic [3:0] held_status;
    string path;
    spk286 dut(.*);
    task automatic check(input logic condition,input string message);
        checks=checks+1;
        if(condition!==1'b1) $fatal(1,"%s case=%0d step=%0d cs:ip=%h:%h flags=%h SP=%h event=%0d/%0d transfer=%0d/%0d",
            message,cases,histories,debug_cs,debug_ip,debug_flags,debug_gpr[79:64],debug_event_kind,debug_event_vector,transfer_index,transfers);
    endtask
    task automatic scan;
        fields=$fscanf(file_handle,"%h",value);
        if(fields!=1) $fatal(1,"malformed event stream vector");
    endtask
    function automatic logic [7:0] byte_at(input logic [23:0] location);
        if(location<24'd1114112 && tags[location[20:0]]==cases+1) byte_at=memory[location[20:0]];
        else byte_at=8'h0F;
    endfunction
    task automatic tick;
        #1;data_in={byte_at({address[23:1],1'b1}),byte_at({address[23:1],1'b0})};
        if(bus_valid && bus_status==0) data_in=acks==0 ? 16'hC399 : 16'hD542;
        #4;
        if(bus_valid && ready && !reset) begin
            if(bus_status==0) begin
                check(acks<expected_acks && bus_lock && !bus_write && !data_oe && address==0 && bus_bhe_n,"modeled acknowledgement pair and lane");
                acks=acks+1;
            end else if(bus_status==5 || bus_status==6) begin
                check(transfer_index<transfers,"stream has no unmodeled data operation");
                check(int'(address)==locations[transfer_index] && int'(bus_write)==directions[transfer_index] && int'(bus_bhe_n)==lanes[transfer_index],"stream ordered word address and lanes");
                check(tags[address[20:0]]==cases+1,"stream accesses initialized data only");
                if(bus_write) begin
                    check(data_oe,"stream write owns output bus");
                    if(address[0]) begin
                        check(data_out[15:8]==8'(values[transfer_index]>>8),"stream odd high lane write");
                        memory[address[20:0]]=data_out[15:8];
                    end else begin
                        check(data_out[7:0]==8'(values[transfer_index]),"stream low lane write");
                        memory[address[20:0]]=data_out[7:0];
                        if(!bus_bhe_n) begin
                            check(data_out==16'(values[transfer_index]) && tags[address+1]==cases+1,"stream complete initialized word write");
                            memory[address+1]=data_out[15:8];
                        end
                    end
                end
                transfer_index=transfer_index+1;
            end
        end
        clk=1;#5;clk=0;#1;
        if(instruction_retired) retires=retires+1;
        if(event_completed) deliveries=deliveries+1;
        check(!microcode_fault && debug_prefetch_count<=6,"stream internal invariants");
    endtask
    task automatic service;
        #1;
        if(waiting) check(bus_valid && address==held_address && data_out==held_data && bus_status==held_status &&
            bus_bhe_n==held_bhe && bus_write==held_write && bus_lock==held_lock,"stream READY holds owner metadata");
        ready=bus_valid && waits>=wait_length;
        waiting=bus_valid && !ready;
        if(waiting) begin
            waits=waits+1;held_address=address;held_data=data_out;held_status=bus_status;
            held_bhe=bus_bhe_n;held_write=bus_write;held_lock=bus_lock;
        end else waits=0;
        tick();
    endtask
    task automatic setup;
        reset=1;execute_enable=0;ready=0;intr=0;nmi=0;waiting=0;waits=0;
        transfer_index=0;acks=0;retires=0;deliveries=0;tick();reset=0;
        for(integer r=0;r<8;r=r+1) begin
            gpr_write_en=1;gpr_write_index=3'(r);gpr_write_data=r==4 ? 16'(initial_sp) : 16'hA500+16'(r);tick();
        end
        gpr_write_en=0;flags_write_en=1;flags_write_mask=16'hFFFF;flags_write_data=16'(initial_flags);tick();flags_write_en=0;
        for(integer s=0;s<4;s=s+1) begin
            segment_load_en=1;segment_load_index=2'(s);segment_load_selector=s==1 ? 16'h1000 : (s==2 ? 16'h8000 : 16'h4000);
            redirect=s==1;ip_write_en=s==1;ip_write_data=16'h0100;tick();
        end
        segment_load_en=0;redirect=0;ip_write_en=0;
    endtask
    initial begin
        if(!$value$plusargs("stream_vectors=%s",path)) $fatal(1,"missing stream vectors");
        file_handle=$fopen(path,"r");if(file_handle==0) $fatal(1,"cannot open stream vectors");
        scan();total=value;
        for(integer c=0;c<total;c=c+1) begin
            scan();initial_flags=value;scan();initial_sp=value;scan();wait_length=value;
            scan();memory_count=value;check(memory_count<=4096,"stream memory capacity");
            for(integer m=0;m<memory_count;m=m+1) begin
                scan();addresses[m]=value;tags[value]=cases+1;scan();memory[addresses[m]]=8'(value);scan();expected_bytes[m]=value;
            end
            setup();scan();count=value;check(count>20 && count<150,"bounded modeled stream length");
            for(integer step=0;step<count;step=step+1) begin
                scan();intr=1'(value);scan();nmi=1'(value);
                for(integer r=0;r<8;r=r+1) begin scan();expected_regs[r]=value;end
                scan();expected_cs=value;scan();expected_ip=value;scan();expected_flags=value;
                scan();expected_retire=value;scan();expected_kind=value;scan();expected_vector=value;scan();expected_halt=value;
                scan();expected_pending=value;scan();expected_blocked=value;scan();expected_shadow=value;scan();expected_acks=value;
                scan();transfers=value;check(transfers<=64,"stream transfer capacity");
                for(integer t=0;t<transfers;t=t+1) begin
                    scan();directions[t]=value;scan();locations[t]=value;scan();values[t]=value;scan();lanes[t]=value;
                end
                transfer_index=0;acks=0;retires=0;deliveries=0;timeout_count=0;execute_enable=1;
                // Always advance at least one clock; the previous completion
                // pulse is still visible while the next oracle record is read.
                service();timeout_count=1;
                while(!instruction_retired && !event_completed && timeout_count<1200) begin
                    service();timeout_count=timeout_count+1;check(!unsupported_opcode && !shutdown,"stream supported execution");
                end
                check(timeout_count<1200,"stream bounded progress under finite READY waits");
                check(retires==expected_retire && deliveries==(expected_vector==256 ? 0 : 1),"stream distinct retire and event completion");
                if(expected_vector!=256) check(int'(debug_event_vector)==expected_vector && int'(debug_event_kind)==expected_kind,"independent priority and vector history");
                for(integer r=0;r<8;r=r+1) check(debug_gpr[r*16+:16]==16'(expected_regs[r]),"stream dependent GPR and SP state");
                check(debug_cs==16'(expected_cs) && debug_ip==16'(expected_ip) && debug_flags==16'(expected_flags),"stream context and FLAGS history");
                check(debug_cs_base=={4'd0,debug_cs,4'd0},"stream coherent CS cache");
                check(int'(halted)==expected_halt && int'(debug_nmi_pending)==expected_pending && int'(debug_nmi_blocked)==expected_blocked && int'(debug_sti_shadow)==expected_shadow,"independent interruptibility history");
                check(transfer_index==transfers && acks==expected_acks,"stream complete modeled physical operations");
                histories=histories+1;
            end
            execute_enable=0;
            for(integer m=0;m<memory_count;m=m+1) check(memory[addresses[m]]==8'(expected_bytes[m]),"stream complete final RAM and untouched neighbors");
            cases=cases+1;
        end
        check(cases==total && cases==96,"complete deterministic stream set");
        $fclose(file_handle);$display("EVENT_STREAMS PASS: %0d streams; %0d completions; %0d checks",cases,histories,checks);$finish;
    end
endmodule
