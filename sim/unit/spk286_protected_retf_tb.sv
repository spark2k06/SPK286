// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module spk286_protected_retf_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer cycles = 0;
    integer retired_count = 0;
    integer checks = 0;
    integer rejected_outer_frame_reads = 0;
    logic boundary_fault_seen = 1'b0;
    logic [7:0] boundary_first_fault_vector = 8'h00;
    logic boundary_observe = 1'b0;
    integer boundary_stack_writes = 0;

    spk286 dut (.*);

    task automatic tick;
        begin
            #1;
            if (reset) begin
                boundary_fault_seen = 1'b0;
                boundary_first_fault_vector = 8'h00;
                boundary_observe = 1'b0;
                boundary_stack_writes = 0;
            end else if (boundary_observe && !boundary_fault_seen && dut.fault_request) begin
                boundary_fault_seen = 1'b1;
                boundary_first_fault_vector = dut.fault_vector;
            end
            ready = bus_valid && ((cycles % 4) != 1);
            data_in = 16'h0000;
            if (bus_valid && !bus_write) begin
                if (bus_status == 4'h0) data_in = 16'h0022;
                else if (address[0]) data_in = {memory[address[15:0]], 8'h00};
                else if (bus_bhe_n) data_in = {8'h00, memory[address[15:0]]};
                else data_in = {memory[address[15:0] + 16'd1], memory[address[15:0]]};
            end
            if (bus_valid && ready && bus_write && bus_status == 4'h6) begin
                if (boundary_observe && address >= 24'h009000 && address < 24'h00A000)
                    boundary_stack_writes = boundary_stack_writes + 1;
                if (address[0]) memory[address[15:0]] = data_out[15:8];
                else begin
                    memory[address[15:0]] = data_out[7:0];
                    if (!bus_bhe_n) memory[address[15:0] + 16'd1] = data_out[15:8];
                end
            end
            if (bus_valid && ready && !bus_write && bus_status == 4'h5 &&
                (address[15:0] == 16'h9FFC || address[15:0] == 16'h9FFE))
                rejected_outer_frame_reads = rejected_outer_frame_reads + 1;
            #4; clk = 1'b1; #5; clk = 1'b0; #1;
            cycles = cycles + 1;
            if (instruction_retired) retired_count = retired_count + 1;
        end
    endtask

    task automatic wait_shutdown;
        integer deadline;
        begin
            deadline = 0;
            while (!shutdown && deadline < 1000) begin
                tick();
                deadline = deadline + 1;
            end
            if (!shutdown)
                $fatal(1, "protected RETF rejection did not reach shutdown; IP=%h opcode=%h pc=%h", debug_ip, debug_opcode, debug_micro_pc);
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
            while (retired_count == start_retired && !halted && !shutdown && deadline < 1000) begin
                tick();
                deadline = deadline + 1;
            end
            if (retired_count != start_retired + 1)
                $fatal(1, "protected RETF instruction did not retire; IP=%h opcode=%h pc=%h bus=%h", debug_ip, debug_opcode, debug_micro_pc, bus_status);
        end
    endtask

    task automatic enter_ring1_caller(input logic [15:0] caller_stack_limit);
        begin
            // Rebuild the small protected-mode fixture so each negative return
            // case starts from a reset CPU and the same outer IRET contract.
            memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h18; memory[16'h0102] = 8'h00;
            memory[16'h0103] = 8'h8E; memory[16'h0104] = 8'hD0;
            memory[16'h0105] = 8'hBB; memory[16'h0106] = 8'h10; memory[16'h0107] = 8'h00;
            memory[16'h0108] = 8'h0F; memory[16'h0109] = 8'h00; memory[16'h010A] = 8'hDB;
            memory[16'h010B] = 8'hEA; memory[16'h010C] = 8'h00; memory[16'h010D] = 8'h02;
            memory[16'h010E] = 8'h38; memory[16'h010F] = 8'h00;
            memory[16'h0200] = 8'hCF;
            memory[16'h1018] = 8'hFF; memory[16'h1019] = 8'hFF;
            memory[16'h1015] = 8'h81;
            memory[16'h1068] = caller_stack_limit[7:0]; memory[16'h1069] = caller_stack_limit[15:8];
            memory[16'h107C] = 8'h02; memory[16'h107D] = 8'hA4;
            memory[16'h0240] = 8'h9A; memory[16'h0241] = 8'h00; memory[16'h0242] = 8'h01;
            memory[16'h0243] = 8'h79; memory[16'h0244] = 8'h00;
            memory[16'hFF00] = 8'h40; memory[16'hFF01] = 8'h02;
            memory[16'hFF02] = 8'h61; memory[16'hFF03] = 8'h00;
            memory[16'hFF04] = 8'h02; memory[16'hFF05] = 8'h02;
            memory[16'hFF06] = 8'h00; memory[16'hFF07] = 8'hFF;
            memory[16'hFF08] = 8'h69; memory[16'hFF09] = 8'h00;

            reset = 1'b1;
            execute_enable = 1'b0;
            ready = 1'b0;
            tick();
            reset = 1'b0;
            far_restart(16'h0000, 16'h0000);

            gpr_write_en = 1'b1;
            gpr_write_index = 3'd0;
            gpr_write_data = 16'h0001;
            tick();
            gpr_write_en = 1'b0;
            gpr_write_index = 3'd4;
            gpr_write_data = 16'hFF00;
            gpr_write_en = 1'b1;
            tick();
            gpr_write_en = 1'b0;
            execute_enable = 1'b1;

            retire_one(); // LGDT
            retire_one(); // MOV AX,1
            retire_one(); // LMSW
            retire_one(); // far jump to protected setup
            retire_one(); // MOV AX,0018
            retire_one(); // MOV SS,AX
            retire_one(); // MOV BX,0010
            retire_one(); // LTR BX
            retire_one(); // far jump to IRET
            memory[16'h0100] = 8'hCA; memory[16'h0101] = 8'h04; memory[16'h0102] = 8'h00;
            retire_one(); // outer IRET to ring 1
        end
    endtask

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "%s: IP=%h opcode=%h CS=%h SS=%h SP=%h", message, debug_ip, debug_opcode,
                       debug_cs, debug_segment_selectors[47:32], debug_gpr[79:64]);
        end
    endtask

    initial begin
        for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;

        // GDTR pseudo-descriptor: limit 007F, base 001000.
        memory[16'h0300] = 8'h7F; memory[16'h0301] = 8'h00;
        memory[16'h0302] = 8'h00; memory[16'h0303] = 8'h10; memory[16'h0304] = 8'h00;

        // GDT entries: 0010 TSS, 0018 ring-0 stack, 0020 non-present data,
        // 0028 code-as-SS rejection, 0038 ring-0 code, 0061 ring-1 code,
        // 0069 ring-1 stack, 0079 two-parameter call gate.
        memory[16'h1010] = 8'h67; memory[16'h1011] = 8'h00;
        memory[16'h1012] = 8'h00; memory[16'h1013] = 8'h80;
        memory[16'h1014] = 8'h00; memory[16'h1015] = 8'h81;
        memory[16'h1016] = 8'h00; memory[16'h1017] = 8'h00;
        memory[16'h1018] = 8'hFF; memory[16'h1019] = 8'hFF;
        memory[16'h101A] = 8'h00; memory[16'h101B] = 8'h00;
        memory[16'h101C] = 8'h00; memory[16'h101D] = 8'h92;
        memory[16'h101E] = 8'h00; memory[16'h101F] = 8'h00;
        memory[16'h1020] = 8'hFF; memory[16'h1021] = 8'hFF;
        memory[16'h1022] = 8'h00; memory[16'h1023] = 8'h00;
        memory[16'h1024] = 8'h00; memory[16'h1025] = 8'h12;
        memory[16'h1026] = 8'h00; memory[16'h1027] = 8'h00;
        memory[16'h1028] = 8'hFF; memory[16'h1029] = 8'hFF;
        memory[16'h102A] = 8'h00; memory[16'h102B] = 8'h00;
        memory[16'h102C] = 8'h00; memory[16'h102D] = 8'h9A;
        memory[16'h102E] = 8'h00; memory[16'h102F] = 8'h00;
        memory[16'h1038] = 8'hFF; memory[16'h1039] = 8'hFF;
        memory[16'h103A] = 8'h00; memory[16'h103B] = 8'h00;
        memory[16'h103C] = 8'h00; memory[16'h103D] = 8'h9A;
        memory[16'h103E] = 8'h00; memory[16'h103F] = 8'h00;
        memory[16'h1060] = 8'hFF; memory[16'h1061] = 8'hFF;
        memory[16'h1062] = 8'h00; memory[16'h1063] = 8'h00;
        memory[16'h1064] = 8'h00; memory[16'h1065] = 8'hBA;
        memory[16'h1066] = 8'h00; memory[16'h1067] = 8'h00;
        memory[16'h1068] = 8'hFF; memory[16'h1069] = 8'hFF;
        memory[16'h106A] = 8'h00; memory[16'h106B] = 8'h00;
        memory[16'h106C] = 8'h00; memory[16'h106D] = 8'hB2;
        memory[16'h106E] = 8'h00; memory[16'h106F] = 8'h00;
        memory[16'h1078] = 8'h00; memory[16'h1079] = 8'h01;
        memory[16'h107A] = 8'h38; memory[16'h107B] = 8'h00;
        memory[16'h107C] = 8'h02; memory[16'h107D] = 8'hA4;
        memory[16'h107E] = 8'h00; memory[16'h107F] = 8'h00;

        // 286 TSS at physical 008000: SP0=A000, SS0=0018.
        memory[16'h8002] = 8'h00; memory[16'h8003] = 8'hA0;
        memory[16'h8004] = 8'h18; memory[16'h8005] = 8'h00;

        // Real-mode setup: LGDT, LMSW, then enter the ring-0 setup code.
        memory[16'h0000] = 8'h0F; memory[16'h0001] = 8'h01; memory[16'h0002] = 8'h16;
        memory[16'h0003] = 8'h00; memory[16'h0004] = 8'h03;
        memory[16'h0005] = 8'hB8; memory[16'h0006] = 8'h01; memory[16'h0007] = 8'h00;
        memory[16'h0008] = 8'h0F; memory[16'h0009] = 8'h01; memory[16'h000A] = 8'hF0;
        memory[16'h000B] = 8'hEA; memory[16'h000C] = 8'h00; memory[16'h000D] = 8'h01;
        memory[16'h000E] = 8'h38; memory[16'h000F] = 8'h00;

        enter_ring1_caller(16'hFFFF);
        check(debug_cs == 16'h0061 && debug_ip == 16'h0240 &&
              debug_segment_selectors[47:32] == 16'h0069 && debug_gpr[79:64] == 16'hFF00,
              "PM4b.3 enters the ring-1 caller through the existing outer IRET path");

        memory[16'hFF00] = 8'h57; memory[16'hFF01] = 8'h13;
        memory[16'hFF02] = 8'h68; memory[16'hFF03] = 8'h24;
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h0100 &&
              debug_segment_selectors[47:32] == 16'h0018 && debug_gpr[79:64] == 16'h9FF4 &&
              memory[16'h9FF4] == 8'h45 && memory[16'h9FF5] == 8'h02 &&
              memory[16'h9FF6] == 8'h61 && memory[16'h9FF7] == 8'h00 &&
              memory[16'h9FF8] == 8'h57 && memory[16'h9FF9] == 8'h13 &&
              memory[16'h9FFA] == 8'h68 && memory[16'h9FFB] == 8'h24 &&
              memory[16'h9FFC] == 8'h00 && memory[16'h9FFD] == 8'hFF &&
              memory[16'h9FFE] == 8'h69 && memory[16'h9FFF] == 8'h00,
              "PM4b.2 frame supplies the PM4b.3 RETF 4 acceptance case");
        retire_one();
        check(debug_cs == 16'h0061 && debug_ip == 16'h0245 &&
              debug_segment_selectors[47:32] == 16'h0069 && debug_gpr[79:64] == 16'hFF04,
              "PM4b.3 RETF 4 restores outer CS/SS and discards the copied parameters");

        // Re-enter through the same gate with a CPL0 stack limit of
        // 9FFB.  After reading IP and CS tentatively, RETF 4 validates the
        // saved SP:SS words at 9FFC..9FFF and must fault before reading them.
        memory[16'h0245] = 8'h9A; memory[16'h0246] = 8'h00; memory[16'h0247] = 8'h01;
        memory[16'h0248] = 8'h79; memory[16'h0249] = 8'h00;
        memory[16'hFF04] = 8'h57; memory[16'hFF05] = 8'h13;
        memory[16'hFF06] = 8'h68; memory[16'hFF07] = 8'h24;
        // Reload the target SS after the gate has admitted its complete
        // 9FF4..9FFF frame; only then tighten the descriptor for RETF.
        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h50; memory[16'h0102] = 8'h00;
        memory[16'h0103] = 8'h8E; memory[16'h0104] = 8'hD0;
        memory[16'h0105] = 8'hCA; memory[16'h0106] = 8'h04; memory[16'h0107] = 8'h00;
        memory[16'h1018] = 8'hFF; memory[16'h1019] = 8'hFF;
        memory[16'h1050] = 8'hFB; memory[16'h1051] = 8'h9F;
        memory[16'h1052] = 8'h00; memory[16'h1053] = 8'h00;
        memory[16'h1054] = 8'h00; memory[16'h1055] = 8'h92;
        memory[16'h1056] = 8'h00; memory[16'h1057] = 8'h00;
        rejected_outer_frame_reads = 0;
        far_restart(16'h0061, 16'h0245);
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h0100 && debug_gpr[79:64] == 16'h9FF4,
              "PM4b.4 call gate reaches the bounded RETF rejection target");
        retire_one(); // MOV AX,0050
        retire_one(); // MOV SS,AX installs the tightened target limit
        wait_shutdown();
        check(debug_cs == 16'h0038 && debug_segment_selectors[47:32] == 16'h0050 &&
              debug_gpr[79:64] == 16'h9FF4 && rejected_outer_frame_reads == 0 &&
              memory[16'h9FFC] == 8'h04 && memory[16'h9FFD] == 8'hFF &&
              memory[16'h9FFE] == 8'h69 && memory[16'h9FFF] == 8'h00,
              "PM4b.4 RETF frame-range fault precedes outer SP:SS reads and CS/SS commit");

        // A null saved SS is rejected after the outer frame is read,
        // without committing the candidate context.
        enter_ring1_caller(16'hFFFF);
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h0100 && debug_gpr[79:64] == 16'h9FF4,
              "PM4b.5 null-SS case reaches the protected RETF target");
        memory[16'h9FFE] = 8'h00; memory[16'h9FFF] = 8'h00;
        wait_shutdown();
        check(debug_cs == 16'h0038 && debug_segment_selectors[47:32] == 16'h0018 &&
              debug_gpr[79:64] == 16'h9FF4,
              "PM4b.5 null outer SS faults without restored CS/SS/SP commit");

        // A present writable SS with the wrong DPL/RPL is also
        // rejected.  Selector 0018 is the ring-0 stack, not ring 1's SS.
        enter_ring1_caller(16'hFFFF);
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h0100 && debug_gpr[79:64] == 16'h9FF4,
              "PM4b.5 privilege-mismatch case reaches the protected RETF target");
        memory[16'h9FFE] = 8'h18; memory[16'h9FFF] = 8'h00;
        wait_shutdown();
        check(debug_cs == 16'h0038 && debug_segment_selectors[47:32] == 16'h0018 &&
              debug_gpr[79:64] == 16'h9FF4,
              "PM4b.5 mismatched outer SS privilege faults atomically");

        // The remaining immediate SS descriptor classes are rejected
        // without restoring the outer context.
        enter_ring1_caller(16'hFFFF);
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h0100 && debug_gpr[79:64] == 16'h9FF4,
              "PM4b.6 non-present SS case reaches the protected RETF target");
        memory[16'h9FFE] = 8'h20; memory[16'h9FFF] = 8'h00;
        wait_shutdown();
        check(debug_cs == 16'h0038 && debug_segment_selectors[47:32] == 16'h0018 &&
              debug_gpr[79:64] == 16'h9FF4,
              "PM4b.6 non-present outer SS faults atomically");

        enter_ring1_caller(16'hFFFF);
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h0100 && debug_gpr[79:64] == 16'h9FF4,
              "PM4b.6 wrong-type SS case reaches the protected RETF target");
        memory[16'h9FFE] = 8'h28; memory[16'h9FFF] = 8'h00;
        wait_shutdown();
        check(debug_cs == 16'h0038 && debug_segment_selectors[47:32] == 16'h0018 &&
              debug_gpr[79:64] == 16'h9FF4,
              "PM4b.6 code-descriptor outer SS faults atomically");

        enter_ring1_caller(16'hFFFF);
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h0100 && debug_gpr[79:64] == 16'h9FF4,
              "PM4b.6 TI=1 SS case reaches the protected RETF target");
        memory[16'h9FFE] = 8'h0D; memory[16'h9FFF] = 8'h00;
        wait_shutdown();
        check(debug_cs == 16'h0038 && debug_segment_selectors[47:32] == 16'h0018 &&
              debug_gpr[79:64] == 16'h9FF4,
              "PM4b.6 LDT-indicator outer SS faults atomically");

        // The caller stack admits the copied parameters through FF03.
        // RETF 4 restores FF04, one byte past the limit: a valid empty stack.
        // Intel's RET outer-return checks do not dereference the restored SP.
        enter_ring1_caller(16'hFF03);
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h0100 && debug_gpr[79:64] == 16'h9FF4,
              "PM4b.7 restored-SP limit case reaches the protected RETF target");
        retire_one();
        check(debug_cs == 16'h0061 && debug_ip == 16'h0245 &&
              debug_segment_selectors[47:32] == 16'h0069 && debug_gpr[79:64] == 16'hFF04,
              "PM4b.7 restored outer SP may point one byte past the stack limit");

        // The restored SP may equal the outer SS limit.  The inclusive
        // upper boundary is valid because RETF does not dereference it.
        enter_ring1_caller(16'hFF04);
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h0100 && debug_gpr[79:64] == 16'h9FF4,
              "PM4b.8 exact-limit case reaches the protected RETF target");
        retire_one();
        check(debug_cs == 16'h0061 && debug_ip == 16'h0245 &&
              debug_segment_selectors[47:32] == 16'h0069 && debug_gpr[79:64] == 16'hFF04,
              "PM4b.8 exact restored-SP limit is accepted");

        // Parameter-count boundaries: the gate field is five bits wide,
        // so counts one and thirty-one must use the same atomic frame service
        // as the existing two-parameter case.
        enter_ring1_caller(16'hFFFF);
        memory[16'h107C] = 8'h01;
        memory[16'h0101] = 8'h02; memory[16'h0102] = 8'h00;
        memory[16'hFF00] = 8'h55; memory[16'hFF01] = 8'hAA;
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h0100 && debug_gpr[79:64] == 16'h9FF6 &&
              {memory[16'h9FFA + 16'd1], memory[16'h9FFA]} == 16'hAA55 &&
              {memory[16'h9FFC + 16'd1], memory[16'h9FFC]} == 16'hFF00 &&
              {memory[16'h9FFE + 16'd1], memory[16'h9FFE]} == 16'h0069,
              "PM4b one-parameter gate copies the frame without an off-by-one");
        retire_one();
        check(debug_cs == 16'h0061 && debug_ip == 16'h0245 && debug_gpr[79:64] == 16'hFF02,
              "PM4b RETF 2 discards exactly one copied parameter");

        enter_ring1_caller(16'hFFFF);
        memory[16'h107C] = 8'h1F;
        memory[16'h0101] = 8'h3E; memory[16'h0102] = 8'h00;
        for (integer idx = 0; idx < 31; idx = idx + 1) begin
            memory[32'h0000FF00 + idx * 32'd2] = idx[7:0];
            memory[32'h0000FF01 + idx * 32'd2] = 8'h40;
        end
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h0100 && debug_gpr[79:64] == 16'h9FBA &&
              {memory[32'h00009FFC + 32'd1], memory[32'h00009FFC]} == 16'hFF00 &&
              {memory[32'h00009FFE + 32'd1], memory[32'h00009FFE]} == 16'h0069,
              "PM4b thirty-one-parameter gate reserves the complete bounded frame");
        for (integer idx = 0; idx < 31; idx = idx + 1)
            check({memory[32'h00009FBE + idx * 32'd2 + 32'd1],
                   memory[32'h00009FBE + idx * 32'd2]} == (16'h4000 + idx[15:0]),
                  "PM4b thirty-one-parameter copy preserves source order");
        retire_one();
        check(debug_cs == 16'h0061 && debug_ip == 16'h0245 && debug_gpr[79:64] == 16'hFF3E,
              "PM4b RETF 62 discards the complete thirty-one-parameter frame");

        // Restore the ordinary two-word gate fixture before the independent
        // expand-down cases below.
        memory[16'h107C] = 8'h02;
        memory[16'h0101] = 8'h04;
        memory[16'h0102] = 8'h00;

        // Exercise the maximum parameter count against multi-word
        // source and target stack boundaries.  The source limit is inclusive
        // for the final parameter byte; the target limit is inclusive for the
        // complete first pushed word and therefore admits the complete
        // downward frame.
        enter_ring1_caller(16'hFF3C);
        memory[16'h107C] = 8'h1F;
        memory[16'h0101] = 8'h3E; memory[16'h0102] = 8'h00;
        boundary_observe = 1'b1;
        wait_shutdown();
        check(debug_cs == 16'h0061 && debug_ip == 16'h0245 && debug_gpr[79:64] == 16'hFF00 &&
              boundary_fault_seen && boundary_first_fault_vector == 8'h0C,
              "PM4b.9 source frame crossing the caller SS limit faults before the gate target");
        // This fixture has no usable IDT. The 80286 requires #SS -> #DF -> shutdown;
        // the final delivery vector therefore cannot identify the first fault.
        check(debug_event_vector == 8'h08 && boundary_stack_writes == 0,
              "PM4b.9 source rejection reaches failed double-fault delivery without target-stack writes");

        enter_ring1_caller(16'hFF3D);
        memory[16'h107C] = 8'h1F;
        memory[16'h0101] = 8'h3E; memory[16'h0102] = 8'h00;
        for (integer idx = 0; idx < 31; idx = idx + 1) begin
            memory[32'h0000FF00 + idx * 32'd2] = idx[7:0];
            memory[32'h0000FF01 + idx * 32'd2] = 8'h40;
        end
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h0100 && debug_gpr[79:64] == 16'h9FBA &&
              debug_segment_limits[47:32] == 16'hFFFF &&
              {memory[16'h9FFC + 16'd1], memory[16'h9FFC]} == 16'hFF00 &&
              {memory[16'h9FFE + 16'd1], memory[16'h9FFE]} == 16'h0069,
              "PM4b.9 exact caller-source limit admits the complete maximum frame");

        enter_ring1_caller(16'hFFFF);
        memory[16'h1018] = 8'hFF; memory[16'h1019] = 8'h9F;
        memory[16'h107C] = 8'h1F;
        memory[16'h0101] = 8'h3E; memory[16'h0102] = 8'h00;
        for (integer idx = 0; idx < 31; idx = idx + 1) begin
            memory[32'h0000FF00 + idx * 32'd2] = idx[7:0];
            memory[32'h0000FF01 + idx * 32'd2] = 8'h40;
        end
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h0100 && debug_gpr[79:64] == 16'h9FBA &&
              debug_segment_limits[47:32] == 16'h9FFF &&
              {memory[16'h9FFC + 16'd1], memory[16'h9FFC]} == 16'hFF00 &&
              {memory[16'h9FFE + 16'd1], memory[16'h9FFE]} == 16'h0069,
              "PM4b.9 exact target-stack limit admits the maximum downward frame");
        retire_one();
        check(debug_cs == 16'h0061 && debug_ip == 16'h0245 && debug_gpr[79:64] == 16'hFF3E,
              "PM4b.9 maximum frame returns through RETF 62 after the target-boundary case");

        enter_ring1_caller(16'hFFFF);
        memory[16'h1018] = 8'hFE; memory[16'h1019] = 8'h9F;
        memory[16'h107C] = 8'h1F;
        memory[16'h0101] = 8'h3E; memory[16'h0102] = 8'h00;
        boundary_observe = 1'b1;
        wait_shutdown();
        check(debug_cs == 16'h0061 && debug_ip == 16'h0245 && debug_gpr[79:64] == 16'hFF00 &&
              boundary_fault_seen && boundary_first_fault_vector == 8'h0C,
              "PM4b.9 target frame crossing the destination SS limit faults before writes");
        check(debug_event_vector == 8'h08 && boundary_stack_writes == 0,
              "PM4b.9 target rejection reaches failed double-fault delivery without target-stack writes");

        // Expand-down outer return: the caller's saved SS accepts the source
        // parameter reads above 9000 and the restored SP remains above the
        // same lower bound through RETF 4.
        memory[16'h106D] = 8'hB6;
        enter_ring1_caller(16'h9000);
        check(debug_segment_access[23:16] == 8'hB7 && debug_segment_limits[47:32] == 16'h9000,
              "expand-down caller stack commits through the outer IRET setup");
        memory[16'hFF00] = 8'h57; memory[16'hFF01] = 8'h13;
        memory[16'hFF02] = 8'h68; memory[16'hFF03] = 8'h24;
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h0100 && debug_segment_selectors[47:32] == 16'h0018,
              "expand-down caller stack accepts the inter-level call-gate source frame");
        retire_one();
        check(debug_cs == 16'h0061 && debug_ip == 16'h0245 &&
              debug_segment_selectors[47:32] == 16'h0069 && debug_segment_access[23:16] == 8'hB7 &&
              debug_segment_limits[47:32] == 16'h9000 && debug_gpr[79:64] == 16'hFF04,
              "expand-down restored SS and SP commit atomically through RETF 4");

        $display("PROTECTED_RETF PASS: %0d checks, READY stalls=%0d", checks, cycles);
        $finish;
    end
endmodule
