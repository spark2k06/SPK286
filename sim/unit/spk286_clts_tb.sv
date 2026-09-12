`timescale 1ns/1ps

module spk286_clts_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer cycles = 0;
    integer retired_count = 0;
    integer checks = 0;
    logic [15:0] flags_before;

    spk286 dut (.*);

    task automatic tick;
        begin
            #1;
            ready = bus_valid && ((cycles % 5) != 2);
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
            if (instruction_retired) retired_count = retired_count + 1;
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

    task automatic retire_one;
        integer deadline;
        integer start_retired;
        begin
            start_retired = retired_count;
            deadline = 0;
            while (retired_count == start_retired && !halted && deadline < 500) begin
                tick();
                deadline = deadline + 1;
            end
            if (retired_count != start_retired + 1)
                $fatal(1, "CLTS instruction did not retire before timeout; IP=%h opcode=%h vector=%h", debug_ip, debug_opcode, debug_event_vector);
        end
    endtask

    task automatic wait_fault(input logic [7:0] expected_vector);
        integer deadline;
        begin
            deadline = 0;
            while ((!event_completed || debug_event_vector != expected_vector) && deadline < 500) begin
                tick();
                deadline = deadline + 1;
            end
            if (!event_completed || debug_event_vector != expected_vector)
                $fatal(1, "CLTS fault did not complete; vector=%h expected=%h IP=%h opcode=%h", debug_event_vector, expected_vector, debug_ip, debug_opcode);
        end
    endtask

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "%s: IP=%h opcode=%h MSW=%h flags=%h", message,
                       debug_ip, debug_opcode, debug_protected_msw, debug_flags);
        end
    endtask

    initial begin
        for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;

        // LOCK CLTS is #UD in Real Mode. The handler stops the first run.
        memory[16'h0000] = 8'hF0; memory[16'h0001] = 8'h0F; memory[16'h0002] = 8'h06;
        memory[16'h0018] = 8'h00; memory[16'h0019] = 8'h02;
        memory[16'h001A] = 8'h00; memory[16'h001B] = 8'h00;
        memory[16'h0200] = 8'hF4;

        // Real-mode CLTS, then protected-mode CPL0 CLTS. LMSW supplies TS.
        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h08; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h0F; memory[16'h0104] = 8'h01; memory[16'h0105] = 8'hF0;
        memory[16'h0106] = 8'h0F; memory[16'h0107] = 8'h06;
        memory[16'h0108] = 8'hB8; memory[16'h0109] = 8'h09; memory[16'h010A] = 8'h00;
        memory[16'h010B] = 8'h0F; memory[16'h010C] = 8'h01; memory[16'h010D] = 8'hF0;
        memory[16'h010E] = 8'h0F; memory[16'h010F] = 8'h06;
        memory[16'h0110] = 8'hF4;

        reset = 1'b1;
        execute_enable = 1'b0;
        ready = 1'b0;
        tick();
        reset = 1'b0;
        flags_write_en = 1'b1;
        flags_write_mask = 16'hFFFF;
        flags_write_data = 16'h0AD7;
        tick();
        flags_write_en = 1'b0;
        execute_enable = 1'b1;

        far_restart(16'h0000, 16'h0000);
        wait_fault(8'd6);
        far_restart(16'h0000, 16'h0100);
        flags_before = debug_flags;

        retire_one(); // MOV AX,0008
        retire_one(); // LMSW AX: set TS in Real Mode
        check(debug_protected_msw[3] && !debug_protected_msw[0], "LMSW sets TS while remaining in Real Mode");
        retire_one(); // CLTS
        check(!debug_protected_msw[3] && !debug_protected_msw[0] && debug_flags == flags_before,
              "CLTS clears TS in Real Mode without changing FLAGS");
        retire_one(); // MOV AX,0009
        retire_one(); // LMSW AX: enter protected mode with TS set
        check(debug_protected_msw[3] && debug_protected_msw[0], "LMSW enters protected mode with TS set");
        retire_one(); // CLTS
        check(!debug_protected_msw[3] && debug_protected_msw[0] && debug_flags == flags_before,
              "CPL0 CLTS clears TS in Protected Mode without changing FLAGS");
        while (!halted) tick();
        check(halted, "CLTS test reaches HLT");
        $display("CLTS PASS: %0d checks, READY stalls=%0d", checks, cycles);
        $finish;
    end
endmodule
