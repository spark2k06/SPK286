// SPDX-License-Identifier: MIT
// Timing observation only. This module counts and exposes existing
// CPU/BIU relationships; it does not insert waits or alter functional state.
`timescale 1ns/1ps

module spk286_timing_trace (
    input  logic        clk,
    input  logic        reset,
    input  logic        ready,
    input  logic        bus_valid,
    input  logic        bus_write,
    input  logic        bus_bhe_n,
    input  logic [3:0]  bus_status,
    input  logic [23:0] address,
    input  logic [15:0] data_in,
    input  logic [15:0] data_out,
    input  logic        bus_lock,
    input  logic        hold_request,
    input  logic        hlda,
    input  logic        prefetch_request_valid,
    input  logic        prefetch_response_accept,
    input  logic [3:0]  queue_count,
    input  logic        queue_consume,
    input  logic        execution_enable,
    input  logic        stream_restart,
    input  logic        cancel_event,
    input  logic        operand_wait,
    input  logic        event_request,
    input  logic        event_complete,
    input  logic [1:0]  timing_policy,
    output logic [63:0] cycle_count,
    output logic [63:0] biu_busy_cycles,
    output logic [63:0] accepted_transfers,
    output logic [63:0] ready_wait_cycles,
    output logic [63:0] prefetch_requests,
    output logic [63:0] prefetch_responses,
    output logic [63:0] queue_consume_count,
    output logic [63:0] queue_empty_cycles,
    output logic [63:0] redirect_count,
    output logic [63:0] cancel_count,
    output logic [63:0] operand_wait_cycles,
    output logic [63:0] event_request_count,
    output logic [63:0] event_complete_count,
    output logic [63:0] compatibility_delay_cycles,
    output logic [3:0]  trace_queue_count,
    output logic [7:0]  trace_schema_version,
    output logic [1:0]  trace_policy,
    output logic        trace_valid,
    output logic [63:0] trace_cycle,
    output logic [23:0] trace_address,
    output logic [3:0]  trace_status,
    output logic [15:0] trace_data,
    output logic [1:0]  trace_lane_mask,
    output logic        trace_write,
    output logic [1:0]  trace_owner,
    output logic        trace_lock,
    output logic        trace_hold,
    output logic        trace_hlda,
    output logic        trace_ready,
    output logic [2:0]  trace_phase
);
    logic prefetch_request_q;
    logic stream_restart_q, cancel_event_q;
    logic event_request_q, event_complete_q;

    wire bus_accept = bus_valid && ready;
    wire bus_wait = bus_valid && !ready;
    wire prefetch_request_edge = prefetch_request_valid && !prefetch_request_q;
    wire redirect_edge = stream_restart && !stream_restart_q;
    wire cancel_edge = cancel_event && !cancel_event_q;
    wire event_request_edge = event_request && !event_request_q;
    wire event_complete_edge = event_complete && !event_complete_q;

    assign trace_schema_version = 8'd1;
    assign trace_policy = timing_policy;
    assign trace_valid = !reset;
    assign trace_cycle = cycle_count;
    assign trace_queue_count = queue_count;
    assign trace_address = bus_valid ? address : 24'h000000;
    assign trace_status = bus_valid ? bus_status : 4'hF;
    assign trace_data = !bus_valid ? 16'h0000 : (bus_write ? data_out : data_in);
    assign trace_write = bus_valid && bus_write;
    assign trace_lock = bus_lock;
    assign trace_hold = hold_request;
    assign trace_hlda = hlda;
    assign trace_ready = ready;
    assign trace_phase = !bus_valid ? 3'd0 : (ready ? 3'd2 : 3'd1);
    assign trace_lane_mask = !bus_valid ? 2'b00 :
                             address[0] ? 2'b10 :
                             bus_bhe_n ? 2'b01 : 2'b11;
    assign trace_owner = !bus_valid ? 2'd0 :
                         (bus_status == 4'h0) ? 2'd3 :
                         (bus_status == 4'hD) ? 2'd1 : 2'd2;

    always_ff @(posedge clk) begin
        if (reset) begin
            cycle_count <= 64'd0;
            biu_busy_cycles <= 64'd0;
            accepted_transfers <= 64'd0;
            ready_wait_cycles <= 64'd0;
            prefetch_requests <= 64'd0;
            prefetch_responses <= 64'd0;
            queue_consume_count <= 64'd0;
            queue_empty_cycles <= 64'd0;
            redirect_count <= 64'd0;
            cancel_count <= 64'd0;
            operand_wait_cycles <= 64'd0;
            event_request_count <= 64'd0;
            event_complete_count <= 64'd0;
            compatibility_delay_cycles <= 64'd0;
            prefetch_request_q <= 1'b0;
            stream_restart_q <= 1'b0;
            cancel_event_q <= 1'b0;
            event_request_q <= 1'b0;
            event_complete_q <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 64'd1;
            if (bus_valid) biu_busy_cycles <= biu_busy_cycles + 64'd1;
            if (bus_accept) accepted_transfers <= accepted_transfers + 64'd1;
            if (bus_wait) ready_wait_cycles <= ready_wait_cycles + 64'd1;
            if (prefetch_request_edge) prefetch_requests <= prefetch_requests + 64'd1;
            if (prefetch_response_accept) prefetch_responses <= prefetch_responses + 64'd1;
            if (queue_consume) queue_consume_count <= queue_consume_count + 64'd1;
            if (execution_enable && queue_count == 4'd0) queue_empty_cycles <= queue_empty_cycles + 64'd1;
            if (redirect_edge) redirect_count <= redirect_count + 64'd1;
            if (cancel_edge) cancel_count <= cancel_count + 64'd1;
            if (operand_wait) operand_wait_cycles <= operand_wait_cycles + 64'd1;
            if (event_request_edge) event_request_count <= event_request_count + 64'd1;
            if (event_complete_edge) event_complete_count <= event_complete_count + 64'd1;

            // No compatibility delay is inserted by the normalized baseline.
            // Keep the counter in the schema so a timing policy can populate it
            // without changing trace consumers.
            prefetch_request_q <= prefetch_request_valid;
            stream_restart_q <= stream_restart;
            cancel_event_q <= cancel_event;
            event_request_q <= event_request;
            event_complete_q <= event_complete;
        end
    end
endmodule
