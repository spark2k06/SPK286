`timescale 1ns/1ps

// Intel 80286 PRM, JMP / JUMP TO CALL GATE. Expectations are independent of
// CALL: preserve CPL, FLAGS and SS:SP; ignore target RPL and pointer offset.
module spk286_jmp_call_gate_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:262143];
    integer cycles = 0, checks = 0, cases = 0;
    integer target_descriptor, descriptor_writes, stack_writes, gate_writes;
    integer gate_descriptor;
    integer forbidden_descriptor, forbidden_reads;
    logic observe_jump;
    spk286 dut (.*);

    task automatic tick;
        begin
            #1;
            ready = bus_valid && ((cycles % 4) != 1);
            data_in = 0;
            if (bus_valid && address < 24'h040000) begin
                if (!bus_write) begin
                    if (observe_jump && ready && forbidden_descriptor >= 0 &&
                        address >= 24'(forbidden_descriptor) && address < 24'(forbidden_descriptor + 8))
                        forbidden_reads = forbidden_reads + 1;
                    if (address[0]) data_in = {memory[address[17:0]], 8'h00};
                    else if (bus_bhe_n) data_in = {8'h00, memory[address[17:0]]};
                    else data_in = {memory[address[17:0]+18'd1], memory[address[17:0]]};
                end else if (ready && bus_status == 4'h6) begin
                    if (observe_jump && address == 24'(target_descriptor + 5))
                        descriptor_writes = descriptor_writes + 1;
                    if (observe_jump && address >= 24'h020000) stack_writes = stack_writes + 1;
                    if (observe_jump && address >= 24'(gate_descriptor) &&
                        address < 24'(gate_descriptor + 8)) gate_writes = gate_writes + 1;
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
            $fatal(1, "JMP_CALL_GATE: %s CS:IP=%h:%h micro=%h SS:SP=%h:%h event=%h:%h",
                   message, debug_cs, debug_ip, debug_micro_pc, debug_segment_selectors[47:32],
                   debug_gpr[79:64], debug_event_vector, debug_event_error_code);
    endtask

    // Faults cover type/privilege before presence, table bounds and offset.
    task automatic run_case(input logic [1:0] cpl, input logic conforming,
                            input logic accessed, input logic gate_local, input logic target_local,
                            input logic indirect_jump, input logic [1:0] policy, input integer fault);
        integer p, deadline;
        logic [15:0] gate_selector, target_selector, caller_cs, caller_ss, target_cs;
        logic [15:0] target_limit, error_code;
        logic [7:0] target_access, gate_access, expected_fault, caller_access, data_access;
        logic jump_seen;
        string label;
        begin
            reset = 1'b1; execute_enable = 1'b0; observe_jump = 1'b0;
            timing_policy_request = policy;
            repeat (4) tick();
            for (integer i = 'h800; i < 'h866; i = i + 1) memory[i] = 0;
            target_descriptor = target_local ? 'h3020 : 'h2020;
            gate_descriptor = gate_local ? 'h3030 : 'h2030;
            gate_selector = gate_local ? 16'h0037 : 16'h0033;
            target_selector = target_local ? 16'h0027 : 16'h0023;
            caller_cs = 16'h0018 | {14'd0,cpl}; caller_ss = 16'h0040 | {14'd0,cpl};
            target_cs = (target_selector & 16'hFFFC) | {14'd0,cpl};
            caller_access = 8'h9B | {1'b0,cpl,5'd0};
            data_access = 8'h93 | {1'b0,cpl,5'd0};
            target_access = (conforming ? 8'h9E : (8'h9A | {1'b0,cpl,5'd0})) | {7'd0,accessed};
            gate_access = 8'hE4;
            target_limit = fault == 3 ? 16'h01FF : 16'hFFFF;
            expected_fault = (fault == 1 || fault == 7) ? 8'd11 : 8'd13;
            case (fault)
                1: target_access = target_access & 8'h7F;
                2: target_access = 8'hD2;
                4: target_access = 8'hBA; // Nonconforming DPL1 cannot lower CPL2.
                5: target_access = 8'hFA; // Nonconforming DPL3 cannot raise CPL2.
                6: target_access = 8'hFE; // Conforming DPL3 also rejects CPL2.
                7: gate_access = 8'h64;
                8: gate_access = 8'hA4; // DPL1 < CPL2.
                9: gate_access = 8'hC4; // DPL2 < gate RPL3.
                10: target_selector = 16'h0003;
                11: target_selector = target_local ? 16'h0107 : 16'h0103;
                12: gate_selector = gate_local ? 16'h0107 : 16'h0103;
                14: target_access = 8'h52; // Absent data is #GP, not #NP.
                15: target_access = 8'h3A; // Absent inward code is #GP.
                16: gate_access = 8'h24; // Gate DPL fails before absence.
                17: gate_access = 8'h44; // Gate RPL fails before absence.
                18: gate_access = 8'hE6; // Interrupt gate is not a JMP route.
                default: begin end
            endcase
            error_code = (fault == 3 || fault == 10) ? 16'd0 :
                         ((fault >= 7 && fault <= 9) || fault == 12 || fault == 13 ||
                           fault >= 16) ? gate_selector & 16'hFFFC : target_selector & 16'hFFFC;
            label = $sformatf("CPL=%0d conf=%b A=%b gateLDT=%b targetLDT=%b indirect=%b policy=%0d fault=%0d",
                              cpl, conforming, accessed, gate_local, target_local, indirect_jump, policy, fault);

            memory[0] = 8'h0F; memory[1] = 8'h05; // LOADALL the independent fixture.
            put_word('h806, 1); put_word('h818, 16'h0046); put_word('h81A, 16'h0100);
            put_word('h81C, 16'h0008);
            put_word('h81E, 16'h0048 | {14'd0,cpl}); put_word('h820, caller_ss);
            put_word('h822, caller_cs); put_word('h824, 16'h0048 | {14'd0,cpl}); put_word('h82C, 16'h1000);
            cache('h836, 24'(target_descriptor), 16'h0007, data_access);
            cache('h83C, 24'h010000, 16'hFFFF, caller_access);
            cache('h842, 24'h020000, 16'hFFFF, data_access);
            cache('h848, 24'h000000, 16'hFFFF, data_access);
            cache('h84E, 24'h002000, 16'h00FF, 0);
            cache('h854, 24'h003000, 16'h00FF, 8'h82);
            cache('h85A, 24'h005000, 16'h00FF, 0);
            // No valid TR/inner stack: JMP must never request either.
            descriptor('h2018, 24'h010000, 16'hFFFF, caller_access);
            descriptor(target_descriptor, 24'h010000, target_limit, target_access);
            descriptor('h2040, 24'h020000, 16'hFFFF, data_access);
            descriptor('h2048, 24'(target_descriptor), 16'h0007, data_access);
            put_word(gate_descriptor, 16'h0200); put_word(gate_descriptor+2, target_selector);
            put_word(gate_descriptor+4, {gate_access,8'h1F}); // Parameter count ignored by JMP.
            put_word(gate_descriptor+6, fault == 13 ? 16'h0001 : 16'h0000);
            // A valid-looking descriptor outside the table must never be read.
            // Zero-filled memory would mask a missing target selector precheck.
            forbidden_descriptor = fault == 10 ? 'h2000 :
                                   fault == 11 ? (target_local ? 'h3100 : 'h2100) :
                                   fault == 12 ? (gate_local ? 'h3100 : 'h2100) : -1;
            if (forbidden_descriptor >= 0)
                descriptor(forbidden_descriptor, 24'h010000, 16'hFFFF, caller_access);
            for (integer i = 'h20FE0; i < 'h21010; i = i + 1) memory[i] = 8'hCC;
            p = 'h10100;
            memory[p] = 8'h3E; p = p + 1; // Fault restart includes the prefix.
            if (indirect_jump) begin
                memory[p] = 8'hFF; memory[p+1] = 8'h2E; put_word(p+2, 16'h0600);
                put_word('h600, 16'hAAAA); put_word('h602, gate_selector);
            end else begin
                memory[p] = 8'hEA; put_word(p+1, 16'hAAAA); put_word(p+3, gate_selector);
            end
            memory['h10200] = 8'hB8; put_word('h10201, 16'hBEEF);
            memory['h10203] = 8'hEB; memory['h10204] = 8'hFE;
            // #NP handler repairs P, discards the error word, and retries via IRET.
            put_word('h5058, 16'h0400); put_word('h505A, caller_cs);
            put_word('h505C, 16'hE600); put_word('h505E, 0);
            memory['h10400] = 8'h26; memory['h10401] = 8'hC6; memory['h10402] = 8'h06;
            put_word('h10403, 5); memory['h10405] = target_access | 8'h80;
            memory['h10406] = 8'h58; memory['h10407] = 8'hCF;

            reset = 1'b0; segment_load_en = 1'b1; segment_load_index = 2'd1;
            segment_load_selector = 0; ip_write_en = 1'b1; ip_write_data = 0; redirect = 1'b1;
            tick(); segment_load_en = 1'b0; ip_write_en = 1'b0; redirect = 1'b0; execute_enable = 1'b1;
            descriptor_writes = 0; stack_writes = 0; gate_writes = 0; forbidden_reads = 0; observe_jump = 1'b1;
            deadline = 0;
            if (fault != 0) begin
                while (!shutdown && debug_timing_event_requests == 0 && deadline < 1500) begin
                    tick(); deadline = deadline + 1;
                end
                check(!shutdown && debug_timing_event_requests == 1 && debug_event_vector == expected_fault &&
                      debug_event_error_code == error_code, {label, " correct fault priority and selector"});
                check(debug_cs == caller_cs && debug_gpr[79:64] == 16'h1000 &&
                      debug_segment_selectors[47:32] == caller_ss && debug_segment_access[15:8] == caller_access &&
                      descriptor_writes == 0 && stack_writes == 0 && gate_writes == 0 &&
                      forbidden_reads == 0 && memory[target_descriptor+5] == target_access,
                      {label, " failed JMP preserves context and avoids invalid descriptor reads"});
                if (fault == 1) begin
                    observe_jump = 1'b0;
                    deadline = 0;
                    while (!shutdown && !(instruction_retired && debug_ip == 16'h0100) && deadline < 1800) begin
                        tick(); deadline = deadline + 1;
                    end
                    check(!shutdown && debug_ip == 16'h0100 && debug_cs == caller_cs &&
                          debug_gpr[79:64] == 16'h1000 && debug_flags == 16'h0046 &&
                          memory[target_descriptor+5] == (target_access | 8'h80),
                          {label, " #NP/IRET repairs and restarts the complete prefixed JMP"});
                    descriptor_writes = 0; stack_writes = 0; gate_writes = 0; observe_jump = 1'b1;
                end
            end
            if (fault == 0 || fault == 1) begin
                jump_seen = 1'b0; deadline = 0;
                while (!shutdown && debug_timing_event_requests == (fault == 1 ? 1 : 0) &&
                       debug_gpr[15:0] != 16'hBEEF && deadline < 1800) begin
                    tick(); deadline = deadline + 1;
                    if (!jump_seen && instruction_retired && debug_cs == target_cs) begin
                        jump_seen = 1'b1;
                        check(debug_ip == 16'h0200 && debug_gpr[79:64] == 16'h1000 &&
                              debug_segment_selectors[47:32] == caller_ss && debug_flags == 16'h0046 &&
                              memory[target_descriptor+5] == (target_access | 8'h81) &&
                              debug_segment_access[15:8] == (target_access | 8'h81) &&
                              descriptor_writes == (accessed ? 0 : 1) && stack_writes == 0 && gate_writes == 0,
                              {label, " commits gate CS:IP with A set and no frame/privilege/FLAGS change"});
                    end
                end
                check(jump_seen && !shutdown && debug_gpr[15:0] == 16'hBEEF && debug_cs == target_cs,
                      {label, " reaches target instead of rejecting the gate or looping"});
            end
            observe_jump = 1'b0; cases = cases + 1;
        end
    endtask

    initial begin
        observe_jump = 1'b0;
        for (integer i = 0; i < 262144; i = i + 1) memory[i] = 0;
        for (integer policy = 0; policy < 3; policy = policy + 1)
            for (integer indirect_jump = 0; indirect_jump < 2; indirect_jump = indirect_jump + 1)
                for (integer tables = 0; tables < 4; tables = tables + 1) begin
                    for (integer cpl = 0; cpl < 4; cpl = cpl + 1)
                        for (integer conforming = 0; conforming < 2; conforming = conforming + 1)
                            for (integer accessed = 0; accessed < 2; accessed = accessed + 1)
                                run_case(2'(cpl), 1'(conforming), 1'(accessed), 1'(tables), 1'(tables >> 1),
                                         1'(indirect_jump), 2'(policy), 0);
                    for (integer fault = 1; fault <= 18; fault = fault + 1)
                        run_case(2, 0, 0, 1'(tables), 1'(tables >> 1), 1'(indirect_jump), 2'(policy), fault);
                end
        $display("JMP_CALL_GATE PASS: %0d checks / %0d cases", checks, cases);
        $finish;
    end
endmodule
