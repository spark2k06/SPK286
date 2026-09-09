`timescale 1ns/1ps
module spk286_far_instructions_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:1114111];
    logic [127:0] initial_gpr, expected_gpr;
    logic [15:0] initial_flags,expected_ip;
    logic [63:0] expected_segments;
    logic [7:0] expected_bytes [0:511];
    integer expected_addresses [0:511];
    logic [15:0] transaction_data [0:255];
    integer transaction_addresses [0:255];
    logic transaction_write [0:255], transaction_bhe [0:255];
    integer file_handle, total, fields, vector_word, length, fault, observed_fault;
    integer cases=0, checks=0, retires=0, transaction_count, transactions, ram_count, a;
    integer wait_length, wait_count, timeout_count, immediate_stalls=0;
    logic waiting;
    logic [23:0] held_address;
    logic [15:0] held_data;
    logic [3:0] held_status;
    logic held_write, held_bhe;
    string path;
    spk286 dut (.*);
    task automatic check(input logic condition,input string message);
        checks++;
        if (condition !== 1'b1)
            $fatal(1,"%s case=%0d opcode=%h IP=%h pc=%h SP=%h BP=%h transactions=%0d/%0d",message,cases,debug_opcode,debug_ip,debug_micro_pc,debug_gpr[64+:16],debug_gpr[80+:16],transactions,transaction_count);
    endtask
    task automatic scan;
        fields=$fscanf(file_handle,"%h",vector_word);
        if (fields!=1) $fatal(1,"malformed frame vector");
    endtask
    task automatic tick;
        #1;
        data_in=16'hF4F4;
        if (bus_valid && address<24'd1114112)
            data_in={memory[{address[20:1],1'b1}],memory[{address[20:1],1'b0}]};
        if (bus_valid && address[0]) data_in[7:0]=8'hA3;
        if (bus_valid && bus_bhe_n) data_in[15:8]=8'hC7;
        #4;
        if (execute_enable && debug_micro_active && !dut.queue_consume_valid &&
            (debug_micro_instruction==spk286_microcode_pkg::MC_FETCH_IMM16 || debug_micro_instruction==spk286_microcode_pkg::MC_FETCH_IMM8_TMP1)) immediate_stalls++;
        if (bus_valid && ready && !reset && (bus_status==5 || bus_status==6)) begin
            check(transactions<transaction_count,"no extra data transfer");
            check(int'(address)==transaction_addresses[transactions] && bus_write==transaction_write[transactions] && bus_bhe_n==transaction_bhe[transactions],"exact data transaction order, direction and lanes");
            check(data_oe==bus_write,"data bus drive direction");
            if (bus_write) begin
                if (address[0]) begin
                    check(data_out[15:8]==transaction_data[transactions][15:8],"odd first write byte");
                    memory[address[20:0]]=data_out[15:8];
                end else begin
                    check(data_out[7:0]==transaction_data[transactions][7:0],"low write byte");
                    memory[address[20:0]]=data_out[7:0];
                    if (!bus_bhe_n) begin
                        check(data_out[15:8]==transaction_data[transactions][15:8],"high write byte");
                        memory[address+1]=data_out[15:8];
                    end
                end
            end
            transactions++;
        end
        clk=1;#5;clk=0;#1;
        if (instruction_retired) retires++;
        check(debug_prefetch_count<=6 && !microcode_fault,"valid microcode branch and queue bounds");
    endtask
    task automatic service;
        #1;
        if (waiting) check(bus_valid && address==held_address && data_out==held_data && bus_status==held_status && bus_write==held_write && bus_bhe_n==held_bhe,"READY holds transfer ownership and data");
        ready=bus_valid && wait_count>=wait_length;
        waiting=bus_valid && !ready;
        if (waiting) begin
            held_address=address;held_data=data_out;held_status=bus_status;
            held_write=bus_write;held_bhe=bus_bhe_n;wait_count++;
        end else wait_count=0;
        tick();
    endtask
    task automatic setup;
        execute_enable=0;reset=1;ready=0;hold_request=0;intr=0;nmi=0;
        gpr_write_en=0;flags_write_en=0;ip_write_en=0;redirect=0;segment_load_en=0;
        waiting=0;wait_count=0;transactions=0;retires=0;
        tick();reset=0;
        for (integer r=0;r<8;r++) begin
            gpr_write_en=1;gpr_write_index=3'(r);gpr_write_data=initial_gpr[r*16+:16];tick();
        end
        gpr_write_en=0;flags_write_en=1;flags_write_mask=16'hFFFF;flags_write_data=initial_flags;
        tick();flags_write_en=0;
        for (integer s=0;s<4;s++) begin
            segment_load_en=1;segment_load_index=2'(s);
            segment_load_selector=s==0?16'h2000:s==1?16'h1000:s==2?16'h8000:16'h4000;
            redirect=s==1;ip_write_en=s==1;ip_write_data=16'h0100;tick();
        end
        segment_load_en=0;redirect=0;ip_write_en=0;execute_enable=1;
    endtask
    initial begin
        if (!$value$plusargs("instruction_vectors=%s",path)) $fatal(1,"missing frame vectors");
        file_handle=$fopen(path,"r");if (file_handle==0) $fatal(1,"cannot open frame vectors");
        scan();total=vector_word;
        for (integer i=0;i<total;i++) begin
            scan();length=vector_word;
            for (integer b=0;b<8;b++) begin scan();memory[65792+b]=8'(vector_word);end
            scan();initial_flags=16'(vector_word);
            for (integer r=0;r<8;r++) begin scan();initial_gpr[r*16+:16]=16'(vector_word);end
            for (integer r=0;r<8;r++) begin scan();expected_gpr[r*16+:16]=16'(vector_word);end
            scan();expected_ip=16'(vector_word);
            for(integer s=0;s<4;s++)begin scan();expected_segments[s*16+:16]=16'(vector_word);end
            scan();fault=vector_word;scan();wait_length=vector_word;
            scan();ram_count=vector_word;
            for (integer b=0;b<ram_count;b++) begin scan();a=vector_word;scan();memory[a]=8'(vector_word);end
            scan();ram_count=vector_word;check(ram_count<=512,"RAM vector capacity");
            for (integer b=0;b<ram_count;b++) begin scan();expected_addresses[b]=vector_word;scan();expected_bytes[b]=8'(vector_word);end
            scan();transaction_count=vector_word;check(transaction_count<=256,"transaction vector capacity");
            for (integer t=0;t<transaction_count;t++) begin
                scan();transaction_write[t]=vector_word!=0;scan();transaction_addresses[t]=vector_word;
                scan();transaction_bhe[t]=vector_word!=0;scan();transaction_data[t]=16'(vector_word);
            end
            setup();timeout_count=0;
            while (!instruction_retired && !dut.fault_request && timeout_count<2000) begin
                service();timeout_count++;check(!unsupported_opcode,"supported far-pointer/control form");
            end
            observed_fault=dut.fault_request?int'(dut.fault_vector):0;
            execute_enable=0;
            repeat (3) service();
            check(observed_fault==fault && retires==(fault==0?1:0),"exact fault producer or single retirement");
            if (fault==0) check(debug_ip==expected_ip,"exact pointer/return target address");
            check(transactions==transaction_count,"complete ordered data transfers");
            check(debug_gpr==expected_gpr,"all architectural GPR results and preservation");
            check(debug_flags==initial_flags,"FLAGS preserved");
            check(debug_segment_selectors==expected_segments,"exact segment selector disposition");
            for(integer segment=0;segment<4;segment++)begin
                check(debug_segment_bases[segment*24+:24]=={4'd0,expected_segments[segment*16+:16],4'd0} &&
                      debug_segment_limits[segment*16+:16]==16'hFFFF && debug_segment_access[segment*8+:8]==8'h93,"coherent real-mode selector/base/limit/access cache");
            end
            for (integer b=0;b<ram_count;b++) check(memory[expected_addresses[b]]==expected_bytes[b],"pointer/link memory and neighbors");
            cases++;
        end
        $fclose(file_handle);
        check(cases==total && cases==6760 && immediate_stalls>0,"complete frame matrix and immediate starvation");
        $display("FAR_INSTRUCTIONS PASS: %0d cases; %0d checks; %0d immediate stalls",cases,checks,immediate_stalls);
        $finish;
    end
endmodule
