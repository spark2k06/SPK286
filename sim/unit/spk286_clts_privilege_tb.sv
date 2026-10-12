// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module spk286_clts_privilege_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer cycles = 0;
    integer checks = 0;

    spk286 dut (.*);

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

    task automatic wait_state(input logic [15:0] expected_cs, input logic [15:0] expected_ip);
        integer deadline;
        begin
            deadline = 0;
            while ((debug_cs != expected_cs || debug_ip != expected_ip) && deadline < 1500) begin
                tick();
                deadline = deadline + 1;
            end
            if (debug_cs != expected_cs || debug_ip != expected_ip)
                $fatal(1, "CLTS privilege setup did not reach %h:%h; got %h:%h", expected_cs, expected_ip, debug_cs, debug_ip);
        end
    endtask

    task automatic wait_fault(input logic [7:0] expected_vector);
        integer deadline;
        begin
            deadline = 0;
            while ((!event_completed || debug_event_vector != expected_vector) && deadline < 1000) begin
                tick();
                deadline = deadline + 1;
            end
            if (!event_completed || debug_event_vector != expected_vector)
                $fatal(1, "CLTS fault did not complete; vector=%h expected=%h CS:IP=%h:%h", debug_event_vector, expected_vector, debug_cs, debug_ip);
        end
    endtask

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "%s: CS:IP=%h:%h MSW=%h", message, debug_cs, debug_ip, debug_protected_msw);
        end
    endtask

    initial begin
        for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;

        // Load a five-entry GDT and an IDT large enough for vectors 6 and 13.
        memory[16'h0000] = 8'h0F; memory[16'h0001] = 8'h01; memory[16'h0002] = 8'h16;
        memory[16'h0003] = 8'h00; memory[16'h0004] = 8'h03; // LGDT [0300]
        memory[16'h0005] = 8'h0F; memory[16'h0006] = 8'h01; memory[16'h0007] = 8'h1E;
        memory[16'h0008] = 8'h10; memory[16'h0009] = 8'h03; // LIDT [0310]
        memory[16'h000A] = 8'hB8; memory[16'h000B] = 8'h09; memory[16'h000C] = 8'h00;
        memory[16'h000D] = 8'h0F; memory[16'h000E] = 8'h01; memory[16'h000F] = 8'hF0; // LMSW PE+TS
        memory[16'h0010] = 8'hEA; memory[16'h0011] = 8'h80; memory[16'h0012] = 8'h00;
        memory[16'h0013] = 8'h18; memory[16'h0014] = 8'h00; // JMP 0018:0080

        // Ring-0 setup builds an outer-level IRET frame for ring 1.
        memory[16'h0080] = 8'hB8; memory[16'h0081] = 8'h20; memory[16'h0082] = 8'h00;
        memory[16'h0083] = 8'h8E; memory[16'h0084] = 8'hD0; // MOV SS,0020
        memory[16'h0085] = 8'hBC; memory[16'h0086] = 8'h00; memory[16'h0087] = 8'hF0; // MOV SP,F000
        memory[16'h0088] = 8'hB8; memory[16'h0089] = 8'h11; memory[16'h008A] = 8'h00;
        memory[16'h008B] = 8'h50; // outer SS=0011
        memory[16'h008C] = 8'hB8; memory[16'h008D] = 8'h00; memory[16'h008E] = 8'hF0;
        memory[16'h008F] = 8'h50; // outer SP=F000
        memory[16'h0090] = 8'hB8; memory[16'h0091] = 8'h02; memory[16'h0092] = 8'h02;
        memory[16'h0093] = 8'h50; // FLAGS=0202
        memory[16'h0094] = 8'hB8; memory[16'h0095] = 8'h09; memory[16'h0096] = 8'h00;
        memory[16'h0097] = 8'h50; // outer CS=0009
        memory[16'h0098] = 8'hB8; memory[16'h0099] = 8'h00; memory[16'h009A] = 8'h01;
        memory[16'h009B] = 8'h50; // outer IP=0100
        memory[16'h009C] = 8'hCF; // IRET

        memory[16'h0100] = 8'h0F; memory[16'h0101] = 8'h06; // CLTS at CPL 1 -> #GP
        memory[16'h0200] = 8'hF4; // common same-level fault handler

        // GDTR: limit 0037, base 0400.
        memory[16'h0300] = 8'h37; memory[16'h0301] = 8'h00;
        memory[16'h0302] = 8'h00; memory[16'h0303] = 8'h04; memory[16'h0304] = 8'h00;
        // IDTR: limit 006F, base 0800.
        memory[16'h0310] = 8'h6F; memory[16'h0311] = 8'h00;
        memory[16'h0312] = 8'h00; memory[16'h0313] = 8'h08; memory[16'h0314] = 8'h00;

        // GDT index 1/2 are DPL1 code/data; index 3/4 are DPL0 code/data.
        memory[16'h0408] = 8'hFF; memory[16'h0409] = 8'hFF; memory[16'h040A] = 8'h00; memory[16'h040B] = 8'h00;
        memory[16'h040C] = 8'h00; memory[16'h040D] = 8'hBA; memory[16'h040E] = 8'h00; memory[16'h040F] = 8'h00;
        memory[16'h0410] = 8'hFF; memory[16'h0411] = 8'hFF; memory[16'h0412] = 8'h00; memory[16'h0413] = 8'h00;
        memory[16'h0414] = 8'h00; memory[16'h0415] = 8'hB2; memory[16'h0416] = 8'h00; memory[16'h0417] = 8'h00;
        memory[16'h0418] = 8'hFF; memory[16'h0419] = 8'hFF; memory[16'h041A] = 8'h00; memory[16'h041B] = 8'h00;
        memory[16'h041C] = 8'h00; memory[16'h041D] = 8'h9A; memory[16'h041E] = 8'h00; memory[16'h041F] = 8'h00;
        memory[16'h0420] = 8'hFF; memory[16'h0421] = 8'hFF; memory[16'h0422] = 8'h00; memory[16'h0423] = 8'h00;
        memory[16'h0424] = 8'h00; memory[16'h0425] = 8'h92; memory[16'h0426] = 8'h00; memory[16'h0427] = 8'h00;
        // DPL3 code/data descriptors used by the same-level privilege matrix.
        memory[16'h0428] = 8'hFF; memory[16'h0429] = 8'hFF; memory[16'h042A] = 8'h00; memory[16'h042B] = 8'h00;
        memory[16'h042C] = 8'h00; memory[16'h042D] = 8'hFA; memory[16'h042E] = 8'h00; memory[16'h042F] = 8'h00;
        memory[16'h0430] = 8'hFF; memory[16'h0431] = 8'hFF; memory[16'h0432] = 8'h00; memory[16'h0433] = 8'h00;
        memory[16'h0434] = 8'h00; memory[16'h0435] = 8'hF2; memory[16'h0436] = 8'h00; memory[16'h0437] = 8'h00;

        // Same-level interrupt gates for #UD (6) and #GP (13), both to 0009:0200.
        memory[16'h0830] = 8'h00; memory[16'h0831] = 8'h02; memory[16'h0832] = 8'h09; memory[16'h0833] = 8'h00;
        memory[16'h0834] = 8'h00; memory[16'h0835] = 8'h86; memory[16'h0836] = 8'h00; memory[16'h0837] = 8'h00;
        memory[16'h0868] = 8'h00; memory[16'h0869] = 8'h02; memory[16'h086A] = 8'h09; memory[16'h086B] = 8'h00;
        memory[16'h086C] = 8'h00; memory[16'h086D] = 8'h86; memory[16'h086E] = 8'h00; memory[16'h086F] = 8'h00;

        reset = 1'b1;
        execute_enable = 1'b0;
        ready = 1'b0;
        tick();
        reset = 1'b0;
        execute_enable = 1'b1;
        far_restart(16'h0000, 16'h0000);
        wait_state(16'h0009, 16'h0100);
        wait_fault(8'd13);
        check(debug_cs == 16'h0009 && debug_protected_msw[0] && debug_protected_msw[3],
              "CPL1 CLTS raises #GP and preserves protected mode plus TS");

        // The protected system loads that mutate privileged state must fault
        // before their descriptor/table or MSW commit paths are entered.
        memory[16'h0100] = 8'h0F; memory[16'h0101] = 8'h01; memory[16'h0102] = 8'h16;
        memory[16'h0103] = 8'h00; memory[16'h0104] = 8'h03; // LGDT [0300]
        far_restart(16'h0009, 16'h0100);
        wait_fault(8'd13);
        check(debug_gdtr_base == 24'h000400 && debug_gdtr_limit == 16'h0037,
              "CPL1 LGDT raises #GP without changing GDTR");

        memory[16'h0100] = 8'h0F; memory[16'h0101] = 8'h01; memory[16'h0102] = 8'h1E;
        memory[16'h0103] = 8'h10; memory[16'h0104] = 8'h03; // LIDT [0310]
        far_restart(16'h0009, 16'h0100);
        wait_fault(8'd13);
        check(debug_idtr_base == 24'h000800 && debug_idtr_limit == 16'h006F,
              "CPL1 LIDT raises #GP without changing IDTR");

        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h01; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h0F; memory[16'h0104] = 8'h01; memory[16'h0105] = 8'hF0; // LMSW AX
        far_restart(16'h0009, 16'h0100);
        wait_fault(8'd13);
        check(debug_protected_msw[0] && debug_protected_msw[3],
              "CPL1 LMSW raises #GP without changing the MSW");

        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h08; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h0F; memory[16'h0104] = 8'h00; memory[16'h0105] = 8'hD0; // LLDT AX
        far_restart(16'h0009, 16'h0100);
        wait_fault(8'd13);
        check(debug_ldtr_selector == 16'h0000,
              "CPL1 LLDT raises #GP without changing LDTR");

        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h10; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h0F; memory[16'h0104] = 8'h00; memory[16'h0105] = 8'hD8; // LTR AX
        far_restart(16'h0009, 16'h0100);
        wait_fault(8'd13);
        check(debug_tr_selector == 16'h0000,
              "CPL1 LTR raises #GP without changing TR");

        memory[16'h0100] = 8'hF0; memory[16'h0101] = 8'h0F; memory[16'h0102] = 8'h06;
        far_restart(16'h0009, 16'h0100);
        wait_fault(8'd6);
        check(debug_cs == 16'h0009 && debug_protected_msw[0] && debug_protected_msw[3],
              "LOCK CLTS raises #UD at CPL1 without changing MSW");

        // Repeat the privileged system-instruction matrix at CPL3. The setup frame and
        // exception gates are changed to DPL3, so every fault is same-level
        // and no untested TSS transition can hide a partial system-state write.
        memory[16'h0089] = 8'h33;
        memory[16'h0095] = 8'h2B;
        memory[16'h0832] = 8'h2B;
        memory[16'h086A] = 8'h2B;
        reset = 1'b1;
        execute_enable = 1'b0;
        ready = 1'b0;
        repeat (64) tick();
        reset = 1'b0;
        execute_enable = 1'b1;
        far_restart(16'h0000, 16'h0000);
        wait_state(16'h002B, 16'h0100);

        memory[16'h0100] = 8'h0F; memory[16'h0101] = 8'h06;
        far_restart(16'h002B, 16'h0100);
        wait_fault(8'd13);
        check(debug_cs == 16'h002B && debug_protected_msw[0] && debug_protected_msw[3],
              "CPL3 CLTS raises #GP and preserves protected mode plus TS");

        memory[16'h0100] = 8'h0F; memory[16'h0101] = 8'h01; memory[16'h0102] = 8'h16;
        memory[16'h0103] = 8'h00; memory[16'h0104] = 8'h03;
        far_restart(16'h002B, 16'h0100);
        wait_fault(8'd13);
        check(debug_cs == 16'h002B && debug_gdtr_base == 24'h000400 && debug_gdtr_limit == 16'h0037,
              "CPL3 LGDT raises #GP without changing GDTR");

        memory[16'h0100] = 8'h0F; memory[16'h0101] = 8'h01; memory[16'h0102] = 8'h1E;
        memory[16'h0103] = 8'h10; memory[16'h0104] = 8'h03;
        far_restart(16'h002B, 16'h0100);
        wait_fault(8'd13);
        check(debug_cs == 16'h002B && debug_idtr_base == 24'h000800 && debug_idtr_limit == 16'h006F,
              "CPL3 LIDT raises #GP without changing IDTR");

        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h01; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h0F; memory[16'h0104] = 8'h01; memory[16'h0105] = 8'hF0;
        far_restart(16'h002B, 16'h0100);
        wait_fault(8'd13);
        check(debug_cs == 16'h002B && debug_protected_msw[0] && debug_protected_msw[3],
              "CPL3 LMSW raises #GP without changing the MSW");

        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h08; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h0F; memory[16'h0104] = 8'h00; memory[16'h0105] = 8'hD0;
        far_restart(16'h002B, 16'h0100);
        wait_fault(8'd13);
        check(debug_cs == 16'h002B && debug_ldtr_selector == 16'h0000,
              "CPL3 LLDT raises #GP without changing LDTR");

        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h10; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h0F; memory[16'h0104] = 8'h00; memory[16'h0105] = 8'hD8;
        far_restart(16'h002B, 16'h0100);
        wait_fault(8'd13);
        check(debug_cs == 16'h002B && debug_tr_selector == 16'h0000,
              "CPL3 LTR raises #GP without changing TR");

        $display("CLTS_PRIVILEGE PASS: %0d checks, READY stalls=%0d", checks, cycles);
        $finish;
    end
endmodule
