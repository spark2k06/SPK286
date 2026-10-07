`timescale 1ns/1ps

// Policy-selection boundary. Policies 0 and 2 are accepted at reset;
// policy 2 is the functionally equivalent dependency-driven Max profile. The
// request is sampled at reset and cannot change after execution starts.
module spk286_timing_policy_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic [1:0] requested_policy = 2'd0;
    logic [1:0] active_policy;
    logic selection_error;
    logic selection_locked;
    integer checks = 0;

    spk286_timing_policy dut (.*);

    task automatic tick;
        #1 clk = 1'b1; #1 clk = 1'b0; #1;
    endtask

    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1)
            $fatal(1, "%s", message);
    endtask

    initial begin
        tick();
        check(active_policy == 2'd0 && !selection_error && !selection_locked,
              "baseline reset selection was not accepted");

        reset = 1'b0;
        tick();
        check(active_policy == 2'd0 && !selection_error && selection_locked,
              "policy boundary did not lock after reset");

        requested_policy = 2'd2;
        tick();
        check(active_policy == 2'd0 && !selection_error && selection_locked,
              "runtime policy request changed the active policy");

        reset = 1'b1;
        requested_policy = 2'd2;
        tick();
        check(active_policy == 2'd2 && !selection_error && !selection_locked,
              "Max reset-time policy was not accepted");

        reset = 1'b0;
        requested_policy = 2'd0;
        tick();
        check(active_policy == 2'd2 && !selection_error && selection_locked,
              "accepted Max policy did not remain locked");

        reset = 1'b1;
        requested_policy = 2'd1;
        tick();
        check(active_policy == 2'd0 && selection_error && !selection_locked,
              "unsupported reset-time policy was not rejected");

        reset = 1'b0;
        requested_policy = 2'd0;
        tick();
        check(active_policy == 2'd0 && selection_error && selection_locked,
              "rejected policy was silently cleared after reset");

        reset = 1'b1;
        tick();
        check(active_policy == 2'd0 && !selection_error && !selection_locked,
              "baseline reset did not clear the prior selection error");

        $display("TIMING POLICY SELECTION PASS checks=%0d", checks);
        $finish;
    end
endmodule
