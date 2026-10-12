// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module spk286_protected_event_outer_tb;
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

    task automatic wait_state(input logic [15:0] expected_cs, input logic [15:0] expected_ip);
        integer deadline;
        begin
            deadline = 0;
            while ((debug_cs != expected_cs || debug_ip != expected_ip) && deadline < 2500) begin
                tick();
                deadline = deadline + 1;
            end
            if (debug_cs != expected_cs || debug_ip != expected_ip)
                $fatal(1, "outer event setup did not reach %h:%h; got %h:%h", expected_cs, expected_ip, debug_cs, debug_ip);
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
                $fatal(1, "outer event did not complete; vector=%h expected=%h CS:IP=%h:%h shutdown=%b halted=%b", debug_event_vector, expected_vector, debug_cs, debug_ip, shutdown, halted);
        end
    endtask

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "%s: CS:IP=%h:%h SS:SP=%h:%h", message, debug_cs, debug_ip,
                       debug_segment_selectors[47:32], debug_gpr[79:64]);
        end
    endtask

    initial begin
        for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;

        // Real-mode setup: GDT at 0400, IDT at 0800, then enter ring 0.
        memory[16'h0000] = 8'h0F; memory[16'h0001] = 8'h01; memory[16'h0002] = 8'h16;
        memory[16'h0003] = 8'h00; memory[16'h0004] = 8'h03; // LGDT [0300]
        memory[16'h0005] = 8'h0F; memory[16'h0006] = 8'h01; memory[16'h0007] = 8'h1E;
        memory[16'h0008] = 8'h10; memory[16'h0009] = 8'h03; // LIDT [0310]
        memory[16'h000A] = 8'hB8; memory[16'h000B] = 8'h09; memory[16'h000C] = 8'h00;
        memory[16'h000D] = 8'h0F; memory[16'h000E] = 8'h01; memory[16'h000F] = 8'hF0; // LMSW
        memory[16'h0010] = 8'hEA; memory[16'h0011] = 8'h80; memory[16'h0012] = 8'h00;
        memory[16'h0013] = 8'h18; memory[16'h0014] = 8'h00; // JMP 0018:0080

        // Ring-0 setup loads TR and creates an outer-level IRET frame for CPL1.
        memory[16'h0080] = 8'hB8; memory[16'h0081] = 8'h28; memory[16'h0082] = 8'h00;
        memory[16'h0083] = 8'h0F; memory[16'h0084] = 8'h00; memory[16'h0085] = 8'hD8; // LTR AX
        memory[16'h0086] = 8'hB8; memory[16'h0087] = 8'h20; memory[16'h0088] = 8'h00;
        memory[16'h0089] = 8'h8E; memory[16'h008A] = 8'hD0; // MOV SS,0020
        memory[16'h008B] = 8'hBC; memory[16'h008C] = 8'h00; memory[16'h008D] = 8'hF0; // SP=F000
        memory[16'h008E] = 8'hB8; memory[16'h008F] = 8'h11; memory[16'h0090] = 8'h00; memory[16'h0091] = 8'h50; // SS=0011
        memory[16'h0092] = 8'hB8; memory[16'h0093] = 8'h00; memory[16'h0094] = 8'hF0; memory[16'h0095] = 8'h50; // SP=F000
        memory[16'h0096] = 8'hB8; memory[16'h0097] = 8'h02; memory[16'h0098] = 8'h02; memory[16'h0099] = 8'h50; // FLAGS=0202
        memory[16'h009A] = 8'hB8; memory[16'h009B] = 8'h09; memory[16'h009C] = 8'h00; memory[16'h009D] = 8'h50; // CS=0009
        memory[16'h009E] = 8'hB8; memory[16'h009F] = 8'h00; memory[16'h00A0] = 8'h01; memory[16'h00A1] = 8'h50; // IP=0100
        memory[16'h00A2] = 8'hCF;

        // CPL1 raises a software INT.  The DPL1 interrupt gate targets CPL0.
        memory[16'h0100] = 8'hCD; memory[16'h0101] = 8'h20;
        memory[16'h0200] = 8'hB8; memory[16'h0201] = 8'hEF; memory[16'h0202] = 8'hBE;
        memory[16'h0203] = 8'hF4;

        // GDTR: limit 002F, base 0400.  IDTR covers vector 20h.
        memory[16'h0300] = 8'h2F; memory[16'h0301] = 8'h00;
        memory[16'h0302] = 8'h00; memory[16'h0303] = 8'h04; memory[16'h0304] = 8'h00;
        memory[16'h0310] = 8'h07; memory[16'h0311] = 8'h01;
        memory[16'h0312] = 8'h00; memory[16'h0313] = 8'h08; memory[16'h0314] = 8'h00;

        // GDT: ring-1 code/data, ring-0 code/data, and a 286 available TSS.
        memory[16'h0408] = 8'hFF; memory[16'h0409] = 8'hFF; memory[16'h040A] = 8'h00; memory[16'h040B] = 8'h00;
        memory[16'h040C] = 8'h00; memory[16'h040D] = 8'hBA; memory[16'h040E] = 8'h00; memory[16'h040F] = 8'h00;
        memory[16'h0410] = 8'hFF; memory[16'h0411] = 8'hFF; memory[16'h0412] = 8'h00; memory[16'h0413] = 8'h00;
        memory[16'h0414] = 8'h00; memory[16'h0415] = 8'hB2; memory[16'h0416] = 8'h00; memory[16'h0417] = 8'h00;
        memory[16'h0418] = 8'hFF; memory[16'h0419] = 8'hFF; memory[16'h041A] = 8'h00; memory[16'h041B] = 8'h00;
        memory[16'h041C] = 8'h00; memory[16'h041D] = 8'h9A; memory[16'h041E] = 8'h00; memory[16'h041F] = 8'h00;
        memory[16'h0420] = 8'hFF; memory[16'h0421] = 8'hFF; memory[16'h0422] = 8'h00; memory[16'h0423] = 8'h00;
        memory[16'h0424] = 8'h00; memory[16'h0425] = 8'h92; memory[16'h0426] = 8'h00; memory[16'h0427] = 8'h00;
        memory[16'h0428] = 8'h67; memory[16'h0429] = 8'h00; memory[16'h042A] = 8'h00; memory[16'h042B] = 8'h05;
        memory[16'h042C] = 8'h00; memory[16'h042D] = 8'h81; memory[16'h042E] = 8'h00; memory[16'h042F] = 8'h00;

        // TSS SP0/SS0 at offsets 2/4; SP1/SS1 are present for the return path.
        memory[16'h0502] = 8'h00; memory[16'h0503] = 8'hF0;
        memory[16'h0504] = 8'h20; memory[16'h0505] = 8'h00;
        memory[16'h0506] = 8'h00; memory[16'h0507] = 8'hF0;
        memory[16'h0508] = 8'h11; memory[16'h0509] = 8'h00;

        // Vector 20h: present DPL1 interrupt gate, target 0018:0200.
        memory[16'h0900] = 8'h00; memory[16'h0901] = 8'h02;
        memory[16'h0902] = 8'h18; memory[16'h0903] = 8'h00;
        memory[16'h0904] = 8'h00; memory[16'h0905] = 8'hA6;
        memory[16'h0906] = 8'h00; memory[16'h0907] = 8'h00;

        reset = 1'b1;
        execute_enable = 1'b0;
        ready = 1'b0;
        repeat (64) tick();
        reset = 1'b0;
        execute_enable = 1'b1;
        far_restart(16'h0000, 16'h0000);
        wait_state(16'h0009, 16'h0100);
        check(debug_idtr_base == 24'h000800 && debug_idtr_limit == 16'h0107,
              "PM3e setup loads the IDTR covering vector 20h");
        check(debug_tr_selector == 16'h0028 && debug_tr_base == 24'h000500,
              "PM3e setup loads the 286 TSS before leaving CPL0");

        wait_event(8'h20);
        check(debug_cs == 16'h0018 && debug_ip == 16'h0200 && debug_segment_selectors[47:32] == 16'h0020,
              "PM3e interrupt gate switches to the target CS and TSS-selected SS");
        check(debug_gpr[79:64] == 16'hEFF6 && !debug_flags[9],
              "PM3e commits the new SP, clears IF and has not executed the handler yet");
        check(memory[16'hEFF6] == 8'h02 && memory[16'hEFF7] == 8'h01 &&
              memory[16'hEFF8] == 8'h09 && memory[16'hEFF9] == 8'h00 &&
              memory[16'hEFFA] == 8'h02 && memory[16'hEFFB] == 8'h02 &&
              memory[16'hEFFC] == 8'h00 && memory[16'hEFFD] == 8'hF0 &&
              memory[16'hEFFE] == 8'h11 && memory[16'hEFFF] == 8'h00,
              "PM3e writes the complete outer event frame on the new stack");
        repeat (64) tick();
        check(debug_gpr[15:0] == 16'hBEEF && halted,
              "PM3e target begins only after stack and context commit");
        $display("PROTECTED_EVENT_OUTER PASS: %0d checks, READY stalls=%0d", checks, cycles);
        $finish;
    end
endmodule
