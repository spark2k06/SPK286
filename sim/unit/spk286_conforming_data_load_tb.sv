`timescale 1ns/1ps

module spk286_conforming_data_load_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:262143];
    integer cycles = 0, checks = 0, cases = 0, descriptor_writes = 0;
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
                    if (address == 24'h003075) descriptor_writes = descriptor_writes + 1;
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
            $fatal(1, "CONFORMING_DATA_LOAD: %s CS:IP=%h:%h micro=%h ES=%h DS=%h SP=%h event=%h:%h access=%h",
                   message, debug_cs, debug_ip, debug_micro_pc,
                   debug_segment_selectors[15:0], debug_segment_selectors[63:48],
                   debug_gpr[79:64], debug_event_vector, debug_event_error_code,
                   memory['h3075]);
    endtask

    // form: MOV DS/ES, POP DS/ES, LDS SI, LES DI.
    // failure: valid, execute-only, absent, inaccessible nonconforming code.
    task automatic run_case(input integer form, input integer cpl, input integer dpl,
                            input integer rpl, input logic accessed,
                            input integer failure, input logic [1:0] policy);
        integer p, deadline;
        logic [15:0] selector, old_selector, expected_sp;
        logic [7:0] access_byte, expected_access;
        string label;
        begin
            reset = 1'b1; execute_enable = 1'b0; timing_policy_request = policy;
            repeat (4) tick();
            for (integer i = 'h800; i < 'h866; i = i + 1) memory[i] = 0;
            for (integer i = 'h10100; i < 'h10112; i = i + 1) memory[i] = 0;
            selector = 16'h0070 | 16'(rpl);
            old_selector = (form == 1 || form == 3 || form == 5) ?
                           (16'h0050 | 16'(cpl)) : (16'h0060 | 16'(cpl));
            access_byte = (failure == 1 ? 8'h9C : failure == 2 ? 8'h1E :
                           failure == 3 ? 8'h9A : 8'h9E) | (8'(dpl) << 5) | {7'd0, accessed};
            expected_access = access_byte | 8'h01;
            expected_sp = (form == 2 || form == 3) ? 16'h0F02 : 16'h0F00;
            label = $sformatf("form=%0d CPL=%0d DPL=%0d RPL=%0d A=%b failure=%0d policy=%0d",
                              form, cpl, dpl, rpl, accessed, failure, policy);

            memory[0] = 8'h0F; memory[1] = 8'h05;
            put_word('h806, 1); put_word('h816, 16'h0010); put_word('h818, 16'h0002);
            put_word('h81A, 16'h0100); put_word('h81C, 16'h0008);
            put_word('h81E, 16'h0060 | 16'(cpl));
            put_word('h820, 16'h0040 | 16'(cpl));
            put_word('h822, 16'h0018 | 16'(cpl));
            put_word('h824, 16'h0050 | 16'(cpl));
            put_word('h82C, 16'h0F00);
            cache('h836, 24'h000000, 16'hFFFF, 8'h93 | (8'(cpl) << 5));
            cache('h83C, 24'h010000, 16'hFFFF, 8'h9B | (8'(cpl) << 5));
            cache('h842, 24'h020000, 16'hFFFF, 8'h93 | (8'(cpl) << 5));
            cache('h848, 24'h000000, 16'hFFFF, 8'h93 | (8'(cpl) << 5));
            cache('h84E, 24'h003000, 16'h00FF, 0);
            cache('h854, 24'h000000, 16'h0000, 0);
            cache('h85A, 24'h000000, 16'h03FF, 0);
            cache('h860, 24'h004000, 16'h002B, 8'h83);
            descriptor('h3070, 24'h012000, 16'h00FF, access_byte);
            put_word('h600, 16'hBEEF); put_word('h602, selector);
            put_word('h20F00, selector);

            p = 'h10100;
            case (form)
                0, 1: begin
                    memory[p] = 8'hB8; put_word(p+1, selector); p = p+3;
                    memory[p] = 8'h8E; memory[p+1] = form == 0 ? 8'hD8 : 8'hC0; p = p+2;
                end
                2, 3: begin memory[p] = form == 2 ? 8'h1F : 8'h07; p = p+1; end
                4, 5: begin
                    memory[p] = form == 4 ? 8'hC5 : 8'hC4;
                    memory[p+1] = form == 4 ? 8'h36 : 8'h3E;
                    put_word(p+2, 16'h0600); p = p+4;
                end
            endcase
            memory[p] = 8'hBB; put_word(p+1, 16'hCAFE);
            memory[p+3] = 8'hEB; memory[p+4] = 8'hFE;

            reset = 1'b0; segment_load_en = 1'b1; segment_load_index = 2'd1;
            segment_load_selector = 0; ip_write_en = 1'b1; ip_write_data = 0; redirect = 1'b1;
            tick(); segment_load_en = 1'b0; ip_write_en = 1'b0; redirect = 1'b0;
            execute_enable = 1'b1; descriptor_writes = 0; deadline = 0;
            while (!shutdown && debug_timing_event_requests == 0 &&
                   debug_gpr[63:48] != 16'hCAFE && deadline < 2000) begin
                tick(); deadline = deadline + 1;
            end
            if (failure == 0) begin
                check(!shutdown && debug_timing_event_requests == 0 &&
                      debug_gpr[63:48] == 16'hCAFE && debug_gpr[79:64] == expected_sp &&
                      (form == 1 || form == 3 || form == 5 ?
                       debug_segment_selectors[15:0] : debug_segment_selectors[63:48]) == selector &&
                      (form == 1 || form == 3 || form == 5 ?
                       debug_segment_access[7:0] : debug_segment_access[31:24]) == expected_access &&
                      memory['h3075] == expected_access && descriptor_writes == (accessed ? 0 : 1),
                      {label, " loads readable conforming code and publishes the Accessed bit"});
                if (form == 4 || form == 5)
                    check((form == 4 ? debug_gpr[111:96] : debug_gpr[127:112]) == 16'hBEEF,
                          {label, " LDS/LES also loads the pointer offset"});
            end else begin
                check(!shutdown && debug_timing_event_requests == 1 &&
                      debug_event_vector == (failure == 2 ? 8'd11 : 8'd13) &&
                      debug_event_error_code == (selector & 16'hFFFC) &&
                      (form == 1 || form == 3 || form == 5 ?
                       debug_segment_selectors[15:0] : debug_segment_selectors[63:48]) == old_selector &&
                      debug_gpr[79:64] == 16'h0F00 && memory['h3075] == access_byte &&
                      descriptor_writes == 0,
                      {label, " rejects invalid/absent target without publishing segment or stack"});
            end
            cases = cases + 1;
        end
    endtask

    initial begin
        for (integer i = 0; i < 262144; i = i + 1) memory[i] = 0;
        // The first case reproduces OS/2's CPL0 -> DPL2 LDS independently.
        run_case(4, 0, 2, 0, 1'b0, 0, 2'd0);
        for (integer policy = 0; policy < 3; policy = policy + 1)
            for (integer form = 0; form < 6; form = form + 1) begin
                run_case(form, 0, 2, 3, 1'b0, 0, 2'(policy));
                run_case(form, 3, 0, 3, 1'b1, 0, 2'(policy));
                run_case(form, 0, 3, 0, 1'b0, 0, 2'(policy));
            end
        for (integer dpl = 0; dpl < 4; dpl = dpl + 1)
            run_case(4, 1, dpl, 3, 1'b0, 0, 2'd0);
        for (integer form = 0; form < 6; form = form + 1)
            for (integer failure = 1; failure < 4; failure = failure + 1)
                run_case(form, 3, 2, 3, 1'b0, failure, 2'd0);
        $display("CONFORMING_DATA_LOAD PASS: %0d checks / %0d cases", checks, cases);
        $finish;
    end
endmodule
