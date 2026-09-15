`timescale 1ns/1ps

module spk286_timing_trace_tb;
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

    initial begin
        tick();
        check(cycle_count == 0 && accepted_transfers == 0, "reset clears counters");
        reset = 1'b0;
        tick();
        check(cycle_count == 1 && trace_valid && trace_phase == 3'd0, "idle cycle is traced");

        bus_valid = 1'b1;
        bus_status = 4'hD;
        address = 24'h123456;
        bus_bhe_n = 1'b0;
        ready = 1'b0;
        tick();
        tick();
        check(biu_busy_cycles == 2 && ready_wait_cycles == 2, "READY waits are counted");
        check(trace_owner == 2'd1 && trace_lane_mask == 2'b11 && trace_phase == 3'd1,
              "code wait trace fields are decoded");
        ready = 1'b1;
        tick();
        check(accepted_transfers == 1 && trace_phase == 3'd2, "READY completion is counted");
        bus_valid = 1'b0;
        ready = 1'b0;

        prefetch_request_valid = 1'b1;
        tick();
        tick();
        prefetch_request_valid = 1'b0;
        prefetch_response_accept = 1'b1;
        tick();
        prefetch_response_accept = 1'b0;
        queue_count = 4'd2;
        queue_consume = 1'b1;
        tick();
        queue_consume = 1'b0;
        check(prefetch_requests == 1 && prefetch_responses == 1 && queue_consume_count == 1,
              "prefetch and queue events are counted");

        stream_restart = 1'b1;
        cancel_event = 1'b1;
        operand_wait = 1'b1;
        event_request = 1'b1;
        event_complete = 1'b1;
        tick();
        tick();
        check(redirect_count == 1 && cancel_count == 1 && operand_wait_cycles == 2,
              "redirect, cancel and operand waits are counted");
        check(event_request_count == 1 && event_complete_count == 1 &&
              compatibility_delay_cycles == 0, "event schema counters are stable");
        check(trace_schema_version == 1 && trace_policy == 0 && trace_queue_count == 2,
              "trace schema metadata is exposed");

        // Exercise data, INTA and observation-only ownership metadata,
        // including odd-byte lanes, write/read selection and HOLD/HLDA.
        bus_valid = 1'b1;
        bus_status = 4'h6;
        bus_write = 1'b1;
        bus_bhe_n = 1'b1;
        address = 24'h001001;
        data_out = 16'hABCD;
        bus_lock = 1'b1;
        hold_request = 1'b1;
        hlda = 1'b1;
        ready = 1'b1;
        tick();
        check(trace_owner == 2'd2 && trace_lane_mask == 2'b10 && trace_write &&
              trace_data == 16'hABCD && trace_lock && trace_hold && trace_hlda &&
              trace_phase == 3'd2, "data write, odd lane and HOLD metadata are traced");

        bus_status = 4'h0;
        bus_write = 1'b0;
        bus_bhe_n = 1'b0;
        address = 24'h000120;
        data_in = 16'hC17E;
        bus_lock = 1'b0;
        hold_request = 1'b0;
        hlda = 1'b0;
        ready = 1'b0;
        tick();
        check(trace_owner == 2'd3 && trace_lane_mask == 2'b11 && !trace_write &&
              trace_data == 16'hC17E && trace_phase == 3'd1,
              "INTA read and READY wait metadata are traced");
        bus_valid = 1'b0;
        ready = 1'b0;
        execution_enable = 1'b1;
        queue_count = 4'd0;
        tick();
        check(queue_empty_cycles > 0, "queue occupancy observation distinguishes empty execution cycles");
        $display("TIMING TRACE PASS checks=%0d cycles=%0d", checks, cycle_count);
        $finish;
    end
endmodule
