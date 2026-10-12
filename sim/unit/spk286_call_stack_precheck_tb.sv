// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module spk286_call_stack_precheck_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer cycles = 0;
    integer checks = 0;
    integer call_writes = 0;
    integer retired = 0;
    logic call_active = 1'b0;
    logic fault_seen = 1'b0;
    logic [7:0] first_fault_vector = 8'h00;

    spk286 dut (.*);

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "%s: CS:IP=%h:%h SS:SP=%h:%h fault=%b vector=%h writes=%0d",
                       message, debug_cs, debug_ip, debug_segment_selectors[47:32],
                       debug_gpr[79:64], fault_seen, first_fault_vector, call_writes);
        end
    endtask

    task automatic tick;
        begin
            #1;
            if (!fault_seen && dut.fault_request) begin
                fault_seen = 1'b1;
                first_fault_vector = dut.fault_vector;
            end
            if (!call_active && debug_opcode == 8'h9A && debug_cs == 16'h0010)
                call_active = 1'b1;
            ready = bus_valid;
            data_in = 16'h0000;
            if (bus_valid && !bus_write && address < 24'd65536) begin
                if (address[0]) data_in = {memory[address[15:0]], 8'h00};
                else if (bus_bhe_n) data_in = {8'h00, memory[address[15:0]]};
                else data_in = {memory[address[15:0] + 16'd1], memory[address[15:0]]};
            end
            if (call_active && bus_valid && ready && bus_write && bus_status == 4'h6 && address < 24'd16)
                call_writes = call_writes + 1;
            if (bus_valid && ready && bus_write && bus_status == 4'h6 && address < 24'd65536) begin
                if (address[0]) memory[address[15:0]] = data_out[15:8];
                else begin
                    memory[address[15:0]] = data_out[7:0];
                    if (!bus_bhe_n) memory[address[15:0] + 16'd1] = data_out[15:8];
                end
            end
            #4; clk = 1'b1; #5; clk = 1'b0; #1;
            if (instruction_retired) retired = retired + 1;
            cycles = cycles + 1;
        end
    endtask

    task automatic reset_cpu;
        begin
            reset = 1'b1;
            execute_enable = 1'b0;
            ready = 1'b0;
            repeat (16) tick();
            reset = 1'b0;
            execute_enable = 1'b1;
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

    task automatic run_case(input logic [15:0] sp, input logic expect_fault);
        integer deadline;
        begin
            cycles = 0;
            call_writes = 0;
            retired = 0;
            call_active = 1'b0;
            fault_seen = 1'b0;
            first_fault_vector = 8'h00;
            memory[16'h0105] = 8'hBC;
            memory[16'h0106] = sp[7:0];
            memory[16'h0107] = sp[15:8];
            memory[16'h0000] = 8'h0F;
            memory[16'h0001] = 8'h01;
            memory[16'h0002] = 8'h16;
            memory[16'h0003] = 8'h00;
            memory[16'h0004] = 8'h03;
            memory[16'h0005] = 8'hB8;
            memory[16'h0006] = 8'h01;
            memory[16'h0007] = 8'h00;
            memory[16'h0008] = 8'h0F;
            memory[16'h0009] = 8'h01;
            memory[16'h000A] = 8'hF0;
            memory[16'h000B] = 8'hEA;
            memory[16'h000C] = 8'h00;
            memory[16'h000D] = 8'h01;
            memory[16'h000E] = 8'h10;
            memory[16'h000F] = 8'h00;
            memory[16'h0100] = 8'hB8;
            memory[16'h0101] = 8'h20;
            memory[16'h0102] = 8'h00;
            memory[16'h0103] = 8'h8E;
            memory[16'h0104] = 8'hD0;
            memory[16'h0108] = 8'h9A;
            memory[16'h0109] = 8'h20;
            memory[16'h010A] = 8'h01;
            memory[16'h010B] = 8'h18;
            memory[16'h010C] = 8'h00;
            memory[16'h010D] = 8'hF4;
            memory[16'h0120] = 8'hF4;

            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            deadline = 0;
            while (!fault_seen && !halted && !shutdown && deadline < 4000) begin
                tick();
                deadline = deadline + 1;
            end
            check(deadline < 4000, "call-stack scenario reaches a terminal state");
            if (expect_fault) begin
                check(fault_seen && first_fault_vector == 8'h0C,
                      "odd low SP raises stack fault before the call frame writes");
                check(call_writes == 0, "call-frame precheck prevents every stack write");
                check(debug_gpr[79:64] == sp, "precheck preserves the architectural SP");
                check(!halted && !instruction_retired, "rejected call does not retire or halt");
            end else begin
                check(halted && !fault_seen, "expand-down stack accepts a complete call frame");
                check(debug_cs == 16'h0010 && debug_ip == 16'h0121,
                      "accepted far call reaches the target HLT");
                check(call_writes == 4 && debug_gpr[79:64] == 16'h0001,
                      "accepted far call writes exactly CS and IP and updates SP");
            end
        end
    endtask

    initial begin
        for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;

        // GDTR pseudo-descriptor: entries 0..4 at 0400h.
        memory[16'h0300] = 8'h27;
        memory[16'h0301] = 8'h00;
        memory[16'h0302] = 8'h00;
        memory[16'h0303] = 8'h04;
        memory[16'h0304] = 8'h00;

        // GDT index 1: normal data; index 2: normal code; index 3: a
        // same-level call gate to that code; index 4: a ring-0 expand-down
        // stack whose lower bound is zero.
        memory[16'h0408] = 8'hFF; memory[16'h0409] = 8'hFF;
        memory[16'h040D] = 8'h93;
        memory[16'h0410] = 8'hFF; memory[16'h0411] = 8'hFF;
        memory[16'h0415] = 8'h9A;
        memory[16'h0418] = 8'h20; memory[16'h0419] = 8'h01;
        memory[16'h041A] = 8'h10; memory[16'h041B] = 8'h00;
        memory[16'h041D] = 8'h84;
        memory[16'h0420] = 8'h00; memory[16'h0421] = 8'h00;
        memory[16'h0425] = 8'h96;

        // SP=3 is the boundary that must be rejected before any write.  The
        // expand-down descriptor makes the first push legal, so a weakened
        // precheck is observable as one committed write before the second
        // push crosses FFFF.  SP=5 is the positive control.
        run_case(16'h0003, 1'b1);
        run_case(16'h0005, 1'b0);

        $display("CALL_STACK_PRECHECK PASS: %0d checks", checks);
        $finish;
    end
endmodule
