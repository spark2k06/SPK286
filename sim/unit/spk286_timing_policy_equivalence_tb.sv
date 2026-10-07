`timescale 1ns/1ps

// Functional-equivalence evidence for the dependency-driven Max
// profile.  The policy is intentionally compared through the observation
// layer: policy metadata may differ, but counters, bus observations,
// ownership, queue state and dependency classifications must not.
module spk286_timing_policy_equivalence_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic ready = 1'b0;
    logic bus_valid = 1'b0, bus_write = 1'b0, bus_bhe_n = 1'b1;
    logic [3:0] bus_status = 4'hF;
    logic [23:0] address = 24'h0;
    logic [15:0] data_in = 16'h1234, data_out = 16'h5678;
    logic bus_lock = 1'b0, hold_request = 1'b0, hlda = 1'b0;
    logic prefetch_request_valid = 1'b0, prefetch_response_accept = 1'b0;
    logic [3:0] queue_count = 4'd0;
    logic queue_consume = 1'b0, execution_enable = 1'b0;
    logic stream_restart = 1'b0, cancel_event = 1'b0, operand_wait = 1'b0;
    logic event_request = 1'b0, event_complete = 1'b0;
    logic [1:0] baseline_policy = 2'd0, max_policy = 2'd2;

    logic [1:0] baseline_active, max_active;
    logic baseline_error, max_error, baseline_locked, max_locked;
    logic [63:0] base_cycle, max_cycle;
    logic [63:0] base_biu_busy, max_biu_busy;
    logic [63:0] base_accepted, max_accepted;
    logic [63:0] base_ready_wait, max_ready_wait;
    logic [63:0] base_prefetch_requests, max_prefetch_requests;
    logic [63:0] base_prefetch_responses, max_prefetch_responses;
    logic [63:0] base_queue_consumes, max_queue_consumes;
    logic [63:0] base_queue_empty, max_queue_empty;
    logic [63:0] base_redirects, max_redirects;
    logic [63:0] base_cancels, max_cancels;
    logic [63:0] base_operand_wait, max_operand_wait;
    logic [63:0] base_event_requests, max_event_requests;
    logic [63:0] base_event_completes, max_event_completes;
    logic [63:0] base_delays, max_delays;
    logic [3:0] base_queue, max_queue;
    logic [7:0] base_schema, max_schema;
    logic [1:0] base_trace_policy, max_trace_policy;
    logic base_valid, max_valid, base_write, max_write;
    logic [63:0] base_trace_cycle, max_trace_cycle;
    logic [23:0] base_trace_address, max_trace_address;
    logic [3:0] base_trace_status, max_trace_status;
    logic [15:0] base_trace_data, max_trace_data;
    logic [1:0] base_lane_mask, max_lane_mask;
    logic [1:0] base_owner, max_owner;
    logic base_lock, max_lock, base_hold, max_hold, base_hlda, max_hlda, base_ready, max_ready;
    logic [2:0] base_phase, max_phase;
    integer checks = 0;

    spk286_timing_policy baseline_selector (
        .clk(clk), .reset(reset), .requested_policy(baseline_policy),
        .active_policy(baseline_active), .selection_error(baseline_error),
        .selection_locked(baseline_locked)
    );
    spk286_timing_policy max_selector (
        .clk(clk), .reset(reset), .requested_policy(max_policy),
        .active_policy(max_active), .selection_error(max_error),
        .selection_locked(max_locked)
    );

    spk286_timing_trace baseline_trace (
        .clk(clk), .reset(reset), .ready(ready), .bus_valid(bus_valid),
        .bus_write(bus_write), .bus_bhe_n(bus_bhe_n), .bus_status(bus_status),
        .address(address), .data_in(data_in), .data_out(data_out),
        .bus_lock(bus_lock), .hold_request(hold_request), .hlda(hlda),
        .prefetch_request_valid(prefetch_request_valid),
        .prefetch_response_accept(prefetch_response_accept),
        .queue_count(queue_count), .queue_consume(queue_consume),
        .execution_enable(execution_enable), .stream_restart(stream_restart),
        .cancel_event(cancel_event), .operand_wait(operand_wait),
        .event_request(event_request), .event_complete(event_complete),
        .timing_policy(baseline_active), .cycle_count(base_cycle),
        .biu_busy_cycles(base_biu_busy), .accepted_transfers(base_accepted),
        .ready_wait_cycles(base_ready_wait),
        .prefetch_requests(base_prefetch_requests),
        .prefetch_responses(base_prefetch_responses),
        .queue_consume_count(base_queue_consumes),
        .queue_empty_cycles(base_queue_empty), .redirect_count(base_redirects),
        .cancel_count(base_cancels), .operand_wait_cycles(base_operand_wait),
        .event_request_count(base_event_requests),
        .event_complete_count(base_event_completes),
        .compatibility_delay_cycles(base_delays), .trace_queue_count(base_queue),
        .trace_schema_version(base_schema), .trace_policy(base_trace_policy),
        .trace_valid(base_valid), .trace_cycle(base_trace_cycle),
        .trace_address(base_trace_address), .trace_status(base_trace_status),
        .trace_data(base_trace_data), .trace_lane_mask(base_lane_mask),
        .trace_write(base_write), .trace_owner(base_owner),
        .trace_lock(base_lock), .trace_hold(base_hold), .trace_hlda(base_hlda),
        .trace_ready(base_ready), .trace_phase(base_phase)
    );

    spk286_timing_trace max_trace (
        .clk(clk), .reset(reset), .ready(ready), .bus_valid(bus_valid),
        .bus_write(bus_write), .bus_bhe_n(bus_bhe_n), .bus_status(bus_status),
        .address(address), .data_in(data_in), .data_out(data_out),
        .bus_lock(bus_lock), .hold_request(hold_request), .hlda(hlda),
        .prefetch_request_valid(prefetch_request_valid),
        .prefetch_response_accept(prefetch_response_accept),
        .queue_count(queue_count), .queue_consume(queue_consume),
        .execution_enable(execution_enable), .stream_restart(stream_restart),
        .cancel_event(cancel_event), .operand_wait(operand_wait),
        .event_request(event_request), .event_complete(event_complete),
        .timing_policy(max_active), .cycle_count(max_cycle),
        .biu_busy_cycles(max_biu_busy), .accepted_transfers(max_accepted),
        .ready_wait_cycles(max_ready_wait),
        .prefetch_requests(max_prefetch_requests),
        .prefetch_responses(max_prefetch_responses),
        .queue_consume_count(max_queue_consumes),
        .queue_empty_cycles(max_queue_empty), .redirect_count(max_redirects),
        .cancel_count(max_cancels), .operand_wait_cycles(max_operand_wait),
        .event_request_count(max_event_requests),
        .event_complete_count(max_event_completes),
        .compatibility_delay_cycles(max_delays), .trace_queue_count(max_queue),
        .trace_schema_version(max_schema), .trace_policy(max_trace_policy),
        .trace_valid(max_valid), .trace_cycle(max_trace_cycle),
        .trace_address(max_trace_address), .trace_status(max_trace_status),
        .trace_data(max_trace_data), .trace_lane_mask(max_lane_mask),
        .trace_write(max_write), .trace_owner(max_owner),
        .trace_lock(max_lock), .trace_hold(max_hold), .trace_hlda(max_hlda),
        .trace_ready(max_ready), .trace_phase(max_phase)
    );

    task automatic tick;
        #1 clk = 1'b1; #1 clk = 1'b0; #1;
    endtask

    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1) $fatal(1, "%s", message);
    endtask

    task automatic compare_observation;
        begin
            check(baseline_active == 2'd0 && !baseline_error && baseline_locked == !reset,
                  "baseline selector boundary changed");
            check(max_active == 2'd2 && !max_error && max_locked == !reset,
                  "Max selector boundary changed");
            check(base_cycle == max_cycle && base_biu_busy == max_biu_busy &&
                  base_accepted == max_accepted && base_ready_wait == max_ready_wait,
                  "Max changed bus counters");
            check(base_prefetch_requests == max_prefetch_requests &&
                  base_prefetch_responses == max_prefetch_responses &&
                  base_queue_consumes == max_queue_consumes &&
                  base_queue_empty == max_queue_empty,
                  "Max changed prefetch counters");
            check(base_redirects == max_redirects && base_cancels == max_cancels &&
                  base_operand_wait == max_operand_wait &&
                  base_event_requests == max_event_requests &&
                  base_event_completes == max_event_completes &&
                  base_delays == max_delays,
                  "Max changed dependency counters");
            check(base_queue == max_queue && base_schema == max_schema &&
                  base_valid == max_valid && base_trace_cycle == max_trace_cycle &&
                  base_trace_address == max_trace_address &&
                  base_trace_status == max_trace_status &&
                  base_trace_data == max_trace_data &&
                  base_lane_mask == max_lane_mask && base_write == max_write &&
                  base_owner == max_owner && base_lock == max_lock &&
                  base_hold == max_hold && base_hlda == max_hlda &&
                  base_ready == max_ready && base_phase == max_phase,
                  "Max changed normalized trace observation");
            check(base_trace_policy == 2'd0 && max_trace_policy == 2'd2,
                  "policy metadata did not identify the selected profile");
        end
    endtask

    initial begin
        tick();
        compare_observation();

        reset = 1'b0;
        tick();
        compare_observation();

        // Code wait and completion, including an odd entry point.
        bus_valid = 1'b1;
        bus_status = 4'hD;
        address = 24'h123457;
        bus_bhe_n = 1'b0;
        ready = 1'b0;
        tick();
        compare_observation();
        ready = 1'b1;
        tick();
        compare_observation();

        // Data ownership, LOCK and HOLD/HLDA remain unchanged.
        bus_status = 4'h6;
        bus_write = 1'b1;
        address = 24'h001000;
        bus_lock = 1'b1;
        hold_request = 1'b1;
        hlda = 1'b0;
        ready = 1'b0;
        tick();
        compare_observation();
        hlda = 1'b1;
        ready = 1'b1;
        tick();
        compare_observation();

        // Queue starvation, refill edge, redirect/cancel and event edges.
        bus_valid = 1'b0;
        bus_write = 1'b0;
        bus_lock = 1'b0;
        hold_request = 1'b0;
        hlda = 1'b0;
        queue_count = 4'd0;
        execution_enable = 1'b1;
        prefetch_request_valid = 1'b1;
        prefetch_response_accept = 1'b1;
        queue_consume = 1'b1;
        stream_restart = 1'b1;
        cancel_event = 1'b1;
        operand_wait = 1'b1;
        event_request = 1'b1;
        event_complete = 1'b1;
        tick();
        compare_observation();

        prefetch_request_valid = 1'b0;
        prefetch_response_accept = 1'b0;
        queue_consume = 1'b0;
        stream_restart = 1'b0;
        cancel_event = 1'b0;
        operand_wait = 1'b0;
        event_request = 1'b0;
        event_complete = 1'b0;
        queue_count = 4'd6;
        execution_enable = 1'b0;
        tick();
        compare_observation();

        // Runtime requests do not alter either selected profile.
        baseline_policy = 2'd2;
        max_policy = 2'd0;
        tick();
        compare_observation();

        $display("TIMING POLICY MAX EQUIVALENCE PASS checks=%0d cycles=%0d", checks, base_cycle);
        $finish;
    end
endmodule
