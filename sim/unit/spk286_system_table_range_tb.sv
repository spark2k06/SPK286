// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module spk286_system_table_range_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:131071];
    integer cycles = 0, cases = 0, checks = 0, failures = 0;
    integer data_writes = 0;
    spk286 dut (.*);

    task automatic tick;
        begin
            #1;
            ready = bus_valid && ((cycles % 4) != 1);
            data_in = 0;
            if (bus_valid && !bus_write) begin
                if (address[0]) data_in = {memory[address[16:0]], 8'h00};
                else if (bus_bhe_n) data_in = {8'h00, memory[address[16:0]]};
                else data_in = {memory[address[16:0]+17'd1], memory[address[16:0]]};
            end
            if (bus_valid && ready && bus_write && bus_status == 4'h6) begin
                data_writes = data_writes + 1;
                if (address[0]) memory[address[16:0]] = data_out[15:8];
                else begin
                    memory[address[16:0]] = data_out[7:0];
                    if (!bus_bhe_n) memory[address[16:0]+17'd1] = data_out[15:8];
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
    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1) begin
            failures = failures + 1;
            $display("SYSTEM_TABLE_RANGE FAIL: %s CS:IP=%h:%h event=%h:%h",
                     message, debug_cs, debug_ip, debug_event_vector, debug_event_error_code);
        end
    endtask

    task automatic run_case(input integer operation_kind, input logic use_ds,
                            input logic expand_down, input integer boundary,
                            input logic [1:0] policy);
        integer deadline, pc, operand_addr;
        logic [15:0] limit_value, offset_value;
        logic expect_fault, is_store;
        logic [23:0] expected_base;
        logic [15:0] expected_limit;
        string label;
        begin
            reset = 1'b1; execute_enable = 1'b0; timing_policy_request = policy;
            repeat (4) tick();
            for (integer i = 0; i < 131072; i = i + 1) memory[i] = 0;
            data_writes = 0;
            is_store = operation_kind < 2;
            // Case zero reproduces the OS/2 SGDT [BP-6] stack range.
            limit_value = expand_down ? 16'hF4DF : 16'hF8FF;
            offset_value = 16'hF896;
            expect_fault = boundary == 2 || boundary == 4;
            case (boundary)
                1: offset_value = expand_down ? limit_value + 16'd1 : limit_value - 16'd5;
                2: offset_value = expand_down ? limit_value : limit_value - 16'd4;
                3: begin offset_value = 16'hFFFA; if (!expand_down) limit_value = 16'hFFFF; end
                4: begin offset_value = 16'hFFFB; if (!expand_down) limit_value = 16'hFFFF; end
                5: offset_value = 16'hF897; // Odd address: exercise split bus transfers.
                default: begin end
            endcase
            label = $sformatf("op=%0d DS=%0d ED=%0d boundary=%0d policy=%0d",
                              operation_kind, use_ds, expand_down, boundary, policy);
            // LOADALL establishes the hidden caches independently of the
            // descriptor-table instructions under test.
            memory[0] = 8'h0F; memory[1] = 8'h05;
            word_put('h806, 16'h0001); word_put('h818, 16'h0086);
            word_put('h81A, 16'h2136); word_put('h81E, 16'h03A0);
            word_put('h820, 16'h0038); word_put('h822, 16'h0380);
            word_put('h82A, offset_value + 16'd6); // BP
            word_put('h82C, 16'hF896); // SP
            cache('h836, 24'h000000, 16'hFFFF, 8'h93);
            cache('h83C, 24'h010000, 16'h4D84, 8'h9B);
            cache('h842, 24'h000000, limit_value, expand_down ? 8'h97 : 8'h93);
            cache('h848, 24'h000000, limit_value, expand_down ? 8'h97 : 8'h93);
            cache('h84E, 24'h110020, 16'h1AFF, 8'h00);
            cache('h854, 24'h000000, 16'h0000, 8'h00);
            cache('h85A, 24'h113336, 16'h03FF, 8'h00);
            cache('h860, 24'h000000, 16'h0000, 8'h00);
            pc = 'h12136;
            if (use_ds) begin memory[pc] = 8'h3E; pc = pc + 1; end
            memory[pc] = 8'h0F; memory[pc+1] = 8'h01;
            memory[pc+2] = 8'h46 | (8'(operation_kind) << 3);
            memory[pc+3] = 8'hFA;
            memory[pc+4] = 8'hB8; word_put(pc+5, 16'hBEEF);
            memory[pc+7] = 8'hF4;
            operand_addr = int'(offset_value);
            // Include the sixth byte and guard bytes in the assertions.
            for (integer j = -1; j < 7; j = j + 1) memory[operand_addr+j] = 8'hA5;
            if (!is_store) begin
                word_put(operand_addr, 16'h5678);
                word_put(operand_addr+2, 16'h9ABC);
                word_put(operand_addr+4, 16'h12DE);
            end
            expected_base = operation_kind == 0 ? 24'h110020 : 24'h113336;
            expected_limit = operation_kind == 0 ? 16'h1AFF : 16'h03FF;
            reset = 1'b0; segment_load_en = 1'b1; segment_load_index = 2'd1;
            segment_load_selector = 0; ip_write_en = 1'b1; ip_write_data = 0; redirect = 1'b1;
            tick(); segment_load_en = 1'b0; ip_write_en = 1'b0; redirect = 1'b0; execute_enable = 1'b1;
            deadline = 0;
            while (!shutdown && !halted && debug_timing_event_requests == 0 && deadline < 1500) begin
                tick(); deadline = deadline + 1;
            end
            if (expect_fault) begin
                check(debug_timing_event_requests == 1 && debug_event_vector == (use_ds ? 8'd13 : 8'd12) &&
                      debug_event_error_valid && debug_event_error_code == 0,
                      {label, " invalid full range raises #SS(0) or #GP(0)"});
                check(data_writes == 0 && debug_gpr[79:64] == 16'hF896,
                      {label, " rejected operand has no partial writes or stack changes"});
                check(debug_gdtr_base == 24'h110020 && debug_gdtr_limit == 16'h1AFF &&
                      debug_idtr_base == 24'h113336 && debug_idtr_limit == 16'h03FF,
                      {label, " rejected load preserves table registers"});
            end else begin
                check(halted && !shutdown && debug_timing_event_requests == 0 && debug_gpr[15:0] == 16'hBEEF,
                      {label, " valid operation reaches continuation"});
                check(debug_flags == 16'h0086 && debug_gpr[79:64] == 16'hF896,
                      {label, " table operation preserves flags and SP"});
                if (is_store) begin
                    check(word_at(operand_addr) == expected_limit &&
                          word_at(operand_addr+2) == expected_base[15:0] &&
                          word_at(operand_addr+4) == {8'hFF, expected_base[23:16]},
                          {label, " store writes six bytes with 286 compatibility byte FF"});
                end else begin
                    check((operation_kind == 2 ? debug_gdtr_base : debug_idtr_base) == 24'hDE9ABC &&
                          (operation_kind == 2 ? debug_gdtr_limit : debug_idtr_limit) == 16'h5678 && data_writes == 0,
                          {label, " load reads the 24-bit base and ignores the sixth byte"});
                end
                check(memory[operand_addr-1] == 8'hA5 && memory[operand_addr+6] == 8'hA5,
                      {label, " operand guard bytes preserved"});
            end
            cases = cases + 1;
        end
    endtask

    initial begin
        for (integer policy = 0; policy < 3; policy = policy + 1)
            for (integer op = 0; op < 4; op = op + 1)
                for (integer ds = 0; ds < 2; ds = ds + 1)
                    for (integer ed = 0; ed < 2; ed = ed + 1)
                        for (integer boundary = 0; boundary < 6; boundary = boundary + 1)
                            run_case(op, 1'(ds), 1'(ed), boundary, 2'(policy));
        if (failures != 0) $fatal(1, "SYSTEM_TABLE_RANGE: %0d failures / %0d cases", failures, cases);
        $display("SYSTEM_TABLE_RANGE PASS: %0d checks / %0d cases", checks, cases);
        $finish;
    end
endmodule
