// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module spk286_timing_capture_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    string trace_path;
    integer trace_fd;
    integer sample_cycle = 0;
    integer records = 0;
    integer bus_contract_checks = 0;
    integer ready_wait_completions = 0;
    logic [63:0] operand_model_wait_cycles = 64'd0;
    logic operand_model_wait_sample = 1'b0;
    logic saw_lock = 1'b0;
    logic previous_trace_valid = 1'b0;
    logic previous_wait = 1'b0;
    logic [23:0] previous_address = 24'h0;
    logic [3:0] previous_status = 4'hF;
    logic [1:0] previous_lane_mask = 2'b00;
    logic previous_write = 1'b0;
    logic [1:0] previous_owner = 2'd0;
    logic [15:0] previous_data = 16'h0;

    spk286 dut (.*);

    // Independent operand-wait model.  It classifies only an effective
    // memory service that is blocked before BIU admission or while awaiting a
    // response.  It deliberately does not read operand.timing_wait.
    task automatic sample_operand_wait_model;
        logic effective_memory;
        logic admission_wait;
        logic response_wait;
        begin
            effective_memory = dut.operand.allowed && dut.operand.is_memory;
            admission_wait = effective_memory && !dut.operand.pending_q &&
                             !dut.operand.request_check && dut.operand.within_limit &&
                             dut.operand.memory_request && !dut.memory_request_ready;
            response_wait = effective_memory && dut.operand.pending_q &&
                            dut.operand.memory_response_ready &&
                            !dut.memory_response_valid;
            if (admission_wait === 1'bx || response_wait === 1'bx)
                $fatal(1, "operand wait model observed an unknown handshake");
            operand_model_wait_sample = admission_wait || response_wait;
            if (operand_model_wait_sample === 1'bx)
                $fatal(1, "operand wait model classification is unknown");
        end
    endtask

    task automatic check_bus_contract;
        logic [1:0] expected_owner;
        begin
            bus_contract_checks = bus_contract_checks + 1;
            if (debug_timing_trace_phase == 3'd0) begin
                if (debug_timing_trace_address !== 24'h000000 ||
                    debug_timing_trace_status !== 4'hF ||
                    debug_timing_trace_data !== 16'h0000 ||
                    debug_timing_trace_lane_mask !== 2'b00 ||
                    debug_timing_trace_write !== 1'b0 ||
                    debug_timing_trace_owner !== 2'd0)
                    $fatal(1, "idle bus contract fields are incoherent");
            end else begin
                expected_owner = debug_timing_trace_status == 4'h0 ? 2'd3 :
                                 debug_timing_trace_status == 4'hD ? 2'd1 : 2'd2;
                if (debug_timing_trace_status == 4'hF ||
                    debug_timing_trace_owner !== expected_owner ||
                    debug_timing_trace_lane_mask == 2'b00 ||
                    debug_timing_trace_ready !== (debug_timing_trace_phase == 3'd2))
                    $fatal(1, "active bus contract fields are incoherent");
                if (debug_timing_trace_address[0]) begin
                    if (debug_timing_trace_lane_mask !== 2'b10)
                        $fatal(1, "odd active bus address has invalid lane mask");
                end else if (debug_timing_trace_lane_mask !== 2'b01 &&
                             debug_timing_trace_lane_mask !== 2'b11) begin
                    $fatal(1, "even active bus address has invalid lane mask");
                end
            end

            if (previous_trace_valid && previous_wait) begin
                if (debug_timing_trace_phase == 3'd0)
                    $fatal(1, "READY-wait transaction disappeared before completion");
                if (debug_timing_trace_address !== previous_address ||
                    debug_timing_trace_status !== previous_status ||
                    debug_timing_trace_lane_mask !== previous_lane_mask ||
                    debug_timing_trace_write !== previous_write ||
                    debug_timing_trace_owner !== previous_owner)
                    $fatal(1, "READY-wait transaction identity changed");
                if (previous_write && debug_timing_trace_data !== previous_data)
                    $fatal(1, "READY-wait write data changed");
                if (debug_timing_trace_phase == 3'd2)
                    ready_wait_completions = ready_wait_completions + 1;
            end

            previous_trace_valid = 1'b1;
            previous_wait = debug_timing_trace_phase == 3'd1;
            previous_address = debug_timing_trace_address;
            previous_status = debug_timing_trace_status;
            previous_lane_mask = debug_timing_trace_lane_mask;
            previous_write = debug_timing_trace_write;
            previous_owner = debug_timing_trace_owner;
            previous_data = debug_timing_trace_data;
        end
    endtask

    task automatic write_trace_record;
        begin
            if (debug_timing_trace_valid) begin
                $fwrite(trace_fd,
                    "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    debug_timing_schema_version,
                    debug_timing_policy,
                    reset,
                    debug_timing_trace_valid,
                    debug_timing_trace_cycle,
                    debug_timing_trace_phase,
                    debug_timing_trace_address,
                    debug_timing_trace_status,
                    debug_timing_trace_data,
                    debug_timing_trace_lane_mask,
                    debug_timing_trace_write,
                    debug_timing_trace_owner,
                    debug_timing_trace_lock,
                    debug_timing_trace_hold,
                    debug_timing_trace_hlda,
                    debug_timing_trace_ready,
                    debug_timing_queue_count,
                    debug_timing_cycle_count,
                    debug_timing_biu_busy_cycles,
                    debug_timing_accepted_transfers,
                    debug_timing_ready_wait_cycles,
                    debug_timing_prefetch_requests,
                    debug_timing_prefetch_responses,
                    debug_timing_queue_consumes,
                    debug_timing_queue_empty_cycles,
                    debug_timing_redirects,
                    debug_timing_cancels,
                    debug_timing_operand_wait_cycles,
                    debug_timing_event_requests,
                    debug_timing_event_completes,
                    debug_timing_compatibility_delay_cycles,
                    halted);
                records = records + 1;
            end
        end
    endtask

    task automatic tick;
        begin
            #1;
            data_in = 16'h0F0F;
            if (bus_valid && address < 24'd65536)
                data_in = {memory[{address[15:1], 1'b1}], memory[{address[15:1], 1'b0}]};
            ready = bus_valid && ((sample_cycle % 4) != 1);
            // Let simulator delta cycles settle after driving the sampled
            // inputs; the trace is an observation, not a same-delta race.
            #1;
            sample_operand_wait_model();
            write_trace_record();
            if (debug_timing_trace_valid)
                check_bus_contract();
            if (debug_timing_trace_lock)
                saw_lock = 1'b1;
            #4;
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
            clk = 1'b1; #5; clk = 1'b0; #1;
            if (operand_model_wait_sample)
                operand_model_wait_cycles = operand_model_wait_cycles + 64'd1;
            if (debug_timing_operand_wait_cycles !== operand_model_wait_cycles)
                $fatal(1, "operand wait counter diverges from independent model at cycle %0d: rtl=%0d model=%0d",
                       sample_cycle, debug_timing_operand_wait_cycles,
                       operand_model_wait_cycles);
            sample_cycle = sample_cycle + 1;
        end
    endtask

    task automatic check(input logic condition, input string message);
        if (condition !== 1'b1)
            $fatal(1, "%s IP=%h AX=%h records=%0d transfers=%0d waits=%0d lock=%b halted=%b",
                   message, debug_ip, debug_gpr[15:0], records,
                   debug_timing_accepted_transfers,
                   debug_timing_ready_wait_cycles, saw_lock, halted);
    endtask

    initial begin
        if (!$value$plusargs("trace_out=%s", trace_path))
            trace_path = "build/timing/spk286_timing_capture.csv";
        trace_fd = $fopen(trace_path, "w");
        if (trace_fd == 0)
            $fatal(1, "cannot open timing trace output: %s", trace_path);
        $fwrite(trace_fd,
            "schema_version,policy,reset,trace_valid,trace_cycle,phase,address,status,data,lane_mask,write,owner,lock,hold,hlda,ready,queue_count,cpu_cycles,biu_busy_cycles,accepted_transfers,ready_wait_cycles,prefetch_requests,prefetch_responses,queue_consumes,queue_empty_cycles,redirects,cancels,operand_wait_cycles,event_requests,event_completes,compatibility_delay_cycles,halted\n");

        for (integer i = 0; i < 65536; i = i + 1)
            memory[i] = 8'h0F;
        // MOV AX,1234; XCHG [0200],AX (implicit LOCK); HLT.
        // The initial memory value makes the exchange externally observable.
        memory[16'h0100] = 8'hB8;
        memory[16'h0101] = 8'h34;
        memory[16'h0102] = 8'h12;
        memory[16'h0103] = 8'h87;
        memory[16'h0104] = 8'h06;
        memory[16'h0105] = 8'h00;
        memory[16'h0106] = 8'h02;
        memory[16'h0107] = 8'hF4;
        memory[16'h0200] = 8'h5A;
        memory[16'h0201] = 8'hC3;

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
        segment_load_en = 1'b1;
        segment_load_index = 2'd1;
        segment_load_selector = 16'h0000;
        redirect = 1'b1;
        ip_write_en = 1'b1;
        ip_write_data = 16'h0100;
        tick();
        segment_load_en = 1'b0;
        redirect = 1'b0;
        ip_write_en = 1'b0;
        execute_enable = 1'b1;

        for (integer cycle = 0; cycle < 220; cycle = cycle + 1)
            tick();

        check(records > 20, "capture contains enough records");
        check(bus_contract_checks > 20, "capture checks the normalized BIU contract");
        check(ready_wait_completions > 0, "capture completes a READY-wait transaction");
        check(debug_timing_accepted_transfers > 0, "capture observes accepted bus transfers");
        check(debug_timing_ready_wait_cycles > 0, "capture observes deterministic READY waits");
        check(debug_timing_prefetch_requests > 0, "capture observes prefetch requests");
        check(debug_timing_queue_consumes > 0, "capture observes queue consumption");
        check(saw_lock, "capture observes implicit LOCK");
        check(halted, "capture reaches HLT");
        check(debug_gpr[15:0] == 16'hC35A, "capture preserves the exchanged AX value");
        check(memory[16'h0200] == 8'h34 && memory[16'h0201] == 8'h12,
              "capture workload completes the locked exchange");
        check(debug_timing_schema_version == 8'd1 && debug_timing_policy == 2'd0,
              "capture metadata remains versioned baseline policy");
        $fclose(trace_fd);
        $display("TIMING CAPTURE PASS trace=%s records=%0d cycles=%0d transfers=%0d waits=%0d",
                 trace_path, records, debug_timing_cycle_count,
                 debug_timing_accepted_transfers, debug_timing_ready_wait_cycles);
        $finish;
    end
endmodule
