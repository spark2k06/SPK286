`timescale 1ns/1ps

module spk286_protected_return_restart_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    integer cycles = 0, cases = 0, checks = 0, failures = 0;
    spk286 dut (.*);

    task automatic tick;
        begin
            #1;
            ready = bus_valid && ((cycles % 4) != 1);
            data_in = 16'h0000;
            if (bus_valid && !bus_write) begin
                if (address[0]) data_in = {memory[address[15:0]], 8'h00};
                else if (bus_bhe_n) data_in = {8'h00, memory[address[15:0]]};
                else data_in = {memory[address[15:0]+16'd1], memory[address[15:0]]};
            end
            if (bus_valid && ready && bus_write && bus_status == 4'h6) begin
                if (address[0]) memory[address[15:0]] = data_out[15:8];
                else begin
                    memory[address[15:0]] = data_out[7:0];
                    if (!bus_bhe_n) memory[address[15:0]+16'd1] = data_out[15:8];
                end
            end
            #4; clk = 1'b1; #5; clk = 1'b0; #1;
            cycles = cycles + 1;
        end
    endtask

    task automatic word_put(input integer addr, input logic [15:0] value);
        memory[addr] = value[7:0]; memory[addr+1] = value[15:8];
    endtask
    function automatic logic [15:0] word_at(input integer addr);
        word_at = {memory[addr+1], memory[addr]};
    endfunction
    task automatic cache(input integer addr, input logic [23:0] base_addr,
                         input logic [15:0] limit_value, input logic [7:0] access_byte);
        word_put(addr, base_addr[15:0]); word_put(addr+2, {access_byte, base_addr[23:16]});
        word_put(addr+4, limit_value);
    endtask
    task automatic descriptor(input integer addr, input logic [23:0] base_addr,
                              input logic [15:0] limit_value, input logic [7:0] access_byte);
        word_put(addr, limit_value); word_put(addr+2, base_addr[15:0]);
        word_put(addr+4, {access_byte, base_addr[23:16]}); word_put(addr+6, 16'h0000);
    endtask
    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1) begin
            failures = failures + 1;
            $display("RETURN_RESTART FAIL: %s CS:IP=%h:%h SP=%h event=%h:%h",
                     message, debug_cs, debug_ip, debug_gpr[79:64], debug_event_vector, debug_event_error_code);
        end
    endtask

    task automatic run_case(input integer form, input integer fault_kind, input logic [1:0] policy);
        integer p, deadline;
        logic [15:0] bad_selector, expected_error, expected_sp;
        logic [7:0] expected_vector;
        string label;
        begin
            reset = 1'b1; execute_enable = 1'b0; timing_policy_request = policy;
            repeat (4) tick();
            for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;
            bad_selector = fault_kind == 0 ? 16'h00E0 : fault_kind == 1 ? 16'h00E3 : 16'h0053;
            expected_error = fault_kind == 2 ? 16'h0000 : 16'h00E0;
            expected_vector = fault_kind == 1 ? 8'd11 : 8'd13;
            expected_sp = form == 0 ? 16'h0FF0 : form == 1 ? 16'h0FF4 : 16'h0FF2;
            label = $sformatf("form=%0d fault=%0d policy=%0d", form, fault_kind, policy);

            // Reproduce the Windows RETF -> #GP(00E0) service convention.
            // LOADALL provides CPL3, a ring-0 fault stack and ES access to
            // the client frame. The handler repairs the return and retries.
            memory[0] = 8'h0F; memory[1] = 8'h05;
            word_put('h806, 16'h0001); word_put('h816, 16'h0088);
            word_put('h818, 16'h0246); word_put('h81A, 16'h9F31); word_put('h81C, 16'h0038);
            word_put('h81E, 16'h004B); word_put('h820, 16'h02DF);
            word_put('h822, 16'h043F); word_put('h824, 16'h005B); word_put('h82C, 16'h0FEC);
            cache('h836, 24'h006000, 16'h0FFF, 8'hF3);
            cache('h83C, 24'h003000, 16'hB6CF, 8'hFB);
            cache('h842, 24'h006000, 16'h0FFF, 8'hF3);
            cache('h848, 24'h001000, 16'hFFFF, 8'hF3);
            cache('h84E, 24'h001000, 16'h011F, 8'h00);
            cache('h854, 24'h002000, 16'h5FFF, 8'h82);
            cache('h85A, 24'h001800, 16'h07FF, 8'h00);
            cache('h860, 24'h009000, 16'h002B, 8'h83);
            descriptor('h2438, 24'h003000, 16'hB6CF, 8'hFB);
            descriptor('h22D8, 24'h006000, 16'h0FFF, 8'hF3);
            descriptor('h1048, 24'h001000, 16'hFFFF, 8'hF3);
            descriptor('h1050, 24'h004000, fault_kind == 2 ? 16'h1000 : 16'h4330, 8'hFB);
            descriptor('h1058, 24'h006000, 16'h0FFF, 8'hF3);
            descriptor('h1068, 24'h00A000, 16'h3FFF, 8'h93);
            descriptor('h1070, 24'h004000, 16'h4330, 8'h9B);
            descriptor('h1088, 24'h009000, 16'h002B, 8'h83);
            descriptor('h10E0, 24'h004000, 16'h4330, fault_kind == 1 ? 8'h7B : 8'h9A);
            word_put('h9002, 16'h3000); word_put('h9004, 16'h0068);
            for (integer vector_num = 11; vector_num <= 13; vector_num = vector_num + 2) begin
                word_put('h1800 + vector_num*8, 16'h0100);
                word_put('h1802 + vector_num*8, 16'h0070);
                word_put('h1804 + vector_num*8, 16'hE600);
            end
            memory['hCF31] = form == 0 ? 8'hCB : form == 1 ? 8'hCA : 8'hCF;
            word_put('hCF32, 16'h0004);
            word_put('h6FEC, 16'h140C); word_put('h6FEE, bad_selector);
            word_put('h6FF0, 16'h0202);
            // Ring-0 #GP/#NP handler uses the saved client SP, exactly the
            // state that was four bytes too high in the Windows log.
            p = 'h4100;
            memory[p] = 8'h8B; memory[p+1] = 8'hEC; p = p+2; // MOV BP,SP
            memory[p] = 8'h8B; memory[p+1] = 8'h5E; memory[p+2] = 8'h08; p = p+3;
            memory[p] = 8'h26; memory[p+1] = 8'hC7; memory[p+2] = 8'h47; memory[p+3] = 8'h02;
            word_put(p+4, 16'h0053); p = p+6; // MOV ES:[BX+2],0053
            memory[p] = 8'hC7; memory[p+1] = 8'h06; word_put(p+2, 16'h0050);
            word_put(p+4, 16'h4330); p = p+6; // restore target limit via DS
            memory[p] = 8'h83; memory[p+1] = 8'hC4; memory[p+2] = 8'h02; memory[p+3] = 8'hCF;
            memory['h540C] = 8'hB8; word_put('h540D, 16'hBEEF);
            memory['h540F] = 8'hEB; memory['h5410] = 8'hFE;

            reset = 1'b0; segment_load_en = 1'b1; segment_load_index = 2'd1;
            segment_load_selector = 0; ip_write_en = 1'b1; ip_write_data = 0; redirect = 1'b1;
            tick(); segment_load_en = 1'b0; ip_write_en = 1'b0; redirect = 1'b0; execute_enable = 1'b1;
            deadline = 0;
            while (debug_timing_event_requests == 0 && !shutdown && deadline < 2000) begin
                tick(); deadline = deadline + 1;
            end
            check(!shutdown && debug_event_vector == expected_vector && debug_event_error_code == expected_error &&
                  debug_gpr[79:64] == 16'h0FEC && debug_cs == 16'h043F && debug_flags == 16'h0246 &&
                  word_at('h6FEC) == 16'h140C && word_at('h6FEE) == bad_selector,
                  {label, " fault preserves architectural SP and return frame"});
            deadline = 0;
            while (!event_completed && !shutdown && deadline < 1500) begin
                tick(); deadline = deadline + 1;
            end
            check(event_completed && !shutdown && debug_cs == 16'h0070 && debug_gpr[79:64] == 16'h2FF4 &&
                  word_at('hCFF4) == expected_error && word_at('hCFF6) == 16'h9F31 &&
                  word_at('hCFF8) == 16'h043F && word_at('hCFFC) == 16'h0FEC &&
                  word_at('hCFFE) == 16'h02DF,
                  {label, " privilege-changing exception saves original SS:SP"});
            deadline = 0;
            while (!shutdown && debug_timing_event_requests == 1 && debug_gpr[15:0] != 16'hBEEF && deadline < 3000) begin
                tick(); deadline = deadline + 1;
            end
            check(!shutdown && debug_timing_event_requests == 1 && debug_cs == 16'h0053 &&
                  debug_gpr[15:0] == 16'hBEEF && debug_gpr[79:64] == expected_sp &&
                  debug_segment_selectors[47:32] == 16'h02DF,
                  {label, " handler repairs frame and IRET retries the protected return"});
            cases = cases + 1;
        end
    endtask

    initial begin
        for (integer policy = 0; policy < 3; policy = policy + 1)
            for (integer form = 0; form < 3; form = form + 1)
                for (integer fault_kind = 0; fault_kind < 3; fault_kind = fault_kind + 1)
                    run_case(form, fault_kind, 2'(policy));
        if (failures != 0) $fatal(1, "PROTECTED_RETURN_RESTART: %0d failures / %0d cases", failures, cases);
        $display("PROTECTED_RETURN_RESTART PASS: %0d checks / %0d cases", checks, cases);
        $finish;
    end
endmodule
