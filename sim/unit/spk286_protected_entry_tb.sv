// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module spk286_protected_entry_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:262143];
    integer cycles = 0;
    integer cases = 0;
    integer failures = 0;
    integer checks = 0;
    spk286 dut (.*);

    task automatic tick;
        begin
            #1;
            ready = bus_valid && ((cycles % 4) != 1);
            data_in = 16'h0000;
            if (bus_valid && address < 24'h040000) begin
                if (!bus_write) begin
                    if (address[0]) data_in = {memory[address[17:0]], 8'h00};
                    else if (bus_bhe_n) data_in = {8'h00, memory[address[17:0]]};
                    else data_in = {memory[address[17:0] + 18'd1], memory[address[17:0]]};
                end else if (ready && bus_status == 4'h6) begin
                    if (address[0]) memory[address[17:0]] = data_out[15:8];
                    else begin
                        memory[address[17:0]] = data_out[7:0];
                        if (!bus_bhe_n) memory[address[17:0] + 18'd1] = data_out[15:8];
                    end
                end
            end
            #4; clk = 1'b1; #5; clk = 1'b0; #1;
            cycles = cycles + 1;
        end
    endtask

    task automatic put_word(input integer addr, input logic [15:0] value);
        memory[addr] = value[7:0];
        memory[addr + 1] = value[15:8];
    endtask

    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1) begin
            failures = failures + 1;
            $display("ENTRY FAIL: %s CS:IP=%h:%h event=%h error=%h shutdown=%b",
                     message, debug_cs, debug_ip, debug_event_vector,
                     debug_event_error_code, shutdown);
        end
    endtask

    task automatic run_case(input logic [15:0] real_cs, input integer variant,
                            input logic [1:0] policy);
        integer base_addr, p, deadline;
        logic pe_seen;
        begin
            reset = 1'b1;
            execute_enable = 1'b0;
            timing_policy_request = policy;
            repeat (4) tick();
            for (integer i = 0; i < 262144; i = i + 1) memory[i] = 8'h00;
            base_addr = {12'h000, real_cs, 4'h0};

            // Actual LMSW transition from a real-mode CS with arbitrary low
            // bits. Intel 210498-005 section 10.4: initial privilege is zero;
            // setting PE preserves the old segment caches until reload.
            p = base_addr;
            memory[p] = 8'h0F; memory[p+1] = 8'h01; memory[p+2] = 8'h16;
            put_word(p+3, 16'h0300); p = p + 5; // LGDT [0300]
            memory[p] = 8'hB8; put_word(p+1, 16'h0009); p = p + 3;
            memory[p] = 8'h0F; memory[p+1] = 8'h01; memory[p+2] = 8'hF0;
            p = p + 3; // LMSW AX: PE+TS
            if (variant == 1) begin
                memory[p] = 8'h0F; memory[p+1] = 8'h06; p = p + 2; // CLTS
            end
            if (variant == 2) begin
                memory[p] = 8'h0F; memory[p+1] = 8'h05; // LOADALL at CPL0
            end else begin
                memory[p] = 8'hEA; put_word(p+1, 16'h0100);
                put_word(p+3, 16'h0008); // JMP to present DPL0 code
            end

            // Protected target clears TS, loads a DPL0 stack, and halts with
            // a marker. Code keeps the same physical base across the switch.
            p = base_addr + 256;
            memory[p] = 8'h0F; memory[p+1] = 8'h06; p = p + 2;
            memory[p] = 8'hB8; put_word(p+1, 16'h0010); p = p + 3;
            memory[p] = 8'h8E; memory[p+1] = 8'hD0; p = p + 2;
            memory[p] = 8'hBC; put_word(p+1, 16'hF000); p = p + 3;
            memory[p] = 8'hB8; put_word(p+1, 16'hBEEF); p = p + 3;
            memory[p] = 8'hF4;

            put_word('h0300, 16'h0017); put_word('h0302, 16'h0400);
            put_word('h0408, 16'hFFFF); put_word('h040A, base_addr[15:0]);
            memory['h040C] = base_addr[23:16]; memory['h040D] = 8'h9A;
            put_word('h0410, 16'hFFFF); memory['h0415] = 8'h92;

            // LOADALL exercises the separate privilege consumer at the CPU
            // boundary. Its loaded protected context has CS.RPL = 0.
            put_word('h0806, 16'h0009); put_word('h0818, 16'h0002);
            put_word('h081A, 16'h0100); put_word('h0822, 16'h0008);
            put_word('h0838, 16'h9300); put_word('h083A, 16'hFFFF);
            put_word('h083C, base_addr[15:0]);
            put_word('h083E, {8'h9A, base_addr[23:16]});
            put_word('h0840, 16'hFFFF);
            put_word('h0844, 16'h9300); put_word('h0846, 16'hFFFF);
            put_word('h084A, 16'h9300); put_word('h084C, 16'hFFFF);
            put_word('h084E, 16'h0400); put_word('h0852, 16'h0017);
            put_word('h085E, 16'h03FF);

            reset = 1'b0;
            segment_load_en = 1'b1; segment_load_index = 2'd1;
            segment_load_selector = real_cs;
            ip_write_en = 1'b1; ip_write_data = 16'h0000; redirect = 1'b1;
            tick();
            segment_load_en = 1'b0; ip_write_en = 1'b0; redirect = 1'b0;
            execute_enable = 1'b1;
            pe_seen = 1'b0;
            deadline = 0;
            while (!halted && !shutdown && deadline < 2000) begin
                tick();
                deadline = deadline + 1;
                if (debug_protected_msw[0] && !pe_seen) begin
                    pe_seen = 1'b1;
                    check(debug_cs == real_cs && debug_cs_base == base_addr[23:0],
                          "LMSW preserves the visible CS and hidden base");
                end
            end
            cases = cases + 1;
            check(pe_seen && halted && !shutdown && debug_cs == 16'h0008 &&
                  debug_cs_base == base_addr[23:0] && debug_gpr[15:0] == 16'hBEEF &&
                  debug_segment_selectors[47:32] == 16'h0010 &&
                  debug_gpr[79:64] == 16'hF000 && !debug_protected_msw[3] &&
                  debug_timing_event_requests == 64'd0,
                  $sformatf("entry from real CS=%h variant=%0d policy=%0d", real_cs, variant, policy));
        end
    endtask

    initial begin
        for (integer policy = 0; policy < 3; policy = policy + 1)
            for (integer variant = 0; variant < 3; variant = variant + 1) begin
                // Cover every low-three-bit combination, plus the selector
                // captured at the Windows 3.1 entry failure in 86Box.
                for (integer low = 0; low < 8; low = low + 1)
                    run_case(16'h1200 + 16'(low), variant, 2'(policy));
                run_case(16'h292E, variant, 2'(policy));
            end
        if (failures != 0) $fatal(1, "PROTECTED_ENTRY: %0d failures / %0d cases", failures, cases);
        $display("PROTECTED_ENTRY PASS: %0d checks / %0d cases", checks, cases);
        $finish;
    end
endmodule
