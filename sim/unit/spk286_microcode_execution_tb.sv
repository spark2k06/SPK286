`timescale 1ns/1ps

module spk286_microcode_execution_tb;
    // TF delivery is verified by the event suite; this stream isolates its original datapath contract.
    `include "spk286_signals.svh"
    logic [7:0] memory [0:4095];
    integer cycles = 0, checks = 0, retirements = 0, underfill_cycles = 0;
    integer phase_cycles = 0;
    logic [127:0] expected_gpr;
    logic [63:0] saved_selectors, saved_limits;
    logic [95:0] saved_bases;
    logic [31:0] saved_access;
    logic [15:0] base_ip, immediate;
    logic [3:0] paused_count;
    logic [11:0] paused_pc;
    spk286 dut (.*);

    task automatic check(input logic condition, input string message);
        if (condition !== 1'b1)
            $fatal(1, "%s IP=%h PC=%h entry=%h op=%h active=%b queue=%d retired=%b",
                   message, debug_ip, debug_micro_pc, debug_micro_entry,
                   debug_micro_instruction, debug_micro_active, debug_prefetch_count, instruction_retired);
        checks = checks + 1;
    endtask
    task automatic tick;
        data_in = 16'h0F0F;
        if (bus_valid && address < 24'd4096)
            data_in = {memory[{address[11:1], 1'b1}], memory[{address[11:1], 1'b0}]};
        #5; clk = 1; #5; clk = 0; #1;
        cycles = cycles + 1;
        if (instruction_retired) retirements = retirements + 1;
        check(debug_prefetch_count <= 6 && !microcode_fault, "queue bounds / microcode validity");
    endtask
    task automatic service;
        ready = (cycles % 7 == 0); // Real READY dependency, including underfilled immediates.
        if (execute_enable && debug_micro_active &&
            debug_micro_instruction == spk286_microcode_pkg::MC_FETCH_IMM16 && debug_prefetch_count == 0)
            underfill_cycles = underfill_cycles + 1;
        tick();
    endtask
    task automatic program_mov(input logic [15:0] ip, input logic [2:0] dst, input logic [15:0] value);
        memory[ip[11:0]] = 8'hB8 + {5'd0, dst};
        memory[ip[11:0] + 12'd1] = value[7:0];
        memory[ip[11:0] + 12'd2] = value[15:8];
        // F1 is retained as a legal-but-unimplemented diagnostic sentinel;
        // invalid 0F escape holes now enter the architectural #UD path.
        memory[ip[11:0] + 12'd3] = 8'hF1;
    endtask
    task automatic redirect_to(input logic [15:0] ip);
        ip_write_en = 1; ip_write_data = ip; redirect = 1;
        tick(); ip_write_en = 0; redirect = 0;
        check(!instruction_retired && !debug_micro_active && debug_prefetch_count == 0,
              "redirect cancels microcode and queue");
    endtask
    task automatic setup(input logic [15:0] ip);
        execute_enable = 0; reset = 1; ready = 0;
        gpr_write_en = 0; flags_write_en = 0; segment_load_en = 0;
        ip_write_en = 0; redirect = 0; gpr_write_byte = 0;
        tick(); reset = 0;
        for (integer r = 0; r < 8; r = r + 1) begin
            gpr_write_en = 1; gpr_write_index = 3'(r); gpr_write_data = 16'hA100 + 16'(r);
            expected_gpr[r*16 +: 16] = gpr_write_data; tick();
        end
        gpr_write_en = 0;
        flags_write_en = 1; flags_write_data = 16'h7ED7; flags_write_mask = 16'hFFFF;
        tick(); flags_write_en = 0;
        for (integer s = 0; s < 4; s = s + 1) begin
            if (s != 1) begin
                segment_load_en = 1; segment_load_index = 2'(s);
                segment_load_selector = 16'h0010 + 16'(s); tick();
            end
        end
        segment_load_en = 1; segment_load_index = 1; segment_load_selector = 0;
        redirect_to(ip); segment_load_en = 0;
        saved_selectors = debug_segment_selectors; saved_bases = debug_segment_bases;
        saved_limits = debug_segment_limits; saved_access = debug_segment_access;
        retirements = 0; execute_enable = 1;
        // Decoder control must own word width and FLAGS even with stale setup inputs.
        gpr_write_byte = 1; flags_write_en = 1; flags_write_data = 0;
    endtask
    task automatic run_to_retire;
        phase_cycles = 0;
        if (instruction_retired) service();
        while (!instruction_retired && phase_cycles < 300) begin
            service(); phase_cycles = phase_cycles + 1;
            check(!unsupported_opcode, "supported program reached retirement");
        end
        check(instruction_retired && !debug_micro_active, "END retirement boundary");
        check(debug_micro_instruction == spk286_microcode_pkg::MC_END, "retirement came from generated END");
        check(debug_micro_entry == 12'(spk286_microcode_pkg::MC_ENTRY_MOV_R16_IMM16), "shared micro-entry");
    endtask
    task automatic check_architecture(input logic [15:0] expected_ip);
        check(debug_gpr == expected_gpr, "destination and unrelated GPR preservation");
        check(debug_ip == expected_ip && debug_flags == 16'h7ED7, "exact IP and FLAGS");
        check(debug_segment_selectors == saved_selectors && debug_segment_bases == saved_bases &&
              debug_segment_limits == saved_limits && debug_segment_access == saved_access, "all segment state preserved");
    endtask
    task automatic reach_stage(input integer stage);
        phase_cycles = 0;
        while (!(debug_micro_active &&
                 ((stage == 0 && debug_ip == 16'h0301) ||
                  (stage == 1 && debug_ip == 16'h0302) ||
                  (stage == 2 && debug_micro_instruction == spk286_microcode_pkg::MC_MOVE) ||
                  (stage == 3 && debug_micro_instruction == spk286_microcode_pkg::MC_END))) && phase_cycles < 300) begin
            service(); phase_cycles = phase_cycles + 1;
        end
        check(phase_cycles < 300 && retirements == 0, "reach cancellation/pause stage");
    endtask

    initial begin
        for (integer i = 0; i < 4096; i = i + 1) memory[i] = 8'hF1;
        // All register encodings, little-endian/extreme immediates and both alignments.
        for (integer alignment = 0; alignment < 2; alignment = alignment + 1) begin
            for (integer r = 0; r < 8; r = r + 1) begin
                for (integer v = 0; v < 3; v = v + 1) begin
                    base_ip = 16'h0100 + 16'(alignment);
                    immediate = (v == 0) ? 16'h0000 : ((v == 1) ? 16'hFFFF : 16'h12A5);
                    program_mov(base_ip, 3'(r), immediate); setup(base_ip); run_to_retire();
                    expected_gpr[r*16 +: 16] = immediate; check_architecture(base_ip + 16'd3);
                    check(retirements == 1, "exactly one retirement");
                    // Stop execution at END; an outstanding prefetch can finish
                    // but a held response must not enter the queue repeatedly.
                    execute_enable = 0; flags_write_en = 0; ready = 1;
                    paused_count = debug_prefetch_count;
                    repeat (8) begin
                        tick(); check(!instruction_retired && debug_prefetch_count == paused_count,
                                      "pause after END / no duplicated prefetch response");
                    end
                    execute_enable = 1;
                    phase_cycles = 0;
                    while (!unsupported_opcode && phase_cycles < 150) begin
                        service(); phase_cycles = phase_cycles + 1;
                    end
                    check(unsupported_opcode && debug_opcode == 8'hF1 && retirements == 1,
                          "unsupported byte cannot execute as MOV");
                    check_architecture(base_ip + 16'd3);
                end
            end
        end
        check(underfill_cycles > 0, "immediate fetch exercised queue underfill");

        // Check architectural state at every END in an uninterrupted MOV stream.
        for (integer r = 0; r < 8; r = r + 1)
            program_mov(16'h0200 + 16'(3*r), 3'(r), 16'h5500 + 16'(r));
        setup(16'h0200);
        for (integer r = 0; r < 8; r = r + 1) begin
            run_to_retire(); expected_gpr[r*16 +: 16] = 16'h5500 + 16'(r);
            check_architecture(16'h0200 + 16'(3*(r+1)));
            check(retirements == r+1, "multi-MOV retirement count");
        end

        // Pause, malformed control, reset and redirect at every functional boundary.
        for (integer stage = 0; stage < 4; stage = stage + 1) begin
            program_mov(16'h0300, 3'd0, 16'h1234);
            program_mov(16'h0381, 3'd7, 16'hBEEF);
            setup(16'h0300); reach_stage(stage);
            paused_pc = debug_micro_pc;
            execute_enable = 0; flags_write_en = 0; ready = 1;
            paused_count = debug_prefetch_count;
            repeat (5) begin
                tick(); check(debug_micro_pc == paused_pc && !instruction_retired &&
                              debug_prefetch_count == paused_count, "pause preserves operation context");
            end
            execute_enable = 1;
            // An invalid control transaction freezes semantic progress atomically.
            redirect = 1; ip_write_en = 0;
            repeat (3) begin
                tick(); check(control_error && debug_micro_pc == paused_pc && !instruction_retired,
                              "malformed redirect cannot consume or commit");
            end
            redirect = 0;
            if (stage == 3) expected_gpr[15:0] = 16'h1234; // Earlier completed write is not rolled back.
            redirect_to(16'h0381);
            run_to_retire(); expected_gpr[127:112] = 16'hBEEF;
            check_architecture(16'h0384);
            check(retirements == 1, "canceled instruction did not retire");

            setup(16'h0300); reach_stage(stage); reset = 1; tick();
            check(!instruction_retired && !debug_micro_active && debug_ip == 16'hFFF0 &&
                  debug_gpr == 0 && debug_flags == 2 && debug_prefetch_count == 0, "reset during microcode");
            setup(16'h0381); run_to_retire(); expected_gpr[127:112] = 16'hBEEF;
            check_architecture(16'h0384);

            // Resume the same operation too: partial immediate bytes must survive.
            setup(16'h0300); reach_stage(stage);
            execute_enable = 0; flags_write_en = 0; ready = 1;
            repeat (6) tick();
            execute_enable = 1; run_to_retire(); expected_gpr[15:0] = 16'h1234;
            check_architecture(16'h0303);
            check(retirements == 1, "resume retires the original instruction exactly once");
        end
        $display("MICROCODE_EXECUTION PASS: 48 MOV vectors, 8-MOV stream, 4 cancellation/reset/resume boundaries; %0d checks; %0d underfill cycles",
                 checks, underfill_cycles);
        $finish;
    end
endmodule
