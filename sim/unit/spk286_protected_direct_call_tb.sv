`timescale 1ns/1ps

module spk286_protected_direct_call_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:2097151];
    integer cycles = 0, checks = 0, cases = 0, failures = 0;
    spk286 dut (.*);

    task automatic tick;
        begin
            #1;
            ready = bus_valid && ((cycles % 4) != 1);
            data_in = 16'h0000;
            if (bus_valid && address < 24'h200000) begin
                if (!bus_write) begin
                    if (address[0]) data_in = {memory[address[20:0]], 8'h00};
                    else if (bus_bhe_n) data_in = {8'h00, memory[address[20:0]]};
                    else data_in = {memory[address[20:0] + 21'd1], memory[address[20:0]]};
                end else if (ready && bus_status == 4'h6) begin
                    if (address[0]) memory[address[20:0]] = data_out[15:8];
                    else begin
                        memory[address[20:0]] = data_out[7:0];
                        if (!bus_bhe_n) memory[address[20:0] + 21'd1] = data_out[15:8];
                    end
                end
            end
            #4; clk = 1'b1; #5; clk = 1'b0; #1;
            cycles = cycles + 1;
        end
    endtask

    task automatic put_word(input integer addr, input logic [15:0] value);
        memory[addr] = value[7:0]; memory[addr + 1] = value[15:8];
    endtask

    function automatic logic [15:0] word_at(input integer addr);
        word_at = {memory[addr + 1], memory[addr]};
    endfunction

    task automatic cache(input integer addr, input logic [23:0] base_addr,
                         input logic [15:0] limit_value, input logic [7:0] access_byte);
        put_word(addr, base_addr[15:0]);
        put_word(addr + 2, {access_byte, base_addr[23:16]});
        put_word(addr + 4, limit_value);
    endtask

    task automatic descriptor(input integer addr, input logic [23:0] base_addr,
                              input logic [15:0] limit_value, input logic [7:0] access_byte);
        put_word(addr, limit_value); put_word(addr + 2, base_addr[15:0]);
        put_word(addr + 4, {access_byte, base_addr[23:16]}); put_word(addr + 6, 16'h0000);
    endtask

    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1) begin
            failures = failures + 1;
            $display("DIRECT_CALL FAIL: %s CS:IP=%h:%h SP=%h event=%h:%h pc=%h",
                     message, debug_cs, debug_ip, debug_gpr[79:64],
                     debug_event_vector, debug_event_error_code, debug_micro_pc);
        end
    endtask

    task automatic run_case(input logic [1:0] cpl, input logic [1:0] rpl,
                            input logic [7:0] target_access, input logic [15:0] target_limit,
                            input logic indirect_call, input logic local_target,
                            input logic [1:0] policy, input logic [7:0] expected_fault,
                            input logic [15:0] upper_word = 16'h0000,
                            input logic recover_absent = 1'b0);
        integer p, target_descriptor, deadline;
        logic [15:0] caller_cs, target_cs, return_ip;
        logic [7:0] caller_access, data_access;
        logic call_seen;
        string label;
        begin
            reset = 1'b1; execute_enable = 1'b0; timing_policy_request = policy;
            repeat (4) tick();
            for (integer i = 'h800; i < 'h866; i = i + 1) memory[i] = 8'h00;
            caller_cs = 16'h0304 | {14'd0, cpl};
            target_cs = (local_target ? 16'h0054 : 16'h0050) | {14'd0, rpl};
            caller_access = 8'h9B | {1'b0, cpl, 5'd0};
            data_access = 8'h93 | {1'b0, cpl, 5'd0};
            target_descriptor = (local_target ? 'h114C50 : 'h110800) + 'h50;
            return_ip = indirect_call ? 16'hB599 : 16'hB59A;
            label = $sformatf("CPL=%0d target=%h AR=%h limit=%h indirect=%b policy=%0d",
                              cpl, target_cs, target_access, target_limit, indirect_call, policy);

            // Reconstruct the Windows 3.1 first-fault context using LOADALL.
            // The CPL3/GDT/indirect/accessed case matches 0307:B595 -> 0053:1CCD.
            memory[0] = 8'h0F; memory[1] = 8'h05;
            put_word('h806, 16'h0001); put_word('h818, 16'h0002);
            put_word('h81A, 16'hB595); put_word('h81C, 16'h0038);
            put_word('h81E, 16'h02FC | {14'd0, cpl});
            put_word('h820, 16'h027C | {14'd0, cpl});
            put_word('h822, caller_cs); put_word('h824, 16'h02FC | {14'd0, cpl});
            put_word('h82C, 16'h01F8);
            cache('h836, 24'h09EA50, 16'hFFFF, data_access);
            cache('h83C, 24'h08FC20, 16'hFFFF, caller_access);
            cache('h842, 24'h08E800, 16'hFFFF, data_access);
            cache('h848, 24'h09EA50, 16'hFFFF, data_access);
            cache('h84E, 24'h110800, 16'h011F, 8'h00);
            cache('h854, 24'h114C50, 16'h5FFF, 8'h82);
            cache('h85A, 24'h110000, 16'h0000, 8'h00);
            descriptor('h114F50, 24'h08FC20, 16'hFFFF, caller_access);
            descriptor(target_descriptor, 24'h110920, target_limit, target_access);
            put_word(target_descriptor + 6, upper_word);
            if (recover_absent) begin
                // A real same-level #NP handler publishes the segment and
                // IRETs to retry CALL. ES maps the target descriptor bytes.
                put_word('h824, 16'h0058 | {14'd0, cpl});
                cache('h836, 24'(target_descriptor), 16'h0007, data_access);
                descriptor('h110858, 24'(target_descriptor), 16'h0007, data_access);
                cache('h85A, 24'h110000, 16'h07FF, 8'h00);
                put_word('h110058, 16'h0100); put_word('h11005A, caller_cs);
                put_word('h11005C, 16'hE600); put_word('h11005E, 16'h0000);
                p = 'h08FC20 + 'h0100;
                memory[p] = 8'h26; memory[p+1] = 8'hC6; memory[p+2] = 8'h06;
                put_word(p+3, 16'h0005); memory[p+5] = 8'hFA; p = p + 6;
                memory[p] = 8'h26; memory[p+1] = 8'hC7; memory[p+2] = 8'h06;
                put_word(p+3, 16'h0000); put_word(p+5, 16'h4330); p = p + 7;
                memory[p] = 8'h83; memory[p+1] = 8'hC4; memory[p+2] = 8'h02;
                memory[p+3] = 8'hCF;
            end
            put_word('h08E9F4, 16'hA55A); put_word('h08E9F6, 16'h5AA5);

            p = 'h08FC20 + 'hB595;
            if (indirect_call) begin
                memory[p] = 8'hFF; memory[p+1] = 8'h1E; put_word(p+2, 16'h09B0);
                put_word('h09F400, 16'h1CCD); put_word('h09F402, target_cs); p = p + 4;
            end else begin
                memory[p] = 8'h9A; put_word(p+1, 16'h1CCD); put_word(p+3, target_cs); p = p + 5;
            end
            memory[p] = 8'hBB; put_word(p+1, 16'hCAFE); // MOV BX,CAFE after RETF
            memory[p+3] = 8'hEB; memory[p+4] = 8'hFE;
            p = 'h110920 + 'h1CCD;
            memory[p] = 8'hB8; put_word(p+1, 16'hBEEF); memory[p+3] = 8'hCB;

            reset = 1'b0; segment_load_en = 1'b1; segment_load_index = 2'd1;
            segment_load_selector = 16'h0000;
            ip_write_en = 1'b1; ip_write_data = 16'h0000; redirect = 1'b1;
            tick();
            segment_load_en = 1'b0; ip_write_en = 1'b0; redirect = 1'b0; execute_enable = 1'b1;
            call_seen = 1'b0; deadline = 0;
            while (!shutdown && debug_timing_event_requests == 0 &&
                   debug_gpr[63:48] != 16'hCAFE && deadline < 3000) begin
                tick(); deadline = deadline + 1;
                if (!call_seen && instruction_retired && debug_cs_base == 24'h110920) begin
                    call_seen = 1'b1;
                    check(debug_cs == {target_cs[15:2], cpl} && debug_ip == 16'h1CCD &&
                          debug_gpr[79:64] == 16'h01F4 &&
                          debug_segment_selectors[47:32] == (16'h027C | {14'd0, cpl}) &&
                          word_at('h08E9F4) == return_ip && word_at('h08E9F6) == caller_cs &&
                          word_at(target_descriptor + 6) == upper_word &&
                          memory[target_descriptor+5] == (target_access | 8'h01),
                          {label, " commits code/cache/accessed bit and same-level return frame"});
                end
            end
            cases = cases + 1;
            if (expected_fault != 0) begin
                check(!call_seen && debug_timing_event_requests == 1 &&
                      debug_event_vector == expected_fault && debug_cs == caller_cs &&
                      debug_gpr[79:64] == 16'h01F8 &&
                      word_at('h08E9F4) == 16'hA55A && word_at('h08E9F6) == 16'h5AA5,
                      {label, " rejects before writing a call frame"});
                check(debug_event_error_valid && debug_event_error_code ==
                      ((expected_fault == 8'd13 && target_access == 8'hFB && target_limit < 16'h1CCD) ?
                       16'h0000 : (target_cs & 16'hFFFC)),
                      {label, " reports selector index/TI without RPL, or zero for an offset fault"});
                if (recover_absent) begin
                    deadline = 0;
                    while (!event_completed && !shutdown && deadline < 1000) begin
                        tick(); deadline = deadline + 1;
                    end
                    check(event_completed && !shutdown && debug_event_vector == 8'd11 &&
                          debug_gpr[79:64] == 16'h01F0 &&
                          word_at('h08E9F0) == (target_cs & 16'hFFFC) &&
                          word_at('h08E9F2) == 16'hB595 && word_at('h08E9F4) == caller_cs,
                          {label, " #NP delivery saves restart IP and normalized selector error"});
                    deadline = 0;
                    while (!shutdown && debug_timing_event_requests == 1 &&
                           debug_gpr[63:48] != 16'hCAFE && deadline < 3000) begin
                        tick(); deadline = deadline + 1;
                    end
                    check(!shutdown && debug_timing_event_requests == 1 &&
                          debug_cs == caller_cs && debug_gpr[79:64] == 16'h01F8 &&
                          debug_gpr[15:0] == 16'hBEEF && debug_gpr[63:48] == 16'hCAFE &&
                          word_at(target_descriptor + 6) == upper_word &&
                          memory[target_descriptor + 5] == 8'hFB,
                          {label, " handler repairs segment and IRET retries CALL/RETF successfully"});
                end
            end else
                check(call_seen && !shutdown && debug_timing_event_requests == 0 &&
                      debug_cs == caller_cs && debug_gpr[79:64] == 16'h01F8 &&
                      debug_gpr[15:0] == 16'hBEEF && debug_gpr[63:48] == 16'hCAFE,
                      {label, " CALL/RETF completes without exception"});
        end
    endtask

    initial begin
        for (integer i = 0; i < 2097152; i = i + 1) memory[i] = 8'h00;
        for (integer policy = 0; policy < 3; policy = policy + 1)
            for (integer indirect_call = 0; indirect_call < 2; indirect_call = indirect_call + 1) begin
                for (integer cpl = 0; cpl < 4; cpl = cpl + 1)
                    for (integer accessed = 0; accessed < 2; accessed = accessed + 1)
                        run_case(2'(cpl), 2'(cpl), 8'h9A | 8'(cpl << 5) | 8'(accessed),
                                 16'h4330, 1'(indirect_call), 1'b0, 2'(policy), 8'd0);
                // Lower RPL, LDT lookup, and conforming code retain caller CPL.
                run_case(2'd3, 2'd0, 8'hFA, 16'h4330, 1'(indirect_call), 1'b0, 2'(policy), 8'd0);
                run_case(2'd3, 2'd3, 8'hFA, 16'h4330, 1'(indirect_call), 1'b1, 2'(policy), 8'd0);
                run_case(2'd3, 2'd0, 8'h9E, 16'h4330, 1'(indirect_call), 1'b0, 2'(policy), 8'd0);
                run_case(2'd0, 2'd3, 8'h9E, 16'h4330, 1'(indirect_call), 1'b0, 2'(policy), 8'd0);
                // Direct CALL must not gain gate privileges or skip validation.
                run_case(2'd3, 2'd0, 8'h9B, 16'h4330, 1'(indirect_call), 1'b0, 2'(policy), 8'd13);
                run_case(2'd0, 2'd3, 8'h9B, 16'h4330, 1'(indirect_call), 1'b0, 2'(policy), 8'd13);
                run_case(2'd3, 2'd3, 8'h7B, 16'h4330, 1'(indirect_call), 1'b0, 2'(policy), 8'd11);
                run_case(2'd3, 2'd3, 8'hF3, 16'h4330, 1'(indirect_call), 1'b0, 2'(policy), 8'd13);
                run_case(2'd3, 2'd3, 8'hFB, 16'h1CCC, 1'(indirect_call), 1'b0, 2'(policy), 8'd13);
                run_case(2'd0, 2'd0, 8'hFE, 16'h4330, 1'(indirect_call), 1'b0, 2'(policy), 8'd13);
                // Windows's next failure uses AR=7B and word 6=0010. The
                // absent segment's short limit must not preempt #NP either.
                run_case(2'd3, 2'd3, 8'h7B, 16'h042F, 1'(indirect_call), 1'b0, 2'(policy), 8'd11, 16'h0010);
                run_case(2'd3, 2'd3, 8'h7B, 16'h042F, 1'(indirect_call), 1'b1, 2'(policy), 8'd11, 16'h0010);
                run_case(2'd3, 2'd3, 8'hFA, 16'h4330, 1'(indirect_call), 1'b1, 2'(policy), 8'd0, 16'hA510);
                run_case(2'd0, 2'd3, 8'h1B, 16'h4330, 1'(indirect_call), 1'b1, 2'(policy), 8'd13, 16'h0010);
                run_case(2'd3, 2'd3, 8'h73, 16'h4330, 1'(indirect_call), 1'b1, 2'(policy), 8'd13, 16'h0010);
                run_case(2'd3, 2'd3, 8'h7B, 16'h042F, 1'(indirect_call), 1'b1, 2'(policy), 8'd11, 16'h0010, 1'b1);
            end
        if (failures != 0) $fatal(1, "PROTECTED_DIRECT_CALL: %0d failures / %0d cases", failures, cases);
        $display("PROTECTED_DIRECT_CALL PASS: %0d checks / %0d cases", checks, cases);
        $finish;
    end
endmodule
