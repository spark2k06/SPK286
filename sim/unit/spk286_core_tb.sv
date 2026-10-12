// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module spk286_core_tb;
    `include "spk286_signals.svh"
    integer checks = 0;
    logic max_policy;
    spk286 dut (.*);

    task automatic tick;
        #5; clk = 1'b1; #5; clk = 1'b0; #1;
    endtask

    task automatic check_bus(input logic [23:0] expected_address);
        if (bus_valid !== 1'b1 || address !== expected_address || bus_status !== 4'hD ||
            bus_bhe_n !== 1'b0 || bus_write !== 1'b0 || data_oe !== 1'b0 ||
            bus_lock !== 1'b0 || hlda !== 1'b0)
            $fatal(1, "core fetch address=%h expected=%h status=%h", address, expected_address, bus_status);
        checks = checks + 1;
    endtask

    task automatic far_restart(input logic [15:0] cs, input logic [15:0] ip);
        segment_load_en = 1'b1;
        segment_load_index = 2'd1;
        segment_load_selector = cs;
        ip_write_en = 1'b1;
        ip_write_data = ip;
        redirect = 1'b1;
        #1;
        if (control_error !== 1'b0) $fatal(1, "valid far restart rejected");
        tick();
        segment_load_en = 1'b0;
        ip_write_en = 1'b0;
        redirect = 1'b0;
        tick();
    endtask

    initial begin
        max_policy = $test$plusargs("max_policy");
        timing_policy_request = max_policy ? 2'd2 : 2'd0;
        tick();
        if (bus_valid !== 1'b0 || debug_gpr !== 128'h0 || debug_flags !== 16'h0002 ||
            debug_ip !== 16'hFFF0 || debug_cs !== 16'hF000 || debug_cs_base !== 24'hFF0000 ||
            debug_segment_selectors !== 64'h00000000F0000000 ||
            debug_segment_bases !== 96'h000000000000FF0000000000 ||
            debug_segment_limits !== 64'hFFFFFFFFFFFFFFFF ||
            debug_segment_access !== 32'h93939393)
            $fatal(1, "integrated architectural reset");
        if (debug_timing_policy !== (max_policy ? 2'd2 : 2'd0) ||
            debug_timing_policy_error !== 1'b0)
            $fatal(1, "integrated timing policy selection");
        reset = 1'b0;
        tick();
        check_bus(24'hFFFFF0);

        // Normal execution commits remain independent of a stalled bus request.
        gpr_write_en = 1'b1;
        gpr_write_index = 3'd0;
        gpr_write_data = 16'hBEEF;
        flags_write_en = 1'b1;
        flags_write_mask = 16'h0041;
        flags_write_data = 16'h0041;
        segment_load_en = 1'b1;
        segment_load_index = 2'd3;
        segment_load_selector = 16'hFFFF;
        tick();
        gpr_write_en = 1'b0;
        flags_write_en = 1'b0;
        segment_load_en = 1'b0;
        check_bus(24'hFFFFF0);
        segment_read_index = 2'd3;
        segment_offset = 16'hFFFF;
        #1;
        if (debug_gpr[15:0] !== 16'hBEEF || gpr_read_a_data !== 16'hBEEF ||
            debug_flags !== 16'h0043 || segment_address !== 24'h10FFEF ||
            segment_base !== 24'h0FFFF0 || debug_cs_base !== 24'hFF0000)
            $fatal(1, "state commit or data-segment address");
        ready = 1'b1;
        data_in = 16'h1234;
        tick();
        ready = 1'b0;
        if (fetch_valid !== 1'b1 || fetch_data !== 16'h1234 || fetch_count !== 2'd2 ||
            fetch_ip !== 16'hFFF0 || debug_ip !== 16'hFFF0 || debug_fetch_cursor !== 17'h0FFF2)
            $fatal(1, "fetch changed architectural IP or lost response");
        if (bus_valid !== 1'b0 || bus_status !== 4'hF) $fatal(1, "passive status");

        // Sequential IP commits do not flush prefetched bytes or change the cursor.
        ip_write_en = 1'b1;
        ip_write_data = 16'hFFF1;
        tick();
        ip_write_en = 1'b0;
        if (debug_ip !== 16'hFFF1 || fetch_valid !== 1'b1 || debug_fetch_cursor !== 17'h0FFF2)
            $fatal(1, "sequential IP commit invalidated prefetch");

        // Reject malformed controller transactions atomically, with observable error.
        segment_load_en = 1'b1;
        segment_load_index = 2'd1;
        segment_load_selector = 16'h1111;
        gpr_write_en = 1'b1;
        gpr_write_data = 16'hDEAD;
        #1;
        if (control_error !== 1'b1) $fatal(1, "uncoordinated CS load accepted");
        tick();
        segment_load_en = 1'b0;
        gpr_write_en = 1'b0;
        if (debug_cs !== 16'hF000 || debug_cs_base !== 24'hFF0000 || debug_gpr[15:0] !== 16'hBEEF)
            $fatal(1, "invalid commit had partial effects");
        redirect = 1'b1;
        #1;
        if (control_error !== 1'b1) $fatal(1, "redirect without IP accepted");
        tick();
        redirect = 1'b0;
        if (fetch_valid !== 1'b1 || debug_ip !== 16'hFFF1) $fatal(1, "invalid redirect had effects");

        // Near redirection preserves the special reset base, but flushes old bytes.
        redirect = 1'b1;
        ip_write_en = 1'b1;
        ip_write_data = 16'h0020;
        tick();
        redirect = 1'b0;
        ip_write_en = 1'b0;
        tick();
        check_bus(24'hFF0020);
        if (fetch_valid !== 1'b0 || debug_ip !== 16'h0020) $fatal(1, "near restart state");
        ready = 1'b1;
        tick();
        ready = 1'b0;

        // Same visible CS reload has ordinary real-mode semantics.
        far_restart(16'hF000, 16'hFFF0);
        check_bus(24'h0FFFF0);
        if (debug_cs_base !== 24'h0F0000 || debug_ip !== 16'hFFF0) $fatal(1, "far cache/IP commit");
        // Far restart during an outstanding transfer keeps the old bus stable.
        far_restart(16'hFFFF, 16'h0011);
        check_bus(24'h0FFFF0);
        if (debug_cs !== 16'hFFFF || debug_cs_base !== 24'h0FFFF0 || debug_ip !== 16'h0011)
            $fatal(1, "redirect did not commit while draining");
        ready = 1'b1;
        data_in = 16'hDEAD;
        tick();
        ready = 1'b0;
        if (fetch_valid !== 1'b0) $fatal(1, "old stream escaped cancellation");
        tick();
        check_bus(24'h100001);
        ready = 1'b1;
        data_in = 16'hA555;
        tick();
        ready = 1'b0;
        if (fetch_valid !== 1'b1 || fetch_data !== 16'h00A5 || fetch_count !== 2'd1 ||
            debug_ip !== 16'h0011 || debug_fetch_cursor !== 17'h00012)
            $fatal(1, "odd fetch integration");

        // Reset clears all mutated state and buffered/in-flight fetch metadata.
        reset = 1'b1;
        ready = 1'b1;
        gpr_write_en = 1'b1;
        tick();
        if (debug_gpr !== 128'h0 || debug_ip !== 16'hFFF0 || debug_cs_base !== 24'hFF0000 ||
            fetch_valid !== 1'b0 || bus_valid !== 1'b0 || debug_flags !== 16'h0002)
            $fatal(1, "integrated repeat reset");
        reset = 1'b0;
        ready = 1'b0;
        gpr_write_en = 1'b0;
        tick();
        check_bus(24'hFFFFF0);
        $display("CORE_STATE_FETCH PASS: %0d bus checks plus architectural state/redirect cases", checks);
        $finish;
    end
endmodule
