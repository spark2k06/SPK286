`timescale 1ns/1ps

module spk286_protected_task_gate_far_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer cycles = 0;
    integer checks = 0;

    spk286 dut (.*);

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "%s: CS=%h IP=%h TR=%h FLAGS=%h MSW=%h bus=%h",
                       message, debug_cs, debug_ip, debug_tr_selector, debug_flags,
                       debug_protected_msw, bus_status);
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

    task automatic initialize_case(input logic do_call);
        begin
            for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;

            // Real-mode setup: LGDT, LMSW and a protected-mode far jump.
            memory[16'h0000] = 8'h0F; memory[16'h0001] = 8'h01; memory[16'h0002] = 8'h16;
            memory[16'h0003] = 8'h00; memory[16'h0004] = 8'h03;
            memory[16'h0005] = 8'hB8; memory[16'h0006] = 8'h01; memory[16'h0007] = 8'h00;
            memory[16'h0008] = 8'h0F; memory[16'h0009] = 8'h01; memory[16'h000A] = 8'hF0;
            memory[16'h000B] = 8'hEA; memory[16'h000C] = 8'h00; memory[16'h000D] = 8'h01;
            memory[16'h000E] = 8'h10; memory[16'h000F] = 8'h00;

            // The far transfer names GDT task gate 0028, which names TSS 0020.
            memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h18; memory[16'h0102] = 8'h00;
            memory[16'h0103] = 8'h0F; memory[16'h0104] = 8'h00; memory[16'h0105] = 8'hD8;
            memory[16'h0106] = do_call ? 8'h9A : 8'hEA;
            memory[16'h0107] = 8'h00; memory[16'h0108] = 8'h00;
            memory[16'h0109] = 8'h28; memory[16'h010A] = 8'h00;

            memory[16'h0200] = 8'hB8; memory[16'h0201] = 8'hEF; memory[16'h0202] = 8'hBE;
            memory[16'h0203] = 8'hF4;

            // GDT at 2000h: data, code, current TSS, target TSS and task gate.
            write_descriptor(32'h2000 + 32'd8 * 1, 24'h000000, 16'hFFFF, 8'h93);
            write_descriptor(32'h2000 + 32'd8 * 2, 24'h000000, 16'hFFFF, 8'h9A);
            write_descriptor(32'h2000 + 32'd8 * 3, 24'h004000, 16'h002B, 8'h81);
            write_descriptor(32'h2000 + 32'd8 * 4, 24'h005000, 16'h002B, 8'h81);
            write_descriptor(32'h2000 + 32'd8 * 5, 24'h000020, 16'h0000, 8'h85);
            write_word(32'h0300, 16'h002F);
            memory[16'h0302] = 8'h00; memory[16'h0303] = 8'h20; memory[16'h0304] = 8'h00;

            // Target TSS supplies the complete incoming image.
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

    task automatic wait_until_call_task_loaded;
        integer deadline;
        begin
            deadline = 0;
            while ((debug_tr_selector != 16'h0020 || !debug_flags[14]) && deadline < 1600) begin
                tick();
                deadline = deadline + 1;
            end
            check(debug_tr_selector == 16'h0020 && debug_flags[14],
                  "far CALL task gate commits target TR and nested-task flag");
        end
    endtask

    task automatic wait_until_jump_task_loaded;
        integer deadline;
        begin
            deadline = 0;
            while (debug_tr_selector != 16'h0020 && deadline < 1600) begin
                tick();
                deadline = deadline + 1;
            end
            check(debug_tr_selector == 16'h0020 && !debug_flags[14],
                  "far JMP task gate commits target TR without nested-task flag");
        end
    endtask

    initial begin
        // CALL FAR through a task gate: backlink and NT are architectural.
        initialize_case(1'b1);
        reset = 1'b1;
        execute_enable = 1'b0;
        tick();
        reset = 1'b0;
        execute_enable = 1'b1;
        far_restart(16'h0000, 16'h0000);

        wait_until_call_task_loaded();
        check(memory[16'h2025] == 8'h83, "far CALL task gate sets target descriptor busy");
        check(memory[16'h5000] == 8'h18, "far CALL task gate writes the outgoing TR backlink");
        check({memory[16'h400F], memory[16'h400E]} == 16'h010B,
              "far CALL task gate saves the post-CALL IP");
        check(debug_cs == 16'h0010 && debug_ip == 16'h0200,
              "far CALL task gate redirects to the incoming task");
        check(debug_gpr[15:0] == 16'hBEEF, "far CALL task gate restores the incoming registers");
        while (!halted && cycles < 2000) tick();
        check(halted, "far CALL task-gate target reaches its handler");

        // JMP FAR through the same kind of gate: no backlink and no NT.
        cycles = 0;
        initialize_case(1'b0);
        reset = 1'b1;
        execute_enable = 1'b0;
        tick();
        reset = 1'b0;
        execute_enable = 1'b1;
        far_restart(16'h0000, 16'h0000);

        wait_until_jump_task_loaded();
        check(memory[16'h201D] == 8'h81 && memory[16'h2025] == 8'h83,
              "far JMP task gate releases the old descriptor and occupies the target");
        check(memory[16'h5000] == 8'h00 && memory[16'h5001] == 8'h00,
              "far JMP task gate leaves the target backlink clear");
        check({memory[16'h400F], memory[16'h400E]} == 16'h010B,
              "far JMP task gate saves the post-JMP IP");
        check(debug_cs == 16'h0010 && debug_ip == 16'h0200,
              "far JMP task gate redirects to the incoming task");
        check(debug_gpr[15:0] == 16'hBEEF, "far JMP task gate restores the incoming registers");
        while (!halted && cycles < 2000) tick();
        check(halted, "far JMP task-gate target reaches its handler");

        $display("PROTECTED_TASK_GATE_FAR PASS: %0d checks, cycles=%0d", checks, cycles);
        $finish;
    end
endmodule
