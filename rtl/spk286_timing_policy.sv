// Timing policy boundary. The normalized functional baseline and the
// dependency-driven Max profile currently share the same functional schedule.
// Max is accepted only as an explicit functional-equivalence profile; this is
// not a historical timing claim.
`timescale 1ns/1ps

module spk286_timing_policy (
    input  logic       clk,
    input  logic       reset,
    input  logic [1:0] requested_policy,
    output logic [1:0] active_policy,
    output logic       selection_error,
    output logic       selection_locked
);
    localparam logic [1:0] POLICY_NORMALIZED_BASELINE = 2'd0;
    localparam logic [1:0] POLICY_MAX = 2'd2;

    wire requested_policy_supported =
        (requested_policy === POLICY_NORMALIZED_BASELINE) ||
        (requested_policy === POLICY_MAX);

    always_ff @(posedge clk) begin
        if (reset) begin
            active_policy <= requested_policy_supported ? requested_policy :
                             POLICY_NORMALIZED_BASELINE;
            selection_error <= !requested_policy_supported;
            selection_locked <= 1'b0;
        end else begin
            // Policy selection is a reset-boundary operation. Runtime writes
            // cannot change timing semantics in the middle of execution.
            active_policy <= active_policy;
            selection_error <= selection_error;
            selection_locked <= 1'b1;
        end
    end
endmodule
