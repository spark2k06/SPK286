// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

// Intel 80286 PRM 10.1: an ordinary gate saves FLAGS before clearing NT.
// Task gates are covered separately; return-FLAGS masks are covered separately.
module spk286_event_nt_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    integer cycles = 0, checks = 0, cases = 0;
    spk286 dut (.*);

    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1)
            $fatal(1,"EVENT_NT %s case=%0d CS:IP=%h:%h SS:SP=%h:%h FLAGS=%h event=%h micro=%h",
                   message,cases,debug_cs,debug_ip,debug_segment_selectors[47:32],
                   debug_gpr[79:64],debug_flags,debug_event_vector,debug_micro_pc);
    endtask
    task automatic tick;
        #1;
        ready = bus_valid && ((cycles % 4) != 1);
        data_in = 0;
        if (bus_valid && !bus_write) begin
            if (address[0]) data_in = {memory[address[15:0]],8'd0};
            else if (bus_bhe_n) data_in = {8'd0,memory[address[15:0]]};
            else data_in = {memory[address[15:0]+16'd1],memory[address[15:0]]};
        end
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
    task automatic run_case(input logic pe, input logic [1:0] cpl,
                            input logic inward, input logic trap_gate, input logic nt,
                            input logic exception_source, input logic [1:0] policy);
        logic [1:0] target_cpl;
        logic [15:0] caller_cs, caller_ss, target_cs, target_ss, old_flags, frame_sp, return_ip;
        integer gate_addr, deadline, flags_addr;
        reset = 1; execute_enable = 0; timing_policy_request = policy;
        repeat (4) tick();
        for (integer i = 'h800; i < 'h866; i = i + 1) memory[i] = 0;
        target_cpl = inward ? 2'd0 : cpl;
        caller_cs = 16'h0018 | {14'd0,cpl}; caller_ss = 16'h0020 | {14'd0,cpl};
        target_cs = inward ? 16'h0008 : caller_cs;
        target_ss = inward ? 16'h0010 : caller_ss;
        old_flags = 16'h3202 | (nt ? 16'h4000 : 16'd0);
        return_ip = exception_source ? 16'h0100 : 16'h0102;
        memory[0] = 8'h0F; memory[1] = 8'h05; // Independent LOADALL setup.
        word_at('h806,{15'd0,pe}); word_at('h818,old_flags); word_at('h81A,16'h0100);
        word_at('h816,16'h0028); word_at('h81E,caller_ss); word_at('h820,caller_ss);
        word_at('h822,caller_cs); word_at('h824,caller_ss); word_at('h82C,16'hF000);
        cache('h836,0,8'h93 | {1'b0,cpl,5'd0},16'hFFFF);
        cache('h83C,0,8'h9B | {1'b0,cpl,5'd0},16'hFFFF);
        cache('h842,0,8'h93 | {1'b0,cpl,5'd0},16'hFFFF);
        cache('h848,0,8'h93 | {1'b0,cpl,5'd0},16'hFFFF);
        cache('h84E,16'h4000,0,16'h003F);
        cache('h85A,16'h5000,0,16'h0107);
        cache('h860,16'h6000,8'h83,16'h002B);
        descriptor('h4008,8'h9B); descriptor('h4010,8'h93);
        descriptor('h4018,8'h9B | {1'b0,cpl,5'd0});
        descriptor('h4020,8'h93 | {1'b0,cpl,5'd0});
        word_at('h6002,16'hE000); word_at('h6004,16'h0010);
        memory['h100] = exception_source ? 8'hF4 : 8'hCD;
        memory['h101] = 8'h20; memory['h102] = 8'hEB; memory['h103] = 8'hFE;
        memory['h200] = exception_source ? 8'h83 : 8'hCF;
        memory['h201] = 8'hC4; memory['h202] = 8'h02; memory['h203] = 8'hCF;
        gate_addr = 'h5000 + (exception_source ? 13 : 32)*8;
        word_at(gate_addr,16'h0200); word_at(gate_addr+2,target_cs);
        word_at(gate_addr+4,{8'h80 | {1'b0,cpl,5'd0} | (trap_gate ? 8'h07 : 8'h06),8'd0});
        word_at(gate_addr+6,0);
        word_at('h80,16'h0200); word_at('h82,0); // Real-mode INT20 control.
        reset = 0; segment_load_en = 1; segment_load_index = 1; segment_load_selector = 0;
        ip_write_en = 1; ip_write_data = 0; redirect = 1;
        tick(); segment_load_en = 0; ip_write_en = 0; redirect = 0; execute_enable = 1;
        deadline = 0;
        while (!event_completed && !shutdown && deadline < 2000) begin tick(); deadline = deadline+1; end
        check(event_completed && !shutdown && debug_event_vector == (exception_source ? 13 : 32),"ordinary event completes");
        execute_enable = 0;
        frame_sp = inward ? 16'hDFF6 : 16'hEFFA;
        if (exception_source) frame_sp = frame_sp - 16'd2;
        flags_addr = int'(frame_sp) + (exception_source ? 6 : 4);
        check(read_word(flags_addr) == old_flags,"stack saves the old NT and IF");
        check(!debug_flags[8] && debug_flags[14] == (pe ? 1'b0 : nt) &&
              debug_flags[9] == (pe && trap_gate),"live NT/TF/IF follow the gate kind and mode");
        check(debug_gpr[79:64] == frame_sp,"exact event frame size");
        if (pe) begin
            check(debug_cs == target_cs && dut.current_cpl == target_cpl &&
                  debug_segment_selectors[47:32] == target_ss,"gate commits the selected context");
            execute_enable = 1; deadline = 0;
            while (!(instruction_retired && debug_opcode == 8'hCF) && !shutdown && deadline < 2000) begin
                tick(); deadline = deadline+1;
            end
            check(instruction_retired && debug_opcode == 8'hCF && !shutdown &&
                  debug_cs == caller_cs && debug_ip == return_ip && debug_gpr[79:64] == 16'hF000,
                  "handler IRET takes the ordinary stack return, not a TSS backlink");
            // Restoring the saved NT on this return is covered by the return-FLAGS bench.
        end
        cases = cases+1;
    endtask
    initial begin
        for (integer i = 0; i < 65536; i = i+1) memory[i] = 0;
        for (integer policy = 0; policy < 3; policy = policy+1)
            for (integer cpl = 0; cpl < 4; cpl = cpl+1)
                for (integer inward = 0; inward < 2; inward = inward+1)
                    if (cpl != 0 || inward == 0)
                        for (integer gate = 0; gate < 2; gate = gate+1)
                            for (integer nt = 0; nt < 2; nt = nt+1) begin
                                run_case(1,2'(cpl),1'(inward),1'(gate),1'(nt),0,2'(policy));
                                if (cpl != 0) run_case(1,2'(cpl),1'(inward),1'(gate),1'(nt),1,2'(policy));
                            end
        for (integer nt = 0; nt < 2; nt = nt+1) run_case(0,0,0,0,1'(nt),0,0);
        $display("EVENT_NT PASS: %0d checks / %0d cases",checks,cases);
        $finish;
    end
endmodule
