`timescale 1ns/1ps

module spk286_protected_task_iret_tb;
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

    task automatic wait_for_nested_task;
        integer deadline;
        begin
            deadline = 0;
            while ((debug_tr_selector != 16'h0020 || !debug_flags[14]) && deadline < 1600) begin
                tick();
                deadline = deadline + 1;
            end
            check(debug_tr_selector == 16'h0020 && debug_flags[14],
                  "task gate enters the nested task before IRET");
        end
    endtask

    task automatic wait_for_task_return;
        integer deadline;
        begin
            deadline = 0;
            while ((debug_tr_selector != 16'h0018 || debug_flags[14]) && deadline < 1800) begin
                tick();
                deadline = deadline + 1;
            end
            check(debug_tr_selector == 16'h0018 && !debug_flags[14],
                  "IRET with NT returns through the backlink task");
        end
    endtask

    initial begin
        for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;

        // Real-mode setup: LGDT, LIDT, LMSW and protected far jump.
        memory[16'h0000] = 8'h0F; memory[16'h0001] = 8'h01; memory[16'h0002] = 8'h16;
        memory[16'h0003] = 8'h00; memory[16'h0004] = 8'h03;
        memory[16'h0005] = 8'h0F; memory[16'h0006] = 8'h01; memory[16'h0007] = 8'h1E;
        memory[16'h0008] = 8'h10; memory[16'h0009] = 8'h03;
        memory[16'h000A] = 8'hB8; memory[16'h000B] = 8'h01; memory[16'h000C] = 8'h00;
        memory[16'h000D] = 8'h0F; memory[16'h000E] = 8'h01; memory[16'h000F] = 8'hF0;
        memory[16'h0010] = 8'hEA; memory[16'h0011] = 8'h00; memory[16'h0012] = 8'h01;
        memory[16'h0013] = 8'h10; memory[16'h0014] = 8'h00;

        // The outer task uses valid protected data selectors so its saved
        // image can be revalidated when the nested task executes IRET.
        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h08; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h8E; memory[16'h0104] = 8'hD0; // MOV SS,AX
        memory[16'h0105] = 8'h8E; memory[16'h0106] = 8'hD8; // MOV DS,AX
        memory[16'h0107] = 8'h8E; memory[16'h0108] = 8'hC0; // MOV ES,AX
        memory[16'h0109] = 8'hBC; memory[16'h010A] = 8'h00; memory[16'h010B] = 8'hFF;
        memory[16'h010C] = 8'hB8; memory[16'h010D] = 8'h18; memory[16'h010E] = 8'h00;
        memory[16'h010F] = 8'h0F; memory[16'h0110] = 8'h00; memory[16'h0111] = 8'hD8;
        memory[16'h0112] = 8'hCD; memory[16'h0113] = 8'h00;
        memory[16'h0114] = 8'hF4;

        // The nested task executes IRET with NT=1; the final F4 is the
        // restored outer task's next instruction.
        memory[16'h0200] = 8'hCF;

        // GDT: data, code, current available TSS and target available TSS.
        write_descriptor(32'h2000 + 32'd8 * 1, 24'h000000, 16'hFFFF, 8'h93);
        write_descriptor(32'h2000 + 32'd8 * 2, 24'h000000, 16'hFFFF, 8'h9A);
        write_descriptor(32'h2000 + 32'd8 * 3, 24'h004000, 16'h002B, 8'h81);
        write_descriptor(32'h2000 + 32'd8 * 4, 24'h005000, 16'h002B, 8'h81);
        write_word(32'h0300, 16'h0027);
        memory[16'h0302] = 8'h00; memory[16'h0303] = 8'h20; memory[16'h0304] = 8'h00;

        // IDT vector 0: DPL0 task gate to selector 0020.
        write_word(32'h0310, 16'h0007);
        memory[16'h0312] = 8'h00; memory[16'h0313] = 8'h30; memory[16'h0314] = 8'h00;
        write_word(32'h3000, 16'h0000); write_word(32'h3002, 16'h0020);
        memory[16'h3004] = 8'h00; memory[16'h3005] = 8'h85;
        write_word(32'h3006, 16'h0000);

        // Target task image.  The service sets NT on entry; IRET then uses
        // the backlink written by the task gate rather than this stack.
        write_word(32'h5000 + 32'h000E, 16'h0200);
        write_word(32'h5000 + 32'h0010, 16'h0202);
        write_word(32'h5000 + 32'h0012, 16'hBEEF);
        write_word(32'h5000 + 32'h001A, 16'hFF00);
        write_word(32'h5000 + 32'h0022, 16'h0008); // ES
        write_word(32'h5000 + 32'h0024, 16'h0010); // CS
        write_word(32'h5000 + 32'h0026, 16'h0008); // SS
        write_word(32'h5000 + 32'h0028, 16'h0008); // DS
        write_word(32'h5000 + 32'h002A, 16'h0000); // null LDTR

        reset = 1'b1;
        execute_enable = 1'b0;
        tick();
        reset = 1'b0;
        execute_enable = 1'b1;
        far_restart(16'h0000, 16'h0000);

        wait_for_nested_task();
        check(debug_protected_msw[3] && debug_protected_msw[0],
              "task-gate entry sets MSW.TS while preserving PE");
        check(memory[16'h2025] == 8'h83, "nested task is busy before IRET");
        check(memory[16'h5000] == 8'h18, "nested task backlink names the outer TR");

        wait_for_task_return();
        check(debug_protected_msw[3] && debug_protected_msw[0],
              "IRET task return reasserts MSW.TS while preserving PE");
        check(memory[16'h2025] == 8'h81, "IRET frees the returning task descriptor");
        check(debug_cs == 16'h0010 && debug_ip == 16'h0114,
              "IRET restores the outer task CS:IP image");
        check({memory[16'h400F], memory[16'h400E]} == 16'h0114,
              "outer TSS contains the post-INT return IP");

        while (!halted && cycles < 3200) tick();
        check(halted, "outer task resumes after nested IRET");
        $display("PROTECTED_TASK_IRET PASS: %0d checks, cycles=%0d", checks, cycles);
        $finish;
    end
endmodule
