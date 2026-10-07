`timescale 1ns/1ps

// Intel 80286 PRM chapter 9. Target selector RPL is ignored by gates.
// Gate DPL checks depend on software versus external event origin.
module spk286_gate_target_rpl_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    integer cycles = 0, checks = 0, cases = 0;
    logic fault_seen = 0;
    logic [7:0] first_vector;
    logic [15:0] first_error;
    spk286 dut (.*);

    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1)
            $fatal(1,"GATE_RPL %s case=%0d CS:IP=%h:%h SS:SP=%h:%h FLAGS=%h event=%h micro=%h",
                   message,cases,debug_cs,debug_ip,debug_segment_selectors[47:32],
                   debug_gpr[79:64],debug_flags,debug_event_vector,debug_micro_pc);
    endtask
    task automatic tick;
        #1;
        if (dut.fault_request && !fault_seen) begin
            fault_seen=1; first_vector=dut.fault_vector; first_error=dut.fault_error_code;
        end
        ready = bus_valid && ((cycles % 4) != 1);
        data_in = 0;
        if (bus_valid && !bus_write) begin
            if (address[0]) data_in = {memory[address[15:0]],8'd0};
            else if (bus_bhe_n) data_in = {8'd0,memory[address[15:0]]};
            else data_in = {memory[address[15:0]+16'd1],memory[address[15:0]]};
        end
        if (bus_valid && bus_status == 0) data_in = 16'h0020; // PIC INTA vector.
        if (bus_valid && ready && bus_write && bus_status == 6) begin
            if (address[0]) memory[address[15:0]] = data_out[15:8];
            else begin
                memory[address[15:0]] = data_out[7:0];
                if (!bus_bhe_n) memory[address[15:0]+16'd1] = data_out[15:8];
            end
        end
        #4; clk = 1; #5; clk = 0; #1;
        cycles = cycles + 1;
    endtask
    task automatic word_at(input integer addr, input logic [15:0] value);
        memory[addr] = value[7:0]; memory[addr+1] = value[15:8];
    endtask
    function automatic logic [15:0] read_word(input integer addr);
        read_word = {memory[addr+1],memory[addr]};
    endfunction
    task automatic cache(input integer addr, input logic [15:0] base_addr,
                         input logic [7:0] access_byte, input logic [15:0] limit_value);
        word_at(addr,base_addr); word_at(addr+2,{access_byte,8'd0}); word_at(addr+4,limit_value);
    endtask
    task automatic descriptor(input integer addr, input logic [7:0] access_byte);
        word_at(addr,16'hFFFF); word_at(addr+2,0); word_at(addr+4,{access_byte,8'd0}); word_at(addr+6,0);
    endtask

    task automatic run_case(input logic [1:0] cpl, input logic [1:0] dpl,
                            input logic [1:0] target_rpl, input logic conforming,
                            input logic trap_gate, input integer origin,
                            input logic denied, input logic [1:0] policy);
        logic [1:0] final_cpl, gate_dpl;
        logic [15:0] old_flags, source_cs, source_ss, final_cs, final_ss, frame_sp;
        integer vector_num, gate_addr, deadline;
        reset=1; execute_enable=0; intr=0; nmi=0; timing_policy_request=policy;
        repeat (4) tick();
        fault_seen=0; first_vector=0; first_error=0;
        for (integer i='h800;i<'h866;i++) memory[i]=0;
        final_cpl=conforming ? cpl : dpl;
        gate_dpl=denied ? cpl-2'd1 : cpl;
        source_cs=16'h0008 | {14'd0,cpl}; source_ss=16'h0010 | {14'd0,cpl};
        final_cs=16'h0018 | {14'd0,final_cpl};
        final_ss=final_cpl==cpl ? source_ss : (16'h0020 | {14'd0,final_cpl});
        old_flags=16'h3202;
        vector_num=origin==2 ? 2 : 32;
        memory['h40]=8'h0F; memory['h41]=8'h05;
        word_at('h806,1); word_at('h816,16'h0028); word_at('h818,old_flags); word_at('h81A,16'h0100);
        word_at('h81E,16'h0033); word_at('h820,source_ss); word_at('h822,source_cs); word_at('h824,16'h0033); word_at('h82C,16'hF000);
        cache('h836,0,8'hF3,16'hFFFF); cache('h83C,0,8'h9B | {1'b0,cpl,5'd0},16'hFFFF);
        cache('h842,0,8'h93 | {1'b0,cpl,5'd0},16'hFFFF); cache('h848,0,8'hF3,16'hFFFF);
        cache('h84E,16'h4000,0,16'h003F); cache('h85A,16'h5000,0,16'h0107); cache('h860,16'h6000,8'h83,16'h002B);
        descriptor('h4008,8'h9B | {1'b0,cpl,5'd0}); descriptor('h4010,8'h93 | {1'b0,cpl,5'd0});
        descriptor('h4018,8'h9B | {1'b0,dpl,5'd0} | (conforming ? 8'h04 : 0));
        descriptor('h4020,8'h93 | {1'b0,final_cpl,5'd0}); descriptor('h4030,8'hF3);
        word_at('h6002,16'hE000); word_at('h6004,16'h0020);
        word_at('h6006,16'hE000); word_at('h6008,16'h0021);
        word_at('h600A,16'hE000); word_at('h600C,16'h0022);
        gate_addr='h5000+vector_num*8;
        word_at(gate_addr,16'h0200); word_at(gate_addr+2,16'h0018 | {14'd0,target_rpl});
        word_at(gate_addr+4,{8'h80 | {1'b0,gate_dpl,5'd0} | (trap_gate ? 8'h07 : 8'h06),8'd0}); word_at(gate_addr+6,0);
        memory['h100]=origin==0 ? 8'hCD : 8'h90; memory['h101]=origin==0 ? 8'h20 : 8'hEB;
        memory['h102]=origin==0 ? 8'hEB : 8'hFE; memory['h103]=8'hFE;
        memory['h200]=8'hCF;
        reset=0; segment_load_en=1; segment_load_index=1; segment_load_selector=0;
        ip_write_en=1; ip_write_data=16'h0040; redirect=1;
        tick(); segment_load_en=0; ip_write_en=0; redirect=0; execute_enable=1;
        deadline=0;
        if (origin!=0) begin
            while (!(instruction_retired && debug_opcode==8'h05) && deadline<1200) begin tick(); deadline++; end
            check(deadline<1200,"LOADALL completes before external interrupt");
            if (origin==1) intr=1; else nmi=1;
        end
        deadline=0;
        while (debug_timing_event_requests==0 && !shutdown && deadline<1200) begin tick(); deadline++; end
        intr=0; nmi=0;
        if (denied && origin==0) begin
            deadline=0;
            while (!fault_seen && deadline<1200) begin tick(); deadline++; end
            // Faults during delivery of a fault are covered by the double-fault benches.
            check(fault_seen && first_vector==13 && first_error==16'h0102,
                  "software INT checks gate DPL and reports IDT selector");
            check(debug_gpr[79:64]==16'hF000 && debug_cs==source_cs && debug_flags==old_flags,
                  "denied INT preserves the source context");
        end else begin
            deadline=0;
            while (!event_completed && !shutdown && deadline<1600) begin tick(); deadline++; end
            execute_enable=0;
            check(event_completed && !shutdown && debug_event_vector==8'(vector_num),"gate delivery completes for every target RPL");
            frame_sp=final_cpl==cpl ? 16'hEFFA : 16'hDFF6;
            check(debug_cs==final_cs && dut.current_cpl==final_cpl && debug_segment_selectors[47:32]==final_ss,
                  "CS RPL is normalized to the delivered CPL; conforming targets retain CPL");
            check(debug_gpr[79:64]==frame_sp && read_word(int'(frame_sp)+2)==source_cs && read_word(int'(frame_sp)+4)==old_flags,
                  "exact frame size and saved source FLAGS/CS");
            check(debug_flags== (trap_gate ? 16'h3202 : 16'h3002),"gate kind controls live IF");
            if (final_cpl<cpl) check(read_word(int'(frame_sp)+6)==16'hF000 && read_word(int'(frame_sp)+8)==source_ss,"inward gate saves source SS:SP");
            if (origin==0) check(read_word(int'(frame_sp))==16'h0102,"software INT saves the following IP");
            execute_enable=1; deadline=0;
            while (!(instruction_retired && debug_opcode==8'hCF) && !shutdown && deadline<1600) begin tick(); deadline++; end
            check(!shutdown && instruction_retired && debug_cs==source_cs && debug_gpr[79:64]==16'hF000 && debug_flags==old_flags,
                  "ordinary IRET restores source state after arbitrary gate target RPL");
        end
        cases++;
    endtask
    initial begin
        for (integer i=0;i<65536;i++) memory[i]=0;
        for (integer policy=0;policy<3;policy++)
            for (integer cpl=0;cpl<4;cpl++)
                for (integer dpl=0;dpl<=cpl;dpl++)
                    for (integer rpl=0;rpl<4;rpl++)
                        for (integer conforming=0;conforming<2;conforming++)
                            for (integer gate=0;gate<2;gate++)
                                for (integer origin=0;origin<3;origin++)
                                    run_case(2'(cpl),2'(dpl),2'(rpl),1'(conforming),1'(gate),origin,0,2'(policy));
        for (integer cpl=1;cpl<4;cpl++)
            for (integer rpl=0;rpl<4;rpl++)
                for (integer origin=0;origin<3;origin++)
                    run_case(2'(cpl),2'(cpl),2'(rpl),0,0,origin,1,0);
        $display("GATE_RPL PASS: %0d checks / %0d cases",checks,cases); $finish;
    end
endmodule
