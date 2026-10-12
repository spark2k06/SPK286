// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module spk286_esc_instructions_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer checks = 0, cases = 0, retired_count = 0, data_reads = 0, data_writes = 0;
    integer timeout_count, wait_count, wait_length;
    logic waiting = 1'b0, esc_entry_seen = 1'b0;
    logic [23:0] held_address;
    logic [15:0] held_data;
    logic [3:0] held_status;
    logic held_bhe, held_write;
    spk286 dut (.*);

    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1)
            $fatal(1, "%s case=%0d opcode=%h AX=%h CX=%h CS:IP=%h:%h micro=%h/%h bus=%h status=%h",
                   message, cases, debug_opcode, debug_gpr[15:0], debug_gpr[31:16], debug_cs, debug_ip,
                   debug_micro_entry, debug_micro_pc, address, bus_status);
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
        if (instruction_retired) retired_count = retired_count + 1;
        if (debug_micro_active && debug_micro_entry == {2'b0, spk286_microcode_pkg::MC_ENTRY_ESC_NO_COPROCESSOR})
            esc_entry_seen = 1'b1;
        check(!microcode_fault && !shutdown && !operand_blocked && debug_prefetch_count <= 6,
              "ESC stream remains live and bounded");
    endtask

    task automatic service;
        #1;
        if (waiting)
            check(bus_valid && address == held_address && data_out == held_data &&
                  bus_status == held_status && bus_bhe_n == held_bhe && bus_write == held_write,
                  "READY wait retains the same fetch transaction");
        ready = bus_valid && wait_count >= wait_length;
        waiting = bus_valid && !ready;
        if (waiting) begin
            held_address = address; held_data = data_out; held_status = bus_status;
            held_bhe = bus_bhe_n; held_write = bus_write; wait_count = wait_count + 1;
        end else wait_count = 0;
        tick();
    endtask

    task automatic setup;
        execute_enable = 1'b0; reset = 1'b1; ready = 1'b0;
        intr = 1'b0; nmi = 1'b0; hold_request = 1'b0;
        redirect = 1'b0; ip_write_en = 1'b0; gpr_write_en = 1'b0;
        flags_write_en = 1'b0; segment_load_en = 1'b0;
        retired_count = 0; data_reads = 0; data_writes = 0;
        wait_count = 0; waiting = 1'b0; esc_entry_seen = 1'b0;
        tick(); reset = 1'b0;
        // Keep the architectural state observable while the follow-on MOV
        // proves that the instruction stream continued after ESC.
        for (integer r = 0; r < 8; r = r + 1) begin
            gpr_write_en = 1'b1; gpr_write_index = 3'(r);
            gpr_write_data = r == 0 ? 16'hA55A : 16'h6000 + 16'(r);
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

    task automatic run_case(input logic [7:0] opcode, input logic [7:0] modrm,
                            input logic prefixed, input integer delay_length);
        integer base, esc_length, expected_ip;
        base = 256;
        for (integer i = 0; i < 32; i = i + 1) memory[base + i] = 8'h0F;
        memory[base] = prefixed ? 8'h2E : opcode;
        memory[base + (prefixed ? 1 : 0)] = opcode;
        memory[base + (prefixed ? 2 : 1)] = modrm;
        if (modrm[7:6] == 2'b01) begin
            memory[base + (prefixed ? 3 : 2)] = 8'h34;
            esc_length = prefixed ? 4 : 3;
        end else if (modrm[7:6] == 2'b00) begin
            memory[base + (prefixed ? 3 : 2)] = 8'h34;
            memory[base + (prefixed ? 4 : 3)] = 8'h12;
            esc_length = prefixed ? 5 : 4;
        end else esc_length = prefixed ? 3 : 2;
        memory[base + esc_length] = 8'hB8;
        memory[base + esc_length + 1] = 8'h34;
        memory[base + esc_length + 2] = 8'h12;
        expected_ip = base + esc_length + 3;
        wait_length = delay_length;
        setup(); timeout_count = 0;
        while (retired_count < 2 && timeout_count < 1000) begin
            service(); timeout_count = timeout_count + 1;
            check(!unsupported_opcode, "D8-DF opcode is not left at queue head");
        end
        check(timeout_count < 1000 && retired_count == 2, "ESC and follow-on instruction retire");
        check(esc_entry_seen, "ESC dispatch reaches the terminal microcode entry");
        check(debug_ip == 16'(expected_ip), "ModR/M and displacement bytes advance IP exactly");
        check(debug_gpr[15:0] == 16'h1234 && debug_gpr[31:16] == 16'h6001,
              "ESC has no GPR effect and the next instruction executes");
        check(data_reads == 0 && data_writes == 0,
              "no-coprocessor ESC passthrough performs no operand bus access");
        execute_enable = 1'b0; repeat (3) service();
        check(retired_count == 2 && !debug_micro_active, "retirement pulses do not repeat while paused");
        cases = cases + 1;
    endtask

    initial begin
        for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h0F;
        for (integer op = 216; op <= 223; op = op + 1) begin
            run_case(8'(op), 8'hC0, 1'b0, 0); // register ModR/M
            run_case(8'(op), 8'h06, 1'b0, op % 3); // disp16 memory ModR/M and READY waits
            run_case(8'(op), 8'h46, 1'b1, 1); // segment prefix + disp8 memory form
        end
        check(cases == 24, "complete D8-DF register/memory/prefix matrix");
        $display("ESC_INSTRUCTIONS PASS: %0d cases; %0d checks", cases, checks);
        $finish;
    end
endmodule
