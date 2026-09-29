`timescale 1ns/1ps

module spk286_protected_expand_down_tb;
    `include "spk286_signals.svh"

    /* Matrix address expressions intentionally use integer loop arithmetic in
       this verification-only bench; RTL widths remain covered by lint. */
    /* verilator lint_off WIDTHEXPAND */
    /* verilator lint_off WIDTHTRUNC */

    logic [7:0] memory [0:65535];
    integer cycles = 0;
    integer checks = 0;
    logic fault_request_reported = 1'b0;
    logic [7:0] first_fault_vector = 8'h00;

    spk286 dut (.*);

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
                if (bus_status == 4'h0) begin
                    if (address[0]) data_in = {memory[address[15:0]], 8'h00};
                    else if (bus_bhe_n) data_in = {8'h00, memory[address[15:0]]};
                    else data_in = {memory[address[15:0] + 16'd1], memory[address[15:0]]};
                end else if (address[0]) data_in = {memory[address[15:0]], 8'h00};
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
            repeat (64) tick();
            reset = 1'b0;
            execute_enable = 1'b1;
        end
    endtask

    task automatic wait_state(input logic [15:0] expected_cs, input logic [15:0] expected_ip);
        integer deadline;
        begin
            deadline = 0;
            while ((debug_cs != expected_cs || debug_ip != expected_ip) && deadline < 2500) begin
                tick();
                deadline = deadline + 1;
            end
            if (debug_cs != expected_cs || debug_ip != expected_ip)
                $fatal(1, "expand-down setup did not reach %h:%h; got %h:%h", expected_cs, expected_ip, debug_cs, debug_ip);
        end
    endtask

    task automatic wait_event(input logic [7:0] expected_vector);
        integer deadline;
        begin
            deadline = 0;
            while ((!event_completed || debug_event_vector != expected_vector) && deadline < 2500) begin
                tick();
                deadline = deadline + 1;
            end
            if (!event_completed || debug_event_vector != expected_vector)
                $fatal(1, "expand-down event did not complete; vector=%h expected=%h CS:IP=%h:%h shutdown=%b",
                       debug_event_vector, expected_vector, debug_cs, debug_ip, shutdown);
        end
    endtask

    task automatic wait_shutdown;
        integer deadline;
        begin
            deadline = 0;
            while (!shutdown && deadline < 2500) begin
                tick();
                deadline = deadline + 1;
            end
            if (!shutdown)
                $fatal(1, "invalid expand-down event did not shut down; vector=%h CS:IP=%h:%h",
                       debug_event_vector, debug_cs, debug_ip);
        end
    endtask

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "%s: CS:IP=%h:%h AX=%h DS=%h SS:SP=%h:%h event=%h first=%h shutdown=%b", message,
                       debug_cs, debug_ip, debug_gpr[15:0], debug_segment_selectors[63:48],
                       debug_segment_selectors[47:32], debug_gpr[79:64], debug_event_vector,
                       first_fault_vector, shutdown);
        end
    endtask

    // Execute one protected-mode segment reload from the CPL1 fixture.  The
    // matrix deliberately keeps the architectural selector and hidden-cache
    // checks separate so a rejected reload cannot be masked by a later fault.
    task automatic run_segment_load_case(
        input logic [7:0] modrm,
        input logic [15:0] selector,
        input logic expect_fault,
        input logic [7:0] expected_vector,
        input logic [15:0] expected_cache_selector,
        input string message
    );
        logic [15:0] observed_selector;
        begin
            memory[16'h0100] = 8'hB8;
            memory[16'h0101] = selector[7:0];
            memory[16'h0102] = selector[15:8];
            memory[16'h0103] = 8'h8E;
            memory[16'h0104] = modrm;
            memory[16'h0105] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
            end else begin
                repeat (128) tick();
            end

            if (modrm == 8'hD0)
                observed_selector = debug_segment_selectors[47:32];
            else if (modrm == 8'hC0)
                observed_selector = debug_segment_selectors[15:0];
            else
                observed_selector = debug_segment_selectors[63:48];

            if (expect_fault) begin
                check(first_fault_vector == expected_vector && observed_selector == expected_cache_selector,
                      message);
            end else begin
                check(halted && observed_selector == selector, message);
            end
        end
    endtask

    task automatic run_word_read_case(
        input logic [15:0] selector,
        input logic [15:0] offset,
        input logic [15:0] physical_address,
        input logic [15:0] expected_ax,
        input logic expect_fault,
        input logic [7:0] expected_vector,
        input string message
    );
        begin
            memory[physical_address] = 8'h78;
            memory[physical_address + 16'd1] = 8'h56;
            memory[16'h0100] = 8'hB8;
            memory[16'h0101] = selector[7:0];
            memory[16'h0102] = selector[15:8];
            memory[16'h0103] = 8'h8E;
            memory[16'h0104] = 8'hD8;
            memory[16'h0105] = 8'hA1;
            memory[16'h0106] = offset[7:0];
            memory[16'h0107] = offset[15:8];
            memory[16'h0108] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
                check(first_fault_vector == expected_vector && debug_segment_selectors[63:48] == selector,
                      message);
            end else begin
                repeat (128) tick();
                check(halted && debug_segment_selectors[63:48] == selector && debug_gpr[15:0] == expected_ax,
                      message);
            end
        end
    endtask

    task automatic run_word_write_case(
        input logic [15:0] selector,
        input logic [15:0] offset,
        input logic [15:0] physical_address,
        input logic expect_fault,
        input logic [7:0] expected_vector,
        input string message
    );
        begin
            memory[physical_address] = 8'hAA;
            memory[physical_address + 16'd1] = 8'h55;
            memory[16'h0100] = 8'hB8;
            memory[16'h0101] = selector[7:0];
            memory[16'h0102] = selector[15:8];
            memory[16'h0103] = 8'h8E;
            memory[16'h0104] = 8'hD8;
            memory[16'h0105] = 8'hB8;
            memory[16'h0106] = 8'h34;
            memory[16'h0107] = 8'h12;
            memory[16'h0108] = 8'hA3;
            memory[16'h0109] = offset[7:0];
            memory[16'h010A] = offset[15:8];
            memory[16'h010B] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
                check(first_fault_vector == expected_vector && debug_segment_selectors[63:48] == selector &&
                      memory[physical_address] == 8'hAA && memory[physical_address + 16'd1] == 8'h55,
                      message);
            end else begin
                repeat (128) tick();
                check(halted && debug_segment_selectors[63:48] == selector &&
                      memory[physical_address] == 8'h34 && memory[physical_address + 16'd1] == 8'h12,
                      message);
            end
        end
    endtask

    task automatic run_cpl0_segment_case(
        input logic [7:0] modrm,
        input logic [15:0] selector,
        input logic expect_fault,
        input logic [7:0] expected_vector,
        input logic [15:0] expected_cache_selector,
        input string message
    );
        logic [15:0] observed_selector;
        begin
            // Enter ring 0 through a real DPL1 call gate from the CPL1
            // fixture; the target then performs the segment reload under test.
            memory[16'h0100] = 8'h9A;
            memory[16'h0101] = 8'h00;
            memory[16'h0102] = 8'h02;
            memory[16'h0103] = 8'h81;
            memory[16'h0104] = 8'h00;
            memory[16'h0105] = 8'hF4;
            memory[16'h0200] = 8'hB8;
            memory[16'h0201] = selector[7:0];
            memory[16'h0202] = selector[15:8];
            memory[16'h0203] = 8'h8E;
            memory[16'h0204] = modrm;
            memory[16'h0205] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
            end else begin
                repeat (256) tick();
            end

            if (modrm == 8'hD0)
                observed_selector = debug_segment_selectors[47:32];
            else if (modrm == 8'hC0)
                observed_selector = debug_segment_selectors[15:0];
            else
                observed_selector = debug_segment_selectors[63:48];

            if (expect_fault) begin
                check(first_fault_vector == expected_vector && observed_selector == expected_cache_selector,
                      message);
            end else begin
                check(halted && debug_cs == 16'h0018 && observed_selector == selector,
                      message);
            end
        end
    endtask

    task automatic run_cpl3_segment_case(
        input logic [7:0] modrm,
        input logic [15:0] selector,
        input logic expect_fault,
        input logic [7:0] expected_vector,
        input logic [15:0] expected_cache_selector,
        input string message
    );
        logic [15:0] observed_selector;
        begin
            // The CPL1 caller enters ring 0 through the same DPL1 gate as the
            // CPL0 matrix. The ring-0 target builds a real outer IRET frame
            // and transfers to the DPL3 code/stack pair before the reload.
            memory[16'h0100] = 8'h9A;
            memory[16'h0101] = 8'h00;
            memory[16'h0102] = 8'h02;
            memory[16'h0103] = 8'h81;
            memory[16'h0104] = 8'h00;
            memory[16'h0105] = 8'hF4;
            memory[16'h0200] = 8'hB8;
            memory[16'h0201] = 8'h53;
            memory[16'h0202] = 8'h00;
            memory[16'h0203] = 8'h50;
            memory[16'h0204] = 8'hB8;
            memory[16'h0205] = 8'h00;
            memory[16'h0206] = 8'hF0;
            memory[16'h0207] = 8'h50;
            memory[16'h0208] = 8'hB8;
            memory[16'h0209] = 8'h02;
            memory[16'h020A] = 8'h02;
            memory[16'h020B] = 8'h50;
            memory[16'h020C] = 8'hB8;
            memory[16'h020D] = 8'hAB;
            memory[16'h020E] = 8'h00;
            memory[16'h020F] = 8'h50;
            memory[16'h0210] = 8'hB8;
            memory[16'h0211] = 8'h00;
            memory[16'h0212] = 8'h06;
            memory[16'h0213] = 8'h50;
            memory[16'h0214] = 8'hCF;
            memory[16'h0600] = 8'hB8;
            memory[16'h0601] = selector[7:0];
            memory[16'h0602] = selector[15:8];
            memory[16'h0603] = 8'h8E;
            memory[16'h0604] = modrm;
            memory[16'h0605] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
            end else begin
                repeat (256) tick();
            end

            if (modrm == 8'hD0)
                observed_selector = debug_segment_selectors[47:32];
            else if (modrm == 8'hC0)
                observed_selector = debug_segment_selectors[15:0];
            else
                observed_selector = debug_segment_selectors[63:48];

            if (expect_fault) begin
                check(first_fault_vector == expected_vector && observed_selector == expected_cache_selector,
                      message);
            end else begin
                check(halted && debug_cs == 16'h00AB && observed_selector == selector,
                      message);
            end
        end
    endtask

    task automatic run_cpl2_segment_case(
        input logic [7:0] modrm,
        input logic [15:0] selector,
        input logic expect_fault,
        input logic [7:0] expected_vector,
        input logic [15:0] expected_cache_selector,
        input string message
    );
        logic [15:0] observed_selector;
        begin
            // Enter ring 0 through the same DPL1 gate as the other outer-level
            // matrices, then use a real IRET frame to enter the DPL2
            // code/stack pair before performing the reload under test.
            memory[16'h0100] = 8'h9A;
            memory[16'h0101] = 8'h00;
            memory[16'h0102] = 8'h02;
            memory[16'h0103] = 8'h81;
            memory[16'h0104] = 8'h00;
            memory[16'h0105] = 8'hF4;
            memory[16'h0200] = 8'hB8;
            memory[16'h0201] = 8'h4A;
            memory[16'h0202] = 8'h00;
            memory[16'h0203] = 8'h50;
            memory[16'h0204] = 8'hB8;
            memory[16'h0205] = 8'h00;
            memory[16'h0206] = 8'hF0;
            memory[16'h0207] = 8'h50;
            memory[16'h0208] = 8'hB8;
            memory[16'h0209] = 8'h02;
            memory[16'h020A] = 8'h00;
            memory[16'h020B] = 8'h50;
            memory[16'h020C] = 8'hB8;
            memory[16'h020D] = 8'hDA;
            memory[16'h020E] = 8'h00;
            memory[16'h020F] = 8'h50;
            memory[16'h0210] = 8'hB8;
            memory[16'h0211] = 8'h00;
            memory[16'h0212] = 8'h06;
            memory[16'h0213] = 8'h50;
            memory[16'h0214] = 8'hCF;
            memory[16'h0600] = 8'hB8;
            memory[16'h0601] = selector[7:0];
            memory[16'h0602] = selector[15:8];
            memory[16'h0603] = 8'h8E;
            memory[16'h0604] = modrm;
            memory[16'h0605] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
            end else begin
                repeat (256) tick();
            end

            if (modrm == 8'hD0)
                observed_selector = debug_segment_selectors[47:32];
            else if (modrm == 8'hC0)
                observed_selector = debug_segment_selectors[15:0];
            else
                observed_selector = debug_segment_selectors[63:48];

            if (expect_fault) begin
                check(first_fault_vector == expected_vector && observed_selector == expected_cache_selector,
                      message);
            end else begin
                check(halted && debug_cs == 16'h00DA && observed_selector == selector,
                      message);
            end
        end
    endtask

    task automatic run_cpl1_far_cs_case(
        input logic [15:0] selector,
        input logic expect_fault,
        input logic [7:0] expected_vector,
        input logic [15:0] expected_cs,
        input string message
    );
        begin
            memory[16'h0100] = 8'hEA;
            memory[16'h0101] = 8'h00;
            memory[16'h0102] = 8'h07;
            memory[16'h0103] = selector[7:0];
            memory[16'h0104] = selector[15:8];
            memory[16'h0105] = 8'hF4;
            memory[16'h0700] = 8'hB8;
            memory[16'h0701] = 8'h34;
            memory[16'h0702] = 8'h12;
            memory[16'h0703] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
                check(first_fault_vector == expected_vector && debug_cs == 16'h0009, message);
            end else begin
                repeat (256) tick();
                check(debug_gpr[15:0] == 16'h1234 && debug_cs == expected_cs && debug_ip == 16'h0704,
                      message);
            end
        end
    endtask

    task automatic run_cpl0_far_cs_case(
        input logic [15:0] selector,
        input logic expect_fault,
        input logic [7:0] expected_vector,
        input logic [15:0] expected_cs,
        input string message
    );
        begin
            memory[16'h0100] = 8'h9A;
            memory[16'h0101] = 8'h00;
            memory[16'h0102] = 8'h02;
            memory[16'h0103] = 8'h81;
            memory[16'h0104] = 8'h00;
            memory[16'h0105] = 8'hF4;
            memory[16'h0200] = 8'hEA;
            memory[16'h0201] = 8'h00;
            memory[16'h0202] = 8'h07;
            memory[16'h0203] = selector[7:0];
            memory[16'h0204] = selector[15:8];
            memory[16'h0205] = 8'hF4;
            memory[16'h0700] = 8'hB8;
            memory[16'h0701] = 8'h34;
            memory[16'h0702] = 8'h12;
            memory[16'h0703] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
                check(first_fault_vector == expected_vector && debug_cs == 16'h0018, message);
            end else begin
                repeat (256) tick();
                check(debug_gpr[15:0] == 16'h1234 && debug_cs == expected_cs && debug_ip == 16'h0704,
                      message);
            end
        end
    endtask

    task automatic run_cpl3_far_cs_case(
        input logic [15:0] selector,
        input logic expect_fault,
        input logic [7:0] expected_vector,
        input logic [15:0] expected_cs,
        input string message
    );
        begin
            memory[16'h0100] = 8'h9A;
            memory[16'h0101] = 8'h00;
            memory[16'h0102] = 8'h02;
            memory[16'h0103] = 8'h81;
            memory[16'h0104] = 8'h00;
            memory[16'h0105] = 8'hF4;
            memory[16'h0200] = 8'hB8;
            memory[16'h0201] = 8'h53;
            memory[16'h0202] = 8'h00;
            memory[16'h0203] = 8'h50;
            memory[16'h0204] = 8'hB8;
            memory[16'h0205] = 8'h00;
            memory[16'h0206] = 8'hF0;
            memory[16'h0207] = 8'h50;
            memory[16'h0208] = 8'hB8;
            memory[16'h0209] = 8'h02;
            memory[16'h020A] = 8'h02;
            memory[16'h020B] = 8'h50;
            memory[16'h020C] = 8'hB8;
            memory[16'h020D] = 8'hAB;
            memory[16'h020E] = 8'h00;
            memory[16'h020F] = 8'h50;
            memory[16'h0210] = 8'hB8;
            memory[16'h0211] = 8'h00;
            memory[16'h0212] = 8'h06;
            memory[16'h0213] = 8'h50;
            memory[16'h0214] = 8'hCF;
            memory[16'h0600] = 8'hEA;
            memory[16'h0601] = 8'h00;
            memory[16'h0602] = 8'h07;
            memory[16'h0603] = selector[7:0];
            memory[16'h0604] = selector[15:8];
            memory[16'h0605] = 8'hF4;
            memory[16'h0700] = 8'hB8;
            memory[16'h0701] = 8'h34;
            memory[16'h0702] = 8'h12;
            memory[16'h0703] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
                check(first_fault_vector == expected_vector && debug_cs == 16'h00AB, message);
            end else begin
                repeat (256) tick();
                check(debug_gpr[15:0] == 16'h1234 && debug_cs == expected_cs && debug_ip == 16'h0704,
                      message);
            end
        end
    endtask

    task automatic run_cpl2_far_cs_case(
        input logic [15:0] selector,
        input logic expect_fault,
        input logic [7:0] expected_vector,
        input logic [15:0] expected_cs,
        input string message
    );
        begin
            memory[16'h0100] = 8'h9A;
            memory[16'h0101] = 8'h00;
            memory[16'h0102] = 8'h02;
            memory[16'h0103] = 8'h81;
            memory[16'h0104] = 8'h00;
            memory[16'h0105] = 8'hF4;
            memory[16'h0200] = 8'hB8;
            memory[16'h0201] = 8'h4A;
            memory[16'h0202] = 8'h00;
            memory[16'h0203] = 8'h50;
            memory[16'h0204] = 8'hB8;
            memory[16'h0205] = 8'h00;
            memory[16'h0206] = 8'hF0;
            memory[16'h0207] = 8'h50;
            memory[16'h0208] = 8'hB8;
            memory[16'h0209] = 8'h02;
            memory[16'h020A] = 8'h00;
            memory[16'h020B] = 8'h50;
            memory[16'h020C] = 8'hB8;
            memory[16'h020D] = 8'hDA;
            memory[16'h020E] = 8'h00;
            memory[16'h020F] = 8'h50;
            memory[16'h0210] = 8'hB8;
            memory[16'h0211] = 8'h00;
            memory[16'h0212] = 8'h06;
            memory[16'h0213] = 8'h50;
            memory[16'h0214] = 8'hCF;
            memory[16'h0600] = 8'hEA;
            memory[16'h0601] = 8'h00;
            memory[16'h0602] = 8'h07;
            memory[16'h0603] = selector[7:0];
            memory[16'h0604] = selector[15:8];
            memory[16'h0605] = 8'hF4;
            memory[16'h0700] = 8'hB8;
            memory[16'h0701] = 8'h34;
            memory[16'h0702] = 8'h12;
            memory[16'h0703] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
                check(first_fault_vector == expected_vector && debug_cs == 16'h00DA, message);
            end else begin
                repeat (256) tick();
                check(debug_gpr[15:0] == 16'h1234 && debug_cs == expected_cs && debug_ip == 16'h0704,
                      message);
            end
        end
    endtask

    task automatic run_cpl0_event_case(
        input logic [7:0] vector,
        input logic expect_fault,
        input logic [7:0] expected_fault_vector,
        input logic [15:0] expected_ax,
        input string message
    );
        begin
            memory[16'h0100] = 8'h9A;
            memory[16'h0101] = 8'h00;
            memory[16'h0102] = 8'h02;
            memory[16'h0103] = 8'h81;
            memory[16'h0104] = 8'h00;
            memory[16'h0105] = 8'hF4;
            memory[16'h0200] = 8'hCD;
            memory[16'h0201] = vector;
            memory[16'h0202] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
                check(first_fault_vector == expected_fault_vector && debug_cs == 16'h0018,
                      message);
            end else begin
                wait_event(vector);
                repeat (256) tick();
                check(debug_cs == 16'h0018 && debug_gpr[15:0] == expected_ax,
                      message);
            end
        end
    endtask

    task automatic run_cpl1_event_case(
        input logic [7:0] vector,
        input logic expect_fault,
        input logic [7:0] expected_fault_vector,
        input logic [15:0] expected_ax,
        input string message
    );
        begin
            memory[16'h0100] = 8'hCD;
            memory[16'h0101] = vector;
            memory[16'h0102] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
                check(first_fault_vector == expected_fault_vector && debug_cs == 16'h0009,
                      message);
            end else begin
                wait_event(vector);
                repeat (256) tick();
                check(debug_cs == 16'h0018 && debug_gpr[15:0] == expected_ax,
                      message);
            end
        end
    endtask

    task automatic run_cpl3_event_case(
        input logic [7:0] vector,
        input logic expect_fault,
        input logic [7:0] expected_fault_vector,
        input logic [15:0] expected_ax,
        input string message
    );
        begin
            memory[16'h0100] = 8'h9A;
            memory[16'h0101] = 8'h00;
            memory[16'h0102] = 8'h02;
            memory[16'h0103] = 8'h81;
            memory[16'h0104] = 8'h00;
            memory[16'h0105] = 8'hF4;
            memory[16'h0200] = 8'hB8;
            memory[16'h0201] = 8'h53;
            memory[16'h0202] = 8'h00;
            memory[16'h0203] = 8'h50;
            memory[16'h0204] = 8'hB8;
            memory[16'h0205] = 8'h00;
            memory[16'h0206] = 8'hF0;
            memory[16'h0207] = 8'h50;
            memory[16'h0208] = 8'hB8;
            memory[16'h0209] = 8'h02;
            memory[16'h020A] = 8'h02;
            memory[16'h020B] = 8'h50;
            memory[16'h020C] = 8'hB8;
            memory[16'h020D] = 8'hAB;
            memory[16'h020E] = 8'h00;
            memory[16'h020F] = 8'h50;
            memory[16'h0210] = 8'hB8;
            memory[16'h0211] = 8'h00;
            memory[16'h0212] = 8'h06;
            memory[16'h0213] = 8'h50;
            memory[16'h0214] = 8'hCF;
            memory[16'h0600] = 8'hCD;
            memory[16'h0601] = vector;
            memory[16'h0602] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
                check(first_fault_vector == expected_fault_vector && debug_cs == 16'h00AB,
                      message);
            end else begin
                wait_event(vector);
                repeat (256) tick();
                check(debug_cs == 16'h00AB && debug_gpr[15:0] == expected_ax,
                      message);
            end
        end
    endtask

    task automatic configure_event_gate(
        input logic [7:0] vector,
        input logic [15:0] target_selector,
        input logic [7:0] access_byte,
        input logic [15:0] target_ip
    );
        integer entry;
        begin
            entry = 16'h0800 + (vector * 8);
            memory[entry] = target_ip[7:0];
            memory[entry + 1] = target_ip[15:8];
            memory[entry + 2] = target_selector[7:0];
            memory[entry + 3] = target_selector[15:8];
            memory[entry + 4] = 8'h00;
            memory[entry + 5] = access_byte;
            memory[entry + 6] = 8'h00;
            memory[entry + 7] = 8'h00;
        end
    endtask

    task automatic configure_event_target(
        input logic [15:0] target_ip,
        input logic [15:0] marker
    );
        begin
            memory[target_ip] = 8'hB8;
            memory[target_ip + 1] = marker[7:0];
            memory[target_ip + 2] = marker[15:8];
            memory[target_ip + 3] = 8'hF4;
        end
    endtask

    task automatic run_cpl0_event_matrix_case(
        input logic [15:0] target_selector,
        input logic [7:0] gate_access,
        input logic [15:0] target_ip,
        input logic [15:0] expected_target_cs,
        input logic expect_fault,
        input logic [7:0] expected_fault_vector,
        input logic [15:0] marker,
        input string message
    );
        begin
            configure_event_gate(8'h28, target_selector, gate_access, target_ip);
            configure_event_target(target_ip, marker);
            memory[16'h0100] = 8'h9A;
            memory[16'h0101] = 8'h00;
            memory[16'h0102] = 8'h02;
            memory[16'h0103] = 8'h81;
            memory[16'h0104] = 8'h00;
            memory[16'h0105] = 8'hF4;
            memory[16'h0200] = 8'hCD;
            memory[16'h0201] = 8'h28;
            memory[16'h0202] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
                check(first_fault_vector == expected_fault_vector && debug_cs == 16'h0018,
                      message);
            end else begin
                wait_event(8'h28);
                repeat (512) tick();
                check(debug_cs == expected_target_cs && debug_gpr[15:0] == marker,
                      message);
            end
        end
    endtask

    task automatic run_cpl1_event_matrix_case(
        input logic [15:0] target_selector,
        input logic [7:0] gate_access,
        input logic [15:0] target_ip,
        input logic [15:0] expected_target_cs,
        input logic expect_fault,
        input logic [7:0] expected_fault_vector,
        input logic [15:0] marker,
        input string message
    );
        begin
            configure_event_gate(8'h28, target_selector, gate_access, target_ip);
            configure_event_target(target_ip, marker);
            memory[16'h0100] = 8'hCD;
            memory[16'h0101] = 8'h28;
            memory[16'h0102] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
                check(first_fault_vector == expected_fault_vector && debug_cs == 16'h0009,
                      message);
            end else begin
                wait_event(8'h28);
                repeat (512) tick();
                check(debug_cs == expected_target_cs && debug_gpr[15:0] == marker,
                      message);
            end
        end
    endtask

    task automatic run_cpl3_event_matrix_case(
        input logic [15:0] target_selector,
        input logic [7:0] gate_access,
        input logic [15:0] target_ip,
        input logic [15:0] expected_target_cs,
        input logic expect_fault,
        input logic [7:0] expected_fault_vector,
        input logic [15:0] marker,
        input string message
    );
        begin
            configure_event_gate(8'h28, target_selector, gate_access, target_ip);
            configure_event_target(target_ip, marker);
            memory[16'h0100] = 8'h9A;
            memory[16'h0101] = 8'h00;
            memory[16'h0102] = 8'h02;
            memory[16'h0103] = 8'h81;
            memory[16'h0104] = 8'h00;
            memory[16'h0105] = 8'hF4;
            memory[16'h0200] = 8'hB8;
            memory[16'h0201] = 8'h53;
            memory[16'h0202] = 8'h00;
            memory[16'h0203] = 8'h50;
            memory[16'h0204] = 8'hB8;
            memory[16'h0205] = 8'h00;
            memory[16'h0206] = 8'hF0;
            memory[16'h0207] = 8'h50;
            memory[16'h0208] = 8'hB8;
            memory[16'h0209] = 8'h02;
            memory[16'h020A] = 8'h02;
            memory[16'h020B] = 8'h50;
            memory[16'h020C] = 8'hB8;
            memory[16'h020D] = 8'hAB;
            memory[16'h020E] = 8'h00;
            memory[16'h020F] = 8'h50;
            memory[16'h0210] = 8'hB8;
            memory[16'h0211] = 8'h00;
            memory[16'h0212] = 8'h06;
            memory[16'h0213] = 8'h50;
            memory[16'h0214] = 8'hCF;
            memory[16'h0600] = 8'hCD;
            memory[16'h0601] = 8'h28;
            memory[16'h0602] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
                check(first_fault_vector == expected_fault_vector && debug_cs == 16'h00AB,
                      message);
            end else begin
                wait_event(8'h28);
                repeat (512) tick();
                check(debug_cs == expected_target_cs && debug_gpr[15:0] == marker,
                      message);
            end
        end
    endtask

    task automatic run_pm1_level_case(
        input logic [15:0] selector,
        input logic [1:0] operation_kind,
        input logic expected_zf,
        input logic [15:0] expected_value,
        input string message
    );
        begin
            memory[16'h0100] = 8'hB8;
            memory[16'h0101] = selector[7:0];
            memory[16'h0102] = selector[15:8];
            memory[16'h0103] = 8'hBB;
            memory[16'h0104] = 8'h34;
            memory[16'h0105] = 8'h12;
            memory[16'h0106] = 8'hB9;
            memory[16'h0107] = 8'h34;
            memory[16'h0108] = 8'h12;
            if (operation_kind == 2'd0) begin
                memory[16'h0109] = 8'h0F;
                memory[16'h010A] = 8'h00;
                memory[16'h010B] = 8'hE0;
            end else if (operation_kind == 2'd1) begin
                memory[16'h0109] = 8'h0F;
                memory[16'h010A] = 8'h00;
                memory[16'h010B] = 8'hE8;
            end else if (operation_kind == 2'd2) begin
                memory[16'h0109] = 8'h0F;
                memory[16'h010A] = 8'h02;
                memory[16'h010B] = 8'hD8;
            end else begin
                memory[16'h0109] = 8'h0F;
                memory[16'h010A] = 8'h03;
                memory[16'h010B] = 8'hC8;
            end
            memory[16'h010C] = 8'hF4;
            memory[16'h042D] = 8'h81;

            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            repeat (1024) tick();
            if (operation_kind == 2'd2)
                check(debug_flags[6] == expected_zf && debug_gpr[63:48] == expected_value, message);
            else if (operation_kind == 2'd3)
                check(debug_flags[6] == expected_zf && debug_gpr[31:16] == expected_value, message);
            else
                check(debug_flags[6] == expected_zf && debug_gpr[15:0] == selector, message);
        end
    endtask

    task automatic run_pm1_level_group(
        input logic [1:0] caller_cpl,
        input logic [15:0] base_selector,
        input logic [1:0] descriptor_dpl,
        input logic [2:0] descriptor_kind,
        input logic descriptor_present,
        input string message
    );
        logic valid;
        logic inspect_valid;
        logic verr_valid;
        logic verw_valid;
        logic [15:0] observed_lar_value;
        logic [1:0] rpl_value;
        integer descriptor_address;
        integer rpl;
        begin
            descriptor_address = 32'h00000400 + ({16'h0000, base_selector} & 32'h0000FFFC);
            observed_lar_value = {memory[descriptor_address + 5], 8'h00};
            for (rpl = 0; rpl < 4; rpl = rpl + 1) begin
                rpl_value = rpl[1:0];
                valid = descriptor_present && descriptor_dpl >= caller_cpl && descriptor_dpl >= rpl_value;
                inspect_valid = descriptor_dpl >= caller_cpl && descriptor_dpl >= rpl_value;
                verr_valid = valid && (descriptor_kind == 3'd0 || descriptor_kind == 3'd1 || descriptor_kind == 3'd2);
                verw_valid = valid && descriptor_kind == 3'd0;
                run_pm1_level_case(base_selector + {14'h0000, rpl_value}, 2'd0,
                                   verr_valid, 16'h1234, message);
                run_pm1_level_case(base_selector + {14'h0000, rpl_value}, 2'd1,
                                   verw_valid, 16'h1234, message);
                run_pm1_level_case(base_selector + {14'h0000, rpl_value}, 2'd2,
                                   inspect_valid, inspect_valid ? observed_lar_value : 16'h1234, message);
                run_pm1_level_case(base_selector + {14'h0000, rpl_value}, 2'd3,
                                   inspect_valid, inspect_valid ? 16'hFFFF : 16'h1234, message);
            end
        end
    endtask

    task automatic run_pm1_cpl3_case(
        input logic [15:0] selector,
        input logic [1:0] operation_kind,
        input logic expected_zf,
        input logic [15:0] expected_value,
        input string message
    );
        begin
            // Enter CPL3 through the same CPL1 -> CPL0 call gate and real
            // outer-level IRET used by the protected event/segment tests.
            memory[16'h0100] = 8'h9A;
            memory[16'h0101] = 8'h00;
            memory[16'h0102] = 8'h02;
            memory[16'h0103] = 8'h81;
            memory[16'h0104] = 8'h00;
            memory[16'h0105] = 8'hF4;
            memory[16'h0200] = 8'hB8;
            memory[16'h0201] = 8'h53;
            memory[16'h0202] = 8'h00;
            memory[16'h0203] = 8'h50;
            memory[16'h0204] = 8'hB8;
            memory[16'h0205] = 8'h00;
            memory[16'h0206] = 8'hF0;
            memory[16'h0207] = 8'h50;
            memory[16'h0208] = 8'hB8;
            memory[16'h0209] = 8'h02;
            memory[16'h020A] = 8'h02;
            memory[16'h020B] = 8'h50;
            memory[16'h020C] = 8'hB8;
            memory[16'h020D] = 8'hAB;
            memory[16'h020E] = 8'h00;
            memory[16'h020F] = 8'h50;
            memory[16'h0210] = 8'hB8;
            memory[16'h0211] = 8'h00;
            memory[16'h0212] = 8'h06;
            memory[16'h0213] = 8'h50;
            memory[16'h0214] = 8'hCF;
            memory[16'h0600] = 8'hB8;
            memory[16'h0601] = selector[7:0];
            memory[16'h0602] = selector[15:8];
            memory[16'h0603] = 8'hBB;
            memory[16'h0604] = 8'h34;
            memory[16'h0605] = 8'h12;
            memory[16'h0606] = 8'hB9;
            memory[16'h0607] = 8'h34;
            memory[16'h0608] = 8'h12;
            if (operation_kind == 2'd0) begin
                memory[16'h0609] = 8'h0F;
                memory[16'h060A] = 8'h00;
                memory[16'h060B] = 8'hE0;
            end else if (operation_kind == 2'd1) begin
                memory[16'h0609] = 8'h0F;
                memory[16'h060A] = 8'h00;
                memory[16'h060B] = 8'hE8;
            end else if (operation_kind == 2'd2) begin
                memory[16'h0609] = 8'h0F;
                memory[16'h060A] = 8'h02;
                memory[16'h060B] = 8'hD8;
            end else begin
                memory[16'h0609] = 8'h0F;
                memory[16'h060A] = 8'h03;
                memory[16'h060B] = 8'hC8;
            end
            memory[16'h060C] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            repeat (2048) tick();
            if (operation_kind == 2'd2)
                check(halted && debug_cs == 16'h00AB && debug_ip == 16'h060D &&
                      debug_flags[6] == expected_zf && debug_gpr[63:48] == expected_value, message);
            else if (operation_kind == 2'd3)
                check(halted && debug_cs == 16'h00AB && debug_ip == 16'h060D &&
                      debug_flags[6] == expected_zf && debug_gpr[31:16] == expected_value, message);
            else
                check(halted && debug_cs == 16'h00AB && debug_ip == 16'h060D &&
                      debug_flags[6] == expected_zf && debug_gpr[15:0] == selector, message);
        end
    endtask

    task automatic run_pm1_cpl3_group(
        input logic [15:0] base_selector,
        input logic [1:0] descriptor_dpl,
        input logic [2:0] descriptor_kind,
        input logic descriptor_present,
        input string message
    );
        logic valid;
        logic inspect_valid;
        logic verr_valid;
        logic verw_valid;
        logic [15:0] observed_lar_value;
        logic [1:0] rpl_value;
        integer descriptor_address;
        integer rpl;
        begin
            descriptor_address = 32'h00000400 + ({16'h0000, base_selector} & 32'h0000FFFC);
            observed_lar_value = {memory[descriptor_address + 5], 8'h00};
            for (rpl = 0; rpl < 4; rpl = rpl + 1) begin
                rpl_value = rpl[1:0];
                valid = descriptor_present && descriptor_dpl >= 2'd3 && descriptor_dpl >= rpl_value;
                inspect_valid = descriptor_dpl >= 2'd3 && descriptor_dpl >= rpl_value;
                verr_valid = valid && (descriptor_kind == 3'd0 || descriptor_kind == 3'd1 || descriptor_kind == 3'd2);
                verw_valid = valid && descriptor_kind == 3'd0;
                run_pm1_cpl3_case(base_selector + {14'h0000, rpl_value}, 2'd0,
                                  verr_valid, 16'h1234, message);
                run_pm1_cpl3_case(base_selector + {14'h0000, rpl_value}, 2'd1,
                                  verw_valid, 16'h1234, message);
                run_pm1_cpl3_case(base_selector + {14'h0000, rpl_value}, 2'd2,
                                  inspect_valid, inspect_valid ? observed_lar_value : 16'h1234, message);
                run_pm1_cpl3_case(base_selector + {14'h0000, rpl_value}, 2'd3,
                                  inspect_valid, inspect_valid ? 16'hFFFF : 16'h1234, message);
            end
        end
    endtask

    task automatic run_cpl1_call_gate_case(
        input logic [15:0] gate_selector,
        input logic expect_fault,
        input logic [7:0] expected_vector,
        input string message
    );
        begin
            memory[16'h0100] = 8'h9A;
            memory[16'h0101] = 8'h80;
            memory[16'h0102] = 8'h07;
            memory[16'h0103] = gate_selector[7:0];
            memory[16'h0104] = gate_selector[15:8];
            memory[16'h0105] = 8'hF4;
            memory[16'h0780] = 8'hB8;
            memory[16'h0781] = 8'h5A;
            memory[16'h0782] = 8'hA5;
            memory[16'h0783] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
                check(first_fault_vector == expected_vector && debug_cs == 16'h0009, message);
            end else begin
                repeat (1024) tick();
                check(debug_gpr[15:0] == 16'hA55A && debug_cs == 16'h0018,
                      message);
            end
        end
    endtask

    task automatic run_cpl0_call_gate_case(
        input logic [15:0] gate_selector,
        input logic expect_fault,
        input logic [7:0] expected_vector,
        input string message
    );
        begin
            memory[16'h0100] = 8'h9A;
            memory[16'h0101] = 8'h00;
            memory[16'h0102] = 8'h02;
            memory[16'h0103] = 8'h81;
            memory[16'h0104] = 8'h00;
            memory[16'h0105] = 8'hF4;
            memory[16'h0200] = 8'h9A;
            memory[16'h0201] = 8'h80;
            memory[16'h0202] = 8'h07;
            memory[16'h0203] = gate_selector[7:0];
            memory[16'h0204] = gate_selector[15:8];
            memory[16'h0205] = 8'hF4;
            memory[16'h0780] = 8'hB8;
            memory[16'h0781] = 8'h5A;
            memory[16'h0782] = 8'hA5;
            memory[16'h0783] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
                check(first_fault_vector == expected_vector && debug_cs == 16'h0018, message);
            end else begin
                repeat (1024) tick();
                check(debug_gpr[15:0] == 16'hA55A && debug_cs == 16'h0018,
                      message);
            end
        end
    endtask

    task automatic run_cpl3_call_gate_case(
        input logic [15:0] gate_selector,
        input logic expect_fault,
        input logic [7:0] expected_vector,
        input string message
    );
        begin
            memory[16'h0100] = 8'h9A;
            memory[16'h0101] = 8'h00;
            memory[16'h0102] = 8'h02;
            memory[16'h0103] = 8'h81;
            memory[16'h0104] = 8'h00;
            memory[16'h0105] = 8'hF4;
            memory[16'h0200] = 8'hB8;
            memory[16'h0201] = 8'h53;
            memory[16'h0202] = 8'h00;
            memory[16'h0203] = 8'h50;
            memory[16'h0204] = 8'hB8;
            memory[16'h0205] = 8'h00;
            memory[16'h0206] = 8'hF0;
            memory[16'h0207] = 8'h50;
            memory[16'h0208] = 8'hB8;
            memory[16'h0209] = 8'h02;
            memory[16'h020A] = 8'h02;
            memory[16'h020B] = 8'h50;
            memory[16'h020C] = 8'hB8;
            memory[16'h020D] = 8'hAB;
            memory[16'h020E] = 8'h00;
            memory[16'h020F] = 8'h50;
            memory[16'h0210] = 8'hB8;
            memory[16'h0211] = 8'h00;
            memory[16'h0212] = 8'h06;
            memory[16'h0213] = 8'h50;
            memory[16'h0214] = 8'hCF;
            memory[16'h0600] = 8'h9A;
            memory[16'h0601] = 8'h80;
            memory[16'h0602] = 8'h07;
            memory[16'h0603] = gate_selector[7:0];
            memory[16'h0604] = gate_selector[15:8];
            memory[16'h0605] = 8'hF4;
            memory[16'h0780] = 8'hB8;
            memory[16'h0781] = 8'h5A;
            memory[16'h0782] = 8'hA5;
            memory[16'h0783] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
                check(first_fault_vector == expected_vector && debug_cs == 16'h00AB, message);
            end else begin
                repeat (1024) tick();
                check(debug_gpr[15:0] == 16'hA55A && debug_cs == 16'h0018,
                      message);
            end
        end
    endtask

    task automatic run_pm1_cpl2_case(
        input logic [15:0] selector,
        input logic [1:0] operation_kind,
        input logic expected_zf,
        input logic [15:0] expected_value,
        input string message
    );
        begin
            // Enter CPL2 through a real outer-level IRET, then execute the
            // selector-inspection instruction at the resulting CS:IP.
            memory[16'h0100] = 8'h9A;
            memory[16'h0101] = 8'h00;
            memory[16'h0102] = 8'h02;
            memory[16'h0103] = 8'h81;
            memory[16'h0104] = 8'h00;
            memory[16'h0105] = 8'hF4;
            memory[16'h0200] = 8'hB8;
            memory[16'h0201] = 8'h4A;
            memory[16'h0202] = 8'h00;
            memory[16'h0203] = 8'h50;
            memory[16'h0204] = 8'hB8;
            memory[16'h0205] = 8'h00;
            memory[16'h0206] = 8'hF0;
            memory[16'h0207] = 8'h50;
            memory[16'h0208] = 8'hB8;
            memory[16'h0209] = 8'h02;
            memory[16'h020A] = 8'h00;
            memory[16'h020B] = 8'h50;
            memory[16'h020C] = 8'hB8;
            memory[16'h020D] = 8'hDA;
            memory[16'h020E] = 8'h00;
            memory[16'h020F] = 8'h50;
            memory[16'h0210] = 8'hB8;
            memory[16'h0211] = 8'h00;
            memory[16'h0212] = 8'h06;
            memory[16'h0213] = 8'h50;
            memory[16'h0214] = 8'hCF;
            memory[16'h0600] = 8'hB8;
            memory[16'h0601] = selector[7:0];
            memory[16'h0602] = selector[15:8];
            memory[16'h0603] = 8'hBB;
            memory[16'h0604] = 8'h34;
            memory[16'h0605] = 8'h12;
            memory[16'h0606] = 8'hB9;
            memory[16'h0607] = 8'h34;
            memory[16'h0608] = 8'h12;
            if (operation_kind == 2'd0) begin
                memory[16'h0609] = 8'h0F;
                memory[16'h060A] = 8'h00;
                memory[16'h060B] = 8'hE0;
            end else if (operation_kind == 2'd1) begin
                memory[16'h0609] = 8'h0F;
                memory[16'h060A] = 8'h00;
                memory[16'h060B] = 8'hE8;
            end else if (operation_kind == 2'd2) begin
                memory[16'h0609] = 8'h0F;
                memory[16'h060A] = 8'h02;
                memory[16'h060B] = 8'hD8;
            end else begin
                memory[16'h0609] = 8'h0F;
                memory[16'h060A] = 8'h03;
                memory[16'h060B] = 8'hC8;
            end
            memory[16'h060C] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            repeat (2048) tick();
            if (operation_kind == 2'd2)
                check(halted && debug_cs == 16'h00DA && debug_ip == 16'h060D &&
                      debug_flags[6] == expected_zf && debug_gpr[63:48] == expected_value,
                      $sformatf("%s op=%0d selector=%h expected_zf=%b value=%h", message,
                                operation_kind, selector, expected_zf, expected_value));
            else if (operation_kind == 2'd3)
                check(halted && debug_cs == 16'h00DA && debug_ip == 16'h060D &&
                      debug_flags[6] == expected_zf && debug_gpr[31:16] == expected_value,
                      $sformatf("%s op=%0d selector=%h expected_zf=%b value=%h", message,
                                operation_kind, selector, expected_zf, expected_value));
            else
                check(halted && debug_cs == 16'h00DA && debug_ip == 16'h060D &&
                      debug_flags[6] == expected_zf && debug_gpr[15:0] == selector,
                      $sformatf("%s op=%0d selector=%h expected_zf=%b", message,
                                operation_kind, selector, expected_zf));
        end
    endtask

    task automatic run_pm1_cpl2_group(
        input logic [15:0] base_selector,
        input logic [1:0] descriptor_dpl,
        input logic [2:0] descriptor_kind,
        input logic descriptor_present,
        input string message
    );
        logic valid;
        logic inspect_valid;
        logic verr_valid;
        logic verw_valid;
        logic [15:0] observed_lar_value;
        logic [15:0] observed_limit;
        logic [1:0] rpl_value;
        integer descriptor_address;
        integer rpl;
        begin
            descriptor_address = 32'h00000400 + ({16'h0000, base_selector} & 32'h0000FFFC);
            observed_lar_value = {memory[descriptor_address + 5], 8'h00};
            observed_limit = {memory[descriptor_address + 1], memory[descriptor_address]};
            for (rpl = 0; rpl < 4; rpl = rpl + 1) begin
                rpl_value = rpl[1:0];
                valid = descriptor_present && descriptor_dpl >= 2'd2 && descriptor_dpl >= rpl_value;
                inspect_valid = descriptor_dpl >= 2'd2 && descriptor_dpl >= rpl_value;
                verr_valid = valid && (descriptor_kind == 3'd0 || descriptor_kind == 3'd1 || descriptor_kind == 3'd2);
                verw_valid = valid && descriptor_kind == 3'd0;
                run_pm1_cpl2_case(base_selector + {14'h0000, rpl_value}, 2'd0,
                                  verr_valid, 16'h1234, message);
                run_pm1_cpl2_case(base_selector + {14'h0000, rpl_value}, 2'd1,
                                  verw_valid, 16'h1234, message);
                run_pm1_cpl2_case(base_selector + {14'h0000, rpl_value}, 2'd2,
                                  inspect_valid, inspect_valid ? observed_lar_value : 16'h1234, message);
                run_pm1_cpl2_case(base_selector + {14'h0000, rpl_value}, 2'd3,
                                  inspect_valid, inspect_valid ? observed_limit : 16'h1234, message);
            end
        end
    endtask

    task automatic run_cpl2_call_gate_case(
        input logic [15:0] gate_selector,
        input logic expect_fault,
        input logic [7:0] expected_vector,
        input string message
    );
        begin
            memory[16'h0100] = 8'h9A;
            memory[16'h0101] = 8'h00;
            memory[16'h0102] = 8'h02;
            memory[16'h0103] = 8'h81;
            memory[16'h0104] = 8'h00;
            memory[16'h0105] = 8'hF4;
            memory[16'h0200] = 8'hB8;
            memory[16'h0201] = 8'h4A;
            memory[16'h0202] = 8'h00;
            memory[16'h0203] = 8'h50;
            memory[16'h0204] = 8'hB8;
            memory[16'h0205] = 8'h00;
            memory[16'h0206] = 8'hF0;
            memory[16'h0207] = 8'h50;
            memory[16'h0208] = 8'hB8;
            memory[16'h0209] = 8'h02;
            memory[16'h020A] = 8'h00;
            memory[16'h020B] = 8'h50;
            memory[16'h020C] = 8'hB8;
            memory[16'h020D] = 8'hDA;
            memory[16'h020E] = 8'h00;
            memory[16'h020F] = 8'h50;
            memory[16'h0210] = 8'hB8;
            memory[16'h0211] = 8'h00;
            memory[16'h0212] = 8'h06;
            memory[16'h0213] = 8'h50;
            memory[16'h0214] = 8'hCF;
            memory[16'h0600] = 8'h9A;
            memory[16'h0601] = 8'h80;
            memory[16'h0602] = 8'h07;
            memory[16'h0603] = gate_selector[7:0];
            memory[16'h0604] = gate_selector[15:8];
            memory[16'h0605] = 8'hF4;
            memory[16'h0780] = 8'hB8;
            memory[16'h0781] = 8'h5A;
            memory[16'h0782] = 8'hA5;
            memory[16'h0783] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
                check(first_fault_vector == expected_vector && debug_cs == 16'h00DA, message);
            end else begin
                repeat (1024) tick();
                check(debug_gpr[15:0] == 16'hA55A && debug_cs == 16'h0018,
                      message);
            end
        end
    endtask

    task automatic write_cpl2_gate_descriptor(
        input logic [15:0] gate_selector,
        input logic [7:0] gate_access,
        input logic [15:0] target_selector
    );
        integer gate_address;
        begin
            gate_address = 32'h00000400 +
                           ({16'h0000, gate_selector} & 32'h0000FFF8);
            memory[gate_address] = 8'h80;
            memory[gate_address + 1] = 8'h07;
            memory[gate_address + 2] = target_selector[7:0];
            memory[gate_address + 3] = target_selector[15:8];
            memory[gate_address + 4] = 8'h00;
            memory[gate_address + 5] = gate_access;
            memory[gate_address + 6] = 8'h00;
            memory[gate_address + 7] = 8'h00;
        end
    endtask

    task automatic run_cpl2_same_level_gate_case(
        input logic [15:0] gate_selector,
        input logic [7:0] gate_access,
        input logic [15:0] target_selector,
        input logic expect_fault,
        input logic [7:0] expected_vector,
        input logic [15:0] expected_cs,
        input string message
    );
        begin
            // The gate descriptor selected by the case is rewritten with its
            // target and access byte while the caller enters CPL2 through a
            // real outer-level IRET.
            write_cpl2_gate_descriptor(gate_selector, gate_access, target_selector);
            memory[16'h0100] = 8'h9A;
            memory[16'h0101] = 8'h00;
            memory[16'h0102] = 8'h02;
            memory[16'h0103] = 8'h81;
            memory[16'h0104] = 8'h00;
            memory[16'h0105] = 8'hF4;
            memory[16'h0200] = 8'hB8;
            memory[16'h0201] = 8'h4A;
            memory[16'h0202] = 8'h00;
            memory[16'h0203] = 8'h50;
            memory[16'h0204] = 8'hB8;
            memory[16'h0205] = 8'h00;
            memory[16'h0206] = 8'hF0;
            memory[16'h0207] = 8'h50;
            memory[16'h0208] = 8'hB8;
            memory[16'h0209] = 8'h02;
            memory[16'h020A] = 8'h00;
            memory[16'h020B] = 8'h50;
            memory[16'h020C] = 8'hB8;
            memory[16'h020D] = 8'hDA;
            memory[16'h020E] = 8'h00;
            memory[16'h020F] = 8'h50;
            memory[16'h0210] = 8'hB8;
            memory[16'h0211] = 8'h00;
            memory[16'h0212] = 8'h06;
            memory[16'h0213] = 8'h50;
            memory[16'h0214] = 8'hCF;
            memory[16'h0600] = 8'h9A;
            memory[16'h0601] = 8'h80;
            memory[16'h0602] = 8'h07;
            memory[16'h0603] = gate_selector[7:0];
            memory[16'h0604] = gate_selector[15:8];
            memory[16'h0605] = 8'hF4;
            memory[16'h0780] = 8'hB8;
            memory[16'h0781] = 8'h5A;
            memory[16'h0782] = 8'hA5;
            memory[16'h0783] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
                check(first_fault_vector == expected_vector && debug_cs == 16'h00DA,
                      message);
            end else begin
                repeat (1024) tick();
                check(debug_gpr[15:0] == 16'hA55A && debug_cs == expected_cs,
                      message);
            end
        end
    endtask

    task automatic run_cpl2_event_matrix_case(
        input logic [15:0] target_selector,
        input logic [7:0] gate_access,
        input logic [15:0] target_ip,
        input logic [15:0] expected_target_cs,
        input logic expect_fault,
        input logic [7:0] expected_fault_vector,
        input logic [15:0] marker,
        input string message
    );
        begin
            configure_event_gate(8'h28, target_selector, gate_access, target_ip);
            configure_event_target(target_ip, marker);
            memory[16'h0100] = 8'h9A;
            memory[16'h0101] = 8'h00;
            memory[16'h0102] = 8'h02;
            memory[16'h0103] = 8'h81;
            memory[16'h0104] = 8'h00;
            memory[16'h0105] = 8'hF4;
            memory[16'h0200] = 8'hB8;
            memory[16'h0201] = 8'h4A;
            memory[16'h0202] = 8'h00;
            memory[16'h0203] = 8'h50;
            memory[16'h0204] = 8'hB8;
            memory[16'h0205] = 8'h00;
            memory[16'h0206] = 8'hF0;
            memory[16'h0207] = 8'h50;
            memory[16'h0208] = 8'hB8;
            memory[16'h0209] = 8'h02;
            memory[16'h020A] = 8'h00;
            memory[16'h020B] = 8'h50;
            memory[16'h020C] = 8'hB8;
            memory[16'h020D] = 8'hDA;
            memory[16'h020E] = 8'h00;
            memory[16'h020F] = 8'h50;
            memory[16'h0210] = 8'hB8;
            memory[16'h0211] = 8'h00;
            memory[16'h0212] = 8'h06;
            memory[16'h0213] = 8'h50;
            memory[16'h0214] = 8'hCF;
            memory[16'h0600] = 8'hCD;
            memory[16'h0601] = 8'h28;
            memory[16'h0602] = 8'hF4;
            memory[16'h042D] = 8'h81;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            wait_state(16'h0009, 16'h0100);
            if (expect_fault) begin
                wait_shutdown();
                check(first_fault_vector == expected_fault_vector && debug_cs == 16'h00DA,
                      message);
            end else begin
                wait_event(8'h28);
                repeat (512) tick();
                check(debug_cs == expected_target_cs && debug_gpr[15:0] == marker,
                      message);
            end
        end
    endtask

    initial begin
        for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;

        // Real-mode setup: GDT at 0400, IDT at 0800, then enter ring 0.
        memory[16'h0000] = 8'h0F; memory[16'h0001] = 8'h01; memory[16'h0002] = 8'h16;
        memory[16'h0003] = 8'h00; memory[16'h0004] = 8'h03;
        memory[16'h0005] = 8'h0F; memory[16'h0006] = 8'h01; memory[16'h0007] = 8'h1E;
        memory[16'h0008] = 8'h10; memory[16'h0009] = 8'h03;
        memory[16'h000A] = 8'hB8; memory[16'h000B] = 8'h09; memory[16'h000C] = 8'h00;
        memory[16'h000D] = 8'h0F; memory[16'h000E] = 8'h01; memory[16'h000F] = 8'hF0;
        memory[16'h0010] = 8'hEA; memory[16'h0011] = 8'h80; memory[16'h0012] = 8'h00;
        memory[16'h0013] = 8'h18; memory[16'h0014] = 8'h00;

        // Ring-0 setup loads TR and creates an outer-level IRET frame for CPL1.
        memory[16'h0080] = 8'hB8; memory[16'h0081] = 8'h28; memory[16'h0082] = 8'h00;
        memory[16'h0083] = 8'h0F; memory[16'h0084] = 8'h00; memory[16'h0085] = 8'hD8;
        memory[16'h0086] = 8'hB8; memory[16'h0087] = 8'h30; memory[16'h0088] = 8'h00;
        memory[16'h0089] = 8'h8E; memory[16'h008A] = 8'hD0;
        memory[16'h008B] = 8'hBC; memory[16'h008C] = 8'h00; memory[16'h008D] = 8'hF0;
        memory[16'h008E] = 8'hB8; memory[16'h008F] = 8'h11; memory[16'h0090] = 8'h00; memory[16'h0091] = 8'h50;
        memory[16'h0092] = 8'hB8; memory[16'h0093] = 8'h00; memory[16'h0094] = 8'hF0; memory[16'h0095] = 8'h50;
        memory[16'h0096] = 8'hB8; memory[16'h0097] = 8'h02; memory[16'h0098] = 8'h02; memory[16'h0099] = 8'h50;
        memory[16'h009A] = 8'hB8; memory[16'h009B] = 8'h09; memory[16'h009C] = 8'h00; memory[16'h009D] = 8'h50;
        memory[16'h009E] = 8'hB8; memory[16'h009F] = 8'h00; memory[16'h00A0] = 8'h01; memory[16'h00A1] = 8'h50;
        memory[16'h00A2] = 8'hCF;

        // CPL1 loads an expand-down DS, reads a valid offset, then raises a
        // software INT. The DPL1 interrupt gate targets CPL0.
        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h39; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h8E; memory[16'h0104] = 8'hD8;
        memory[16'h0105] = 8'hA1; memory[16'h0106] = 8'h02; memory[16'h0107] = 8'hE0;
        memory[16'h0108] = 8'hCD; memory[16'h0109] = 8'h20;
        memory[16'h010A] = 8'hF4;
        memory[16'hE002] = 8'hFE; memory[16'hE003] = 8'hCA;
        memory[16'h0200] = 8'hF4;

        // GDT limit 0147h: matrix descriptors through index 40 are inside
        // the table; selector 0148h is the shared limit-overflow probe.
        memory[16'h0300] = 8'h47; memory[16'h0301] = 8'h01;
        memory[16'h0302] = 8'h00; memory[16'h0303] = 8'h04; memory[16'h0304] = 8'h00;
        memory[16'h0310] = 8'h77; memory[16'h0311] = 8'h01;
        memory[16'h0312] = 8'h00; memory[16'h0313] = 8'h08; memory[16'h0314] = 8'h00;

        // GDT: ring-1 code/data, ring-0 code, expand-down ring-0 stack, TSS.
        memory[16'h0408] = 8'hFF; memory[16'h0409] = 8'hFF; memory[16'h040A] = 8'h00; memory[16'h040B] = 8'h00;
        memory[16'h040C] = 8'h00; memory[16'h040D] = 8'hBA; memory[16'h040E] = 8'h00; memory[16'h040F] = 8'h00;
        memory[16'h0410] = 8'hFF; memory[16'h0411] = 8'hFF; memory[16'h0412] = 8'h00; memory[16'h0413] = 8'h00;
        memory[16'h0414] = 8'h00; memory[16'h0415] = 8'hB2; memory[16'h0416] = 8'h00; memory[16'h0417] = 8'h00;
        memory[16'h0418] = 8'hFF; memory[16'h0419] = 8'hFF; memory[16'h041A] = 8'h00; memory[16'h041B] = 8'h00;
        memory[16'h041C] = 8'h00; memory[16'h041D] = 8'h9A; memory[16'h041E] = 8'h00; memory[16'h041F] = 8'h00;
        // Index 4: expand-down writable data, limit E000, accessed clear.
        memory[16'h0420] = 8'h00; memory[16'h0421] = 8'hE0; memory[16'h0422] = 8'h00; memory[16'h0423] = 8'h00;
        memory[16'h0424] = 8'h00; memory[16'h0425] = 8'h96; memory[16'h0426] = 8'h00; memory[16'h0427] = 8'h00;
        memory[16'h0428] = 8'h67; memory[16'h0429] = 8'h00; memory[16'h042A] = 8'h00; memory[16'h042B] = 8'h0E;
        memory[16'h042C] = 8'h00; memory[16'h042D] = 8'h81; memory[16'h042E] = 8'h00; memory[16'h042F] = 8'h00;
        // Index 6: expand-down ring-0 data stack used while constructing and
        // later reading the outer-level IRET frame in the setup code.
        memory[16'h0430] = 8'h00; memory[16'h0431] = 8'hE0; memory[16'h0432] = 8'h00; memory[16'h0433] = 8'h00;
        memory[16'h0434] = 8'h00; memory[16'h0435] = 8'h96; memory[16'h0436] = 8'h00; memory[16'h0437] = 8'h00;
        // Index 7: expand-down ring-1 writable data, limit E000, accessed clear.
        memory[16'h0438] = 8'h00; memory[16'h0439] = 8'hE0; memory[16'h043A] = 8'h00; memory[16'h043B] = 8'h00;
        memory[16'h043C] = 8'h00; memory[16'h043D] = 8'hB6; memory[16'h043E] = 8'h00; memory[16'h043F] = 8'h00;
        // Matrix descriptors: normal data at DPL1/DPL2/DPL3, not-present
        // DPL1 data, non-readable DPL1 code, and read-only DPL1 data.
        memory[16'h0440] = 8'hFF; memory[16'h0441] = 8'hFF; memory[16'h0442] = 8'h00; memory[16'h0443] = 8'h00;
        memory[16'h0444] = 8'h00; memory[16'h0445] = 8'hB2; memory[16'h0446] = 8'h00; memory[16'h0447] = 8'h00;
        memory[16'h0448] = 8'hFF; memory[16'h0449] = 8'hFF; memory[16'h044A] = 8'h00; memory[16'h044B] = 8'h00;
        memory[16'h044C] = 8'h00; memory[16'h044D] = 8'hD2; memory[16'h044E] = 8'h00; memory[16'h044F] = 8'h00;
        memory[16'h0450] = 8'hFF; memory[16'h0451] = 8'hFF; memory[16'h0452] = 8'h00; memory[16'h0453] = 8'h00;
        memory[16'h0454] = 8'h00; memory[16'h0455] = 8'hF2; memory[16'h0456] = 8'h00; memory[16'h0457] = 8'h00;
        memory[16'h0458] = 8'hFF; memory[16'h0459] = 8'hFF; memory[16'h045A] = 8'h00; memory[16'h045B] = 8'h00;
        memory[16'h045C] = 8'h00; memory[16'h045D] = 8'h32; memory[16'h045E] = 8'h00; memory[16'h045F] = 8'h00;
        memory[16'h0460] = 8'hFF; memory[16'h0461] = 8'hFF; memory[16'h0462] = 8'h00; memory[16'h0463] = 8'h00;
        memory[16'h0464] = 8'h00; memory[16'h0465] = 8'hB8; memory[16'h0466] = 8'h00; memory[16'h0467] = 8'h00;
        memory[16'h0468] = 8'hFF; memory[16'h0469] = 8'hFF; memory[16'h046A] = 8'h00; memory[16'h046B] = 8'h00;
        memory[16'h046C] = 8'h00; memory[16'h046D] = 8'hB1; memory[16'h046E] = 8'h00; memory[16'h046F] = 8'h00;
        // Index 14: normal writable DPL1 data, base 1000h, limit 0010h.
        memory[16'h0470] = 8'h10; memory[16'h0471] = 8'h00; memory[16'h0472] = 8'h00; memory[16'h0473] = 8'h10;
        memory[16'h0474] = 8'h00; memory[16'h0475] = 8'hB2; memory[16'h0476] = 8'h00; memory[16'h0477] = 8'h00;
        // Index 15: expand-down writable DPL1 data, base 1000h, limit E000h.
        memory[16'h0478] = 8'h00; memory[16'h0479] = 8'hE0; memory[16'h047A] = 8'h00; memory[16'h047B] = 8'h10;
        memory[16'h047C] = 8'h00; memory[16'h047D] = 8'hB6; memory[16'h047E] = 8'h00; memory[16'h047F] = 8'h00;
        // Index 16: DPL1 call gate from the CPL1 fixture to ring-0 CS:0200.
        memory[16'h0480] = 8'h00; memory[16'h0481] = 8'h02; memory[16'h0482] = 8'h18; memory[16'h0483] = 8'h00;
        memory[16'h0484] = 8'h00; memory[16'h0485] = 8'hA4; memory[16'h0486] = 8'h00; memory[16'h0487] = 8'h00;
        // Index 17: normal writable DPL0 data; index 18: read-only DPL0 data.
        memory[16'h0488] = 8'hFF; memory[16'h0489] = 8'hFF; memory[16'h048A] = 8'h00; memory[16'h048B] = 8'h00;
        memory[16'h048C] = 8'h00; memory[16'h048D] = 8'h92; memory[16'h048E] = 8'h00; memory[16'h048F] = 8'h00;
        memory[16'h0490] = 8'hFF; memory[16'h0491] = 8'hFF; memory[16'h0492] = 8'h00; memory[16'h0493] = 8'h00;
        memory[16'h0494] = 8'h00; memory[16'h0495] = 8'h91; memory[16'h0496] = 8'h00; memory[16'h0497] = 8'h00;
        // Index 19: non-readable DPL0 code; index 20: not-present DPL0 data.
        memory[16'h0498] = 8'hFF; memory[16'h0499] = 8'hFF; memory[16'h049A] = 8'h00; memory[16'h049B] = 8'h00;
        memory[16'h049C] = 8'h00; memory[16'h049D] = 8'h98; memory[16'h049E] = 8'h00; memory[16'h049F] = 8'h00;
        memory[16'h04A0] = 8'hFF; memory[16'h04A1] = 8'hFF; memory[16'h04A2] = 8'h00; memory[16'h04A3] = 8'h00;
        memory[16'h04A4] = 8'h00; memory[16'h04A5] = 8'h12; memory[16'h04A6] = 8'h00; memory[16'h04A7] = 8'h00;
        // Index 21: DPL3 readable code used by the outer IRET; index 22 is
        // DPL3 read-only data, index 23 is DPL3 not-present data, and index
        // 24 is DPL3 non-readable code.
        memory[16'h04A8] = 8'hFF; memory[16'h04A9] = 8'hFF; memory[16'h04AA] = 8'h00; memory[16'h04AB] = 8'h00;
        memory[16'h04AC] = 8'h00; memory[16'h04AD] = 8'hFA; memory[16'h04AE] = 8'h00; memory[16'h04AF] = 8'h00;
        memory[16'h04B0] = 8'hFF; memory[16'h04B1] = 8'hFF; memory[16'h04B2] = 8'h00; memory[16'h04B3] = 8'h00;
        memory[16'h04B4] = 8'h00; memory[16'h04B5] = 8'hF1; memory[16'h04B6] = 8'h00; memory[16'h04B7] = 8'h00;
        memory[16'h04B8] = 8'hFF; memory[16'h04B9] = 8'hFF; memory[16'h04BA] = 8'h00; memory[16'h04BB] = 8'h00;
        memory[16'h04BC] = 8'h00; memory[16'h04BD] = 8'h72; memory[16'h04BE] = 8'h00; memory[16'h04BF] = 8'h00;
        memory[16'h04C0] = 8'hFF; memory[16'h04C1] = 8'hFF; memory[16'h04C2] = 8'h00; memory[16'h04C3] = 8'h00;
        memory[16'h04C4] = 8'h00; memory[16'h04C5] = 8'hF8; memory[16'h04C6] = 8'h00; memory[16'h04C7] = 8'h00;
        // Indices 25/26: conforming readable code at DPL0/DPL3.
        memory[16'h04C8] = 8'hFF; memory[16'h04C9] = 8'hFF; memory[16'h04CA] = 8'h00; memory[16'h04CB] = 8'h00;
        memory[16'h04CC] = 8'h00; memory[16'h04CD] = 8'h9E; memory[16'h04CE] = 8'h00; memory[16'h04CF] = 8'h00;
        memory[16'h04D0] = 8'hFF; memory[16'h04D1] = 8'hFF; memory[16'h04D2] = 8'h00; memory[16'h04D3] = 8'h00;
        memory[16'h04D4] = 8'h00; memory[16'h04D5] = 8'hFE; memory[16'h04D6] = 8'h00; memory[16'h04D7] = 8'h00;
        // Index 27/28: readable/non-readable DPL2 code.
        memory[16'h04D8] = 8'hFF; memory[16'h04D9] = 8'hFF; memory[16'h04DA] = 8'h00; memory[16'h04DB] = 8'h00;
        memory[16'h04DC] = 8'h00; memory[16'h04DD] = 8'hDA; memory[16'h04DE] = 8'h00; memory[16'h04DF] = 8'h00;
        memory[16'h04E0] = 8'hFF; memory[16'h04E1] = 8'hFF; memory[16'h04E2] = 8'h00; memory[16'h04E3] = 8'h00;
        memory[16'h04E4] = 8'h00; memory[16'h04E5] = 8'hD8; memory[16'h04E6] = 8'h00; memory[16'h04E7] = 8'h00;
        // Indices 29/30/31: not-present readable code at DPL1/DPL3/DPL2.
        memory[16'h04E8] = 8'hFF; memory[16'h04E9] = 8'hFF; memory[16'h04EA] = 8'h00; memory[16'h04EB] = 8'h00;
        memory[16'h04EC] = 8'h00; memory[16'h04ED] = 8'h3A; memory[16'h04EE] = 8'h00; memory[16'h04EF] = 8'h00;
        memory[16'h04F0] = 8'hFF; memory[16'h04F1] = 8'hFF; memory[16'h04F2] = 8'h00; memory[16'h04F3] = 8'h00;
        memory[16'h04F4] = 8'h00; memory[16'h04F5] = 8'h7A; memory[16'h04F6] = 8'h00; memory[16'h04F7] = 8'h00;
        memory[16'h04F8] = 8'hFF; memory[16'h04F9] = 8'hFF; memory[16'h04FA] = 8'h00; memory[16'h04FB] = 8'h00;
        memory[16'h04FC] = 8'h00; memory[16'h04FD] = 8'h5A; memory[16'h04FE] = 8'h00; memory[16'h04FF] = 8'h00;

        // Indices 37/38: DPL2 read-only and not-present writable data used
        // by the CPL2 selector matrix. Their selectors are 0128h/0130h.
        memory[16'h0528] = 8'hFF; memory[16'h0529] = 8'hFF; memory[16'h052A] = 8'h00; memory[16'h052B] = 8'h00;
        memory[16'h052C] = 8'h00; memory[16'h052D] = 8'hD1; memory[16'h052E] = 8'h00; memory[16'h052F] = 8'h00;
        memory[16'h0530] = 8'hFF; memory[16'h0531] = 8'hFF; memory[16'h0532] = 8'h00; memory[16'h0533] = 8'h00;
        memory[16'h0534] = 8'h00; memory[16'h0535] = 8'h52; memory[16'h0536] = 8'h00; memory[16'h0537] = 8'h00;
        // Indices 39/40: DPL2/DPL3 expand-down writable data variants.
        memory[16'h0538] = 8'h00; memory[16'h0539] = 8'hE0; memory[16'h053A] = 8'h00; memory[16'h053B] = 8'h00;
        memory[16'h053C] = 8'h00; memory[16'h053D] = 8'hD6; memory[16'h053E] = 8'h00; memory[16'h053F] = 8'h00;
        memory[16'h0540] = 8'h00; memory[16'h0541] = 8'hE0; memory[16'h0542] = 8'h00; memory[16'h0543] = 8'h00;
        memory[16'h0544] = 8'h00; memory[16'h0545] = 8'hF6; memory[16'h0546] = 8'h00; memory[16'h0547] = 8'h00;

        // Indices 32..36: DPL0/DPL1/DPL2/DPL3 call gates to ring-0 CS:0780
        // plus a not-present DPL2 gate. The TSS was moved to 0E00h so these
        // descriptors do not overlap its SPn/SSn words.
        memory[16'h0500] = 8'h80; memory[16'h0501] = 8'h07; memory[16'h0502] = 8'h18; memory[16'h0503] = 8'h00;
        memory[16'h0504] = 8'h00; memory[16'h0505] = 8'h84; memory[16'h0506] = 8'h00; memory[16'h0507] = 8'h00;
        memory[16'h0508] = 8'h80; memory[16'h0509] = 8'h07; memory[16'h050A] = 8'h18; memory[16'h050B] = 8'h00;
        memory[16'h050C] = 8'h00; memory[16'h050D] = 8'hA4; memory[16'h050E] = 8'h00; memory[16'h050F] = 8'h00;
        memory[16'h0510] = 8'h80; memory[16'h0511] = 8'h07; memory[16'h0512] = 8'h18; memory[16'h0513] = 8'h00;
        memory[16'h0514] = 8'h00; memory[16'h0515] = 8'hC4; memory[16'h0516] = 8'h00; memory[16'h0517] = 8'h00;
        memory[16'h0518] = 8'h80; memory[16'h0519] = 8'h07; memory[16'h051A] = 8'h18; memory[16'h051B] = 8'h00;
        memory[16'h051C] = 8'h00; memory[16'h051D] = 8'hE4; memory[16'h051E] = 8'h00; memory[16'h051F] = 8'h00;
        memory[16'h0520] = 8'h80; memory[16'h0521] = 8'h07; memory[16'h0522] = 8'h18; memory[16'h0523] = 8'h00;
        memory[16'h0524] = 8'h00; memory[16'h0525] = 8'h44; memory[16'h0526] = 8'h00; memory[16'h0527] = 8'h00;

        // TSS SP0/SS0 at offsets 2/4; SP1/SS1 are present for the return path.
        memory[16'h0E02] = 8'h00; memory[16'h0E03] = 8'hF0;
        memory[16'h0E04] = 8'h20; memory[16'h0E05] = 8'h00;
        memory[16'h0E06] = 8'h00; memory[16'h0E07] = 8'hF0;
        memory[16'h0E08] = 8'h11; memory[16'h0E09] = 8'h00;
        memory[16'h0E0A] = 8'h00; memory[16'h0E0B] = 8'hEE;
        memory[16'h0E0C] = 8'h4A; memory[16'h0E0D] = 8'h00;

        // Vector 20h: present DPL1 interrupt gate, target 0018:0200.
        memory[16'h0900] = 8'h00; memory[16'h0901] = 8'h02;
        memory[16'h0902] = 8'h18; memory[16'h0903] = 8'h00;
        memory[16'h0904] = 8'h00; memory[16'h0905] = 8'hA6;
        memory[16'h0906] = 8'h00; memory[16'h0907] = 8'h00;
        // Correct IDT locations for vectors 21h..26h (base 0800h).
        memory[16'h0908] = 8'h30; memory[16'h0909] = 8'h07;
        memory[16'h090A] = 8'h18; memory[16'h090B] = 8'h00;
        memory[16'h090C] = 8'h00; memory[16'h090D] = 8'hA6;
        memory[16'h090E] = 8'h00; memory[16'h090F] = 8'h00;
        memory[16'h0910] = 8'h20; memory[16'h0911] = 8'h07;
        memory[16'h0912] = 8'h18; memory[16'h0913] = 8'h00;
        memory[16'h0914] = 8'h00; memory[16'h0915] = 8'h86;
        memory[16'h0916] = 8'h00; memory[16'h0917] = 8'h00;
        memory[16'h0918] = 8'h30; memory[16'h0919] = 8'h07;
        memory[16'h091A] = 8'h18; memory[16'h091B] = 8'h00;
        memory[16'h091C] = 8'h00; memory[16'h091D] = 8'hA6;
        memory[16'h091E] = 8'h00; memory[16'h091F] = 8'h00;
        memory[16'h0920] = 8'h40; memory[16'h0921] = 8'h07;
        memory[16'h0922] = 8'hAB; memory[16'h0923] = 8'h00;
        memory[16'h0924] = 8'h00; memory[16'h0925] = 8'hE6;
        memory[16'h0926] = 8'h00; memory[16'h0927] = 8'h00;
        memory[16'h0928] = 8'h40; memory[16'h0929] = 8'h07;
        memory[16'h092A] = 8'hAB; memory[16'h092B] = 8'h00;
        memory[16'h092C] = 8'h00; memory[16'h092D] = 8'h66;
        memory[16'h092E] = 8'h00; memory[16'h092F] = 8'h00;
        memory[16'h0930] = 8'h40; memory[16'h0931] = 8'h07;
        memory[16'h0932] = 8'hF3; memory[16'h0933] = 8'h00;
        memory[16'h0934] = 8'h00; memory[16'h0935] = 8'hE6;
        memory[16'h0936] = 8'h00; memory[16'h0937] = 8'h00;
        memory[16'h0720] = 8'hB8; memory[16'h0721] = 8'h22; memory[16'h0722] = 8'h22; memory[16'h0723] = 8'hF4;
        memory[16'h0730] = 8'hB8; memory[16'h0731] = 8'h23; memory[16'h0732] = 8'h23; memory[16'h0733] = 8'hF4;
        memory[16'h0740] = 8'hB8; memory[16'h0741] = 8'h24; memory[16'h0742] = 8'h24; memory[16'h0743] = 8'hF4;

        reset_cpu();
        far_restart(16'h0000, 16'h0000);
        wait_state(16'h0009, 16'h0100);
        wait_event(8'h20);
        check(debug_gpr[15:0] == 16'hCAFE && debug_segment_selectors[63:48] == 16'h0039,
              "expand-down data segment accepts an offset above its lower bound");
        check(debug_segment_selectors[47:32] == 16'h0020 && debug_gpr[79:64] == 16'hEFF6,
              "expand-down event selects the TSS stack and commits the expected SP");
        check(memory[16'hEFF6] == 8'h0A && memory[16'hEFF7] == 8'h01 && memory[16'hEFFF] == 8'h00,
              "expand-down event writes its lowest and highest frame bytes");
        repeat (64) tick();
        check(debug_gpr[15:0] == 16'hCAFE && halted,
              "valid expand-down event reaches the target handler");

        // DS and ES accept a null selector as an unloaded cache, while SS
        // rejects a null selector with #GP. Verify that the earlier null
        // commits survive the later SS fault and that no transition frame is
        // started by the rejected stack reload.
        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h00; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h8E; memory[16'h0104] = 8'hD8;
        memory[16'h0105] = 8'h8E; memory[16'h0106] = 8'hC0;
        memory[16'h0107] = 8'h8E; memory[16'h0108] = 8'hD0;
        memory[16'h0109] = 8'hF4;
        memory[16'h042D] = 8'h81;
        for (integer i = 16'hEFF6; i <= 16'hEFFF; i = i + 1) memory[i] = 8'h00;
        fault_request_reported = 1'b0;
        first_fault_vector = 8'h00;
        reset_cpu();
        far_restart(16'h0000, 16'h0000);
        wait_state(16'h0009, 16'h0100);
        wait_shutdown();
        check(first_fault_vector == 8'h0D && debug_segment_selectors[63:48] == 16'h0000 &&
              debug_segment_selectors[15:0] == 16'h0000 && debug_segment_selectors[47:32] == 16'h0011,
              "DS and ES accept null selectors while SS rejects null with #GP");
        check(memory[16'hEFF6] == 8'h00 && memory[16'hEFFF] == 8'h00,
              "rejected null SS reload performs no transition-stack writes");

        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h39; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h8E; memory[16'h0104] = 8'hD8;
        memory[16'h0105] = 8'hA1; memory[16'h0106] = 8'h02; memory[16'h0107] = 8'hE0;
        memory[16'h0108] = 8'hCD; memory[16'h0109] = 8'h20;
        memory[16'h010A] = 8'hF4;

        // A CPL1 data reload may not select the present DPL0 data descriptor.
        // The privilege check must reject the selector before changing DS or
        // reaching the later software event in the test program.
        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h20; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h8E; memory[16'h0104] = 8'hD8;
        memory[16'h0105] = 8'hF4;
        memory[16'h042D] = 8'h81;
        for (integer i = 16'hEFF6; i <= 16'hEFFF; i = i + 1) memory[i] = 8'h00;
        fault_request_reported = 1'b0;
        first_fault_vector = 8'h00;
        reset_cpu();
        far_restart(16'h0000, 16'h0000);
        wait_state(16'h0009, 16'h0100);
        wait_shutdown();
        check(first_fault_vector == 8'h0D && debug_segment_selectors[63:48] == 16'h0000,
              "CPL1 rejects a DPL0 DS reload before changing the hidden cache");
        check(memory[16'hEFF6] == 8'h00 && memory[16'hEFFF] == 8'h00,
              "rejected CPL1 DS reload performs no transition-stack writes");

        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h39; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h8E; memory[16'h0104] = 8'hD8;
        memory[16'h0105] = 8'hA1; memory[16'h0106] = 8'h02; memory[16'h0107] = 8'hE0;
        memory[16'h0108] = 8'hCD; memory[16'h0109] = 8'h20;
        memory[16'h010A] = 8'hF4;

        // SS has the stricter privilege rule: CPL1 cannot load the present
        // DPL0 stack descriptor even though it is writable.
        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h20; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h8E; memory[16'h0104] = 8'hD0;
        memory[16'h0105] = 8'hF4;
        memory[16'h042D] = 8'h81;
        for (integer i = 16'hEFF6; i <= 16'hEFFF; i = i + 1) memory[i] = 8'h00;
        fault_request_reported = 1'b0;
        first_fault_vector = 8'h00;
        reset_cpu();
        far_restart(16'h0000, 16'h0000);
        wait_state(16'h0009, 16'h0100);
        wait_shutdown();
        check(first_fault_vector == 8'h0D && debug_segment_selectors[47:32] == 16'h0011,
              "CPL1 rejects a DPL0 SS reload before changing the hidden cache");
        check(memory[16'hEFF6] == 8'h00 && memory[16'hEFFF] == 8'h00,
              "rejected CPL1 SS reload performs no transition-stack writes");

        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h39; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h8E; memory[16'h0104] = 8'hD8;
        memory[16'h0105] = 8'hA1; memory[16'h0106] = 8'h02; memory[16'h0107] = 8'hE0;
        memory[16'h0108] = 8'hCD; memory[16'h0109] = 8'h20;
        memory[16'h010A] = 8'hF4;

        // ES uses the same data-segment privilege rule as DS. Keep the
        // descriptor present and writable so this isolates the DPL mismatch.
        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h20; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h8E; memory[16'h0104] = 8'hC0;
        memory[16'h0105] = 8'hF4;
        memory[16'h042D] = 8'h81;
        for (integer i = 16'hEFF6; i <= 16'hEFFF; i = i + 1) memory[i] = 8'h00;
        fault_request_reported = 1'b0;
        first_fault_vector = 8'h00;
        reset_cpu();
        far_restart(16'h0000, 16'h0000);
        wait_state(16'h0009, 16'h0100);
        wait_shutdown();
        check(first_fault_vector == 8'h0D && debug_segment_selectors[15:0] == 16'h0000,
              "CPL1 rejects a DPL0 ES reload before changing the hidden cache");
        check(memory[16'hEFF6] == 8'h00 && memory[16'hEFFF] == 8'h00,
              "rejected CPL1 ES reload performs no transition-stack writes");

        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h39; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h8E; memory[16'h0104] = 8'hD8;
        memory[16'h0105] = 8'hA1; memory[16'h0106] = 8'h02; memory[16'h0107] = 8'hE0;
        memory[16'h0108] = 8'hCD; memory[16'h0109] = 8'h20;
        memory[16'h010A] = 8'hF4;

        // The effective privilege also includes the selector RPL. RPL3 must
        // reject the same present DPL0 descriptor even from the CPL1 caller.
        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h23; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h8E; memory[16'h0104] = 8'hD8;
        memory[16'h0105] = 8'hF4;
        memory[16'h042D] = 8'h81;
        for (integer i = 16'hEFF6; i <= 16'hEFFF; i = i + 1) memory[i] = 8'h00;
        fault_request_reported = 1'b0;
        first_fault_vector = 8'h00;
        reset_cpu();
        far_restart(16'h0000, 16'h0000);
        wait_state(16'h0009, 16'h0100);
        wait_shutdown();
        check(first_fault_vector == 8'h0D && debug_segment_selectors[63:48] == 16'h0000,
              "CPL1 rejects a DPL0 DS reload when selector RPL is 3");
        check(memory[16'hEFF6] == 8'h00 && memory[16'hEFFF] == 8'h00,
              "rejected RPL3 DS reload performs no transition-stack writes");

        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h39; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h8E; memory[16'h0104] = 8'hD8;
        memory[16'h0105] = 8'hA1; memory[16'h0106] = 8'h02; memory[16'h0107] = 8'hE0;
        memory[16'h0108] = 8'hCD; memory[16'h0109] = 8'h20;
        memory[16'h010A] = 8'hF4;

        // A software INT from CPL1 must not enter a present DPL0 gate. The
        // gate check must fault before the privilege transition can write any
        // part of the outer event frame.
        memory[16'h0905] = 8'h86;
        memory[16'h042D] = 8'h81;
        for (integer i = 16'hEFF6; i <= 16'hEFFF; i = i + 1) memory[i] = 8'h00;
        fault_request_reported = 1'b0;
        first_fault_vector = 8'h00;
        reset_cpu();
        far_restart(16'h0000, 16'h0000);
        wait_state(16'h0009, 16'h0100);
        wait_shutdown();
        check(first_fault_vector == 8'h0D,
              "software INT below the gate DPL raises general protection");
        check(memory[16'hEFF6] == 8'h00 && memory[16'hEFFF] == 8'h00,
              "rejected software INT performs no outer event-frame writes");

        memory[16'h0905] = 8'hA6;

        // The final frame word at EFF6 is now outside an expand-down stack
        // whose lower bound is EFF6. The preflight must reject the frame.
        memory[16'h0420] = 8'hF6;
        memory[16'h0421] = 8'hEF;
        memory[16'h042D] = 8'h81;
        for (integer i = 16'hEFF6; i <= 16'hEFFF; i = i + 1) memory[i] = 8'h00;
        fault_request_reported = 1'b0;
        first_fault_vector = 8'h00;
        reset_cpu();
        far_restart(16'h0000, 16'h0000);
        wait_state(16'h0009, 16'h0100);
        wait_shutdown();
        check(first_fault_vector == 8'h0C,
              "expand-down frame boundary raises stack fault before event entry");
        check(memory[16'hEFF6] == 8'h00 && memory[16'hEFFF] == 8'h00,
              "rejected expand-down frame performs no stack writes");

        // Restore the TSS SS0 descriptor changed by the preceding boundary
        // case before reusing the CPL1 fixture for the selector matrix.
        memory[16'h0420] = 8'h00;
        memory[16'h0421] = 8'hE0;
        memory[16'h042D] = 8'h81;
        // Exhaustive CPL1 data/stack selector matrix.  For DS and ES the
        // effective privilege is max(CPL,RPL) <= DPL; SS additionally
        // requires DPL == CPL and RPL == CPL.  Present/type faults are kept
        // distinct from privilege faults to validate their precedence.
        for (integer rpl = 0; rpl < 4; rpl = rpl + 1) begin
            run_segment_load_case(8'hD8, 16'h0040 + rpl, rpl > 1, 8'h0D, 16'h0000,
                                  "CPL1 DS DPL1 writable data RPL matrix");
            run_segment_load_case(8'hD8, 16'h0048 + rpl, rpl > 2, 8'h0D, 16'h0000,
                                  "CPL1 DS DPL2 writable data RPL matrix");
            run_segment_load_case(8'hD8, 16'h0050 + rpl, 1'b0, 8'h00, 16'h0000,
                                  "CPL1 DS DPL3 writable data RPL matrix");
            run_segment_load_case(8'hD8, 16'h0058 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL1 DS not-present selector matrix");
            run_segment_load_case(8'hD8, 16'h0060 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL1 DS non-readable code rejection");
            run_segment_load_case(8'hD8, 16'h0068 + rpl, rpl > 1, 8'h0D, 16'h0000,
                                  "CPL1 DS read-only data selector matrix");

            run_segment_load_case(8'hC0, 16'h0040 + rpl, rpl > 1, 8'h0D, 16'h0000,
                                  "CPL1 ES DPL1 writable data RPL matrix");
            run_segment_load_case(8'hC0, 16'h0048 + rpl, rpl > 2, 8'h0D, 16'h0000,
                                  "CPL1 ES DPL2 writable data RPL matrix");
            run_segment_load_case(8'hC0, 16'h0050 + rpl, 1'b0, 8'h00, 16'h0000,
                                  "CPL1 ES DPL3 writable data RPL matrix");
            run_segment_load_case(8'hC0, 16'h0058 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL1 ES not-present selector matrix");
            run_segment_load_case(8'hC0, 16'h0060 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL1 ES non-readable code rejection");
            run_segment_load_case(8'hC0, 16'h0068 + rpl, rpl > 1, 8'h0D, 16'h0000,
                                  "CPL1 ES read-only data selector matrix");

            run_segment_load_case(8'hD0, 16'h0040 + rpl, rpl != 1, 8'h0D, 16'h0011,
                                  "CPL1 SS DPL1 writable data exact RPL matrix");
            run_segment_load_case(8'hD0, 16'h0048 + rpl, 1'b1, 8'h0D, 16'h0011,
                                  "CPL1 SS DPL2 rejection");
            run_segment_load_case(8'hD0, 16'h0050 + rpl, 1'b1, 8'h0D, 16'h0011,
                                  "CPL1 SS DPL3 rejection");
            run_segment_load_case(8'hD0, 16'h0058 + rpl, 1'b1, 8'h0C, 16'h0011,
                                  "CPL1 SS not-present selector matrix");
            run_segment_load_case(8'hD0, 16'h0060 + rpl, 1'b1, 8'h0D, 16'h0011,
                                  "CPL1 SS non-readable code rejection");
            run_segment_load_case(8'hD0, 16'h0068 + rpl, 1'b1, 8'h0D, 16'h0011,
                                  "CPL1 SS read-only data rejection");
        end

        // The same selector truth table is exercised at CPL0 after a real
        // PM4 inter-level call-gate transition.  The target starts with the
        // TSS-selected SS=0020, so invalid DS/ES and SS reloads have distinct
        // unchanged-cache expectations.
        for (integer rpl = 0; rpl < 4; rpl = rpl + 1) begin
            run_cpl0_segment_case(8'hD8, 16'h0088 + rpl, rpl != 0, 8'h0D, 16'h0000,
                                  "CPL0 DS DPL0 writable data RPL matrix");
            run_cpl0_segment_case(8'hD8, 16'h0040 + rpl, rpl > 1, 8'h0D, 16'h0000,
                                  "CPL0 DS DPL1 writable data RPL matrix");
            run_cpl0_segment_case(8'hD8, 16'h0048 + rpl, rpl > 2, 8'h0D, 16'h0000,
                                  "CPL0 DS DPL2 writable data RPL matrix");
            run_cpl0_segment_case(8'hD8, 16'h0050 + rpl, 1'b0, 8'h00, 16'h0000,
                                  "CPL0 DS DPL3 writable data RPL matrix");
            run_cpl0_segment_case(8'hD8, 16'h0058 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL0 DS not-present selector matrix");
            run_cpl0_segment_case(8'hD8, 16'h0060 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL0 DS non-readable code rejection");
            run_cpl0_segment_case(8'hD8, 16'h0068 + rpl, rpl > 1, 8'h0D, 16'h0000,
                                  "CPL0 DS read-only data selector matrix");
            run_cpl0_segment_case(8'hD8, 16'h0090 + rpl, rpl != 0, 8'h0D, 16'h0000,
                                  "CPL0 DS DPL0 read-only data RPL matrix");

            run_cpl0_segment_case(8'hC0, 16'h0088 + rpl, rpl != 0, 8'h0D, 16'h0000,
                                  "CPL0 ES DPL0 writable data RPL matrix");
            run_cpl0_segment_case(8'hC0, 16'h0040 + rpl, rpl > 1, 8'h0D, 16'h0000,
                                  "CPL0 ES DPL1 writable data RPL matrix");
            run_cpl0_segment_case(8'hC0, 16'h0048 + rpl, rpl > 2, 8'h0D, 16'h0000,
                                  "CPL0 ES DPL2 writable data RPL matrix");
            run_cpl0_segment_case(8'hC0, 16'h0050 + rpl, 1'b0, 8'h00, 16'h0000,
                                  "CPL0 ES DPL3 writable data RPL matrix");
            run_cpl0_segment_case(8'hC0, 16'h0058 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL0 ES not-present selector matrix");
            run_cpl0_segment_case(8'hC0, 16'h0060 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL0 ES non-readable code rejection");
            run_cpl0_segment_case(8'hC0, 16'h0068 + rpl, rpl > 1, 8'h0D, 16'h0000,
                                  "CPL0 ES read-only data selector matrix");
            run_cpl0_segment_case(8'hC0, 16'h0090 + rpl, rpl != 0, 8'h0D, 16'h0000,
                                  "CPL0 ES DPL0 read-only data RPL matrix");

            run_cpl0_segment_case(8'hD0, 16'h0088 + rpl, rpl != 0, 8'h0D, 16'h0020,
                                  "CPL0 SS DPL0 writable data exact RPL matrix");
            run_cpl0_segment_case(8'hD0, 16'h0040 + rpl, 1'b1, 8'h0D, 16'h0020,
                                  "CPL0 SS DPL1 rejection");
            run_cpl0_segment_case(8'hD0, 16'h0048 + rpl, 1'b1, 8'h0D, 16'h0020,
                                  "CPL0 SS DPL2 rejection");
            run_cpl0_segment_case(8'hD0, 16'h0050 + rpl, 1'b1, 8'h0D, 16'h0020,
                                  "CPL0 SS DPL3 rejection");
            run_cpl0_segment_case(8'hD0, 16'h00A0 + rpl, 1'b1, 8'h0C, 16'h0020,
                                  "CPL0 SS not-present selector matrix");
            run_cpl0_segment_case(8'hD0, 16'h0098 + rpl, 1'b1, 8'h0D, 16'h0020,
                                  "CPL0 SS non-readable code rejection");
            run_cpl0_segment_case(8'hD0, 16'h0090 + rpl, 1'b1, 8'h0D, 16'h0020,
                                  "CPL0 SS read-only data rejection");
        end

        // CPL2 is entered through a real outer IRET from the ring-0 target.
        // DS/ES accept present data or readable-code descriptors when
        // max(CPL,RPL) <= DPL; SS additionally requires an exact DPL/RPL
        // match and writable data. The matrix includes normal and
        // expand-down data, read-only/readable-code types, non-readable code,
        // not-present descriptors, and the enlarged GDT boundary.
        for (logic [2:0] rpl = 3'd0; rpl < 3'd4; rpl = rpl + 3'd1) begin
            run_cpl2_segment_case(8'hD8, 16'h0088 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 DS DPL0 writable data RPL matrix");
            run_cpl2_segment_case(8'hD8, 16'h0040 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 DS DPL1 writable data RPL matrix");
            run_cpl2_segment_case(8'hD8, 16'h0048 + rpl, rpl > 3'd2, 8'h0D, 16'h0000,
                                  "CPL2 DS DPL2 writable data RPL matrix");
            run_cpl2_segment_case(8'hD8, 16'h0050 + rpl, 1'b0, 8'h00, 16'h0000,
                                  "CPL2 DS DPL3 writable data RPL matrix");
            run_cpl2_segment_case(8'hD8, 16'h0020 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 DS DPL0 expand-down data RPL matrix");
            run_cpl2_segment_case(8'hD8, 16'h0038 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 DS DPL1 expand-down data RPL matrix");
            run_cpl2_segment_case(8'hD8, 16'h0138 + rpl, rpl > 3'd2, 8'h0D, 16'h0000,
                                  "CPL2 DS DPL2 expand-down data RPL matrix");
            run_cpl2_segment_case(8'hD8, 16'h0140 + rpl, 1'b0, 8'h00, 16'h0000,
                                  "CPL2 DS DPL3 expand-down data RPL matrix");
            run_cpl2_segment_case(8'hD8, 16'h0090 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 DS DPL0 read-only data RPL matrix");
            run_cpl2_segment_case(8'hD8, 16'h0068 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 DS DPL1 read-only data RPL matrix");
            run_cpl2_segment_case(8'hD8, 16'h0128 + rpl, rpl > 3'd2, 8'h0D, 16'h0000,
                                  "CPL2 DS DPL2 read-only data RPL matrix");
            run_cpl2_segment_case(8'hD8, 16'h00B0 + rpl, 1'b0, 8'h00, 16'h0000,
                                  "CPL2 DS DPL3 read-only data RPL matrix");
            run_cpl2_segment_case(8'hD8, 16'h0018 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 DS DPL0 readable code rejection");
            run_cpl2_segment_case(8'hD8, 16'h0008 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 DS DPL1 readable code rejection");
            run_cpl2_segment_case(8'hD8, 16'h00D8 + rpl, rpl > 3'd2, 8'h0D, 16'h0000,
                                  "CPL2 DS DPL2 readable code RPL matrix");
            run_cpl2_segment_case(8'hD8, 16'h00A8 + rpl, 1'b0, 8'h00, 16'h0000,
                                  "CPL2 DS DPL3 readable code RPL matrix");
            run_cpl2_segment_case(8'hD8, 16'h0098 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 DS DPL0 non-readable code rejection");
            run_cpl2_segment_case(8'hD8, 16'h0060 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 DS DPL1 non-readable code rejection");
            run_cpl2_segment_case(8'hD8, 16'h00E0 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 DS DPL2 non-readable code rejection");
            run_cpl2_segment_case(8'hD8, 16'h00C0 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 DS DPL3 non-readable code rejection");
            run_cpl2_segment_case(8'hD8, 16'h00A0 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL2 DS DPL0 not-present data matrix");
            run_cpl2_segment_case(8'hD8, 16'h0058 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL2 DS DPL1 not-present data matrix");
            run_cpl2_segment_case(8'hD8, 16'h0130 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL2 DS DPL2 not-present data matrix");
            run_cpl2_segment_case(8'hD8, 16'h00B8 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL2 DS DPL3 not-present data matrix");
            run_cpl2_segment_case(8'hD8, 16'h00E8 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL2 DS DPL1 not-present code matrix");
            run_cpl2_segment_case(8'hD8, 16'h00F8 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL2 DS DPL2 not-present code matrix");
            run_cpl2_segment_case(8'hD8, 16'h00F0 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL2 DS DPL3 not-present code matrix");
            run_cpl2_segment_case(8'hD8, 16'h0148 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 DS GDT-limit overflow matrix");

            run_cpl2_segment_case(8'hC0, 16'h0088 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 ES DPL0 writable data RPL matrix");
            run_cpl2_segment_case(8'hC0, 16'h0040 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 ES DPL1 writable data RPL matrix");
            run_cpl2_segment_case(8'hC0, 16'h0048 + rpl, rpl > 3'd2, 8'h0D, 16'h0000,
                                  "CPL2 ES DPL2 writable data RPL matrix");
            run_cpl2_segment_case(8'hC0, 16'h0050 + rpl, 1'b0, 8'h00, 16'h0000,
                                  "CPL2 ES DPL3 writable data RPL matrix");
            run_cpl2_segment_case(8'hC0, 16'h0020 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 ES DPL0 expand-down data RPL matrix");
            run_cpl2_segment_case(8'hC0, 16'h0038 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 ES DPL1 expand-down data RPL matrix");
            run_cpl2_segment_case(8'hC0, 16'h0138 + rpl, rpl > 3'd2, 8'h0D, 16'h0000,
                                  "CPL2 ES DPL2 expand-down data RPL matrix");
            run_cpl2_segment_case(8'hC0, 16'h0140 + rpl, 1'b0, 8'h00, 16'h0000,
                                  "CPL2 ES DPL3 expand-down data RPL matrix");
            run_cpl2_segment_case(8'hC0, 16'h0090 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 ES DPL0 read-only data RPL matrix");
            run_cpl2_segment_case(8'hC0, 16'h0068 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 ES DPL1 read-only data RPL matrix");
            run_cpl2_segment_case(8'hC0, 16'h0128 + rpl, rpl > 3'd2, 8'h0D, 16'h0000,
                                  "CPL2 ES DPL2 read-only data RPL matrix");
            run_cpl2_segment_case(8'hC0, 16'h00B0 + rpl, 1'b0, 8'h00, 16'h0000,
                                  "CPL2 ES DPL3 read-only data RPL matrix");
            run_cpl2_segment_case(8'hC0, 16'h0018 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 ES DPL0 readable code rejection");
            run_cpl2_segment_case(8'hC0, 16'h0008 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 ES DPL1 readable code rejection");
            run_cpl2_segment_case(8'hC0, 16'h00D8 + rpl, rpl > 3'd2, 8'h0D, 16'h0000,
                                  "CPL2 ES DPL2 readable code RPL matrix");
            run_cpl2_segment_case(8'hC0, 16'h00A8 + rpl, 1'b0, 8'h00, 16'h0000,
                                  "CPL2 ES DPL3 readable code RPL matrix");
            run_cpl2_segment_case(8'hC0, 16'h0098 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 ES DPL0 non-readable code rejection");
            run_cpl2_segment_case(8'hC0, 16'h0060 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 ES DPL1 non-readable code rejection");
            run_cpl2_segment_case(8'hC0, 16'h00E0 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 ES DPL2 non-readable code rejection");
            run_cpl2_segment_case(8'hC0, 16'h00C0 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 ES DPL3 non-readable code rejection");
            run_cpl2_segment_case(8'hC0, 16'h00A0 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL2 ES DPL0 not-present data matrix");
            run_cpl2_segment_case(8'hC0, 16'h0058 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL2 ES DPL1 not-present data matrix");
            run_cpl2_segment_case(8'hC0, 16'h0130 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL2 ES DPL2 not-present data matrix");
            run_cpl2_segment_case(8'hC0, 16'h00B8 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL2 ES DPL3 not-present data matrix");
            run_cpl2_segment_case(8'hC0, 16'h00E8 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL2 ES DPL1 not-present code matrix");
            run_cpl2_segment_case(8'hC0, 16'h00F8 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL2 ES DPL2 not-present code matrix");
            run_cpl2_segment_case(8'hC0, 16'h00F0 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL2 ES DPL3 not-present code matrix");
            run_cpl2_segment_case(8'hC0, 16'h0148 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL2 ES GDT-limit overflow matrix");

            run_cpl2_segment_case(8'hD0, 16'h0088 + rpl, 1'b1, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL0 writable data RPL matrix");
            run_cpl2_segment_case(8'hD0, 16'h0040 + rpl, 1'b1, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL1 writable data RPL matrix");
            run_cpl2_segment_case(8'hD0, 16'h0048 + rpl, rpl != 3'd2, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL2 writable data exact RPL matrix");
            run_cpl2_segment_case(8'hD0, 16'h0050 + rpl, 1'b1, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL3 writable data RPL matrix");
            run_cpl2_segment_case(8'hD0, 16'h0020 + rpl, 1'b1, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL0 expand-down data RPL matrix");
            run_cpl2_segment_case(8'hD0, 16'h0038 + rpl, 1'b1, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL1 expand-down data RPL matrix");
            run_cpl2_segment_case(8'hD0, 16'h0138 + rpl, rpl != 3'd2, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL2 expand-down data exact RPL matrix");
            run_cpl2_segment_case(8'hD0, 16'h0140 + rpl, 1'b1, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL3 expand-down data RPL matrix");
            run_cpl2_segment_case(8'hD0, 16'h0090 + rpl, 1'b1, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL0 read-only data rejection");
            run_cpl2_segment_case(8'hD0, 16'h0068 + rpl, 1'b1, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL1 read-only data rejection");
            run_cpl2_segment_case(8'hD0, 16'h0128 + rpl, 1'b1, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL2 read-only data rejection");
            run_cpl2_segment_case(8'hD0, 16'h00B0 + rpl, 1'b1, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL3 read-only data rejection");
            run_cpl2_segment_case(8'hD0, 16'h0018 + rpl, 1'b1, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL0 readable code rejection");
            run_cpl2_segment_case(8'hD0, 16'h0008 + rpl, 1'b1, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL1 readable code rejection");
            run_cpl2_segment_case(8'hD0, 16'h00D8 + rpl, 1'b1, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL2 readable code rejection");
            run_cpl2_segment_case(8'hD0, 16'h00A8 + rpl, 1'b1, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL3 readable code rejection");
            run_cpl2_segment_case(8'hD0, 16'h0098 + rpl, 1'b1, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL0 non-readable code rejection");
            run_cpl2_segment_case(8'hD0, 16'h0060 + rpl, 1'b1, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL1 non-readable code rejection");
            run_cpl2_segment_case(8'hD0, 16'h00E0 + rpl, 1'b1, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL2 non-readable code rejection");
            run_cpl2_segment_case(8'hD0, 16'h00C0 + rpl, 1'b1, 8'h0D, 16'h004A,
                                  "CPL2 SS DPL3 non-readable code rejection");
            run_cpl2_segment_case(8'hD0, 16'h00A0 + rpl, 1'b1, 8'h0C, 16'h004A,
                                  "CPL2 SS DPL0 not-present data matrix");
            run_cpl2_segment_case(8'hD0, 16'h0058 + rpl, 1'b1, 8'h0C, 16'h004A,
                                  "CPL2 SS DPL1 not-present data matrix");
            run_cpl2_segment_case(8'hD0, 16'h0130 + rpl, 1'b1, 8'h0C, 16'h004A,
                                  "CPL2 SS DPL2 not-present data matrix");
            run_cpl2_segment_case(8'hD0, 16'h00B8 + rpl, 1'b1, 8'h0C, 16'h004A,
                                  "CPL2 SS DPL3 not-present data matrix");
            run_cpl2_segment_case(8'hD0, 16'h0148 + rpl, 1'b1, 8'h0D, 16'h004A,
                                  "CPL2 SS GDT-limit overflow matrix");
        end

        // CPL3 is reached through the CPL1->CPL0 gate followed by an actual
        // outer IRET.  At this level only DPL3 data is usable; SS additionally
        // requires RPL3 and writable data, while not-present descriptors keep
        // their #NP/#SS distinction.
        for (integer rpl = 0; rpl < 4; rpl = rpl + 1) begin
            run_cpl3_segment_case(8'hD8, 16'h0088 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL3 DS DPL0 rejection");
            run_cpl3_segment_case(8'hD8, 16'h0040 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL3 DS DPL1 rejection");
            run_cpl3_segment_case(8'hD8, 16'h0048 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL3 DS DPL2 rejection");
            run_cpl3_segment_case(8'hD8, 16'h0050 + rpl, 1'b0, 8'h00, 16'h0000,
                                  "CPL3 DS DPL3 writable data RPL matrix");
            run_cpl3_segment_case(8'hD8, 16'h0058 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL3 DS DPL1 not-present rejection");
            run_cpl3_segment_case(8'hD8, 16'h00B8 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL3 DS DPL3 not-present selector matrix");
            run_cpl3_segment_case(8'hD8, 16'h0060 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL3 DS non-readable code rejection");
            run_cpl3_segment_case(8'hD8, 16'h00C0 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL3 DS DPL3 non-readable code rejection");
            run_cpl3_segment_case(8'hD8, 16'h0068 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL3 DS lower-DPL read-only data rejection");
            run_cpl3_segment_case(8'hD8, 16'h00B0 + rpl, 1'b0, 8'h00, 16'h0000,
                                  "CPL3 DS DPL3 read-only data RPL matrix");

            run_cpl3_segment_case(8'hC0, 16'h0088 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL3 ES DPL0 rejection");
            run_cpl3_segment_case(8'hC0, 16'h0040 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL3 ES DPL1 rejection");
            run_cpl3_segment_case(8'hC0, 16'h0048 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL3 ES DPL2 rejection");
            run_cpl3_segment_case(8'hC0, 16'h0050 + rpl, 1'b0, 8'h00, 16'h0000,
                                  "CPL3 ES DPL3 writable data RPL matrix");
            run_cpl3_segment_case(8'hC0, 16'h0058 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL3 ES DPL1 not-present rejection");
            run_cpl3_segment_case(8'hC0, 16'h00B8 + rpl, 1'b1, 8'h0B, 16'h0000,
                                  "CPL3 ES DPL3 not-present selector matrix");
            run_cpl3_segment_case(8'hC0, 16'h0060 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL3 ES non-readable code rejection");
            run_cpl3_segment_case(8'hC0, 16'h00C0 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL3 ES DPL3 non-readable code rejection");
            run_cpl3_segment_case(8'hC0, 16'h0068 + rpl, 1'b1, 8'h0D, 16'h0000,
                                  "CPL3 ES lower-DPL read-only data rejection");
            run_cpl3_segment_case(8'hC0, 16'h00B0 + rpl, 1'b0, 8'h00, 16'h0000,
                                  "CPL3 ES DPL3 read-only data RPL matrix");

            run_cpl3_segment_case(8'hD0, 16'h0088 + rpl, 1'b1, 8'h0D, 16'h0053,
                                  "CPL3 SS DPL0 rejection");
            run_cpl3_segment_case(8'hD0, 16'h0040 + rpl, 1'b1, 8'h0D, 16'h0053,
                                  "CPL3 SS DPL1 rejection");
            run_cpl3_segment_case(8'hD0, 16'h0048 + rpl, 1'b1, 8'h0D, 16'h0053,
                                  "CPL3 SS DPL2 rejection");
            run_cpl3_segment_case(8'hD0, 16'h0050 + rpl, rpl != 3, 8'h0D, 16'h0053,
                                  "CPL3 SS DPL3 writable data exact RPL matrix");
            run_cpl3_segment_case(8'hD0, 16'h00B8 + rpl, 1'b1, 8'h0C, 16'h0053,
                                  "CPL3 SS DPL3 not-present selector matrix");
            run_cpl3_segment_case(8'hD0, 16'h00C0 + rpl, 1'b1, 8'h0D, 16'h0053,
                                  "CPL3 SS DPL3 non-readable code rejection");
            run_cpl3_segment_case(8'hD0, 16'h00B0 + rpl, 1'b1, 8'h0D, 16'h0053,
                                  "CPL3 SS DPL3 read-only data rejection");
        end

        // PM2b direct far-CS matrix. Non-conforming code requires DPL=CPL
        // and RPL<=CPL; conforming code requires DPL<=CPL and retains the
        // caller CPL in the visible CS selector. Not-present code is kept in
        // the matrix to verify #NP and atomic CS/cache behavior.
        for (integer rpl = 0; rpl < 4; rpl = rpl + 1) begin
            run_cpl1_far_cs_case(16'h0018 + rpl, 1'b1, 8'h0D, 16'h0009,
                                  "CPL1 direct far jump to DPL0 code rejects");
            run_cpl1_far_cs_case(16'h0008 + rpl, rpl > 1, 8'h0D, 16'h0009,
                                  "CPL1 DPL1 readable code RPL matrix");
            run_cpl1_far_cs_case(16'h0060 + rpl, rpl > 1, 8'h0D, 16'h0061,
                                  "CPL1 DPL1 non-readable code RPL matrix");
            run_cpl1_far_cs_case(16'h00D8 + rpl, 1'b1, 8'h0D, 16'h0009,
                                  "CPL1 DPL2 readable code rejection");
            run_cpl1_far_cs_case(16'h00A8 + rpl, 1'b1, 8'h0D, 16'h0009,
                                  "CPL1 DPL3 readable code rejection");
            run_cpl1_far_cs_case(16'h0098 + rpl, 1'b1, 8'h0D, 16'h0009,
                                  "CPL1 DPL0 non-readable code rejection");
            run_cpl1_far_cs_case(16'h00C0 + rpl, 1'b1, 8'h0D, 16'h0009,
                                  "CPL1 DPL3 non-readable code rejection");
            run_cpl1_far_cs_case(16'h00C8 + rpl, 1'b0, 8'h00, 16'h00C9,
                                  "CPL1 DPL0 conforming code RPL matrix");
            run_cpl1_far_cs_case(16'h00D0 + rpl, 1'b1, 8'h0D, 16'h0009,
                                  "CPL1 DPL3 conforming code rejection");
            run_cpl1_far_cs_case(16'h00E8 + rpl, 1'b1,
                                  rpl > 3'd1 ? 8'h0D : 8'h0B, 16'h0009,
                                  "CPL1 DPL1 not-present code privilege/RPL matrix");
            run_cpl1_far_cs_case(16'h00F8 + rpl, 1'b1, 8'h0D, 16'h0009,
                                  "CPL1 DPL2 not-present code matrix");
            run_cpl1_far_cs_case(16'h00F0 + rpl, 1'b1, 8'h0D, 16'h0009,
                                  "CPL1 DPL3 not-present code matrix");

            run_cpl0_far_cs_case(16'h0018 + rpl, rpl != 0, 8'h0D, 16'h0018,
                                  "CPL0 DPL0 readable code exact RPL matrix");
            run_cpl0_far_cs_case(16'h0098 + rpl, rpl != 0, 8'h0D, 16'h0098,
                                  "CPL0 DPL0 non-readable code exact RPL matrix");
            run_cpl0_far_cs_case(16'h0008 + rpl, 1'b1, 8'h0D, 16'h0018,
                                  "CPL0 DPL1 readable code rejection");
            run_cpl0_far_cs_case(16'h00D8 + rpl, 1'b1, 8'h0D, 16'h0018,
                                  "CPL0 DPL2 readable code rejection");
            run_cpl0_far_cs_case(16'h00A8 + rpl, 1'b1, 8'h0D, 16'h0018,
                                  "CPL0 DPL3 readable code rejection");
            run_cpl0_far_cs_case(16'h00C8 + rpl, 1'b0, 8'h00, 16'h00C8,
                                  "CPL0 DPL0 conforming code RPL matrix");
            run_cpl0_far_cs_case(16'h00D0 + rpl, 1'b1, 8'h0D, 16'h0018,
                                  "CPL0 DPL3 conforming code rejection");
            run_cpl0_far_cs_case(16'h00E8 + rpl, 1'b1, 8'h0D, 16'h0018,
                                  "CPL0 DPL1 not-present code matrix");
            run_cpl0_far_cs_case(16'h00F8 + rpl, 1'b1, 8'h0D, 16'h0018,
                                  "CPL0 DPL2 not-present code matrix");
            run_cpl0_far_cs_case(16'h00F0 + rpl, 1'b1, 8'h0D, 16'h0018,
                                  "CPL0 DPL3 not-present code matrix");

            run_cpl3_far_cs_case(16'h00A8 + rpl, 1'b0, 8'h00, 16'h00AB,
                                  "CPL3 DPL3 readable code RPL matrix");
            run_cpl3_far_cs_case(16'h00C0 + rpl, 1'b0, 8'h00, 16'h00C3,
                                  "CPL3 DPL3 non-readable code RPL matrix");
            run_cpl3_far_cs_case(16'h0018 + rpl, 1'b1, 8'h0D, 16'h00AB,
                                  "CPL3 DPL0 readable code rejection");
            run_cpl3_far_cs_case(16'h0008 + rpl, 1'b1, 8'h0D, 16'h00AB,
                                  "CPL3 DPL1 readable code rejection");
            run_cpl3_far_cs_case(16'h00D8 + rpl, 1'b1, 8'h0D, 16'h00AB,
                                  "CPL3 DPL2 readable code rejection");
            run_cpl3_far_cs_case(16'h0098 + rpl, 1'b1, 8'h0D, 16'h00AB,
                                  "CPL3 DPL0 non-readable code rejection");
            run_cpl3_far_cs_case(16'h00C8 + rpl, 1'b0, 8'h00, 16'h00CB,
                                  "CPL3 DPL0 conforming code RPL matrix");
            run_cpl3_far_cs_case(16'h00D0 + rpl, 1'b0, 8'h00, 16'h00D3,
                                  "CPL3 DPL3 conforming code RPL matrix");
            run_cpl3_far_cs_case(16'h00E8 + rpl, 1'b1, 8'h0D, 16'h00AB,
                                  "CPL3 DPL1 not-present code matrix");
            run_cpl3_far_cs_case(16'h00F8 + rpl, 1'b1, 8'h0D, 16'h00AB,
                                  "CPL3 DPL2 not-present code matrix");
            run_cpl3_far_cs_case(16'h00F0 + rpl, 1'b1, 8'h0B, 16'h00AB,
                                  "CPL3 DPL3 not-present code matrix");
        end

        // The same direct far-CS rules are exercised at CPL2 after a real
        // outer IRET. Non-conforming DPL2 code is valid only for RPL0..RPL2;
        // conforming DPL0 code retains the CPL2 visible selector RPL. The
        // matrix also keeps code class, presence and GDT-limit failures
        // separate from the valid transfers.
        for (logic [2:0] cpl2_rpl = 3'd0; cpl2_rpl < 3'd4; cpl2_rpl = cpl2_rpl + 3'd1) begin
            run_cpl2_far_cs_case(16'h0018 + cpl2_rpl, 1'b1, 8'h0D, 16'h00DA,
                                 "CPL2 DPL0 readable code rejection");
            run_cpl2_far_cs_case(16'h0008 + cpl2_rpl, 1'b1, 8'h0D, 16'h00DA,
                                 "CPL2 DPL1 readable code rejection");
            run_cpl2_far_cs_case(16'h00D8 + cpl2_rpl, cpl2_rpl > 3'd2, 8'h0D, 16'h00DA,
                                 "CPL2 DPL2 readable code RPL matrix");
            run_cpl2_far_cs_case(16'h00A8 + cpl2_rpl, 1'b1, 8'h0D, 16'h00DA,
                                 "CPL2 DPL3 readable code rejection");
            run_cpl2_far_cs_case(16'h0098 + cpl2_rpl, 1'b1, 8'h0D, 16'h00DA,
                                 "CPL2 DPL0 non-readable code rejection");
            run_cpl2_far_cs_case(16'h0060 + cpl2_rpl, 1'b1, 8'h0D, 16'h00DA,
                                 "CPL2 DPL1 non-readable code rejection");
            run_cpl2_far_cs_case(16'h00E0 + cpl2_rpl, cpl2_rpl > 3'd2, 8'h0D, 16'h00E2,
                                 "CPL2 DPL2 non-readable code RPL matrix");
            run_cpl2_far_cs_case(16'h00C0 + cpl2_rpl, 1'b1, 8'h0D, 16'h00DA,
                                 "CPL2 DPL3 non-readable code rejection");
            run_cpl2_far_cs_case(16'h00C8 + cpl2_rpl, 1'b0, 8'h00, 16'h00CA,
                                 "CPL2 DPL0 conforming code RPL matrix");
            run_cpl2_far_cs_case(16'h00D0 + cpl2_rpl, 1'b1, 8'h0D, 16'h00DA,
                                 "CPL2 DPL3 conforming code rejection");
            run_cpl2_far_cs_case(16'h00E8 + cpl2_rpl, 1'b1, 8'h0D, 16'h00DA,
                                 "CPL2 DPL1 not-present code matrix");
            run_cpl2_far_cs_case(16'h00F8 + cpl2_rpl, 1'b1, cpl2_rpl == 3'd3 ? 8'h0D : 8'h0B, 16'h00DA,
                                 "CPL2 DPL2 not-present code matrix");
            run_cpl2_far_cs_case(16'h00F0 + cpl2_rpl, 1'b1, 8'h0D, 16'h00DA,
                                 "CPL2 DPL3 not-present code matrix");
            run_cpl2_far_cs_case(16'h0148 + cpl2_rpl, 1'b1, 8'h0D, 16'h00DA,
                                 "CPL2 direct far-CS GDT-limit matrix");
        end

        // PM3 software-event matrix: same-level CPL0/CPL3 delivery, outer
        // CPL1 delivery, software DPL rejection, not-present gate/target and
        // IDTR limit preflight.
        run_cpl0_event_case(8'h22, 1'b0, 8'h00, 16'h2222,
                            "CPL0 software INT enters a DPL0 same-level gate");
        run_cpl1_event_case(8'h23, 1'b0, 8'h00, 16'h2323,
                            "CPL1 software INT enters a DPL1 outer gate");
        run_cpl1_event_case(8'h22, 1'b1, 8'h0D, 16'h0000,
                            "CPL1 software INT below gate DPL raises #GP");
        run_cpl3_event_case(8'h24, 1'b0, 8'h00, 16'h2424,
                            "CPL3 software INT enters a DPL3 same-level gate");
        run_cpl3_event_case(8'h23, 1'b1, 8'h0D, 16'h0000,
                            "CPL3 software INT below gate DPL raises #GP");
        run_cpl3_event_case(8'h25, 1'b1, 8'h0B, 16'h0000,
                            "CPL3 software INT on a not-present gate raises #NP");
        run_cpl3_event_case(8'h26, 1'b1, 8'h0B, 16'h0000,
                            "CPL3 software INT on a not-present target raises #NP");
        run_cpl3_event_case(8'h2F, 1'b1, 8'h0D, 16'h0000,
                            "CPL3 software INT beyond IDTR limit raises #GP");

        // PM3 target privilege/RPL matrix. The event target selector keeps
        // the descriptor index fixed while RPL varies, so successful cases
        // also verify the architectural CS-RPL normalization rules.
        for (integer rpl = 0; rpl < 4; rpl = rpl + 1) begin
            run_cpl0_event_matrix_case(16'h0018 + rpl, 8'h86, 16'h0700,
                                       16'h0018, rpl != 0, 8'h0D,
                                       16'hC000 + rpl,
                                       "CPL0 DPL0 event target RPL matrix");

            run_cpl1_event_matrix_case(16'h0018 + rpl, 8'hA6, 16'h0700,
                                       16'h0018, rpl != 0, 8'h0D,
                                       16'hC100 + rpl,
                                       "CPL1 outer DPL0 event target RPL matrix");
            run_cpl1_event_matrix_case(16'h0008 + rpl, 8'hA6, 16'h0700,
                                       16'h0009, rpl > 1, 8'h0D,
                                       16'hC110 + rpl,
                                       "CPL1 same-level DPL1 event target RPL matrix");
            run_cpl1_event_matrix_case(16'h00D8 + rpl, 8'hA6, 16'h0700,
                                       16'h00DB, 1'b1, 8'h0D,
                                       16'hC120 + rpl,
                                       "CPL1 DPL2 event target rejection matrix");
            run_cpl1_event_matrix_case(16'h00A8 + rpl, 8'hA6, 16'h0700,
                                       16'h00AB, 1'b1, 8'h0D,
                                       16'hC130 + rpl,
                                       "CPL1 DPL3 event target rejection matrix");

            run_cpl3_event_matrix_case(16'h0018 + rpl, 8'hE6, 16'h0700,
                                       16'h0018, rpl != 0, 8'h0D,
                                       16'hC300 + rpl,
                                       "CPL3 outer DPL0 event target RPL matrix");
            run_cpl3_event_matrix_case(16'h0008 + rpl, 8'hE6, 16'h0700,
                                       16'h0009, rpl != 1, 8'h0D,
                                       16'hC310 + rpl,
                                       "CPL3 outer DPL1 event target RPL matrix");
            run_cpl3_event_matrix_case(16'h00D8 + rpl, 8'hE6, 16'h0700,
                                       16'h00DA, rpl != 2, 8'h0D,
                                       16'hC320 + rpl,
                                       "CPL3 outer DPL2 event target RPL matrix");
            run_cpl3_event_matrix_case(16'h00A8 + rpl, 8'hE6, 16'h0700,
                                       16'h00AB, 1'b0, 8'h00,
                                       16'hC330 + rpl,
                                       "CPL3 same-level DPL3 event target RPL matrix");
        end

        // PM3 CPL2 target privilege/RPL matrix. The DPL0 and DPL1 targets
        // exercise real TSS stack descents; DPL2 is same-level, DPL3 is an
        // invalid outward privilege, and conforming DPL0 code retains CPL2.
        for (logic [2:0] cpl2_rpl = 3'd0; cpl2_rpl < 3'd4; cpl2_rpl = cpl2_rpl + 3'd1) begin
            run_cpl2_event_matrix_case(16'h0018 + cpl2_rpl, 8'hC6, 16'h0700,
                                       16'h0018, cpl2_rpl != 3'd0, 8'h0D,
                                       16'hC200 + cpl2_rpl,
                                       "CPL2 outer DPL0 event target RPL matrix");
            run_cpl2_event_matrix_case(16'h0008 + cpl2_rpl, 8'hC6, 16'h0700,
                                       16'h0009, cpl2_rpl != 3'd1, 8'h0D,
                                       16'hC210 + cpl2_rpl,
                                       "CPL2 outer DPL1 event target RPL matrix");
            run_cpl2_event_matrix_case(16'h00D8 + cpl2_rpl, 8'hC6, 16'h0700,
                                       16'h00DA, cpl2_rpl > 3'd2, 8'h0D,
                                       16'hC220 + cpl2_rpl,
                                       "CPL2 same-level DPL2 event target RPL matrix");
            run_cpl2_event_matrix_case(16'h00A8 + cpl2_rpl, 8'hC6, 16'h0700,
                                       16'h00DA, 1'b1, 8'h0D,
                                       16'hC230 + cpl2_rpl,
                                       "CPL2 DPL3 event target rejection matrix");
            run_cpl2_event_matrix_case(16'h00E0 + cpl2_rpl, 8'hC6, 16'h0700,
                                       16'h00E2, cpl2_rpl > 3'd2, 8'h0D,
                                       16'hC240 + cpl2_rpl,
                                       "CPL2 non-readable DPL2 event target RPL matrix");
            run_cpl2_event_matrix_case(16'h00C8 + cpl2_rpl, 8'hC6, 16'h0700,
                                       16'h00CA, 1'b0, 8'h00,
                                       16'hC250 + cpl2_rpl,
                                       "CPL2 conforming DPL0 event target RPL matrix");
        end

        // PM3 gate DPL/type/presence matrix with a valid same-level target.
        run_cpl0_event_matrix_case(16'h0018, 8'h86, 16'h0700, 16'h0018,
                                   1'b0, 8'h00, 16'hC400,
                                   "CPL0 interrupt gate DPL0 is accepted");
        run_cpl0_event_matrix_case(16'h0018, 8'hA6, 16'h0700, 16'h0018,
                                   1'b0, 8'h00, 16'hC401,
                                   "CPL0 interrupt gate DPL1 is accepted");
        run_cpl0_event_matrix_case(16'h0018, 8'hC6, 16'h0700, 16'h0018,
                                   1'b0, 8'h00, 16'hC402,
                                   "CPL0 interrupt gate DPL2 is accepted");
        run_cpl0_event_matrix_case(16'h0018, 8'hE7, 16'h0700, 16'h0018,
                                   1'b0, 8'h00, 16'hC403,
                                   "CPL0 trap gate DPL3 is accepted");

        run_cpl1_event_matrix_case(16'h0009, 8'h86, 16'h0700, 16'h0009,
                                   1'b1, 8'h0D, 16'hC410,
                                   "CPL1 software INT rejects a DPL0 gate");
        run_cpl1_event_matrix_case(16'h0009, 8'hA6, 16'h0700, 16'h0009,
                                   1'b0, 8'h00, 16'hC411,
                                   "CPL1 interrupt gate DPL1 is accepted");
        run_cpl1_event_matrix_case(16'h0009, 8'hC7, 16'h0700, 16'h0009,
                                   1'b0, 8'h00, 16'hC412,
                                   "CPL1 trap gate DPL2 is accepted");
        run_cpl1_event_matrix_case(16'h0009, 8'hE6, 16'h0700, 16'h0009,
                                   1'b0, 8'h00, 16'hC413,
                                   "CPL1 interrupt gate DPL3 is accepted");

        run_cpl2_event_matrix_case(16'h00DA, 8'h86, 16'h0700, 16'h00DA,
                                   1'b1, 8'h0D, 16'hC420,
                                   "CPL2 software INT rejects a DPL0 gate");
        run_cpl2_event_matrix_case(16'h00DA, 8'hA6, 16'h0700, 16'h00DA,
                                   1'b1, 8'h0D, 16'hC421,
                                   "CPL2 software INT rejects a DPL1 gate");
        run_cpl2_event_matrix_case(16'h00DA, 8'hC6, 16'h0700, 16'h00DA,
                                   1'b0, 8'h00, 16'hC422,
                                   "CPL2 interrupt gate DPL2 is accepted");
        run_cpl2_event_matrix_case(16'h00DA, 8'hC7, 16'h0700, 16'h00DA,
                                   1'b0, 8'h00, 16'hC423,
                                   "CPL2 trap gate DPL2 is accepted");
        run_cpl2_event_matrix_case(16'h00DA, 8'hE6, 16'h0700, 16'h00DA,
                                   1'b0, 8'h00, 16'hC424,
                                   "CPL2 interrupt gate DPL3 is accepted");
        run_cpl2_event_matrix_case(16'h00DA, 8'h46, 16'h0700, 16'h00DA,
                                   1'b1, 8'h0B, 16'hC425,
                                   "CPL2 not-present event gate raises #NP");
        run_cpl2_event_matrix_case(16'h00DA, 8'hC4, 16'h0700, 16'h00DA,
                                   1'b1, 8'h0D, 16'hC426,
                                   "CPL2 reserved event gate type raises #GP");
        run_cpl2_event_matrix_case(16'h004A, 8'hC6, 16'h0700, 16'h00DA,
                                   1'b1, 8'h0D, 16'hC427,
                                   "CPL2 data target descriptor raises #GP");
        run_cpl2_event_matrix_case(16'h00FA, 8'hC6, 16'h0700, 16'h00DA,
                                   1'b1, 8'h0B, 16'hC428,
                                   "CPL2 not-present code target raises #NP");

        // The same-level DPL2 target is present and correctly typed, but its
        // entry IP is exactly one past the descriptor limit.
        memory[16'h04D8] = 8'hFF; memory[16'h04D9] = 8'h06;
        run_cpl2_event_matrix_case(16'h00DA, 8'hC6, 16'h0700, 16'h00DA,
                                   1'b1, 8'h0D, 16'hC429,
                                   "CPL2 target CS limit fault is pre-commit");
        memory[16'h04D8] = 8'hFF; memory[16'h04D9] = 8'hFF;

        run_cpl3_event_matrix_case(16'h00AB, 8'h86, 16'h0700, 16'h00AB,
                                   1'b1, 8'h0D, 16'hC430,
                                   "CPL3 software INT rejects a DPL0 gate");
        run_cpl3_event_matrix_case(16'h00AB, 8'hA6, 16'h0700, 16'h00AB,
                                   1'b1, 8'h0D, 16'hC431,
                                   "CPL3 software INT rejects a DPL1 gate");
        run_cpl3_event_matrix_case(16'h00AB, 8'hC7, 16'h0700, 16'h00AB,
                                   1'b1, 8'h0D, 16'hC432,
                                   "CPL3 software INT rejects a DPL2 gate");
        run_cpl3_event_matrix_case(16'h00AB, 8'hE7, 16'h0700, 16'h00AB,
                                   1'b0, 8'h00, 16'hC433,
                                   "CPL3 trap gate DPL3 is accepted");

        run_cpl3_event_matrix_case(16'h00AB, 8'h66, 16'h0700, 16'h00AB,
                                   1'b1, 8'h0B, 16'hC440,
                                   "CPL3 not-present event gate raises #NP");
        run_cpl3_event_matrix_case(16'h00AB, 8'hE4, 16'h0700, 16'h00AB,
                                   1'b1, 8'h0D, 16'hC441,
                                   "CPL3 reserved event gate type raises #GP");
        run_cpl3_event_matrix_case(16'h00B3, 8'hE6, 16'h0700, 16'h00B3,
                                   1'b1, 8'h0D, 16'hC442,
                                   "CPL3 data target descriptor raises #GP");
        run_cpl3_event_matrix_case(16'h00C3, 8'hE6, 16'h0700, 16'h00C3,
                                   1'b0, 8'h00, 16'hC443,
                                   "CPL3 non-readable code target remains executable");
        run_cpl3_event_matrix_case(16'h00F3, 8'hE6, 16'h0700, 16'h00F3,
                                   1'b1, 8'h0B, 16'hC444,
                                   "CPL3 not-present code target raises #NP");
        run_cpl3_event_matrix_case(16'h00D3, 8'hE6, 16'h0700, 16'h00D3,
                                   1'b0, 8'h00, 16'hC445,
                                   "CPL3 conforming code target is accepted");

        // The target code descriptor is present and correctly typed, but the
        // requested entry IP is exactly one past its limit.
        memory[16'h04A8] = 8'hFF; memory[16'h04A9] = 8'h06;
        run_cpl3_event_matrix_case(16'h00AB, 8'hE6, 16'h0700, 16'h00AB,
                                   1'b1, 8'h0D, 16'hC446,
                                   "CPL3 target CS limit fault is pre-commit");
        memory[16'h04A8] = 8'hFF; memory[16'h04A9] = 8'hFF;

        // PM1 inspection matrix at CPL1. These groups reuse the protected
        // selector fixture's DPL0..DPL3 data/code descriptors and execute all
        // four selector-inspection operations for every RPL. CPL3 requires a
        // separately validated outer-level entry harness and remains pending.
        run_pm1_level_group(2'd1, 16'h0088, 2'd0, 3'd0, 1'b1,
                             "PM1 CPL1 DPL0 writable-data group");
        run_pm1_level_group(2'd1, 16'h0040, 2'd1, 3'd0, 1'b1,
                             "PM1 CPL1 DPL1 writable-data group");
        run_pm1_level_group(2'd1, 16'h0048, 2'd2, 3'd0, 1'b1,
                             "PM1 CPL1 DPL2 writable-data group");
        run_pm1_level_group(2'd1, 16'h0050, 2'd3, 3'd0, 1'b1,
                             "PM1 CPL1 DPL3 writable-data group");
        run_pm1_level_group(2'd1, 16'h0090, 2'd0, 3'd1, 1'b1,
                             "PM1 CPL1 DPL0 read-only-data group");
        run_pm1_level_group(2'd1, 16'h0068, 2'd1, 3'd1, 1'b1,
                             "PM1 CPL1 DPL1 read-only-data group");
        run_pm1_level_group(2'd1, 16'h00B0, 2'd3, 3'd1, 1'b1,
                             "PM1 CPL1 DPL3 read-only-data group");
        run_pm1_level_group(2'd1, 16'h0018, 2'd0, 3'd2, 1'b1,
                             "PM1 CPL1 DPL0 readable-code group");
        run_pm1_level_group(2'd1, 16'h0008, 2'd1, 3'd2, 1'b1,
                             "PM1 CPL1 DPL1 readable-code group");
        run_pm1_level_group(2'd1, 16'h00D8, 2'd2, 3'd2, 1'b1,
                             "PM1 CPL1 DPL2 readable-code group");
        run_pm1_level_group(2'd1, 16'h00A8, 2'd3, 3'd2, 1'b1,
                             "PM1 CPL1 DPL3 readable-code group");
        run_pm1_level_group(2'd1, 16'h0098, 2'd0, 3'd3, 1'b1,
                             "PM1 CPL1 DPL0 non-readable-code group");
        run_pm1_level_group(2'd1, 16'h0060, 2'd1, 3'd3, 1'b1,
                             "PM1 CPL1 DPL1 non-readable-code group");
        run_pm1_level_group(2'd1, 16'h00E0, 2'd2, 3'd3, 1'b1,
                             "PM1 CPL1 DPL2 non-readable-code group");
        run_pm1_level_group(2'd1, 16'h00C0, 2'd3, 3'd3, 1'b1,
                             "PM1 CPL1 DPL3 non-readable-code group");
        run_pm1_level_group(2'd1, 16'h00A0, 2'd0, 3'd0, 1'b0,
                             "PM1 CPL1 DPL0 not-present-data group");
        run_pm1_level_group(2'd1, 16'h0058, 2'd1, 3'd0, 1'b0,
                             "PM1 CPL1 DPL1 not-present-data group");
        run_pm1_level_group(2'd1, 16'h00B8, 2'd3, 3'd0, 1'b0,
                             "PM1 CPL1 DPL3 not-present-data group");
        run_pm1_level_group(2'd1, 16'h00E8, 2'd1, 3'd2, 1'b0,
                             "PM1 CPL1 DPL1 not-present-code group");
        run_pm1_level_group(2'd1, 16'h00F8, 2'd2, 3'd2, 1'b0,
                             "PM1 CPL1 DPL2 not-present-code group");
        run_pm1_level_group(2'd1, 16'h00F0, 2'd3, 3'd2, 1'b0,
                             "PM1 CPL1 DPL3 not-present-code group");
        run_pm1_level_group(2'd1, 16'h0148, 2'd0, 3'd0, 1'b0,
                             "PM1 CPL1 GDT-limit overflow group");

        // PM1 selector-inspection matrix at CPL3. The DPL0..DPL2 groups are
        // retained as negative privilege cases; DPL3 is the valid level for
        // all RPL0..RPL3 selectors after the real outer-level transition.
        run_pm1_cpl3_group(16'h0088, 2'd0, 3'd0, 1'b1,
                           "PM1 CPL3 DPL0 writable-data group");
        run_pm1_cpl3_group(16'h0040, 2'd1, 3'd0, 1'b1,
                           "PM1 CPL3 DPL1 writable-data group");
        run_pm1_cpl3_group(16'h0048, 2'd2, 3'd0, 1'b1,
                           "PM1 CPL3 DPL2 writable-data group");
        run_pm1_cpl3_group(16'h0050, 2'd3, 3'd0, 1'b1,
                           "PM1 CPL3 DPL3 writable-data group");
        run_pm1_cpl3_group(16'h0090, 2'd0, 3'd1, 1'b1,
                           "PM1 CPL3 DPL0 read-only-data group");
        run_pm1_cpl3_group(16'h0068, 2'd1, 3'd1, 1'b1,
                           "PM1 CPL3 DPL1 read-only-data group");
        run_pm1_cpl3_group(16'h00B0, 2'd3, 3'd1, 1'b1,
                           "PM1 CPL3 DPL3 read-only-data group");
        run_pm1_cpl3_group(16'h0018, 2'd0, 3'd2, 1'b1,
                           "PM1 CPL3 DPL0 readable-code group");
        run_pm1_cpl3_group(16'h0008, 2'd1, 3'd2, 1'b1,
                           "PM1 CPL3 DPL1 readable-code group");
        run_pm1_cpl3_group(16'h00D8, 2'd2, 3'd2, 1'b1,
                           "PM1 CPL3 DPL2 readable-code group");
        run_pm1_cpl3_group(16'h00A8, 2'd3, 3'd2, 1'b1,
                           "PM1 CPL3 DPL3 readable-code group");
        run_pm1_cpl3_group(16'h0098, 2'd0, 3'd3, 1'b1,
                           "PM1 CPL3 DPL0 non-readable-code group");
        run_pm1_cpl3_group(16'h0060, 2'd1, 3'd3, 1'b1,
                           "PM1 CPL3 DPL1 non-readable-code group");
        run_pm1_cpl3_group(16'h00E0, 2'd2, 3'd3, 1'b1,
                           "PM1 CPL3 DPL2 non-readable-code group");
        run_pm1_cpl3_group(16'h00C0, 2'd3, 3'd3, 1'b1,
                           "PM1 CPL3 DPL3 non-readable-code group");
        run_pm1_cpl3_group(16'h00A0, 2'd0, 3'd0, 1'b0,
                           "PM1 CPL3 DPL0 not-present-data group");
        run_pm1_cpl3_group(16'h0058, 2'd1, 3'd0, 1'b0,
                           "PM1 CPL3 DPL1 not-present-data group");
        run_pm1_cpl3_group(16'h00B8, 2'd3, 3'd0, 1'b0,
                           "PM1 CPL3 DPL3 not-present-data group");
        run_pm1_cpl3_group(16'h00E8, 2'd1, 3'd2, 1'b0,
                           "PM1 CPL3 DPL1 not-present-code group");
        run_pm1_cpl3_group(16'h00F8, 2'd2, 3'd2, 1'b0,
                           "PM1 CPL3 DPL2 not-present-code group");
        run_pm1_cpl3_group(16'h00F0, 2'd3, 3'd2, 1'b0,
                           "PM1 CPL3 DPL3 not-present-code group");
        run_pm1_cpl3_group(16'h0148, 2'd0, 3'd0, 1'b0,
                           "PM1 CPL3 GDT-limit overflow group");

        // PM1 selector-inspection matrix at CPL2. The real outer-level IRET
        // in each case establishes CPL2 before VERR/VERW/LAR/LSL execute.
        // Include normal and expand-down writable data, read-only data,
        // readable/non-readable code, not-present descriptors and the GDT
        // limit boundary. DPL2 is valid for RPL0..RPL2; DPL3 is valid for
        // every RPL at this caller level.
        run_pm1_cpl2_group(16'h0088, 2'd0, 3'd0, 1'b1,
                           "PM1 CPL2 DPL0 writable-data group");
        run_pm1_cpl2_group(16'h0040, 2'd1, 3'd0, 1'b1,
                           "PM1 CPL2 DPL1 writable-data group");
        run_pm1_cpl2_group(16'h0048, 2'd2, 3'd0, 1'b1,
                           "PM1 CPL2 DPL2 writable-data group");
        run_pm1_cpl2_group(16'h0050, 2'd3, 3'd0, 1'b1,
                           "PM1 CPL2 DPL3 writable-data group");
        run_pm1_cpl2_group(16'h0020, 2'd0, 3'd0, 1'b1,
                           "PM1 CPL2 DPL0 expand-down-data group");
        run_pm1_cpl2_group(16'h0038, 2'd1, 3'd0, 1'b1,
                           "PM1 CPL2 DPL1 expand-down-data group");
        run_pm1_cpl2_group(16'h0138, 2'd2, 3'd0, 1'b1,
                           "PM1 CPL2 DPL2 expand-down-data group");
        run_pm1_cpl2_group(16'h0140, 2'd3, 3'd0, 1'b1,
                           "PM1 CPL2 DPL3 expand-down-data group");
        run_pm1_cpl2_group(16'h0090, 2'd0, 3'd1, 1'b1,
                           "PM1 CPL2 DPL0 read-only-data group");
        run_pm1_cpl2_group(16'h0068, 2'd1, 3'd1, 1'b1,
                           "PM1 CPL2 DPL1 read-only-data group");
        run_pm1_cpl2_group(16'h0128, 2'd2, 3'd1, 1'b1,
                           "PM1 CPL2 DPL2 read-only-data group");
        run_pm1_cpl2_group(16'h00B0, 2'd3, 3'd1, 1'b1,
                           "PM1 CPL2 DPL3 read-only-data group");
        run_pm1_cpl2_group(16'h0018, 2'd0, 3'd2, 1'b1,
                           "PM1 CPL2 DPL0 readable-code group");
        run_pm1_cpl2_group(16'h0008, 2'd1, 3'd2, 1'b1,
                           "PM1 CPL2 DPL1 readable-code group");
        run_pm1_cpl2_group(16'h00D8, 2'd2, 3'd2, 1'b1,
                           "PM1 CPL2 DPL2 readable-code group");
        run_pm1_cpl2_group(16'h00A8, 2'd3, 3'd2, 1'b1,
                           "PM1 CPL2 DPL3 readable-code group");
        run_pm1_cpl2_group(16'h0098, 2'd0, 3'd3, 1'b1,
                           "PM1 CPL2 DPL0 non-readable-code group");
        run_pm1_cpl2_group(16'h0060, 2'd1, 3'd3, 1'b1,
                           "PM1 CPL2 DPL1 non-readable-code group");
        run_pm1_cpl2_group(16'h00E0, 2'd2, 3'd3, 1'b1,
                           "PM1 CPL2 DPL2 non-readable-code group");
        run_pm1_cpl2_group(16'h00C0, 2'd3, 3'd3, 1'b1,
                           "PM1 CPL2 DPL3 non-readable-code group");
        run_pm1_cpl2_group(16'h00A0, 2'd0, 3'd0, 1'b0,
                           "PM1 CPL2 DPL0 not-present-data group");
        run_pm1_cpl2_group(16'h0058, 2'd1, 3'd0, 1'b0,
                           "PM1 CPL2 DPL1 not-present-data group");
        run_pm1_cpl2_group(16'h0130, 2'd2, 3'd0, 1'b0,
                           "PM1 CPL2 DPL2 not-present-data group");
        run_pm1_cpl2_group(16'h00B8, 2'd3, 3'd0, 1'b0,
                           "PM1 CPL2 DPL3 not-present-data group");
        run_pm1_cpl2_group(16'h00E8, 2'd1, 3'd2, 1'b0,
                           "PM1 CPL2 DPL1 not-present-code group");
        run_pm1_cpl2_group(16'h00F8, 2'd2, 3'd2, 1'b0,
                           "PM1 CPL2 DPL2 not-present-code group");
        run_pm1_cpl2_group(16'h00F0, 2'd3, 3'd2, 1'b0,
                           "PM1 CPL2 DPL3 not-present-code group");
        run_pm1_cpl2_group(16'h0148, 2'd0, 3'd0, 1'b0,
                           "PM1 CPL2 GDT-limit overflow group");

        // PM4a same-level call-gate matrix at CPL2. The caller is established
        // by a real outer IRET, so successful cases must keep CPL2 and SS:SP
        // while rejected gates must fault before a same-level return frame.
        for (logic [2:0] cpl2_gate_rpl = 3'd0; cpl2_gate_rpl < 3'd4;
             cpl2_gate_rpl = cpl2_gate_rpl + 3'd1) begin
            run_cpl2_same_level_gate_case(16'h0100 + cpl2_gate_rpl, 8'h84,
                                          16'h00DA, 1'b1, 8'h0D, 16'h00DA,
                                          "CPL2 DPL0 same-level gate rejection matrix");
            run_cpl2_same_level_gate_case(16'h0108 + cpl2_gate_rpl, 8'hA4,
                                          16'h00DA, 1'b1, 8'h0D, 16'h00DA,
                                          "CPL2 DPL1 same-level gate rejection matrix");
            run_cpl2_same_level_gate_case(16'h0110 + cpl2_gate_rpl, 8'hC4,
                                          16'h00DA, cpl2_gate_rpl > 3'd2, 8'h0D,
                                          16'h00DA, "CPL2 DPL2 same-level gate RPL matrix");
            run_cpl2_same_level_gate_case(16'h0118 + cpl2_gate_rpl, 8'hE4,
                                          16'h00DA, 1'b0, 8'h00, 16'h00DA,
                                          "CPL2 DPL3 same-level gate RPL matrix");
            run_cpl2_same_level_gate_case(16'h0120 + cpl2_gate_rpl, 8'h44,
                                          16'h00DA, 1'b1, 8'h0B, 16'h00DA,
                                          "CPL2 not-present same-level gate matrix");
            run_cpl2_same_level_gate_case(16'h0148 + cpl2_gate_rpl, 8'hC4,
                                          16'h00DA, 1'b1, 8'h0D, 16'h00DA,
                                          "CPL2 same-level gate GDT-limit matrix");
        end
        run_cpl2_same_level_gate_case(16'h0110, 8'hC4, 16'h00E2, 1'b0, 8'h00,
                                      16'h00E2, "CPL2 same-level non-readable target is accepted");
        run_cpl2_same_level_gate_case(16'h0110, 8'hC4, 16'h00CA, 1'b0, 8'h00,
                                      16'h00CA, "CPL2 same-level conforming target is accepted");
        run_cpl2_same_level_gate_case(16'h0110, 8'hC4, 16'h004A, 1'b1, 8'h0D,
                                      16'h00DA, "CPL2 same-level data target is rejected");
        run_cpl2_same_level_gate_case(16'h0110, 8'hC4, 16'h00FA, 1'b1, 8'h0B,
                                      16'h00DA, "CPL2 same-level not-present target is rejected");

        // Restore the DPL0..DPL3 and not-present inter-level gates used by
        // the PM4b matrix below.
        write_cpl2_gate_descriptor(16'h0100, 8'h84, 16'h0018);
        write_cpl2_gate_descriptor(16'h0108, 8'hA4, 16'h0018);
        write_cpl2_gate_descriptor(16'h0110, 8'hC4, 16'h0018);
        write_cpl2_gate_descriptor(16'h0118, 8'hE4, 16'h0018);
        write_cpl2_gate_descriptor(16'h0120, 8'h44, 16'h0018);

        // PM4 call-gate privilege/presence matrix. Every gate targets the
        // same ring-0 entry point, so the only variables are caller CPL,
        // gate DPL, selector RPL, presence and the GDT table boundary.
        for (integer rpl = 0; rpl < 4; rpl = rpl + 1) begin
            run_cpl0_call_gate_case(16'h0100 + rpl, rpl != 0, 8'h0D,
                                    "CPL0 DPL0 call gate exact RPL matrix");
            run_cpl0_call_gate_case(16'h0108 + rpl, rpl > 1, 8'h0D,
                                    "CPL0 DPL1 call gate RPL matrix");
            run_cpl0_call_gate_case(16'h0110 + rpl, rpl > 2, 8'h0D,
                                    "CPL0 DPL2 call gate RPL matrix");
            run_cpl0_call_gate_case(16'h0118 + rpl, 1'b0, 8'h00,
                                    "CPL0 DPL3 call gate RPL matrix");
            run_cpl0_call_gate_case(16'h0120 + rpl, 1'b1, 8'h0B,
                                    "CPL0 not-present call gate matrix");
            run_cpl0_call_gate_case(16'h0148 + rpl, 1'b1, 8'h0D,
                                    "CPL0 call gate GDT-limit matrix");

            run_cpl1_call_gate_case(16'h0100 + rpl, 1'b1, 8'h0D,
                                    "CPL1 DPL0 call gate rejection matrix");
            run_cpl1_call_gate_case(16'h0108 + rpl, rpl > 1, 8'h0D,
                                    "CPL1 DPL1 call gate RPL matrix");
            run_cpl1_call_gate_case(16'h0110 + rpl, rpl > 2, 8'h0D,
                                    "CPL1 DPL2 call gate RPL matrix");
            run_cpl1_call_gate_case(16'h0118 + rpl, 1'b0, 8'h00,
                                    "CPL1 DPL3 call gate RPL matrix");
            run_cpl1_call_gate_case(16'h0120 + rpl, 1'b1, 8'h0B,
                                    "CPL1 not-present call gate matrix");
            run_cpl1_call_gate_case(16'h0148 + rpl, 1'b1, 8'h0D,
                                    "CPL1 call gate GDT-limit matrix");

            run_cpl3_call_gate_case(16'h0100 + rpl, 1'b1, 8'h0D,
                                    "CPL3 DPL0 call gate rejection matrix");
            run_cpl3_call_gate_case(16'h0108 + rpl, 1'b1, 8'h0D,
                                    "CPL3 DPL1 call gate rejection matrix");
            run_cpl3_call_gate_case(16'h0110 + rpl, 1'b1, 8'h0D,
                                    "CPL3 DPL2 call gate rejection matrix");
            run_cpl3_call_gate_case(16'h0118 + rpl, 1'b0, 8'h00,
                                    "CPL3 DPL3 call gate RPL matrix");
            run_cpl3_call_gate_case(16'h0120 + rpl, 1'b1, 8'h0B,
                                    "CPL3 not-present call gate matrix");
            run_cpl3_call_gate_case(16'h0148 + rpl, 1'b1, 8'h0D,
                                    "CPL3 call gate GDT-limit matrix");
        end

        // CPL2 enters through a real outer IRET, then exercises the same
        // gate privilege matrix from ring 2.  Keep the loop explicitly
        // three bits wide so the RPL=3 case remains representable in strict
        // Keep the loop width explicit for strict simulator checking.
        for (logic [2:0] cpl2_rpl = 3'd0; cpl2_rpl < 3'd4;
             cpl2_rpl = cpl2_rpl + 3'd1) begin
            run_cpl2_call_gate_case(16'h0100 + cpl2_rpl, 1'b1, 8'h0D,
                                    "CPL2 DPL0 call gate rejection matrix");
            run_cpl2_call_gate_case(16'h0108 + cpl2_rpl, 1'b1, 8'h0D,
                                    "CPL2 DPL1 call gate rejection matrix");
            run_cpl2_call_gate_case(16'h0110 + cpl2_rpl, cpl2_rpl > 3'd2,
                                    8'h0D, "CPL2 DPL2 call gate RPL matrix");
            run_cpl2_call_gate_case(16'h0118 + cpl2_rpl, 1'b0, 8'h00,
                                    "CPL2 DPL3 call gate RPL matrix");
            run_cpl2_call_gate_case(16'h0120 + cpl2_rpl, 1'b1, 8'h0B,
                                    "CPL2 not-present call gate matrix");
            run_cpl2_call_gate_case(16'h0148 + cpl2_rpl, 1'b1, 8'h0D,
                                    "CPL2 call gate GDT-limit matrix");
        end

        // Data permissions and complete-word limit checks are exercised after
        // the selector matrix so descriptor loading and operand access cannot
        // accidentally share a single expected result.
        run_word_read_case(16'h0069, 16'h0200, 16'h0200, 16'h5678, 1'b0, 8'h00,
                           "CPL1 read-only DS permits reads");
        run_word_write_case(16'h0069, 16'h0200, 16'h0200, 1'b1, 8'h0D,
                            "CPL1 read-only DS rejects writes atomically");
        run_word_write_case(16'h0041, 16'h0200, 16'h0200, 1'b0, 8'h00,
                            "CPL1 writable DPL1 DS permits writes");
        run_word_read_case(16'h0071, 16'h000F, 16'h100F, 16'h5678, 1'b0, 8'h00,
                           "normal data word ending exactly at limit is accepted");
        run_word_read_case(16'h0071, 16'h0010, 16'h1010, 16'h0000, 1'b1, 8'h0D,
                           "normal data word crossing limit is rejected");
        run_word_read_case(16'h0079, 16'hE001, 16'hF001, 16'h5678, 1'b0, 8'h00,
                           "expand-down word above lower bound is accepted");
        run_word_read_case(16'h0079, 16'hE000, 16'hF000, 16'h0000, 1'b1, 8'h0D,
                           "expand-down word at lower bound is rejected");
        run_word_read_case(16'h0079, 16'hFFFF, 16'h0FFF, 16'h0000, 1'b1, 8'h0D,
                           "expand-down word wrapping at FFFF is rejected");

        $display("PROTECTED_EXPAND_DOWN PASS: %0d checks, READY stalls=%0d", checks, cycles);
        $finish;
    end
    /* verilator lint_on WIDTHTRUNC */
    /* verilator lint_on WIDTHEXPAND */
endmodule
