// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module spk286_protected_task_gate_fault_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer cycles = 0;
    integer checks = 0;
    logic fault_request_reported = 1'b0;
    logic [7:0] first_fault_vector = 8'h00;
    logic stall_ready = 1'b0;

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
            ready = !stall_ready && bus_valid && ((cycles % 4) != 1);
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
        input logic [15:0] gate_selector,
        input logic [15:0] gate_limit,
        input logic [7:0] gate_access,
        input logic [15:0] target_limit,
        input logic [7:0] target_access
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

            // LTR is completed before the candidate far task-gate transfer.
            memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h18; memory[16'h0102] = 8'h00;
            memory[16'h0103] = 8'h0F; memory[16'h0104] = 8'h00; memory[16'h0105] = 8'hD8;
            memory[16'h0106] = do_call ? 8'h9A : 8'hEA;
            memory[16'h0107] = 8'h00; memory[16'h0108] = 8'h00;
            memory[16'h0109] = gate_selector[7:0]; memory[16'h010A] = gate_selector[15:8];

            // GDT at 2000h: data, code, current TSS, target TSS and task gate.
            write_descriptor(32'h2000 + 32'd8 * 1, 24'h000000, 16'hFFFF, 8'h93);
            write_descriptor(32'h2000 + 32'd8 * 2, 24'h000000, 16'hFFFF, 8'h9A);
            write_descriptor(32'h2000 + 32'd8 * 3, 24'h004000, 16'h002B, 8'h81);
            write_descriptor(32'h2000 + 32'd8 * 4, 24'h005000, target_limit, target_access);
            write_descriptor(32'h2000 + 32'd8 * 5, 24'h000020, gate_limit, gate_access);
            write_word(32'h0300, 16'h002F);
            memory[16'h0302] = 8'h00; memory[16'h0303] = 8'h20; memory[16'h0304] = 8'h00;

            // Valid incoming image; invalid cases must fail before it is used.
            write_word(32'h5000 + 32'h000E, 16'h0200);
            write_word(32'h5000 + 32'h0010, 16'h0202);
            write_word(32'h5000 + 32'h0012, 16'hBEEF);
            write_word(32'h5000 + 32'h0022, 16'h0000); // ES
            write_word(32'h5000 + 32'h0024, 16'h0010); // CS
            write_word(32'h5000 + 32'h0026, 16'h0008); // SS
            write_word(32'h5000 + 32'h0028, 16'h0000); // DS
            write_word(32'h5000 + 32'h002A, 16'h0000); // null LDTR
            memory[16'h0200] = 8'hB8; memory[16'h0201] = 8'hEF; memory[16'h0202] = 8'hBE;
            memory[16'h0203] = 8'hF4;
        end
    endtask

    task automatic wait_fault(input logic [7:0] expected_vector, input string message);
        integer deadline;
        begin
            deadline = 0;
            while (!fault_request_reported && deadline < 1800) begin
                tick();
                deadline = deadline + 1;
            end
            check(fault_request_reported && first_fault_vector == expected_vector,
                  message);
            check(debug_tr_selector == 16'h0018 && memory[16'h201D] == 8'h83,
                  "rejected far task gate leaves the current task installed");
            check(memory[16'h5000] == 8'h00 && memory[16'h5001] == 8'h00,
                  "rejected far task gate leaves the outgoing backlink unchanged");
        end
    endtask

    task automatic run_fault_case(
        input logic do_call,
        input logic [15:0] gate_selector,
        input logic [15:0] gate_limit,
        input logic [7:0] gate_access,
        input logic [15:0] target_limit,
        input logic [7:0] target_access,
        input logic [7:0] expected_vector,
        input string message
    );
        begin
            initialize_case(do_call, gate_selector, gate_limit, gate_access,
                            target_limit, target_access);
            cycles = 0;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            stall_ready = 1'b0;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_fault(expected_vector, message);
            check(memory[16'h2025] == target_access,
                  "rejected far task gate does not mark the target TSS busy");
        end
    endtask

    task automatic run_fault_pair(
        input logic [15:0] gate_selector,
        input logic [15:0] gate_limit,
        input logic [7:0] gate_access,
        input logic [15:0] target_limit,
        input logic [7:0] target_access,
        input logic [7:0] expected_vector,
        input string message
    );
        begin
            run_fault_case(1'b1, gate_selector, gate_limit, gate_access,
                           target_limit, target_access, expected_vector, message);
            run_fault_case(1'b0, gate_selector, gate_limit, gate_access,
                           target_limit, target_access, expected_vector, message);
        end
    endtask

    initial begin
        // Gate DPL/RPL rejection: a ring-3 selector cannot use a DPL-0 gate.
        run_fault_pair(16'h002B, 16'h0000, 8'h85,
                       16'h002B, 8'h81, 8'h0D,
                       "far CALL/JMP task gate enforces gate DPL against selector RPL");

        // A not-present gate is #NP, before target TSS resolution.
        run_fault_pair(16'h0028, 16'h0000, 8'h05,
                       16'h002B, 8'h81, 8'h0B,
                       "far CALL/JMP task gate reports a not-present gate");

        // Non-zero reserved gate words are rejected as #GP.
        run_fault_pair(16'h0028, 16'h0001, 8'h85,
                       16'h002B, 8'h81, 8'h0D,
                       "far CALL/JMP task gate rejects reserved encoding");

        // A busy target TSS is not a valid entry target.
        run_fault_pair(16'h0028, 16'h0000, 8'h85,
                       16'h002B, 8'h83, 8'h0D,
                       "far CALL/JMP task gate rejects a busy target TSS");

        // A not-present target TSS reports #NP rather than entering the task.
        run_fault_pair(16'h0028, 16'h0000, 8'h85,
                       16'h002B, 8'h01, 8'h0B,
                       "far CALL/JMP task gate reports a not-present target TSS");

        // A short target TSS reaches task service and raises #TS before the
        // TSS image can publish any side effect.
        run_fault_pair(16'h0028, 16'h0000, 8'h85,
                       16'h002A, 8'h81, 8'h0A,
                       "far CALL/JMP task gate rejects a short target TSS as #TS");

        // Reset while the descriptor/TSS path is held by READY must cancel the
        // in-flight candidate without publishing TR or target busy state.
        initialize_case(1'b1, 16'h0028, 16'h0000, 8'h85, 16'h002B, 8'h81);
        cycles = 0;
        fault_request_reported = 1'b0;
        first_fault_vector = 8'h00;
        stall_ready = 1'b0;
        reset_cpu();
        far_restart(16'h0000, 16'h0000);
        stall_ready = 1'b1;
        repeat (32) tick();
        reset = 1'b1;
        execute_enable = 1'b0;
        repeat (8) tick();
        reset = 1'b0;
        execute_enable = 1'b1;
        stall_ready = 1'b0;
        check(!debug_protected_msw[0] && debug_tr_selector == 16'h0000 &&
              memory[16'h2025] == 8'h81 && !shutdown,
              "reset during a stalled task gate cancels candidate state cleanly");

        $display("PROTECTED_TASK_GATE_FAULT PASS: %0d checks, cases=13 (CALL/JMP + reset), cycles=%0d", checks, cycles);
        $finish;
    end
endmodule
