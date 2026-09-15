`timescale 1ns/1ps

module spk286_protected_task_gate_event_privilege_outer_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer cycles = 0;
    integer checks = 0;
    logic fault_request_reported = 1'b0;
    logic [7:0] first_fault_vector = 8'h00;
    logic [15:0] target_limit_case = 16'h002B;
    logic [7:0] target_access_case = 8'h81;
    logic target_reserved_case = 1'b0;

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

    task automatic initialize_case(input integer current_cpl, input integer gate_dpl,
                                   input integer target_rpl);
        logic [15:0] current_cs, current_ss, target_selector;
        logic [7:0] gate_access, ring_code_access, ring_data_access;
        integer code_index, data_index;
        begin
            target_selector = 16'h0020 + {14'd0, target_rpl[1:0]};
            gate_access = 8'h85 | {1'b0, gate_dpl[1:0], 5'b00000};
            code_index = 5 + ((current_cpl - 1) * 2);
            data_index = 6 + ((current_cpl - 1) * 2);
            if (current_cpl == 0) begin
                current_cs = 16'h0010;
                current_ss = 16'h0008;
            end else begin
                current_cs = 16'(code_index << 3) | 16'(current_cpl);
                current_ss = 16'(data_index << 3) | 16'(current_cpl);
            end
            for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;

            // Enter protected ring 0, load the current task, then construct an
            // outer IRET frame for the selected CPL.
            memory[16'h0000] = 8'h0F; memory[16'h0001] = 8'h01; memory[16'h0002] = 8'h16;
            memory[16'h0003] = 8'h00; memory[16'h0004] = 8'h03; // LGDT [0300]
            memory[16'h0005] = 8'h0F; memory[16'h0006] = 8'h01; memory[16'h0007] = 8'h1E;
            memory[16'h0008] = 8'h10; memory[16'h0009] = 8'h03; // LIDT [0310]
            memory[16'h000A] = 8'hB8; memory[16'h000B] = 8'h01; memory[16'h000C] = 8'h00;
            memory[16'h000D] = 8'h0F; memory[16'h000E] = 8'h01; memory[16'h000F] = 8'hF0;
            memory[16'h0010] = 8'hEA; memory[16'h0011] = 8'h80; memory[16'h0012] = 8'h00;
            memory[16'h0013] = 8'h10; memory[16'h0014] = 8'h00;

            memory[16'h0080] = 8'hB8; memory[16'h0081] = 8'h18; memory[16'h0082] = 8'h00;
            memory[16'h0083] = 8'h0F; memory[16'h0084] = 8'h00; memory[16'h0085] = 8'hD8; // LTR
            memory[16'h0086] = 8'hB8; memory[16'h0087] = 8'h08; memory[16'h0088] = 8'h00;
            memory[16'h0089] = 8'h8E; memory[16'h008A] = 8'hD0; // ring-0 SS
            memory[16'h008B] = 8'hBC; memory[16'h008C] = 8'h00; memory[16'h008D] = 8'hF0;
            memory[16'h008E] = 8'hB8; memory[16'h008F] = current_ss[7:0]; memory[16'h0090] = current_ss[15:8];
            memory[16'h0091] = 8'h50; // saved SS
            memory[16'h0092] = 8'hB8; memory[16'h0093] = 8'h00; memory[16'h0094] = 8'hF0;
            memory[16'h0095] = 8'h50; // saved SP
            memory[16'h0096] = 8'hB8; memory[16'h0097] = 8'h02; memory[16'h0098] = 8'h02;
            memory[16'h0099] = 8'h50; // saved FLAGS
            memory[16'h009A] = 8'hB8; memory[16'h009B] = current_cs[7:0]; memory[16'h009C] = current_cs[15:8];
            memory[16'h009D] = 8'h50; // saved CS
            memory[16'h009E] = 8'hB8; memory[16'h009F] = 8'h00; memory[16'h00A0] = 8'h02;
            memory[16'h00A1] = 8'h50; // saved IP
            memory[16'h00A2] = 8'hCF;

            // The selected-CPL code raises a software event through IDT[0].
            memory[16'h0200] = 8'hCD; memory[16'h0201] = 8'h00; // INT 0
            memory[16'h0202] = 8'hF4;
            memory[16'h0400] = 8'hF4;

            // GDT: ring-0 data/code, current TSS, DPL0 target TSS, and
            // ring 1..3 code/data pairs for the outer IRET setup.
            write_descriptor(32'h2000 + 32'd8 * 1, 24'h000000, 16'hFFFF, 8'h93);
            write_descriptor(32'h2000 + 32'd8 * 2, 24'h000000, 16'hFFFF, 8'h9A);
            write_descriptor(32'h2000 + 32'd8 * 3, 24'h004000, 16'h002B, 8'h81);
            write_descriptor(32'h2000 + 32'd8 * 4, 24'h005000,
                             target_limit_case, target_access_case);
            for (integer ring = 1; ring < 4; ring = ring + 1) begin
                ring_code_access = 8'h9A | {1'b0, ring[1:0], 5'b00000};
                ring_data_access = 8'h92 | {1'b0, ring[1:0], 5'b00000};
                write_descriptor(32'h2000 + 32'd8 * (5 + ((ring - 1) * 2)),
                                 24'h000000, 16'hFFFF, ring_code_access);
                write_descriptor(32'h2000 + 32'd8 * (6 + ((ring - 1) * 2)),
                                 24'h000000, 16'hFFFF, ring_data_access);
            end
            write_word(32'h0300, 16'h0057);
            memory[16'h0302] = 8'h00; memory[16'h0303] = 8'h20; memory[16'h0304] = 8'h00;

            // IDT[0] is a software-visible task gate.  The target TSS
            // selector RPL is varied independently from the gate DPL.
            write_descriptor(32'h3000, 24'h000020 + 24'(target_rpl), 16'h0000, gate_access);
            write_word(32'h0310, 16'h0007);
            memory[16'h0312] = 8'h00; memory[16'h0313] = 8'h30; memory[16'h0314] = 8'h00;
            if (target_reserved_case) write_word(32'h2026, 16'h0001);

            // Valid incoming ring-0 image.
            write_word(32'h5000 + 32'h000E, 16'h0400);
            write_word(32'h5000 + 32'h0010, 16'h0202);
            write_word(32'h5000 + 32'h0012, 16'hBEEF);
            write_word(32'h5000 + 32'h0022, 16'h0000); // ES
            write_word(32'h5000 + 32'h0024, 16'h0010); // CS
            write_word(32'h5000 + 32'h0026, 16'h0008); // SS
            write_word(32'h5000 + 32'h0028, 16'h0000); // DS
            write_word(32'h5000 + 32'h002A, 16'h0000); // LDTR
        end
    endtask

    task automatic run_case(input integer current_cpl, input integer gate_dpl,
                            input integer target_rpl, input logic expect_success);
        logic [15:0] target_selector;
        integer deadline;
        begin
            target_selector = 16'h0020 + {14'd0, target_rpl[1:0]};
            target_limit_case = 16'h002B;
            target_access_case = 8'h81;
            target_reserved_case = 1'b0;
            initialize_case(current_cpl, gate_dpl, target_rpl);
            cycles = 0;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            deadline = 0;
            if (expect_success) begin
                while ((debug_tr_selector != target_selector || debug_cs != 16'h0010) && deadline < 3000) begin
                    tick();
                    deadline = deadline + 1;
                end
                check(!fault_request_reported && debug_tr_selector == target_selector,
                      "software INT task gate accepts gate DPL >= current CPL");
                check(memory[16'h2025] == 8'h83,
                      "event task gate marks the DPL0 target TSS busy regardless of target RPL");
                check(debug_flags[14], "event task gate sets NT for the nested task");
                check(debug_ip == 16'h0400 && debug_cs == 16'h0010,
                      "event task gate loads the incoming task code context");
            end else begin
                while (!fault_request_reported && deadline < 3000) begin
                    tick();
                    deadline = deadline + 1;
                end
                check(fault_request_reported && first_fault_vector == 8'h0D,
                      "software INT task gate rejects insufficient gate DPL with #GP");
                check(debug_tr_selector == 16'h0018 && memory[16'h2025] == 8'h81,
                      "event task-gate rejection preserves TR and target TSS");
            end
        end
    endtask

    task automatic run_target_fault_case(input integer current_cpl,
                                         input integer target_rpl,
                                         input logic [15:0] target_limit,
                                         input logic [7:0] target_access,
                                         input logic target_reserved,
                                         input logic [7:0] expected_vector,
                                         input string message);
        integer deadline;
        begin
            target_limit_case = target_limit;
            target_access_case = target_access;
            target_reserved_case = target_reserved;
            initialize_case(current_cpl, 3, target_rpl);
            cycles = 0;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            deadline = 0;
            while (!fault_request_reported && deadline < 3000) begin
                tick();
                deadline = deadline + 1;
            end
            check(fault_request_reported && first_fault_vector == expected_vector,
                  message);
            check(debug_tr_selector == 16'h0018 && memory[16'h2025] == target_access,
                  "event task-gate target rejection preserves TR and target descriptor");
            check(!debug_flags[14],
                  "event task-gate target rejection does not publish NT");
        end
    endtask

    initial begin
        for (integer cpl = 0; cpl < 4; cpl = cpl + 1)
            for (integer dpl = 0; dpl < 4; dpl = dpl + 1)
                for (integer rpl = 0; rpl < 4; rpl = rpl + 1)
                    run_case(cpl, dpl, rpl, dpl >= cpl);

        // With an authorized DPL3 gate, the target TSS descriptor itself is
        // independently validated for every outer CPL and selector RPL.
        for (integer cpl = 0; cpl < 4; cpl = cpl + 1)
            for (integer rpl = 0; rpl < 4; rpl = rpl + 1) begin
                run_target_fault_case(cpl, rpl, 16'h002B, 8'h01, 1'b0, 8'h0B,
                                      "event task gate reports a not-present target TSS as #NP");
                run_target_fault_case(cpl, rpl, 16'h002B, 8'h83, 1'b0, 8'h0D,
                                      "event task gate rejects a busy target TSS as #GP");
                run_target_fault_case(cpl, rpl, 16'hFFFF, 8'h93, 1'b0, 8'h0D,
                                      "event task gate rejects a non-TSS target as #GP");
                run_target_fault_case(cpl, rpl, 16'h002A, 8'h81, 1'b0, 8'h0A,
                                      "event task gate rejects a short target TSS as #TS");
                run_target_fault_case(cpl, rpl, 16'h002B, 8'h81, 1'b1, 8'h0D,
                                      "event task gate rejects reserved target TSS form as #GP");
            end

        $display("PROTECTED_TASK_GATE_EVENT_PRIVILEGE_OUTER PASS: %0d checks, cases=144", checks);
        $finish;
    end
endmodule
