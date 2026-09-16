`timescale 1ns/1ps

// Phase 9E entry contract.  The current policy is intentionally an
// observation-only normalized baseline.  This bank protects that boundary
// until independently validated Accurate/Fast/Max policies are introduced.
module spk286_timing_policy_contract_tb;
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
    logic [63:0] cycle_count, biu_busy_cycles, accepted_transfers, ready_wait_cycles;
    logic [63:0] prefetch_requests, prefetch_responses, queue_consume_count;
    logic [63:0] queue_empty_cycles, redirect_count, cancel_count, operand_wait_cycles;
    logic [63:0] event_request_count, event_complete_count, compatibility_delay_cycles;
    logic [3:0] trace_queue_count;
    logic [1:0] timing_policy = 2'd0;
    logic [7:0] trace_schema_version;
    logic [1:0] trace_policy;
    logic trace_valid, trace_write, trace_lock, trace_hold, trace_hlda, trace_ready;
    logic [63:0] trace_cycle;
    logic [23:0] trace_address;
    logic [3:0] trace_status;
    logic [15:0] trace_data;
    logic [1:0] trace_lane_mask, trace_owner;
    logic [2:0] trace_phase;
    integer checks = 0;

    spk286_timing_trace dut (.*);

    task automatic tick;
        #1 clk = 1'b1; #1 clk = 1'b0; #1;
    endtask

    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1) $fatal(1, "%s", message);
    endtask

    task automatic check_baseline;
        logic [1:0] expected_owner;
        begin
            check(trace_policy == 2'd0, "non-baseline timing policy was published");
            check(compatibility_delay_cycles == 64'd0,
                  "normalized baseline inserted a compatibility delay");
            check(trace_valid == !reset, "trace validity crossed the reset boundary");
            check(trace_queue_count == queue_count, "policy changed queue occupancy metadata");
            check(trace_ready == ready, "policy changed READY observation");
            check(trace_lock == bus_lock && trace_hold == hold_request && trace_hlda == hlda,
                  "policy changed ownership metadata");
            if (!bus_valid) begin
                check(trace_phase == 3'd0 && trace_owner == 2'd0 &&
                      trace_address == 24'h000000 && trace_status == 4'hF,
                      "idle baseline metadata is not canonical");
            end else begin
                expected_owner = bus_status == 4'h0 ? 2'd3 :
                                 bus_status == 4'hD ? 2'd1 : 2'd2;
                check(trace_owner == expected_owner && trace_address == address &&
                      trace_status == bus_status && trace_write == bus_write,
                      "baseline changed active bus identity");
                check(trace_phase == (ready ? 3'd2 : 3'd1),
                      "baseline changed READY phase classification");
            end
        end
    endtask

    initial begin
        tick();
        check_baseline();

        reset = 1'b0;
        tick();
        check_baseline();

        // Code ownership in both a READY wait and completion phase.
        bus_valid = 1'b1;
        bus_status = 4'hD;
        address = 24'h123456;
        bus_bhe_n = 1'b0;
        ready = 1'b0;
        tick();
        check_baseline();
        ready = 1'b1;
        tick();
        check_baseline();

        // Data ownership, implicit LOCK metadata and HOLD/HLDA observation.
        bus_status = 4'h6;
        bus_write = 1'b1;
        address = 24'h001001;
        bus_lock = 1'b1;
        hold_request = 1'b1;
        hlda = 1'b0;
        ready = 1'b0;
        tick();
        check_baseline();
        hlda = 1'b1;
        ready = 1'b1;
        tick();
        check_baseline();

        // INTA ownership, queue pressure and event edges remain observations.
        bus_status = 4'h0;
        bus_write = 1'b0;
        address = 24'h000120;
        bus_lock = 1'b0;
        hold_request = 1'b0;
        hlda = 1'b0;
        queue_count = 4'd0;
        execution_enable = 1'b1;
        ready = 1'b0;
        stream_restart = 1'b1;
        cancel_event = 1'b1;
        operand_wait = 1'b1;
        event_request = 1'b1;
        event_complete = 1'b1;
        tick();
        check_baseline();

        bus_valid = 1'b0;
        ready = 1'b0;
        prefetch_request_valid = 1'b1;
        prefetch_response_accept = 1'b1;
        queue_consume = 1'b1;
        tick();
        check_baseline();

        check(trace_schema_version == 8'd1, "baseline schema version changed unexpectedly");
        check(compatibility_delay_cycles == 0 && trace_policy == 0,
              "baseline policy counters changed after mixed observations");
        $display("TIMING POLICY CONTRACT PASS checks=%0d cycles=%0d", checks, cycle_count);
        $finish;
    end
endmodule
