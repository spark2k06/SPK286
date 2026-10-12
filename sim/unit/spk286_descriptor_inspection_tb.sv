// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module spk286_descriptor_inspection_tb;
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
            $display("DESCRIPTOR_INSPECTION FAIL: %s CS:IP=%h:%h SP=%h event=%h:%h",
                     message, debug_cs, debug_ip, debug_gpr[79:64], debug_event_vector, debug_event_error_code);
        end
    endtask

    task automatic run_case(input logic load_limit, input integer kind,
                            input logic present_bit, input logic [1:0] policy);
        integer deadline;
        logic [15:0] selector, expected_value;
        logic [7:0] access_byte;
        logic visible_descriptor;
        string label;
        begin
            reset = 1'b1; execute_enable = 1'b0; timing_policy_request = policy;
            repeat (4) tick();
            for (integer i = 0; i < 65536; i = i + 1) memory[i] = 0;
            selector = kind == 4 ? 16'h0000 : kind == 5 ? 16'h6007 : 16'h0B2F;
            access_byte = (kind == 1 ? 8'h72 : kind == 2 ? 8'h61 : kind == 3 ? 8'h1B : 8'h7B) |
                          (present_bit ? 8'h80 : 8'h00);
            visible_descriptor = kind < 3;
            expected_value = !visible_descriptor ? 16'h0000 : load_limit ? 16'h0ADF : {access_byte, 8'h00};
            label = $sformatf("LSL=%0d kind=%0d P=%0d policy=%0d", load_limit, kind, present_bit, policy);

            // LOADALL enters CPL3 at the captured Windows LSL CX,BX site.
            // The absent segment's limit encodes the NE module selector.
            memory[0] = 8'h0F; memory[1] = 8'h05;
            word_put('h806, 16'h0001); word_put('h818, 16'h0206);
            word_put('h81A, 16'h58C1); word_put('h81C, 16'h0038);
            word_put('h81E, 16'h004B); word_put('h820, 16'h02DF);
            word_put('h822, 16'h043F); word_put('h824, 16'h0000);
            word_put('h82C, 16'h0800); word_put('h82E, selector);
            cache('h836, 24'h000000, 16'h0000, 8'h00);
            cache('h83C, 24'h003000, 16'hB6CF, 8'hFB);
            cache('h842, 24'h006000, 16'h0FFF, 8'hF3);
            cache('h848, 24'h005000, 16'h0FFF, 8'hF3);
            cache('h84E, 24'h001000, 16'h011F, 8'h00);
            cache('h854, 24'h002000, 16'h5FFF, 8'h82);
            cache('h85A, 24'h001800, 16'h0000, 8'h00);
            cache('h860, 24'h000000, 16'h0000, 8'h00);
            descriptor('h2B28, 24'h000000, 16'h0ADF, access_byte);
            if (kind != 2) word_put('h2B2E, 16'h0010);
            descriptor('h2AD8, 24'h005000, 16'h0FFF, 8'hF3);
            word_put('h5000, 16'h454E);
            memory['h88C1] = 8'h0F; memory['h88C2] = load_limit ? 8'h03 : 8'h02;
            memory['h88C3] = 8'hCB; // LSL/LAR CX,BX
            memory['h88C4] = 8'hB8; word_put('h88C5, 16'hBEEF);
            memory['h88C7] = 8'hEB; memory['h88C8] = 8'hFE;
            if (load_limit && visible_descriptor) begin
                memory['h88C7] = 8'h8E; memory['h88C8] = 8'hC1; // MOV ES,CX
                memory['h88C9] = 8'h26; memory['h88CA] = 8'h81;
                memory['h88CB] = 8'h3E; word_put('h88CC, 0); word_put('h88CE, 16'h454E);
                memory['h88D0] = 8'hB8; word_put('h88D1, 16'hCAFE);
                memory['h88D3] = 8'hEB; memory['h88D4] = 8'hFE;
            end
            reset = 1'b0; segment_load_en = 1'b1; segment_load_index = 2'd1;
            segment_load_selector = 0; ip_write_en = 1'b1; ip_write_data = 0; redirect = 1'b1;
            tick(); segment_load_en = 1'b0; ip_write_en = 1'b0; redirect = 1'b0; execute_enable = 1'b1;
            deadline = 0;
            while (!shutdown && debug_gpr[15:0] != 16'hBEEF && deadline < 1500) begin
                tick(); deadline = deadline + 1;
            end
            check(!shutdown && debug_timing_event_requests == 0 && debug_gpr[15:0] == 16'hBEEF &&
                  debug_gpr[31:16] == expected_value && debug_flags == (visible_descriptor ? 16'h0246 : 16'h0206),
                  {label, " result and ZF depend on visibility, not presence"});
            check(word_at('h2B28) == 16'h0ADF && memory['h2B2D] == access_byte &&
                  word_at('h2B2E) == (kind == 2 ? 16'h0000 : 16'h0010),
                  {label, " descriptor inspection does not mutate the descriptor"});
            if (load_limit && visible_descriptor) begin
                deadline = 0;
                while (!shutdown && debug_gpr[15:0] != 16'hCAFE && deadline < 1000) begin
                    tick(); deadline = deadline + 1;
                end
                check(!shutdown && debug_timing_event_requests == 0 && debug_gpr[15:0] == 16'hCAFE &&
                      debug_flags[6] && debug_segment_selectors[15:0] == 16'h0ADF,
                      {label, " loader can read the NE header through the returned selector"});
            end
            cases = cases + 1;
        end
    endtask

    initial begin
        for (integer policy = 0; policy < 3; policy = policy + 1)
            for (integer op = 0; op < 2; op = op + 1)
                for (integer kind = 0; kind < 6; kind = kind + 1)
                    for (integer p = 0; p < 2; p = p + 1)
                        run_case(1'(op), kind, 1'(p), 2'(policy));
        if (failures != 0) $fatal(1, "DESCRIPTOR_INSPECTION: %0d failures / %0d cases", failures, cases);
        $display("DESCRIPTOR_INSPECTION PASS: %0d checks / %0d cases", checks, cases);
        $finish;
    end
endmodule
