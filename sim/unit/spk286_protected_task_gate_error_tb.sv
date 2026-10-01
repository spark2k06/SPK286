`timescale 1ns/1ps

// An exception routed through an IDT task gate must retain its error word.
// The first task deliberately faults on MOV DS,0030; the task-gate target
// must receive #GP(0030) on its new stack after the architectural switch.
module spk286_protected_task_gate_error_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer cycles = 0;
    integer checks = 0;

    spk286 dut (.*);

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "%s: CS=%h IP=%h SP=%h SS=%h TR=%h FLAGS=%h event=%h bus=%h stack=%h/%h op=%h done=%b evvalid=%b evcode=%h",
                       message, debug_cs, debug_ip, debug_gpr[79:64], debug_segment_selectors[47:32],
                       debug_tr_selector, debug_flags,
                       debug_event_vector, bus_status, memory[16'h00FF], memory[16'h00FE],
                       dut.micro_executor.operation, dut.micro_executor.task_event_switch_done_q,
                       dut.event_error_valid, dut.event_error_code);
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

    initial begin
        for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;

        // Real-mode setup: LGDT, LIDT, LMSW and protected entry.
        memory[16'h0000] = 8'h0F; memory[16'h0001] = 8'h01; memory[16'h0002] = 8'h16;
        memory[16'h0003] = 8'h00; memory[16'h0004] = 8'h03;
        memory[16'h0005] = 8'h0F; memory[16'h0006] = 8'h01; memory[16'h0007] = 8'h1E;
        memory[16'h0008] = 8'h10; memory[16'h0009] = 8'h03;
        memory[16'h000A] = 8'hB8; memory[16'h000B] = 8'h01; memory[16'h000C] = 8'h00;
        memory[16'h000D] = 8'h0F; memory[16'h000E] = 8'h01; memory[16'h000F] = 8'hF0;
        memory[16'h0010] = 8'hEA; memory[16'h0011] = 8'h00; memory[16'h0012] = 8'h01;
        memory[16'h0013] = 8'h10; memory[16'h0014] = 8'h00;

        // Current task enters through IDT[0] and the first task faults on
        // MOV DS,0030; the second task is the #GP task-gate destination.
        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h18; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h0F; memory[16'h0104] = 8'h00; memory[16'h0105] = 8'hD8;
        memory[16'h0106] = 8'hCD; memory[16'h0107] = 8'h00;
        memory[16'h0200] = 8'hB8; memory[16'h0201] = 8'h30; memory[16'h0202] = 8'h00;
        memory[16'h0203] = 8'h8E; memory[16'h0204] = 8'hD8;
        memory[16'h0400] = 8'hF4;

        // GDT: data, code, current TSS, first task TSS, #GP task TSS.
        write_descriptor(32'h2000 + 32'd8 * 1, 24'h000000, 16'hFFFF, 8'h93);
        write_descriptor(32'h2000 + 32'd8 * 2, 24'h000000, 16'hFFFF, 8'h9A);
        write_descriptor(32'h2000 + 32'd8 * 3, 24'h004000, 16'h002B, 8'h81);
        write_descriptor(32'h2000 + 32'd8 * 4, 24'h005000, 16'h002B, 8'h81);
        write_descriptor(32'h2000 + 32'd8 * 5, 24'h006000, 16'h002B, 8'h81);
        write_word(32'h0300, 16'h002F);
        memory[16'h0302] = 8'h00; memory[16'h0303] = 8'h20; memory[16'h0304] = 8'h00;

        // IDT[0] -> TSS 0020; IDT[13] -> TSS 0028.
        write_word(32'h0310, 16'h006F);
        memory[16'h0312] = 8'h00; memory[16'h0313] = 8'h30; memory[16'h0314] = 8'h00;
        write_word(32'h3000, 16'h0000);
        write_word(32'h3002, 16'h0020);
        memory[16'h3004] = 8'h00; memory[16'h3005] = 8'h85;
        write_word(32'h3068, 16'h0000);
        write_word(32'h306A, 16'h0028);
        memory[16'h306C] = 8'h00; memory[16'h306D] = 8'h85;

        // TSS 0020: SP=0100, code at 0200, then the invalid selector fault.
        write_word(32'h5000 + 32'h000E, 16'h0200);
        write_word(32'h5000 + 32'h0010, 16'h0202);
        write_word(32'h5000 + 32'h0012, 16'hBEEF);
        write_word(32'h5000 + 32'h001A, 16'h0100);
        write_word(32'h5000 + 32'h0022, 16'h0000);
        write_word(32'h5000 + 32'h0024, 16'h0010);
        write_word(32'h5000 + 32'h0026, 16'h0008);
        write_word(32'h5000 + 32'h0028, 16'h0000);
        write_word(32'h5000 + 32'h002A, 16'h0000);

        // TSS 0028: the exception task receives the error word at SS:SP-2.
        write_word(32'h6000 + 32'h000E, 16'h0400);
        write_word(32'h6000 + 32'h0010, 16'h0202);
        write_word(32'h6000 + 32'h001A, 16'h0100);
        write_word(32'h6000 + 32'h0022, 16'h0000);
        write_word(32'h6000 + 32'h0024, 16'h0010);
        write_word(32'h6000 + 32'h0026, 16'h0008);
        write_word(32'h6000 + 32'h0028, 16'h0000);
        write_word(32'h6000 + 32'h002A, 16'h0000);

        reset = 1'b1;
        execute_enable = 1'b0;
        tick();
        reset = 1'b0;
        execute_enable = 1'b1;
        far_restart(16'h0000, 16'h0000);

        while (debug_tr_selector != 16'h0020 && cycles < 2200) tick();
        check(debug_tr_selector == 16'h0020 && debug_flags[14],
              "initial task gate enters the faulting task");
        while (debug_tr_selector != 16'h0028 && cycles < 3600) tick();
        check(debug_tr_selector == 16'h0028 && debug_ip == 16'h0400,
              "#GP dispatch through an IDT task gate enters the exception task");
        while (!dut.micro_executor.task_event_switch_done_q && cycles < 4200) tick();
        while ((memory[16'h00FE] != 8'h30 || memory[16'h00FF] != 8'h00) && cycles < 4600) tick();
        check(debug_event_vector == 8'd13 && debug_flags[14],
              "task-gate exception retains vector and nested-task state");
        check(memory[16'h6000] == 8'h20 && memory[16'h6001] == 8'h00,
              "exception task backlink identifies the faulting task");
        check(memory[16'h202D] == 8'h83,
              "exception task descriptor is marked busy");
        check(memory[16'h00FE] == 8'h30 && memory[16'h00FF] == 8'h00,
              "task-gate exception pushes #GP selector error code");

        while (!halted && cycles < 4200) tick();
        check(halted, "exception task reaches its handler after the error push");
        check(debug_gpr[79:64] == 16'h00FE,
              "task-gate error push commits the target SP before entry completes");
        $display("PROTECTED_TASK_GATE_ERROR PASS: %0d checks, cycles=%0d", checks, cycles);
        $finish;
    end
endmodule
