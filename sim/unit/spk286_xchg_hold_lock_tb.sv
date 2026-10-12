// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module spk286_xchg_hold_lock_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer checks = 0, data_reads = 0, data_writes = 0, retired_count = 0;
    integer timeout_count = 0, write_waits = 0;
    logic locked_collision_seen = 1'b0;
    logic [15:0] xchg_ax = 16'h0000;
    spk286 dut (.*);

    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1)
            $fatal(1, "%s IP=%h AX=%h mem=%h/%h micro=%h/%h address=%h status=%h hlda=%b lock=%b reads/writes=%0d/%0d",
                   message, debug_ip, debug_gpr[15:0], memory[16'h1002], memory[16'h1001],
                   debug_micro_entry, debug_micro_pc, address, bus_status,
                   hlda, bus_lock, data_reads, data_writes);
    endtask

    task automatic tick;
        #1;
        data_in = 16'h0F0F;
        if (bus_valid && address < 24'd65536)
            data_in = {memory[{address[15:1], 1'b1}], memory[{address[15:1], 1'b0}]};
        #4;
        if (bus_valid && ready && !reset && (bus_status == 4'd5 || bus_status == 4'd6)) begin
            if (bus_write) begin
                data_writes = data_writes + 1;
                if (address[0]) memory[address[15:0]] = data_out[15:8];
                else begin
                    memory[address[15:0]] = data_out[7:0];
                    if (!bus_bhe_n) memory[address[15:0] + 16'd1] = data_out[15:8];
                end
            end else data_reads = data_reads + 1;
        end
        clk = 1'b1; #5; clk = 1'b0; #1;
        if (instruction_retired) begin
            if (retired_count == 0) xchg_ax = debug_gpr[15:0];
            retired_count = retired_count + 1;
        end
    endtask

    task automatic service;
        #1;
        if (bus_valid && bus_status == 4'd6) begin
            // Deliberately hold READY low during the first locked write beat;
            // the address/data/lane contract must remain stable.
            ready = write_waits >= 2;
            if (!ready) begin
                check(!hlda && bus_lock && address == 24'h001001 && !bus_bhe_n &&
                      data_out == 16'hEF00, "READY wait retains the first locked odd write");
                locked_collision_seen = 1'b1;
            end
            write_waits = write_waits + 1;
        end else begin
            ready = bus_valid;
            if (!bus_valid) write_waits = 0;
        end
        tick();
        check(!microcode_fault && !shutdown && !unsupported_opcode,
              "XCHG/HOLD stream remains executable");
    endtask

    task automatic setup;
        execute_enable = 1'b0; reset = 1'b1; ready = 1'b0;
        intr = 1'b0; nmi = 1'b0; hold_request = 1'b0;
        redirect = 1'b0; ip_write_en = 1'b0; gpr_write_en = 1'b0;
        flags_write_en = 1'b0; segment_load_en = 1'b0;
        retired_count = 0; data_reads = 0; data_writes = 0;
        timeout_count = 0; write_waits = 0; locked_collision_seen = 1'b0;
        tick(); reset = 1'b0;
        for (integer r = 0; r < 8; r = r + 1) begin
            gpr_write_en = 1'b1; gpr_write_index = 3'(r);
            gpr_write_data = r == 0 ? 16'hBEEF : 16'h6000 + 16'(r);
            tick();
        end
        gpr_write_en = 1'b0;
        flags_write_en = 1'b1; flags_write_mask = 16'hFFFF; flags_write_data = 16'h0002; tick();
        flags_write_en = 1'b0;
        segment_load_en = 1'b1; segment_load_index = 2'd1; segment_load_selector = 16'h0000;
        redirect = 1'b1; ip_write_en = 1'b1; ip_write_data = 16'h0100; tick();
        segment_load_en = 1'b0; redirect = 1'b0; ip_write_en = 1'b0;
        execute_enable = 1'b1;
    endtask

    initial begin
        for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h0F;
        memory[16'h0100] = 8'h87; // XCHG [001001], AX: implicit LOCK
        memory[16'h0101] = 8'h06;
        memory[16'h0102] = 8'h01;
        memory[16'h0103] = 8'h10;
        memory[16'h0104] = 8'hB8; // follow-on instruction proves stream progress
        memory[16'h0105] = 8'h34;
        memory[16'h0106] = 8'h12;
        memory[16'h1001] = 8'h5A;
        memory[16'h1002] = 8'hC3;

        setup();
        // Assert HOLD before ModR/M resolution has raised implicit LOCK. This
        // creates the real boundary where a stale HLDA can strand XCHG.
        timeout_count = 0;
        while (!(dut.micro_active && dut.opcode_q == 8'h87 && !dut.operand_context_valid) && timeout_count < 300) begin
            service(); timeout_count = timeout_count + 1;
        end
        check(timeout_count < 300, "reach XCHG decode before ownership collision");
        hold_request = 1'b1; ready = 1'b1; service();
        timeout_count = 0;
        while (!hlda && timeout_count < 100) begin
            ready = 1'b1; service(); timeout_count = timeout_count + 1;
        end
        check(hlda, "HOLD is first granted at a free pre-LOCK boundary");

        timeout_count = 0;
        while (!dut.implicit_lock && timeout_count < 200) begin
            ready = 1'b1; service(); timeout_count = timeout_count + 1;
        end
        check(timeout_count < 200 && dut.implicit_lock, "XCHG raises implicit LOCK while HOLD is asserted");
        ready = 1'b0; service();
        check(!hlda && bus_lock, "implicit LOCK withdraws stale HLDA before data ownership");

        timeout_count = 0;
        while (retired_count < 2 && timeout_count < 600) begin
            service(); timeout_count = timeout_count + 1;
            if (bus_valid && bus_write) check(!hlda && bus_lock, "HOLD cannot steal locked XCHG write");
        end
        check(timeout_count < 600 && retired_count == 2, "XCHG and follow-on instruction complete once");
        check(locked_collision_seen && data_reads == 2 && data_writes == 2,
              "READY wait and exact odd-word physical traffic are covered");
        check(memory[16'h1001] == 8'hEF && memory[16'h1002] == 8'hBE &&
              xchg_ax == 16'hC35A && debug_gpr[15:0] == 16'h1234,
              "XCHG exchanges memory and AX without duplication");
        check(debug_ip == 16'h0107, "follow-on IP excludes no bytes and includes XCHG exactly once");

        execute_enable = 1'b0; ready = 1'b1; timeout_count = 0;
        while (!hlda && timeout_count < 100) begin
            service(); timeout_count = timeout_count + 1;
        end
        check(timeout_count < 100, "later HOLD grant does not time out");
        check(hlda && !bus_valid && !bus_lock, "HOLD is granted at the later legal boundary");
        hold_request = 1'b0; service();
        check(!hlda && !bus_lock, "HLDA releases after HOLD deassertion");
        $display("XCHG_HOLD_LOCK PASS: %0d checks; %0d data reads/%0d writes", checks, data_reads, data_writes);
        $finish;
    end
endmodule
