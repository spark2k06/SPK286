`timescale 1ns/1ps

// Direct far CALL/JMP task-transfer descriptor matrix.  Descriptor-class
// failures are rejected before task service entry; a short TSS is allowed to
// reach the task service and then raises #TS before any TSS image write.
module spk286_protected_task_fault_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer cycles = 0;
    integer checks = 0;
    logic fault_request_reported = 1'b0;
    logic [7:0] first_fault_vector = 8'h00;

    spk286 dut (.*);

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "%s: CS=%h IP=%h TR=%h FLAGS=%h MSW=%h fault=%h bus=%h",
                       message, debug_cs, debug_ip, debug_tr_selector, debug_flags,
                       debug_protected_msw, first_fault_vector, bus_status);
        end
    endtask

    task automatic write_word(input integer address, input logic [15:0] value);
        begin
            memory[address] = value[7:0];
            memory[address + 1] = value[15:8];
        end
    endtask

    task automatic write_descriptor(
        input integer address,
        input logic [23:0] base,
        input logic [15:0] limit,
        input logic [7:0] access
    );
        begin
            write_word(address, limit);
            write_word(address + 2, base[15:0]);
            memory[address + 4] = base[23:16];
            memory[address + 5] = access;
            memory[address + 6] = 8'h00;
            memory[address + 7] = 8'h00;
        end
    endtask

    task automatic tick;
        begin
            #1;
            if (!fault_request_reported && dut.fault_request) begin
                fault_request_reported = 1'b1;
                first_fault_vector = dut.fault_vector;
            end
            ready = bus_valid && ((cycles % 4) != 1);
            data_in = 16'h0000;
            if (bus_valid && !bus_write) begin
                if (bus_status == 4'h0) data_in = 16'h0022;
                else if (address[0]) data_in = {memory[address[15:0]], 8'h00};
                else if (bus_bhe_n) data_in = {8'h00, memory[address[15:0]]};
                else data_in = {memory[address[15:0] + 16'd1], memory[address[15:0]]};
            end
            if (bus_valid && ready && bus_write && bus_status == 4'h6) begin
                if (address[0]) memory[address[15:0]] = data_out[15:8];
                else begin
                    memory[address[15:0]] = data_out[7:0];
                    if (!bus_bhe_n) memory[address[15:0] + 16'd1] = data_out[15:8];
                end
            end
            #4; clk = 1'b1; #5; clk = 1'b0; #1;
            cycles = cycles + 1;
        end
    endtask

    task automatic far_restart(input logic [15:0] cs, input logic [15:0] ip);
        begin
            segment_load_en = 1'b1;
            segment_load_index = 2'd1;
            segment_load_selector = cs;
            ip_write_en = 1'b1;
            ip_write_data = ip;
            redirect = 1'b1;
            tick();
            segment_load_en = 1'b0;
            ip_write_en = 1'b0;
            redirect = 1'b0;
            tick();
        end
    endtask

    task automatic reset_cpu;
        begin
            reset = 1'b1;
            execute_enable = 1'b0;
            ready = 1'b0;
            repeat (8) tick();
            reset = 1'b0;
            execute_enable = 1'b1;
        end
    endtask

    task automatic initialize_case(
        input logic do_call,
        input logic [15:0] target_selector,
        input logic [15:0] gdt_limit,
        input logic [15:0] target_limit,
        input logic [7:0] target_access,
        input logic target_reserved
    );
        begin
            for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;

            // Real-mode setup: LGDT, LMSW and a protected-mode far jump.
            memory[16'h0000] = 8'h0F; memory[16'h0001] = 8'h01; memory[16'h0002] = 8'h16;
            memory[16'h0003] = 8'h00; memory[16'h0004] = 8'h03;
            memory[16'h0005] = 8'hB8; memory[16'h0006] = 8'h01; memory[16'h0007] = 8'h00;
            memory[16'h0008] = 8'h0F; memory[16'h0009] = 8'h01; memory[16'h000A] = 8'hF0;
            memory[16'h000B] = 8'hEA; memory[16'h000C] = 8'h00; memory[16'h000D] = 8'h01;
            memory[16'h000E] = 8'h10; memory[16'h000F] = 8'h00;

            // LTR current TSS, then direct far CALL/JMP to the test selector.
            memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h18; memory[16'h0102] = 8'h00;
            memory[16'h0103] = 8'h0F; memory[16'h0104] = 8'h00; memory[16'h0105] = 8'hD8;
            memory[16'h0106] = do_call ? 8'h9A : 8'hEA;
            memory[16'h0107] = 8'h00; memory[16'h0108] = 8'h00;
            memory[16'h0109] = target_selector[7:0]; memory[16'h010A] = target_selector[15:8];

            // GDT at 2000h: data, code, current TSS, target TSS, spare TSS.
            write_descriptor(32'h2000 + 32'd8 * 1, 24'h000000, 16'hFFFF, 8'h93);
            write_descriptor(32'h2000 + 32'd8 * 2, 24'h000000, 16'hFFFF, 8'h9A);
            write_descriptor(32'h2000 + 32'd8 * 3, 24'h004000, 16'h002B, 8'h81);
            write_descriptor(32'h2000 + 32'd8 * 4, 24'h005000, target_limit, target_access);
            write_descriptor(32'h2000 + 32'd8 * 5, 24'h005000, 16'h002B, 8'h81);
            write_word(32'h0300, gdt_limit);
            memory[16'h0302] = 8'h00; memory[16'h0303] = 8'h20; memory[16'h0304] = 8'h00;
            if (target_reserved) write_word(32'h2026, 16'h0001);

            // Valid image: invalid descriptor cases must not consume it.
            write_word(32'h5000 + 32'h000E, 16'h0200);
            write_word(32'h5000 + 32'h0010, 16'h0202);
            write_word(32'h5000 + 32'h0012, 16'hBEEF);
            write_word(32'h5000 + 32'h0022, 16'h0000); // ES
            write_word(32'h5000 + 32'h0024, 16'h0010); // CS
            write_word(32'h5000 + 32'h0026, 16'h0008); // SS
            write_word(32'h5000 + 32'h0028, 16'h0000); // DS
            write_word(32'h5000 + 32'h002A, 16'h0000); // null LDTR
        end
    endtask

    task automatic run_fault_case(
        input logic do_call,
        input logic [15:0] target_selector,
        input logic [15:0] gdt_limit,
        input logic [15:0] target_limit,
        input logic [7:0] target_access,
        input logic target_reserved,
        input logic [7:0] expected_vector,
        input string message
    );
        integer deadline;
        begin
            initialize_case(do_call, target_selector, gdt_limit, target_limit,
                            target_access, target_reserved);
            cycles = 0;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            deadline = 0;
            while (!fault_request_reported && deadline < 2200) begin
                tick();
                deadline = deadline + 1;
            end
            check(fault_request_reported && first_fault_vector == expected_vector,
                  message);
            check(debug_tr_selector == 16'h0018 && memory[16'h2025] == target_access,
                  "rejected direct TSS transfer preserves the current task and target busy bit");
            check({memory[16'h400F], memory[16'h400E]} == 16'h0000,
                  "rejected direct TSS transfer does not save the outgoing IP");
            check(memory[16'h201D] == 8'h83 && memory[16'h5000] == 8'h00 &&
                  memory[16'h5001] == 8'h00,
                  "rejected direct TSS transfer preserves outgoing busy and backlink");
        end
    endtask

    initial begin
        // Not-present TSS: #NP before task-service entry.
        run_fault_case(1'b1, 16'h0020, 16'h002F, 16'h002B, 8'h01, 1'b0, 8'h0B,
                       "direct CALL/JMP reports a not-present TSS as #NP");
        run_fault_case(1'b0, 16'h0020, 16'h002F, 16'h002B, 8'h01, 1'b0, 8'h0B,
                       "direct CALL/JMP reports a not-present TSS as #NP");

        // Busy TSS is not a valid direct entry target.
        run_fault_case(1'b0, 16'h0020, 16'h002F, 16'h002B, 8'h83, 1'b0, 8'h0D,
                       "direct CALL/JMP rejects a busy TSS as #GP");
        run_fault_case(1'b1, 16'h0020, 16'h002F, 16'h002B, 8'h83, 1'b0, 8'h0D,
                       "direct CALL/JMP rejects a busy TSS as #GP");

        // Direct entry requires an available TSS, not a segment or LDT.
        run_fault_case(1'b1, 16'h0020, 16'h002F, 16'hFFFF, 8'h93, 1'b0, 8'h0D,
                       "direct CALL/JMP rejects a data descriptor as #GP");
        run_fault_case(1'b0, 16'h0020, 16'h002F, 16'hFFFF, 8'h82, 1'b0, 8'h0D,
                       "direct CALL/JMP rejects an LDT descriptor as #GP");
        run_fault_case(1'b0, 16'h0020, 16'h002F, 16'hFFFF, 8'h93, 1'b0, 8'h0D,
                       "direct CALL/JMP rejects a data descriptor as #GP");
        run_fault_case(1'b1, 16'h0020, 16'h002F, 16'hFFFF, 8'h82, 1'b0, 8'h0D,
                       "direct CALL/JMP rejects an LDT descriptor as #GP");

        // Reserved descriptor form is rejected before task-state write.  A
        // short TSS reaches the task service and reports invalid TSS (#TS).
        run_fault_case(1'b1, 16'h0020, 16'h002F, 16'h002A, 8'h81, 1'b0, 8'h0A,
                       "direct CALL/JMP rejects a short TSS descriptor as #TS");
        run_fault_case(1'b0, 16'h0020, 16'h002F, 16'h002B, 8'h81, 1'b1, 8'h0D,
                       "direct CALL/JMP rejects reserved TSS descriptor words as #GP");
        run_fault_case(1'b0, 16'h0020, 16'h002F, 16'h002A, 8'h81, 1'b0, 8'h0A,
                       "direct CALL/JMP rejects a short TSS descriptor as #TS");
        run_fault_case(1'b1, 16'h0020, 16'h002F, 16'h002B, 8'h81, 1'b1, 8'h0D,
                       "direct CALL/JMP rejects reserved TSS descriptor words as #GP");

        // GDT boundary and TI selector rejection must happen without a
        // wrapped descriptor read.
        run_fault_case(1'b1, 16'h0028, 16'h0027, 16'h002B, 8'h81, 1'b0, 8'h0D,
                       "direct CALL/JMP rejects a TSS selector beyond the GDT limit");
        run_fault_case(1'b0, 16'h0024, 16'h002F, 16'h002B, 8'h81, 1'b0, 8'h0D,
                       "direct CALL/JMP rejects an LDT-qualified TSS selector without an LDT");
        run_fault_case(1'b0, 16'h0028, 16'h0027, 16'h002B, 8'h81, 1'b0, 8'h0D,
                       "direct CALL/JMP rejects a TSS selector beyond the GDT limit");
        run_fault_case(1'b1, 16'h0024, 16'h002F, 16'h002B, 8'h81, 1'b0, 8'h0D,
                       "direct CALL/JMP rejects an LDT-qualified TSS selector without an LDT");

        $display("PROTECTED_TASK_FAULT PASS: %0d checks, cases=16 (CALL/JMP)", checks);
        $finish;
    end
endmodule
