// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

// Remaining instruction classes.  These are normalized functional
// observations; they are not historical 80286 timing claims.
module spk286_timing_calibration_extra_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    string output_path;
    integer output_fd;
    integer scenario = 0;
    integer expected_index = 0;
    integer expected_count = 0;
    integer sample_count = 0;
    integer completed_records = 0;
    logic current_instruction_valid = 1'b0;
    logic [15:0] current_start_ip = 16'h0000;
    logic [63:0] current_start_cycle = 64'd0;
    logic [63:0] current_start_biu = 64'd0;
    logic [63:0] current_start_accepted = 64'd0;
    logic [63:0] current_start_wait = 64'd0;
    logic [63:0] current_start_prefetch = 64'd0;
    logic [63:0] current_start_response = 64'd0;
    logic [63:0] current_start_consume = 64'd0;
    logic [63:0] current_start_operand_wait = 64'd0;
    logic current_saw_lock = 1'b0;
    string current_case;

    spk286 dut (.*);

    function automatic logic [15:0] expected_start_ip(input integer which, input integer index);
        case (which)
            0: expected_start_ip = 16'h0100; // odd_word_read
            1: case (index)
                   0: expected_start_ip = 16'h0100; // near_call
                   1: expected_start_ip = 16'h0109; // near_ret
                   default: expected_start_ip = 16'h0000;
               endcase
            2: expected_start_ip = 16'h0100; // rep_movsb
            3: expected_start_ip = 16'h0100; // int3
            4: expected_start_ip = 16'h0100; // divide_fault
            default: expected_start_ip = 16'h0000;
        endcase
    endfunction

    function automatic logic [15:0] expected_end_ip(input integer which, input integer index);
        case (which)
            0: expected_end_ip = 16'h0104;
            1: case (index)
                   0: expected_end_ip = 16'h0106;
                   1: expected_end_ip = 16'h0103;
                   default: expected_end_ip = 16'h0000;
               endcase
            2: expected_end_ip = 16'h0102;
            3: expected_end_ip = 16'h0200;
            4: expected_end_ip = 16'h0200;
            default: expected_end_ip = 16'h0000;
        endcase
    endfunction

    function automatic string expected_case_name(input integer which, input integer index);
        case (which)
            0: expected_case_name = "odd_word_read";
            1: case (index)
                   0: expected_case_name = "near_call";
                   1: expected_case_name = "near_ret";
                   default: expected_case_name = "unclassified";
               endcase
            2: expected_case_name = "rep_movsb";
            3: expected_case_name = "int3";
            4: expected_case_name = "divide_fault";
            default: expected_case_name = "unclassified";
        endcase
    endfunction

    task automatic putword(input integer address_value, input logic [15:0] value);
        begin
            memory[address_value] = value[7:0];
            memory[address_value + 1] = value[15:8];
        end
    endtask

    task automatic write_gpr(input logic [2:0] index, input logic [15:0] value);
        begin
            gpr_write_en = 1'b1;
            gpr_write_index = index;
            gpr_write_data = value;
            tick();
            gpr_write_en = 1'b0;
        end
    endtask

    task automatic observe;
        logic completion;
        begin
            sample_count = sample_count + 1;
            if (debug_timing_trace_lock)
                current_saw_lock = 1'b1;

            if (debug_micro_active && current_instruction_valid &&
                debug_instruction_ip != current_start_ip)
                $fatal(1, "extra calibration instruction start changed before completion: %h -> %h",
                       current_start_ip, debug_instruction_ip);

            if (debug_micro_active && !current_instruction_valid &&
                expected_index < expected_count &&
                debug_instruction_ip == expected_start_ip(scenario, expected_index)) begin
                current_start_ip = debug_instruction_ip;
                current_start_cycle = debug_timing_cycle_count;
                current_start_biu = debug_timing_biu_busy_cycles;
                current_start_accepted = debug_timing_accepted_transfers;
                current_start_wait = debug_timing_ready_wait_cycles;
                current_start_prefetch = debug_timing_prefetch_requests;
                current_start_response = debug_timing_prefetch_responses;
                current_start_consume = debug_timing_queue_consumes;
                current_start_operand_wait = debug_timing_operand_wait_cycles;
                current_instruction_valid = 1'b1;
                current_saw_lock = 1'b0;
                current_case = expected_case_name(scenario, expected_index);
            end

            completion = instruction_retired;
            if (scenario == 4 && event_completed && !instruction_retired &&
                debug_event_vector == 8'd0)
                completion = 1'b1;

            if (completion && current_instruction_valid) begin
                if (debug_ip != expected_end_ip(scenario, expected_index))
                    $fatal(1, "extra calibration endpoint mismatch scenario=%0d index=%0d case=%s start=%h end=%h expected=%h",
                           scenario, expected_index, current_case, current_start_ip, debug_ip,
                           expected_end_ip(scenario, expected_index));
                if (scenario == 3 && debug_event_vector != 8'd3)
                    $fatal(1, "INT3 calibration completed with vector=%0d", debug_event_vector);
                if (scenario == 4 && debug_event_vector != 8'd0)
                    $fatal(1, "divide-fault calibration completed with vector=%0d", debug_event_vector);
                $fwrite(output_fd,
                    "0,%s,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    current_case,
                    current_start_ip,
                    debug_ip,
                    debug_flags,
                    debug_timing_cycle_count - current_start_cycle,
                    debug_timing_biu_busy_cycles - current_start_biu,
                    debug_timing_accepted_transfers - current_start_accepted,
                    debug_timing_ready_wait_cycles - current_start_wait,
                    debug_timing_prefetch_requests - current_start_prefetch,
                    debug_timing_prefetch_responses - current_start_response,
                    debug_timing_queue_consumes - current_start_consume,
                    debug_timing_operand_wait_cycles - current_start_operand_wait,
                    current_saw_lock,
                    debug_timing_trace_phase,
                    debug_timing_trace_status,
                    debug_timing_trace_owner);
                $fflush(output_fd);
                completed_records = completed_records + 1;
                expected_index = expected_index + 1;
                current_instruction_valid = 1'b0;
            end
        end
    endtask

    task automatic tick;
        begin
            #1;
            data_in = 16'h0000;
            if (bus_valid && address < 24'd65536)
                data_in = {memory[{address[15:1], 1'b1}], memory[{address[15:1], 1'b0}]};
            ready = bus_valid;
            if (bus_valid && ready && !reset && bus_write) begin
                if (address[0]) begin
                    memory[address[15:0]] = data_out[15:8];
                end else begin
                    memory[address[15:0]] = data_out[7:0];
                    if (!bus_bhe_n)
                        memory[address[15:0] + 16'd1] = data_out[15:8];
                end
            end
            #1;
            clk = 1'b1; #5; clk = 1'b0; #1;
            observe();
        end
    endtask

    task automatic start_cpu(input logic [15:0] start_ip);
        begin
            segment_load_en = 1'b1;
            segment_load_index = 2'd1;
            segment_load_selector = 16'h0000;
            ip_write_en = 1'b1;
            ip_write_data = start_ip;
            redirect = 1'b1;
            tick();
            segment_load_en = 1'b0;
            ip_write_en = 1'b0;
            redirect = 1'b0;
            execute_enable = 1'b1;
        end
    endtask

    task automatic setup_scenario(input integer which);
        begin
            scenario = which;
            expected_index = 0;
            expected_count = which == 1 ? 2 : 1;
            current_instruction_valid = 1'b0;
            current_saw_lock = 1'b0;
            execute_enable = 1'b0;
            reset = 1'b1;
            ready = 1'b0;
            intr = 1'b0;
            nmi = 1'b0;
            hold_request = 1'b0;
            redirect = 1'b0;
            ip_write_en = 1'b0;
            gpr_write_en = 1'b0;
            flags_write_en = 1'b0;
            segment_load_en = 1'b0;
            tick();
            reset = 1'b0;
            for (integer i = 256; i < 768; i = i + 1)
                memory[i] = 8'hF4;

            case (which)
                0: begin
                    memory[16'h0100] = 8'h8B; memory[16'h0101] = 8'h06;
                    memory[16'h0102] = 8'h01; memory[16'h0103] = 8'h03;
                    memory[16'h0301] = 8'h34; memory[16'h0302] = 8'h12;
                end
                1: begin
                    memory[16'h0100] = 8'hE8; memory[16'h0101] = 8'h03; memory[16'h0102] = 8'h00;
                    memory[16'h0106] = 8'hB8; memory[16'h0107] = 8'h34; memory[16'h0108] = 8'h12;
                    memory[16'h0109] = 8'hC3;
                    write_gpr(3'd4, 16'h1003);
                end
                2: begin
                    memory[16'h0100] = 8'hF3; memory[16'h0101] = 8'hA4;
                    memory[16'h0300] = 8'h5A; memory[16'h0301] = 8'hA5;
                    write_gpr(3'd1, 16'd2); // CX
                    write_gpr(3'd6, 16'h0300); // SI
                    write_gpr(3'd7, 16'h0400); // DI
                end
                3: begin
                    memory[16'h0100] = 8'hCC;
                    putword(12, 16'h0200);
                    putword(14, 16'h0000);
                    memory[16'h0200] = 8'hCF;
                end
                4: begin
                    memory[16'h0100] = 8'hF7; memory[16'h0101] = 8'hF1;
                    putword(0, 16'h0200);
                    putword(2, 16'h0000);
                    memory[16'h0200] = 8'hF4;
                    write_gpr(3'd1, 16'h0000); // DIV CX -> #DE
                end
                default: $fatal(1, "invalid extra timing scenario=%0d", which);
            endcase
            start_cpu(16'h0100);
        end
    endtask

    task automatic run_scenario;
        integer deadline;
        begin
            deadline = 0;
            while ((!halted || expected_index < expected_count) && deadline < 1800) begin
                tick();
                deadline = deadline + 1;
                if (unsupported_opcode || microcode_fault || control_error)
                    $fatal(1, "extra calibration control failure scenario=%0d IP=%h opcode=%h",
                           scenario, debug_ip, debug_opcode);
            end
            if (!halted || expected_index != expected_count)
                $fatal(1, "extra calibration scenario=%0d incomplete halted=%b records=%0d/%0d IP=%h",
                       scenario, halted, expected_index, expected_count, debug_ip);
            case (scenario)
                0: if (debug_gpr[15:0] !== 16'h1234)
                       $fatal(1, "odd-word read result AX=%h", debug_gpr[15:0]);
                1: if (debug_gpr[79:64] !== 16'h1003 || debug_gpr[15:0] !== 16'h1234)
                       $fatal(1, "near call/return state SP=%h AX=%h", debug_gpr[79:64], debug_gpr[15:0]);
                2: if (debug_gpr[31:16] !== 16'h0000 || debug_gpr[111:96] !== 16'h0302 ||
                       debug_gpr[127:112] !== 16'h0402 || memory[16'h0400] !== 8'h5A ||
                       memory[16'h0401] !== 8'hA5)
                       $fatal(1, "REP MOVSB state CX=%h SI=%h DI=%h data=%h%h",
                              debug_gpr[31:16], debug_gpr[111:96], debug_gpr[127:112],
                              memory[16'h0401], memory[16'h0400]);
                3: if (debug_event_vector !== 8'd3)
                       $fatal(1, "INT3 final vector=%0d", debug_event_vector);
                4: if (debug_event_vector !== 8'd0)
                       $fatal(1, "divide-fault final vector=%0d", debug_event_vector);
                default: $fatal(1, "invalid completed scenario=%0d", scenario);
            endcase
        end
    endtask

    initial begin
        if (!$value$plusargs("calibration_extra_out=%s", output_path))
            output_path = "build/timing/spk286_timing_calibration_extra.csv";
        output_fd = $fopen(output_path, "w");
        if (output_fd == 0)
            $fatal(1, "cannot open extra calibration output: %s", output_path);
        $fwrite(output_fd,
            "policy,case,start_ip,end_ip,final_flags,cycles,biu_busy_cycles,accepted_transfers,ready_wait_cycles,prefetch_requests,prefetch_responses,queue_consumes,operand_wait_cycles,saw_lock,final_phase,final_status,final_owner\n");
        for (integer i = 0; i < 65536; i = i + 1)
            memory[i] = 8'hF4;

        for (integer which = 0; which < 5; which = which + 1) begin
            setup_scenario(which);
            run_scenario();
        end

        if (completed_records != 6)
            $fatal(1, "unexpected extra calibration record count=%0d", completed_records);
        $fclose(output_fd);
        $display("TIMING EXTRA CALIBRATION PASS records=%0d samples=%0d cycles=%0d",
                 completed_records, sample_count, debug_timing_cycle_count);
        $finish;
    end
endmodule
