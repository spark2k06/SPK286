`timescale 1ns/1ps

// Direct task switch with a non-null incoming LDTR.  The task's data
// segments are deliberately selected from the LDT so the test covers both
// hidden LDTR-cache construction and subsequent LDT descriptor resolution.
// Repeat with incoming CS at LDT entry zero, which is non-null (TI=1).
module spk286_protected_task_ldt_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer cycles = 0;
    integer checks = 0;

    spk286 dut (.*);

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "%s: CS=%h IP=%h LDTR=%h TR=%h seg=%h access=%h bus=%h",
                       message, debug_cs, debug_ip, debug_ldtr_selector,
                       debug_tr_selector, debug_segment_selectors,
                       debug_segment_access, bus_status);
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

    task automatic wait_until_task_loaded;
        integer deadline;
        begin
            deadline = 0;
            // TR/FLAGS are published before late LDTR/segment validation.
            // Wait for actual completion, not a fixed delay after early state.
            while (!dut.micro_executor.task_commit_done_q && !dut.task_service_fault && deadline < 1500) begin
                tick();
                deadline = deadline + 1;
            end
            check(dut.micro_executor.task_commit_done_q && !dut.task_service_fault,
                  "task switch completes late LDTR and segment validation");
            check(debug_tr_selector == 16'h0020 && debug_flags[14],
                  "non-null-LDTR task switch commits target TR and nested-task flag");
        end
    endtask

    task automatic run_case(input integer ldt_code);
        cycles = 0;
        for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;

        // Real-mode setup: LGDT, LMSW, then enter the protected code segment.
        memory[16'h0000] = 8'h0F; memory[16'h0001] = 8'h01; memory[16'h0002] = 8'h16;
        memory[16'h0003] = 8'h00; memory[16'h0004] = 8'h03;
        memory[16'h0005] = 8'hB8; memory[16'h0006] = 8'h01; memory[16'h0007] = 8'h00;
        memory[16'h0008] = 8'h0F; memory[16'h0009] = 8'h01; memory[16'h000A] = 8'hF0;
        memory[16'h000B] = 8'hEA; memory[16'h000C] = 8'h00; memory[16'h000D] = 8'h01;
        memory[16'h000E] = 8'h10; memory[16'h000F] = 8'h00;

        // Protected current task: LTR 0018, then direct far CALL to TSS 0020.
        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h18; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h0F; memory[16'h0104] = 8'h00; memory[16'h0105] = 8'hD8;
        memory[16'h0106] = 8'h9A; memory[16'h0107] = 8'h00; memory[16'h0108] = 8'h00;
        memory[16'h0109] = 8'h20; memory[16'h010A] = 8'h00;
        memory[16'h0200] = 8'hB8; memory[16'h0201] = 8'hEF; memory[16'h0202] = 8'hBE;
        memory[16'h0203] = 8'hF4;
        // Distinct physical code base proves that the LDT cache is used.
        memory[16'h8200] = 8'hB8; memory[16'h8201] = 8'h0D; memory[16'h8202] = 8'hD0;
        memory[16'h8203] = 8'hF4;

        // GDT at 2000h: data, code, current/target TSS, then an LDT.
        write_descriptor(32'h2000 + 32'd8 * 1, 24'h000000, 16'hFFFF, 8'h93);
        write_descriptor(32'h2000 + 32'd8 * 2, 24'h000000, 16'hFFFF, 8'h9A);
        write_descriptor(32'h2000 + 32'd8 * 3, 24'h004000, 16'h002B, 8'h81);
        write_descriptor(32'h2000 + 32'd8 * 4, 24'h005000, 16'h002B, 8'h81);
        write_descriptor(32'h2000 + 32'd8 * 6, 24'h006000, 16'h001F, 8'h82);
        write_descriptor(32'h6000, 24'h008000, 16'h02FF, 8'h9A);
        if (ldt_code == 2) memory[16'h6005] = 8'h1A; // Late not-present CS.
        if (ldt_code == 3) memory[16'h2035] = 8'h02; // Invalid incoming LDT.
        // LDT index 1 is a writable data segment, selected by 000Ch.
        write_descriptor(32'h6000 + 32'd8 * 1, 24'h000000, 16'hFFFF, 8'h93);
        write_word(32'h0300, 16'h0037);
        memory[16'h0302] = 8'h00; memory[16'h0303] = 8'h20; memory[16'h0304] = 8'h00;

        // Current TSS is empty; target TSS supplies an LDTR and LDT-backed data segments.
        write_word(32'h5000 + 32'h000E, 16'h0200);
        write_word(32'h5000 + 32'h0010, 16'h0202);
        write_word(32'h5000 + 32'h0012, 16'hBEEF);
        write_word(32'h5000 + 32'h0022, 16'h000C); // ES from LDT index 1
        write_word(32'h5000 + 32'h0024, ldt_code != 0 ? 16'h0004 : 16'h0010);
        write_word(32'h5000 + 32'h0026, 16'h000C); // SS from LDT index 1
        write_word(32'h5000 + 32'h0028, 16'h000C); // DS from LDT index 1
        write_word(32'h5000 + 32'h002A, 16'h0030); // LDTR from GDT index 6

        reset = 1'b1;
        execute_enable = 1'b0;
        tick();
        reset = 1'b0;
        execute_enable = 1'b1;
        far_restart(16'h0000, 16'h0000);

        if (ldt_code >= 2) begin
            while (!dut.task_service_fault && cycles < 1500) tick();
            check(dut.task_service_fault &&
                  dut.task_service_fault_vector == (ldt_code == 2 ? 8'd11 : 8'd10) &&
                  dut.task_service_fault_error_code == (ldt_code == 2 ? 16'h0004 : 16'h0030),
                  "incoming CS/LDT absence reports the corresponding late task fault");
            check(debug_tr_selector == 16'h0020 && debug_ldtr_selector == 16'h0030,
                  "late faults retain the incoming TR and LDTR selectors");
            check(debug_ldtr_base == (ldt_code == 2 ? 24'h006000 : 24'h000000) &&
                  debug_ldtr_limit == (ldt_code == 2 ? 16'h001F : 16'h0000) &&
                  dut.protected_ldtr_valid == (ldt_code == 2),
                  "validated LDT survives a later CS fault; invalid LDT stays unusable");
        end else begin
            wait_until_task_loaded();
            check(debug_ldtr_selector == 16'h0030,
                  "task switch publishes the incoming LDTR selector");
            check(debug_ldtr_base == 24'h006000 && debug_ldtr_limit == 16'h001F,
                  "task switch publishes the incoming LDTR hidden base and limit");
            check(debug_segment_selectors[63:48] == 16'h000C &&
                  debug_segment_selectors[47:32] == 16'h000C &&
                  debug_segment_selectors[15:0] == 16'h000C,
                  "task switch resolves ES/SS/DS through the incoming LDT");
            check(debug_segment_access[31:24] == 8'h93 &&
                  debug_segment_access[23:16] == 8'h93 &&
                  debug_segment_access[7:0] == 8'h93,
                  "task switch commits the LDT-backed data caches");
            check(debug_cs == (ldt_code != 0 ? 16'h0004 : 16'h0010) && debug_ip == 16'h0200 &&
                  debug_cs_base == (ldt_code != 0 ? 24'h008000 : 24'h000000),
                  "task switch redirects through the selected GDT or LDT code cache");
            check(debug_gpr[15:0] == 16'hBEEF,
                  "task switch restores the incoming general-register image");

            while (!halted && cycles < 1900) tick();
            check(halted, "incoming LDT-backed task reaches its protected-mode handler");
            check(debug_gpr[15:0] == (ldt_code != 0 ? 16'hD00D : 16'hBEEF),
                  "incoming task executes at the descriptor's physical code base");
            if (ldt_code != 0)
                check(memory[16'h6005] == 8'h9B, "LDT entry-zero code descriptor is marked accessed");
        end
    endtask

    initial begin
        for (integer ldt_code = 0; ldt_code < 4; ldt_code = ldt_code + 1) run_case(ldt_code);
        $display("PROTECTED_TASK_LDT PASS: %0d checks, cycles=%0d", checks, cycles);
        $finish;
    end
endmodule
