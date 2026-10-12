// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module spk286_reset_tb;
    `include "spk286_signals.svh"
    logic [23:0] expected_fetch = 24'hFFFFF0;
    logic [23:0] observed_fetch = 24'h000000;
    logic saw_fetch = 1'b0;

    always #5 clk = ~clk;

    spk286 dut (.*);

    initial begin
        if ($value$plusargs("expected_fetch=%h", expected_fetch)) begin
            // The plusarg is used by the failure-path check.
        end

        repeat (2) @(posedge clk);
        #1;
        if (debug_cs !== 16'hF000)
            $fatal(1, "reset CS mismatch: got %h", debug_cs);
        if (debug_cs_base !== 24'hFF0000)
            $fatal(1, "hidden CS base mismatch: got %h", debug_cs_base);
        if (debug_ip !== 16'hFFF0)
            $fatal(1, "reset IP mismatch: got %h", debug_ip);
        if (debug_flags !== 16'h0002 || bus_valid !== 1'b0)
            $fatal(1, "reset FLAGS or bus activity");

        reset = 1'b0;
        repeat (4) begin
            @(posedge clk);
            #1;
            if (bus_valid) begin
                saw_fetch = 1'b1;
                if (bus_write !== 1'b0)
                    $fatal(1, "first fetch unexpectedly writes");
                if (bus_status !== 4'hD)
                    $fatal(1, "first fetch bus status mismatch: got %h", bus_status);
                if (bus_bhe_n !== 1'b0)
                    $fatal(1, "first fetch did not select the upper lane");
                if (address !== expected_fetch)
                    $fatal(1, "first fetch address mismatch: got %h expected %h", address, expected_fetch);
                if (debug_bus_state !== 4'h1)
                    $fatal(1, "debug bus state mismatch: got %h", debug_bus_state);
                if (debug_micro_pc !== 12'h000)
                    $fatal(1, "debug micro-PC mismatch: got %h", debug_micro_pc);
                observed_fetch = address;
                ready = 1'b1;
                @(posedge clk);
                #1;
                if (bus_valid !== 1'b0)
                    $fatal(1, "fetch did not complete after READY");
                $display("RESET_SMOKE PASS CS=%h CS_BASE=%h IP=%h FETCH=%h", debug_cs, debug_cs_base, debug_ip, observed_fetch);
                $finish;
            end
        end

        if (!saw_fetch)
            $fatal(1, "no first code-fetch request observed");
    end
endmodule
