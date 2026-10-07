`timescale 1ns/1ps

// First increment: measure isolated instruction intervals on the
// normalized functional baseline.  This is an observation harness, not a
// historical 80286 timing claim.
module spk286_timing_calibration_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    string output_path;
    integer output_fd;
    integer retired_count = 0;
    integer sample_count = 0;
    logic [15:0] current_start_ip = 16'h0000;
    logic [63:0] current_start_cycle = 64'd0;
    logic [63:0] current_start_biu = 64'd0;
    logic [63:0] current_start_accepted = 64'd0;
    logic [63:0] current_start_wait = 64'd0;
    logic [63:0] current_start_prefetch = 64'd0;
    logic [63:0] current_start_response = 64'd0;
    logic [63:0] current_start_consume = 64'd0;
    logic [63:0] current_start_operand_wait = 64'd0;
    logic current_instruction_valid = 1'b0;
    logic current_saw_lock = 1'b0;
    string current_case;
    integer expected_case_index = 0;

    function automatic logic is_expected_start(input logic [15:0] ip);
        case (ip)
            16'h0100, 16'h0103, 16'h0106, 16'h0108, 16'h010C, 16'h0110:
                is_expected_start = 1'b1;
            default:
                is_expected_start = 1'b0;
        endcase
    endfunction

    function automatic logic [15:0] expected_start_ip(input integer index);
        case (index)
            0: expected_start_ip = 16'h0100;
            1: expected_start_ip = 16'h0103;
            2: expected_start_ip = 16'h0106;
            3: expected_start_ip = 16'h0108;
            4: expected_start_ip = 16'h010C;
            5: expected_start_ip = 16'h0110;
            default: expected_start_ip = 16'h0000;
        endcase
    endfunction

    function automatic logic [15:0] expected_end_ip(input integer index);
        case (index)
            0: expected_end_ip = 16'h0103;
            1: expected_end_ip = 16'h0106;
            2: expected_end_ip = 16'h0108;
            3: expected_end_ip = 16'h010C;
            4: expected_end_ip = 16'h0110;
            5: expected_end_ip = 16'h0114;
            default: expected_end_ip = 16'h0000;
        endcase
    endfunction

    spk286 dut (.*);

    task automatic observe;
        begin
            sample_count = sample_count + 1;
            if (debug_timing_trace_lock)
                current_saw_lock = 1'b1;

            if (debug_micro_active && current_instruction_valid &&
                debug_instruction_ip != current_start_ip)
                $fatal(1, "calibration instruction start changed before completion: %h -> %h",
                       current_start_ip, debug_instruction_ip);

            if (debug_micro_active && !current_instruction_valid &&
                expected_case_index < 6 &&
                debug_instruction_ip == expected_start_ip(expected_case_index)) begin
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
                case (debug_instruction_ip)
                    16'h0100: current_case = "mov_ax_imm";
                    16'h0103: current_case = "mov_bx_imm";
                    16'h0106: current_case = "alu_reg";
                    16'h0108: current_case = "mov_mem_read";
                    16'h010C: current_case = "mov_mem_write";
                    16'h0110: current_case = "branch_short";
                    default: $fatal(1, "calibration observed an unclassified instruction IP=%h",
                                    debug_instruction_ip);
                endcase
            end

            if (instruction_retired) begin
                if (!current_instruction_valid)
                    $fatal(1, "retirement without a measured instruction start IP=%h", debug_ip);
                if (!is_expected_start(current_start_ip) ||
                    current_start_ip != expected_start_ip(expected_case_index) ||
                    debug_ip != expected_end_ip(expected_case_index))
                    $fatal(1, "calibration sequence mismatch index=%0d case=%s start=%h end=%h",
                           expected_case_index, current_case, current_start_ip, debug_ip);
                case (expected_case_index)
                    0: if (debug_gpr[15:0] !== 16'h1234)
                           $fatal(1, "MOV AX,imm checkpoint mismatch AX=%h", debug_gpr[15:0]);
                    1: if (debug_gpr[63:48] !== 16'h5678)
                           $fatal(1, "MOV BX,imm checkpoint mismatch BX=%h", debug_gpr[63:48]);
                    2: begin
                           if (debug_gpr[15:0] !== 16'h68AC)
                               $fatal(1, "ADD AX,BX checkpoint mismatch AX=%h", debug_gpr[15:0]);
                           if (debug_flags !== 16'h0006)
                               $fatal(1, "ADD AX,BX FLAGS checkpoint mismatch FLAGS=%h", debug_flags);
                       end
                    3: if (debug_gpr[15:0] !== 16'hBEEF)
                           $fatal(1, "MOV AX,[mem] checkpoint mismatch AX=%h", debug_gpr[15:0]);
                    4: if (memory[16'h0202] !== 8'hEF || memory[16'h0203] !== 8'hBE)
                           $fatal(1, "MOV [mem],AX checkpoint mismatch memory=%h%h",
                                  memory[16'h0203], memory[16'h0202]);
                    5: if (debug_ip !== 16'h0114)
                           $fatal(1, "JMP checkpoint mismatch IP=%h", debug_ip);
                    default: $fatal(1, "unexpected calibration case index=%0d", expected_case_index);
                endcase
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
                retired_count = retired_count + 1;
                expected_case_index = expected_case_index + 1;
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
            if (bus_valid && ready && !reset && bus_write &&
                (bus_status == 4'd5 || bus_status == 4'd6)) begin
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

    initial begin
        if (!$value$plusargs("calibration_out=%s", output_path))
            output_path = "build/timing/spk286_timing_calibration.csv";
        output_fd = $fopen(output_path, "w");
        if (output_fd == 0)
            $fatal(1, "cannot open calibration output: %s", output_path);
        $fwrite(output_fd,
            "policy,case,start_ip,end_ip,final_flags,cycles,biu_busy_cycles,accepted_transfers,ready_wait_cycles,prefetch_requests,prefetch_responses,queue_consumes,operand_wait_cycles,saw_lock,final_phase,final_status,final_owner\n");

        for (integer i = 0; i < 65536; i = i + 1)
            memory[i] = 8'h00;

        // MOV AX,1234; MOV BX,5678; ADD AX,BX;
        // MOV AX,[0200]; MOV [0202],AX; JMP short over an unsupported byte; HLT.
        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h34; memory[16'h0102] = 8'h12;
        memory[16'h0103] = 8'hBB; memory[16'h0104] = 8'h78; memory[16'h0105] = 8'h56;
        memory[16'h0106] = 8'h01; memory[16'h0107] = 8'hD8;
        memory[16'h0108] = 8'h8B; memory[16'h0109] = 8'h06; memory[16'h010A] = 8'h00; memory[16'h010B] = 8'h02;
        memory[16'h010C] = 8'h89; memory[16'h010D] = 8'h06; memory[16'h010E] = 8'h02; memory[16'h010F] = 8'h02;
        memory[16'h0110] = 8'hEB; memory[16'h0111] = 8'h02;
        memory[16'h0112] = 8'h0F; memory[16'h0113] = 8'h0F;
        memory[16'h0114] = 8'hF4;
        memory[16'h0200] = 8'hEF; memory[16'h0201] = 8'hBE;

        reset = 1'b1;
        ready = 1'b0;
        execute_enable = 1'b0;
        tick();
        reset = 1'b0;
        segment_load_en = 1'b1;
        segment_load_index = 2'd1;
        segment_load_selector = 16'h0000;
        ip_write_en = 1'b1;
        ip_write_data = 16'h0100;
        redirect = 1'b1;
        tick();
        segment_load_en = 1'b0;
        ip_write_en = 1'b0;
        redirect = 1'b0;
        execute_enable = 1'b1;

        for (integer cycle = 0; cycle < 1400 && !halted; cycle = cycle + 1)
            tick();

        if (!halted)
            $fatal(1, "calibration stream did not reach HLT retired=%0d IP=%h", retired_count, debug_ip);
        if (retired_count != 6)
            $fatal(1, "unexpected calibration retire count=%0d IP=%h", retired_count, debug_ip);
        if (expected_case_index != 6)
            $fatal(1, "calibration did not observe every expected class index=%0d", expected_case_index);
        if (debug_gpr[15:0] !== 16'hBEEF || debug_gpr[63:48] !== 16'h5678 ||
            memory[16'h0202] !== 8'hEF || memory[16'h0203] !== 8'hBE)
            $fatal(1, "calibration architectural result AX=%h BX=%h memory=%h%h",
                   debug_gpr[15:0], debug_gpr[63:48], memory[16'h0203], memory[16'h0202]);
        if (unsupported_opcode || microcode_fault || control_error)
            $fatal(1, "calibration stream raised unsupported/fault control=%b unsupported=%b microfault=%b",
                   control_error, unsupported_opcode, microcode_fault);

        $fclose(output_fd);
        $display("TIMING CALIBRATION PASS records=%0d samples=%0d cycles=%0d",
                 retired_count, sample_count, debug_timing_cycle_count);
        $finish;
    end
endmodule
