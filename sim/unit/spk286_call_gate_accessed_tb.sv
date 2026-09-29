`timescale 1ns/1ps

module spk286_call_gate_accessed_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:262143];
    integer cycles = 0, checks = 0, cases = 0;
    integer target_descriptor, descriptor_writes, frame_writes;
    logic observe_call;
    spk286 dut (.*);

    task automatic tick;
        begin
            #1;
            ready = bus_valid && ((cycles % 4) != 1);
            data_in = 0;
            if (bus_valid && address < 24'h040000) begin
                if (!bus_write) begin
                    if (address[0]) data_in = {memory[address[17:0]], 8'h00};
                    else if (bus_bhe_n) data_in = {8'h00, memory[address[17:0]]};
                    else data_in = {memory[address[17:0]+18'd1], memory[address[17:0]]};
                end else if (ready && bus_status == 4'h6) begin
                    if (observe_call && address == 24'(target_descriptor + 5))
                        descriptor_writes = descriptor_writes + 1;
                    if (observe_call && address >= 24'h020000) begin
                        frame_writes = frame_writes + 1;
                        if (!memory[target_descriptor+5][0])
                            $fatal(1, "call frame written before the target accessed bit");
                    end
                    if (address[0]) memory[address[17:0]] = data_out[15:8];
                    else begin
                        memory[address[17:0]] = data_out[7:0];
                        if (!bus_bhe_n) memory[address[17:0]+18'd1] = data_out[15:8];
                    end
                end
            end
            #4; clk = 1'b1; #5; clk = 1'b0; #1;
            cycles = cycles + 1;
        end
    endtask

    task automatic put_word(input integer addr, input logic [15:0] value);
        memory[addr] = value[7:0]; memory[addr+1] = value[15:8];
    endtask
    function automatic logic [15:0] word_at(input integer addr);
        word_at = {memory[addr+1], memory[addr]};
    endfunction
    task automatic cache(input integer addr, input logic [23:0] base_addr,
                         input logic [15:0] limit_value, input logic [7:0] access_byte);
        put_word(addr, base_addr[15:0]); put_word(addr+2, {access_byte, base_addr[23:16]});
        put_word(addr+4, limit_value);
    endtask
    task automatic descriptor(input integer addr, input logic [23:0] base_addr,
                              input logic [15:0] limit_value, input logic [7:0] access_byte);
        put_word(addr, limit_value); put_word(addr+2, base_addr[15:0]);
        put_word(addr+4, {access_byte, base_addr[23:16]}); put_word(addr+6, 0);
    endtask
    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1)
            $fatal(1, "CALL_GATE_ACCESSED: %s CS:IP=%h:%h micro=%h SS:SP=%h:%h event=%h:%h descriptor=%h phase=%0d",
                   message, debug_cs, debug_ip, debug_micro_pc, debug_segment_selectors[47:32],
                   debug_gpr[79:64], debug_event_vector, debug_event_error_code,
                   memory[target_descriptor+5], dut.micro_executor.descriptor_phase_q);
    endtask

    // kind: 0 same-level, 1 inner CPL0, 2 conforming DPL2, 3 inner CPL2 (OS/2).
    // fault: 0 success, 1 absent target (repair + retry), 2 wrong type, 3 offset.
    task automatic run_case(input integer kind, input logic accessed,
                            input logic local_table, input logic indirect_call,
                            input logic [1:0] policy, input integer fault);
        integer gate_descriptor, p, deadline, frame_base;
        logic [15:0] gate_selector, target_selector, target_cs, return_ip, target_limit, inner_ss;
        logic [7:0] target_access, expected_fault;
        logic call_seen, inner_call;
        string label;
        begin
            reset = 1'b1; execute_enable = 1'b0; observe_call = 1'b0;
            timing_policy_request = policy;
            repeat (4) tick();
            for (integer i = 'h800; i < 'h866; i = i + 1) memory[i] = 0;
            target_descriptor = local_table ? 'h3020 : 'h2020;
            gate_descriptor = local_table ? 'h3030 : 'h2030;
            gate_selector = local_table ? 16'h0037 : 16'h0033;
            target_selector = local_table ? 16'h0027 : 16'h0023;
            inner_call = kind == 1 || kind == 3;
            inner_ss = kind == 3 ? 16'h002A : 16'h0028;
            target_cs = inner_call ? (target_selector & 16'hFFFC) | (kind == 3 ? 16'd2 : 16'd0) : target_selector;
            target_access = (kind == 1 ? 8'h9A : kind == 2 ? 8'hDE : kind == 3 ? 8'hDA : 8'hFA) | {7'd0, accessed};
            if (fault == 1) target_access = target_access & 8'h7F;
            if (fault == 2) target_access = 8'hF2;
            target_limit = fault == 3 ? 16'h01FF : 16'hFFFF;
            expected_fault = fault == 1 ? 8'd11 : fault != 0 ? 8'd13 : 8'd0;
            return_ip = indirect_call ? 16'h0104 : 16'h0105;
            label = $sformatf("kind=%0d A=%b LDT=%b indirect=%b policy=%0d fault=%0d",
                              kind, accessed, local_table, indirect_call, policy, fault);

            memory[0] = 8'h0F; memory[1] = 8'h05; // LOADALL the caller at CPL3.
            put_word('h806, 1); put_word('h816, 16'h0010); put_word('h818, 16'h0002);
            put_word('h81A, 16'h0100); put_word('h81C, 16'h0008);
            put_word('h81E, 16'h004B); put_word('h820, 16'h0043);
            put_word('h822, 16'h001B); put_word('h824, 16'h004B); put_word('h82C, 16'h1000);
            cache('h836, 24'(target_descriptor), 16'h0007, 8'hF3);
            cache('h83C, 24'h010000, 16'hFFFF, 8'hFB);
            cache('h842, 24'h020000, 16'hFFFF, 8'hF3);
            cache('h848, 24'h000000, 16'hFFFF, 8'hF3);
            cache('h84E, 24'h002000, 16'h00FF, 0);
            cache('h854, 24'h003000, 16'h00FF, 8'h82);
            cache('h85A, 24'h005000, 16'h00FF, 0);
            cache('h860, 24'h004000, 16'h002B, 8'h83);
            descriptor('h2018, 24'h010000, 16'hFFFF, 8'hFB);
            descriptor(target_descriptor, 24'h010000, target_limit, target_access);
            descriptor('h2028, 24'h030000, 16'hFFFF, kind == 3 ? 8'hD3 : 8'h93);
            descriptor('h2040, 24'h020000, 16'hFFFF, 8'hF3);
            descriptor('h2048, 24'(target_descriptor), 16'h0007, 8'hF3);
            put_word(gate_descriptor, 16'h0200); put_word(gate_descriptor+2, target_selector);
            put_word(gate_descriptor+4, inner_call ? 16'hE402 : 16'hE400);
            put_word(gate_descriptor+6, 0);
            put_word('h4002, 16'h0800); put_word('h4004, 16'h0028);
            put_word('h400A, 16'h0800); put_word('h400C, 16'h002A);
            put_word('h21000, 16'hA55A); put_word('h21002, 16'h5AA5);
            for (integer i = 'h20FF0; i < 'h21000; i = i + 1) memory[i] = 8'hCC;
            for (integer i = 'h307F0; i < 'h30800; i = i + 1) memory[i] = 8'hCC;

            p = 'h10100;
            if (indirect_call) begin
                memory[p] = 8'hFF; memory[p+1] = 8'h1E; put_word(p+2, 16'h0600);
                put_word('h600, 16'hAAAA); put_word('h602, gate_selector); p = p + 4;
            end else begin
                memory[p] = 8'h9A; put_word(p+1, 16'hAAAA); put_word(p+3, gate_selector); p = p + 5;
            end
            memory[p] = 8'hBB; put_word(p+1, 16'hCAFE); memory[p+3] = 8'hEB; memory[p+4] = 8'hFE;
            memory['h10200] = 8'hB8; put_word('h10201, 16'hBEEF);
            memory['h10203] = inner_call ? 8'hCA : 8'hCB; put_word('h10204, 4);
            // #NP handler publishes the target with A=0, consumes the error,
            // and IRETs to the original CALL. No fixture-side repair is used.
            put_word('h5058, 16'h0400); put_word('h505A, 16'h001B);
            put_word('h505C, 16'hE600); put_word('h505E, 0);
            memory['h10400] = 8'h26; memory['h10401] = 8'hC6; memory['h10402] = 8'h06;
            put_word('h10403, 5); memory['h10405] = target_access | 8'h80;
            memory['h10406] = 8'h58; memory['h10407] = 8'hCF;

            reset = 1'b0; segment_load_en = 1'b1; segment_load_index = 2'd1;
            segment_load_selector = 0; ip_write_en = 1'b1; ip_write_data = 0; redirect = 1'b1;
            tick(); segment_load_en = 1'b0; ip_write_en = 1'b0; redirect = 1'b0; execute_enable = 1'b1;
            descriptor_writes = 0; frame_writes = 0; observe_call = 1'b1;
            deadline = 0;
            if (fault != 0) begin
                while (!shutdown && debug_timing_event_requests == 0 && deadline < 1200) begin
                    tick(); deadline = deadline + 1;
                end
                check(!shutdown && debug_timing_event_requests == 1 && debug_event_vector == expected_fault &&
                      debug_event_error_code == (fault == 3 ? 16'h0000 : target_selector & 16'hFFFC),
                      {label, " rejects target with the architectural selector/offset fault"});
                check(debug_cs == 16'h001B && debug_gpr[79:64] == 16'h1000 &&
                      descriptor_writes == 0 && frame_writes == 0 && memory[target_descriptor+5] == target_access,
                      {label, " failure preserves caller and leaves A clear"});
                if (fault == 1) begin
                    observe_call = 1'b0; // The exception frame is separate from the CALL frame.
                    deadline = 0;
                    while (!shutdown && !(instruction_retired && debug_ip == 16'h0100) && deadline < 1800) begin
                        tick(); deadline = deadline + 1;
                    end
                    check(!shutdown && debug_ip == 16'h0100 && debug_cs == 16'h001B &&
                          debug_gpr[79:64] == 16'h1000 && memory[target_descriptor+5] == (target_access | 8'h80),
                          {label, " #NP handler repairs P and IRET retries the same CALL"});
                    descriptor_writes = 0; frame_writes = 0; observe_call = 1'b1;
                end
            end
            if (fault == 0 || fault == 1) begin
                call_seen = 1'b0; deadline = 0;
                while (!shutdown && debug_timing_event_requests == (fault == 1 ? 1 : 0) &&
                       debug_gpr[63:48] != 16'hCAFE && deadline < 1800) begin
                    tick(); deadline = deadline + 1;
                    if (!call_seen && instruction_retired && debug_cs == target_cs) begin
                        call_seen = 1'b1;
                        frame_base = inner_call ? 'h307F4 : 'h20FFC;
                        check(debug_ip == 16'h0200 && debug_gpr[79:64] == (inner_call ? 16'h07F4 : 16'h0FFC) &&
                              debug_segment_selectors[47:32] == (inner_call ? inner_ss : 16'h0043) &&
                              word_at(frame_base) == return_ip && word_at(frame_base+2) == 16'h001B &&
                              memory[target_descriptor+5] == (target_access | 8'h81) &&
                              debug_segment_access[15:8] == (target_access | 8'h81) &&
                              descriptor_writes == (accessed ? 0 : 1),
                              {label, " sets A before publishing the target and complete call frame"});
                        if (inner_call)
                            check(word_at(frame_base+4) == 16'hA55A && word_at(frame_base+6) == 16'h5AA5 &&
                                  word_at(frame_base+8) == 16'h1000 && word_at(frame_base+10) == 16'h0043,
                                  {label, " copies parameters and preserves outer SS:SP"});
                    end
                end
                check(call_seen && !shutdown && debug_gpr[15:0] == 16'hBEEF && debug_gpr[63:48] == 16'hCAFE &&
                      debug_cs == 16'h001B && debug_segment_selectors[47:32] == 16'h0043 &&
                      debug_gpr[79:64] == (inner_call ? 16'h1004 : 16'h1000),
                      {label, " CALL and RETF complete without a validation loop"});
            end
            observe_call = 1'b0; cases = cases + 1;
        end
    endtask

    initial begin
        observe_call = 1'b0;
        for (integer i = 0; i < 262144; i = i + 1) memory[i] = 0;
        for (integer policy = 0; policy < 3; policy = policy + 1)
            for (integer indirect_call = 0; indirect_call < 2; indirect_call = indirect_call + 1)
                for (integer local_table = 0; local_table < 2; local_table = local_table + 1) begin
                    for (integer kind = 0; kind < 4; kind = kind + 1)
                        for (integer accessed = 0; accessed < 2; accessed = accessed + 1)
                            run_case(kind, 1'(accessed), 1'(local_table), 1'(indirect_call), 2'(policy), 0);
                    for (integer fault = 1; fault < 4; fault = fault + 1)
                        run_case(0, 0, 1'(local_table), 1'(indirect_call), 2'(policy), fault);
                    run_case(3, 0, 1'(local_table), 1'(indirect_call), 2'(policy), 1);
                end
        $display("CALL_GATE_ACCESSED PASS: %0d checks / %0d cases", checks, cases);
        $finish;
    end
endmodule
