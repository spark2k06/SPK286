`timescale 1ns/1ps

module spk286_protected_ltr_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer cycles = 0;
    integer checks = 0;

    spk286 dut (.*);

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "%s: CS=%h IP=%h TR=%h MSW=%h",
                       message, debug_cs, debug_ip, debug_tr_selector,
                       debug_protected_msw);
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

    task automatic write_gate(input integer address, input logic [15:0] offset,
                              input logic [15:0] selector);
        begin
            write_word(address, offset);
            write_word(address + 2, selector);
            memory[address + 4] = 8'h00;
            memory[address + 5] = 8'h86;
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

    task automatic wait_state(input logic [15:0] expected_cs,
                              input logic [15:0] expected_ip);
        integer deadline;
        begin
            deadline = 0;
            while ((debug_cs != expected_cs || debug_ip != expected_ip) && deadline < 1500) begin
                tick();
                deadline = deadline + 1;
            end
            check(debug_cs == expected_cs && debug_ip == expected_ip,
                  "protected-mode setup reaches the LTR test entry");
        end
    endtask

    task automatic wait_halt;
        integer deadline;
        begin
            deadline = 0;
            while (!halted && deadline < 1800) begin
                tick();
                deadline = deadline + 1;
            end
            check(halted, "LTR test reaches its terminal HLT");
        end
    endtask

    task automatic wait_fault(input logic [7:0] expected_vector);
        integer deadline;
        begin
            deadline = 0;
            while ((!event_completed || debug_event_vector != expected_vector) && deadline < 1200) begin
                tick();
                deadline = deadline + 1;
            end
            check(event_completed && debug_event_vector == expected_vector,
                  "LTR fault is delivered through the expected protected gate");
        end
    endtask

    task automatic write_ltr_program(input logic [15:0] selector);
        begin
            memory[16'h0100] = 8'hB8;
            write_word(32'h00000101, selector);
            memory[16'h0103] = 8'h0F;
            memory[16'h0104] = 8'h00;
            memory[16'h0105] = 8'hD8;
            memory[16'h0106] = 8'hF4;
        end
    endtask

    task automatic reset_to_ltr_entry;
        begin
            reset = 1'b1;
            execute_enable = 1'b0;
            ready = 1'b0;
            repeat (2) tick();
            reset = 1'b0;
            execute_enable = 1'b1;
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0010, 16'h0100);
        end
    endtask

    task automatic initialize_memory;
        begin
            for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;

            // Real-mode setup: LGDT, LIDT, LMSW and a far jump to CPL0 code.
            memory[16'h0000] = 8'h0F; memory[16'h0001] = 8'h01; memory[16'h0002] = 8'h16;
            memory[16'h0003] = 8'h00; memory[16'h0004] = 8'h03;
            memory[16'h0005] = 8'h0F; memory[16'h0006] = 8'h01; memory[16'h0007] = 8'h1E;
            memory[16'h0008] = 8'h10; memory[16'h0009] = 8'h03;
            memory[16'h000A] = 8'hB8; memory[16'h000B] = 8'h01; memory[16'h000C] = 8'h00;
            memory[16'h000D] = 8'h0F; memory[16'h000E] = 8'h01; memory[16'h000F] = 8'hF0;
            memory[16'h0010] = 8'hEA; memory[16'h0011] = 8'h00; memory[16'h0012] = 8'h01;
            memory[16'h0013] = 8'h10; memory[16'h0014] = 8'h00;

            // A common protected-mode handler halts after #GP/#NP delivery.
            memory[16'h0200] = 8'hF4;

            // GDTR: entries 1/2 are data/code; entries 3/4 are TSS.
            write_word(32'h00000300, 16'h003F);
            memory[16'h0302] = 8'h00; memory[16'h0303] = 8'h04; memory[16'h0304] = 8'h00;
            write_descriptor(32'h00000408, 24'h000000, 16'hFFFF, 8'h93);
            write_descriptor(32'h00000410, 24'h000000, 16'hFFFF, 8'h9A);
            write_descriptor(32'h00000418, 24'h001000, 16'h002B, 8'h81);
            write_descriptor(32'h00000420, 24'h002000, 16'h002B, 8'h81);

            // IDTR and same-level interrupt gates for #NP (11) and #GP (13).
            write_word(32'h00000310, 16'h006F);
            memory[16'h0312] = 8'h00; memory[16'h0313] = 8'h08; memory[16'h0314] = 8'h00;
            write_gate(32'h00000858, 16'h0200, 16'h0010);
            write_gate(32'h00000868, 16'h0200, 16'h0010);
        end
    endtask

    initial begin
        initialize_memory();

        // A valid LTR marks the target busy and publishes the fixed TSS cache.
        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h18; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h0F; memory[16'h0104] = 8'h00; memory[16'h0105] = 8'hD8;
        memory[16'h0106] = 8'hB8; memory[16'h0107] = 8'h20; memory[16'h0108] = 8'h00;
        memory[16'h0109] = 8'h0F; memory[16'h010A] = 8'h00; memory[16'h010B] = 8'hD8;
        memory[16'h010C] = 8'hF4;
        reset_to_ltr_entry();
        while (debug_tr_selector != 16'h0020 && cycles < 1800) tick();
        check(debug_tr_selector == 16'h0020 && debug_tr_base == 24'h002000 &&
              debug_tr_limit == 16'h002B && debug_tr_selector[2] == 1'b0,
              "LTR publishes the second available TSS cache");
        check(dut.protected_tr_access == 8'h83 &&
              dut.protected_tr_class == spk286_protected_pkg::DESC_TSS_BUSY,
              "LTR cache records the busy TSS descriptor state");
        check(memory[16'h041D] == 8'h83 && memory[16'h0425] == 8'h83,
              "successive LTR instructions set both TSS descriptors busy");
        wait_halt();

        // Busy TSS is rejected and cannot replace the current TR.
        write_ltr_program(16'h0018);
        memory[16'h041D] = 8'h83;
        reset_to_ltr_entry();
        wait_fault(8'd13);
        check(debug_tr_selector == 16'h0000 && memory[16'h041D] == 8'h83,
              "LTR rejects a busy TSS without changing TR or memory");

        // Not-present TSS reports #NP and preserves the descriptor byte.
        write_ltr_program(16'h0018);
        memory[16'h041D] = 8'h01;
        reset_to_ltr_entry();
        wait_fault(8'd11);
        check(debug_tr_selector == 16'h0000 && memory[16'h041D] == 8'h01,
              "LTR reports #NP for a not-present TSS");

        // A code descriptor is not a valid LTR target.
        write_ltr_program(16'h0010);
        reset_to_ltr_entry();
        wait_fault(8'd13);
        check(debug_tr_selector == 16'h0000,
              "LTR rejects a non-TSS descriptor");

        // The fixed 80286 image must include the final LDT word.
        write_ltr_program(16'h0018);
        write_descriptor(32'h00000418, 24'h001000, 16'h002A, 8'h81);
        reset_to_ltr_entry();
        wait_fault(8'd13);
        check(debug_tr_selector == 16'h0000 && memory[16'h041D] == 8'h81,
              "LTR rejects a TSS shorter than the fixed 80286 image");

        // LDT and null selectors are invalid for LTR before any busy write.
        write_ltr_program(16'h000C);
        reset_to_ltr_entry();
        wait_fault(8'd13);
        check(debug_tr_selector == 16'h0000,
              "LTR rejects an LDT selector");

        write_ltr_program(16'h0000);
        reset_to_ltr_entry();
        wait_fault(8'd13);
        check(debug_tr_selector == 16'h0000,
              "LTR rejects a null selector");

        $display("PROTECTED_LTR PASS: %0d checks, READY stalls=%0d", checks, cycles);
        $finish;
    end
endmodule
