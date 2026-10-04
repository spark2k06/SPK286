// Provisional instruction-interval scheduler. Functional services stay on the
// fabric clock; this module qualifies observable instruction/event boundaries.
// The metadata budget is independent of micro-operation implementation count.
`ifndef SPK286_INSTRUCTION_SCHEDULE_SV
`define SPK286_INSTRUCTION_SCHEDULE_SV
`timescale 1ns/1ps
module spk286_instruction_schedule (
    input logic clk, reset, historical_enable, cpu_boundary,
    input logic cancel, preserve_cancel,
    input logic start_interval, start_body,
    input logic metadata_valid, metadata_freeze,
    input logic [9:0] metadata_clocks,
    input logic read_wait_event, alignment_event,
    input logic functional_retired,
    input logic repeat_checkpoint,
    input logic [9:0] repeat_next_clocks,
    output logic active, body_active, retire_pending,
    output logic head_permit, deadline_ready, retire_fire,
    output logic [9:0] elapsed_clocks, scheduled_clocks,
    output logic implementation_extension
);
    logic active_q, body_q, pending_q, qualified_q, frozen_q, admission_window_q;
    logic [9:0] elapsed_q, base_q, extra_q;
    logic [10:0] elapsed_next, effective_base, extra_next, total;
    logic metadata_available;

    always_comb begin
        // Extra READ waits can be arbitrarily long. Count productive CPU
        // boundaries instead of accumulating an unbounded wait-state debt:
        // elapsed_real >= base + READ_waits iff productive >= base.
        elapsed_next = {1'b0, elapsed_q} + 11'(cpu_boundary && !read_wait_event);
        if (elapsed_next > 11'd1023) elapsed_next = 11'd1023;
        effective_base = (!frozen_q && metadata_valid) ?
                         {1'b0, metadata_clocks} : {1'b0, base_q};
        extra_next = {1'b0, extra_q} + (alignment_event ? 11'd2 : 11'd0);
        if (extra_next > 11'd1023) extra_next = 11'd1023;
        // Current bus admissions may depend on an EU checkpoint permit. They
        // update the retained budget at this edge, never feed that permit
        // combinationally. Every reference precedes its functional retirement.
        total = effective_base + {1'b0, extra_q};
        if (total > 11'd1023) total = 11'd1023;
        metadata_available = qualified_q || (!frozen_q && metadata_valid);
    end
    assign active = historical_enable && active_q;
    assign body_active = historical_enable && body_q;
    assign retire_pending = historical_enable && pending_q;
    assign head_permit = !historical_enable ||
                         ((cpu_boundary || admission_window_q) &&
                          (!active_q || !body_q) && !pending_q);
    assign deadline_ready = !historical_enable ||
                            (active_q && body_q && metadata_available && elapsed_next >= total);
    assign retire_fire = !historical_enable ? functional_retired :
                         !reset && !cancel && cpu_boundary && deadline_ready &&
                         (pending_q || functional_retired);
    assign elapsed_clocks = elapsed_q;
    assign scheduled_clocks = total[9:0];

    always_ff @(posedge clk) begin
        if (reset || !historical_enable || (cancel && !preserve_cancel)) begin
            active_q <= 1'b0; body_q <= 1'b0; pending_q <= 1'b0;
            qualified_q <= 1'b0; frozen_q <= 1'b0;
            admission_window_q <= 1'b0;
            elapsed_q <= 10'd0; base_q <= 10'd0; extra_q <= 10'd0;
            implementation_extension <= 1'b0;
        end else begin
            if (active_q) begin
                elapsed_q <= elapsed_next[9:0];
                extra_q <= extra_next[9:0];
                if (!frozen_q && metadata_valid) begin
                    base_q <= metadata_clocks;
                    qualified_q <= 1'b1;
                end
                if (metadata_freeze) frozen_q <= 1'b1;
                if (functional_retired) pending_q <= 1'b1;
                if (cpu_boundary && !read_wait_event && deadline_ready &&
                    !pending_q && !functional_retired && !repeat_checkpoint)
                    implementation_extension <= 1'b1;
            end
            if (retire_fire) begin
                active_q <= 1'b0; body_q <= 1'b0; pending_q <= 1'b0;
                qualified_q <= 1'b0; frozen_q <= 1'b0;
                // The interval opens at this virtual boundary. Its next head
                // is consumed after the old context has cleared, on a fabric
                // edge in the same virtual interval, without adding a CPU tick.
                admission_window_q <= 1'b1;
                elapsed_q <= 10'd0; base_q <= 10'd0; extra_q <= 10'd0;
            end
            if (repeat_checkpoint) begin
                active_q <= 1'b1; body_q <= 1'b1; pending_q <= 1'b0;
                qualified_q <= 1'b1; frozen_q <= 1'b1;
                elapsed_q <= 10'd0; base_q <= repeat_next_clocks; extra_q <= 10'd0;
            end
            if (start_body) begin body_q <= 1'b1; admission_window_q <= 1'b0; end
            if (start_interval) begin
                active_q <= 1'b1; body_q <= start_body; pending_q <= 1'b0;
                qualified_q <= metadata_valid; frozen_q <= 1'b0;
                elapsed_q <= 10'd0; base_q <= metadata_clocks; extra_q <= 10'd0;
                implementation_extension <= 1'b0;
            end
        end
    end
endmodule
`endif
