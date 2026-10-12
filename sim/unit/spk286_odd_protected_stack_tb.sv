// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

// Intel 80286 PRM 2.2: words, including stack words, may be unaligned.
// Segment limits and complete frame ranges remain independent requirements.
module spk286_odd_protected_stack_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    integer cycles = 0, checks = 0, cases = 0;
    integer stack_reads = 0, stack_writes = 0, odd_reads = 0, odd_writes = 0;
    integer low_reads = 0, low_writes = 0;
    logic observe = 0, fault_seen = 0;
    logic [7:0] first_fault_vector = 0;
    spk286 dut (.*);
    task automatic check(input logic condition, input string message);
        checks = checks+1;
        if (condition !== 1'b1)
            $fatal(1,"ODD_STACK %s case=%0d CS:IP=%h:%h SS:SP=%h:%h fault=%h:%h reads=%0d writes=%0d micro=%h",
                   message,cases,debug_cs,debug_ip,debug_segment_selectors[47:32],debug_gpr[79:64],
                   debug_event_vector,debug_event_error_code,stack_reads,stack_writes,debug_micro_pc);
    endtask
    task automatic tick;
        #1;
        if (observe && dut.fault_request && !fault_seen) begin
            fault_seen = 1;
            first_fault_vector = dut.fault_vector;
        end
        ready = bus_valid && ((cycles % 4) != 1);
        data_in = 0;
        if (bus_valid && !bus_write) begin
            if (address[0]) data_in = {memory[address[15:0]],8'd0};
            else if (bus_bhe_n) data_in = {8'd0,memory[address[15:0]]};
            else data_in = {memory[address[15:0]+16'd1],memory[address[15:0]]};
        end
        if (observe && bus_valid && ready && address >= 24'h00D000 && bus_status == 5) begin
            stack_reads = stack_reads+1;
            if (address[0]) begin
                odd_reads = odd_reads+1;
                check(!bus_bhe_n,"odd read uses only the high byte lane");
            end else if (bus_bhe_n) low_reads = low_reads+1;
        end
        if (bus_valid && ready && bus_write && bus_status == 6) begin
            if (observe && address >= 24'h00D000) begin
                stack_writes = stack_writes+1;
                if (address[0]) begin
                    odd_writes = odd_writes+1;
                    check(!bus_bhe_n,"odd write uses only the high byte lane");
                end else if (bus_bhe_n) low_writes = low_writes+1;
            end
            if (address[0]) memory[address[15:0]] = data_out[15:8];
            else begin
                memory[address[15:0]] = data_out[7:0];
                if (!bus_bhe_n) memory[address[15:0]+16'd1] = data_out[15:8];
            end
        end
        #4; clk = 1; #5; clk = 0; #1; cycles = cycles+1;
    endtask
    task automatic word_put(input integer addr, input logic [15:0] value);
        memory[addr & 65535] = value[7:0]; memory[(addr+1) & 65535] = value[15:8];
    endtask
    function automatic logic [15:0] word_at(input integer addr);
        word_at = {memory[(addr+1) & 65535],memory[addr & 65535]};
    endfunction
    task automatic cache(input integer addr, input logic [15:0] base_addr,
                         input logic [15:0] limit_value, input logic [7:0] access_byte);
        word_put(addr,base_addr); word_put(addr+2,{access_byte,8'd0}); word_put(addr+4,limit_value);
    endtask
    task automatic descriptor(input integer addr, input logic [15:0] limit_value,
                              input logic [7:0] access_byte);
        word_put(addr,limit_value); word_put(addr+2,0); word_put(addr+4,{access_byte,8'd0}); word_put(addr+6,0);
    endtask
    task automatic run_case(input integer form, input logic expand_down, input logic odd_sp,
                            input integer boundary, input logic [1:0] policy);
        logic entry_case;
        logic [15:0] source_sp, target_sp, frame_sp, source_cs, source_ss, source_limit, target_limit;
        logic [15:0] expected_sp, expected_ip;
        integer deadline, frame_bytes, flags_pos, saved_sp_pos;
        reset = 1; execute_enable = 0; observe = 0; timing_policy_request = policy;
        repeat (4) tick();
        for (integer i = 'h800; i < 'h866; i = i+1) memory[i] = 0;
        for (integer i = 'hD000; i < 65536; i = i+1) memory[i] = 8'hCC;
        stack_reads=0; stack_writes=0; odd_reads=0; odd_writes=0; low_reads=0; low_writes=0;
        fault_seen=0; first_fault_vector=0;
        entry_case = form >= 3;
        source_sp = 16'hF000 + {15'd0,odd_sp};
        if (!entry_case && boundary == 2) source_sp = 16'hFFF9;
        target_sp = 16'hE000 + {15'd0,odd_sp};
        source_cs = entry_case ? 16'h001B : 16'h0008;
        source_ss = entry_case ? 16'h0023 : 16'h0010;
        frame_bytes = form == 0 ? 8 : form == 1 ? 12 : form == 2 ? 10 : form == 3 ? 12 : 10;
        source_limit = expand_down ? 16'hEFFF : 16'hFFFF;
        target_limit = expand_down ? 16'hDFF0 : 16'hFFFF;
        if (boundary == 1) begin
            if (entry_case) target_limit = expand_down ? target_sp-16'(frame_bytes) : target_sp-16'd3;
            else source_limit = expand_down ? source_sp : source_sp+16'(frame_bytes)-16'd2;
        end
        if (entry_case && boundary == 2) target_sp = 16'h0009; // Too little space, not an alignment fault.
        memory['h40] = 8'h0F; memory['h41] = 8'h05;
        word_put('h806,1); word_put('h816,16'h0028); word_put('h818,16'h3202); word_put('h81A,16'h0100);
        word_put('h81E,16'h0023); word_put('h820,source_ss); word_put('h822,source_cs); word_put('h824,16'h0023);
        word_put('h82C,source_sp);
        cache('h836,0,16'hFFFF,8'hF3);
        cache('h83C,0,16'hFFFF,entry_case ? 8'hFB : 8'h9B);
        cache('h842,0,source_limit,(entry_case ? 8'hF3 : 8'h93) | (expand_down ? 8'h04 : 8'h00));
        cache('h848,0,16'hFFFF,8'hF3); cache('h84E,16'h4000,16'h003F,0);
        cache('h85A,16'h5000,16'h0107,0); cache('h860,16'h6000,16'h002B,8'h83);
        descriptor('h4008,16'hFFFF,8'h9B);
        descriptor('h4010,entry_case ? target_limit : source_limit,8'h93 | (expand_down ? 8'h04 : 8'h00));
        descriptor('h4018,16'hFFFF,8'hFB); descriptor('h4020,16'hFFFF,8'hF3);
        word_put('h6002,target_sp); word_put('h6004,16'h0010);
        word_put('h4030,16'h0200); word_put('h4032,16'h0008); word_put('h4034,16'hE402); word_put('h4036,0);
        word_put('h5100,16'h0200); word_put('h5102,16'h0008);
        word_put('h5104,form == 5 ? 16'hE700 : 16'hE600); word_put('h5106,0);
        memory['h300] = 8'hEB; memory['h301] = 8'hFE;
        if (entry_case) begin
            memory['h100] = form == 3 ? 8'h9A : 8'hCD;
            if (form == 3) begin
                word_put('h101,0); word_put('h103,16'h0033);
                memory['h200] = 8'hCA; word_put('h201,4);
            end else begin memory['h101]=8'h20; memory['h200]=8'hCF; end
            word_put(int'(source_sp),16'hA55A); word_put(int'(source_sp)+2,16'h1234);
            expected_ip = form == 3 ? 16'h0105 : 16'h0102;
            expected_sp = source_sp + (form == 3 ? 16'd4 : 16'd0);
        end else begin
            memory['h100] = form == 0 ? 8'hCB : form == 1 ? 8'hCA : 8'hCF;
            word_put('h101,4);
            word_put(int'(source_sp),16'h0300); word_put(int'(source_sp)+2,16'h001B);
            flags_pos=int'(source_sp)+4;
            if (form == 2) word_put(flags_pos,16'h3202);
            saved_sp_pos=int'(source_sp)+(form == 0 ? 4 : form == 1 ? 8 : 6);
            word_put(saved_sp_pos,target_sp); word_put(saved_sp_pos+2,16'h0023);
            expected_ip=16'h0300; expected_sp=target_sp+(form == 1 ? 16'd4 : 16'd0);
        end
        reset=0; segment_load_en=1; segment_load_index=1; segment_load_selector=0;
        ip_write_en=1; ip_write_data=16'h0040; redirect=1;
        tick(); segment_load_en=0; ip_write_en=0; redirect=0; execute_enable=1; observe=1;
        deadline=0;
        while (!fault_seen && !shutdown &&
               !(debug_cs == (entry_case ? 16'h0008 : 16'h001B) && debug_ip == (entry_case ? 16'h0200 : expected_ip)) && deadline<2200) begin
            tick(); deadline=deadline+1;
        end
        if (boundary != 0) begin
            check(fault_seen && first_fault_vector == 12 && !instruction_retired,
                  "invalid complete frame is rejected with #SS for both returns and gates");
            check(debug_cs == source_cs && debug_gpr[79:64] == source_sp && stack_writes == 0,
                  "failed range check preserves source context and prevents frame writes");
        end else if (!entry_case) begin
            check(debug_cs == 16'h001B && debug_ip == expected_ip && debug_gpr[79:64] == expected_sp &&
                  debug_segment_selectors[47:32] == 16'h0023 && debug_timing_event_requests == 0,
                  "odd outer RETF/RETF-immediate/IRET publishes the complete return");
            check(stack_reads == (odd_sp ? frame_bytes : frame_bytes/2) - (form == 1 ? (odd_sp ? 4 : 2) : 0) && stack_writes == 0,
                  "source frame uses the exact byte/word bus transfers");
            if (odd_sp) check(odd_reads == low_reads && odd_reads != 0,"odd source words use paired byte lanes");
        end else begin
            frame_sp=target_sp-16'(frame_bytes); execute_enable=0;
            check(debug_cs == 16'h0008 && debug_ip == 16'h0200 && debug_gpr[79:64] == frame_sp &&
                  debug_segment_selectors[47:32] == 16'h0010,"odd new stack accepts the complete gate frame");
            check(word_at(int'(frame_sp)) == expected_ip && word_at(int'(frame_sp)+2) == source_cs,
                  "gate frame contains exact return IP and CS");
            if (form == 3)
                check(word_at(int'(frame_sp)+4) == 16'hA55A && word_at(int'(frame_sp)+6) == 16'h1234 &&
                      word_at(int'(frame_sp)+8) == source_sp && word_at(int'(frame_sp)+10) == source_ss,
                      "call gate copies both odd-addressed parameters and the old stack");
            else check(word_at(int'(frame_sp)+4) == 16'h3202 && word_at(int'(frame_sp)+6) == source_sp &&
                       word_at(int'(frame_sp)+8) == source_ss,"interrupt frame saves FLAGS and old stack");
            check(stack_writes == (odd_sp ? frame_bytes : frame_bytes/2),"exact frame write transfer count");
            if (odd_sp) check(odd_writes == low_writes && odd_writes == frame_bytes/2,"every odd frame word splits into two bytes");
            execute_enable=1; deadline=0;
            while (!(instruction_retired && debug_opcode == (form == 3 ? 8'hCA : 8'hCF)) && !shutdown && deadline<2200) begin tick(); deadline=deadline+1; end
            check(debug_cs == source_cs && debug_ip == expected_ip && debug_gpr[79:64] == expected_sp && !shutdown,
                  "handler returns through its odd outer frame");
        end
        cases=cases+1; observe=0;
    endtask
    initial begin
        for (integer i=0;i<65536;i=i+1) memory[i]=0;
        for (integer policy=0;policy<3;policy=policy+1)
            for (integer form=0;form<6;form=form+1)
                for (integer ed=0;ed<2;ed=ed+1)
                    for (integer odd_sp=0;odd_sp<2;odd_sp=odd_sp+1)
                        for (integer boundary=0;boundary<3;boundary=boundary+1)
                            run_case(form,1'(ed),1'(odd_sp),boundary,2'(policy));
        $display("ODD_PROTECTED_STACK PASS: %0d checks / %0d cases",checks,cases);
        $finish;
    end
endmodule
