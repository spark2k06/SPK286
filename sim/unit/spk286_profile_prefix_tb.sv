`timescale 1ns/1ps
// Passive full-TOP aggregation oracle. Original functional expectations stay
// in the compatibility banks; these cases inspect only actual prefix metadata.
module spk286_profile_prefix_tb;
    `include "spk286_signals.svh"
    logic historical_enable = 1'b1, cpu_boundary = 1'b0;
    logic timing_read_wait_event = 1'b0;
    logic [7:0] memory [0:4095];
    integer edges = 0, case_id = 0, checks = 0, counted_prefixes = 0;
    integer expected_count, expected_budget, expected_estimated, timeout_count;
    logic checked;
    spk286_profiled dut (.*);

    task automatic check(input logic condition, input string message);
        checks++;
        if (condition !== 1'b1)
            $fatal(1, "%s case%0d count%0d/%0d budget%0d/%0d opcode%h",
                message, case_id, dut.profile_prefix_count_q, expected_count,
                dut.profile_metadata_clocks, expected_budget, debug_opcode);
    endtask

    task automatic tick;
        cpu_boundary = (edges % 8) == 0;
        ready = execute_enable && bus_valid;
        data_in = 16'hF4F4;
        if (bus_valid && address < 24'd4096)
            data_in = {memory[{address[11:1],1'b1}],memory[{address[11:1],1'b0}]};
        #4;
        if (execute_enable) begin
            if (dut.profile_real_prefix) counted_prefixes++;
            if (dut.profile_body_active && dut.profile_metadata_valid && !checked) begin
                check(int'(dut.profile_prefix_count_q) == expected_count,
                      "actual prefix aggregation count");
                check(counted_prefixes == expected_count, "accepted prefix count oracle");
                check(int'(dut.profile_metadata_clocks) == expected_budget,
                      "LOCK/REP/override aggregate instruction budget");
                check(int'(dut.profile_metadata_estimated) == expected_estimated,
                      "extra native fallback marked estimated");
                checked = 1;
            end
            if (bus_valid && ready && bus_write && address < 24'd4096) begin
                if (!address[0]) memory[address[11:0]] = data_out[7:0];
                if (!bus_bhe_n) memory[{address[11:1],1'b1}] = data_out[15:8];
            end
        end
        clk = 1; #5; clk = 0; #1; edges++;
        if (execute_enable)
            check(!unsupported_opcode && !microcode_fault && !shutdown && !control_error,
                  "original functional engine accepts probe");
    endtask

    task automatic setup(input logic [63:0] code, input integer length,
                         input integer prefix_count, input integer budget,
                         input integer estimated);
        execute_enable = 0; reset = 1; ready = 0;
        gpr_write_en = 0; flags_write_en = 0; ip_write_en = 0;
        redirect = 0; segment_load_en = 0;
        checked = 0; counted_prefixes = 0;
        expected_count = prefix_count; expected_budget = budget; expected_estimated = estimated;
        for (integer i=0; i<4096; i++) memory[i] = 8'hF4;
        for (integer i=0; i<length; i++) memory[256+i] = code[i*8+:8];
        memory[768] = 8'h5A;
        tick(); reset = 0;
        for (integer i=0; i<8; i++) begin
            gpr_write_en = 1; gpr_write_index = 3'(i);
            gpr_write_data = i==1 ? 16'd1 : i==6 ? 16'd768 : i==7 ? 16'd1024 : 16'd0;
            tick();
        end
        gpr_write_en = 0;
        for (integer i=0; i<4; i++) begin
            segment_load_en = 1; segment_load_index = 2'(i); segment_load_selector = 0;
            redirect = i==1; ip_write_en = i==1; ip_write_data = 16'h0100;
            tick();
        end
        segment_load_en = 0; redirect = 0; ip_write_en = 0; execute_enable = 1;
        timeout_count = 0;
        while (!instruction_retired && timeout_count < 5000) begin tick(); timeout_count++; end
        check(instruction_retired && checked, "probe retirement and passive budget coverage");
        execute_enable = 0;
        $display("PROFILE_PREFIX_CASE case%0d prefix%0d budget%0d estimated%0d",
                 case_id, expected_count, expected_budget, expected_estimated);
        case_id++;
    endtask

    initial begin
        setup(64'hD801, 2, 0, 2, 0);             // ADD AX,BX
        setup(64'hD801F0, 3, 0, 2, 0);           // LOCK adds0
        setup(64'hD8012E, 3, 1, 4, 1);           // segment fallback estimated2
        setup(64'hA4F3, 2, 1, 9, 0);             // REP MOVSB setup5 + iteration4
        setup(64'hA4F32E, 3, 2, 11, 1);          // REP + override
        setup(64'hA4F32EF0, 4, 2, 11, 1);        // LOCK + REP + override
        setup(64'hA4F3F3, 3, 2, 11, 1);          // repeated REP, one in setup
        setup(64'hD801F0F0, 4, 0, 2, 0);         // repeated LOCK still adds0
        $display("PROFILE_PREFIX_PASS cases%0d checks%0d", case_id, checks);
        $finish;
    end
endmodule
