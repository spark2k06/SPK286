// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module spk286_registers_tb;
    logic clk = 1'b0;
    logic reset = 1'b1;
    logic [2:0] read_a_index = 3'd0, read_b_index = 3'd0;
    logic read_a_byte = 1'b0, read_b_byte = 1'b0;
    wire [15:0] read_a_data, read_b_data;
    logic write_en = 1'b0, write_byte = 1'b0;
    logic [2:0] write_index = 3'd0;
    logic [15:0] write_data = 16'h0000;
    logic ip_write_en = 1'b0, flags_write_en = 1'b0;
    logic [15:0] ip_write_data = 16'h0000;
    logic [15:0] flags_write_data = 16'h0000, flags_write_mask = 16'h0000;
    logic flags_write_protected_task = 1'b0;
    logic loadall_commit_en = 1'b0;
    logic [127:0] loadall_gpr = 128'h0;
    logic [15:0] loadall_ip = 16'h0, loadall_flags = 16'h0;
    wire [127:0] gpr_state;
    wire [15:0] ip, flags;
    logic [15:0] expected [0:7];
    logic [15:0] old_flags;
    integer checks = 0;

    spk286_registers dut (.*);

    task automatic tick;
        #5; clk = 1'b1; #5; clk = 1'b0; #1;
    endtask

    task automatic check_all;
        for (integer i = 0; i < 8; i = i + 1) begin
            read_a_index = 3'(i);
            read_b_index = 3'(7-i);
            read_a_byte = 1'b0;
            read_b_byte = 1'b0;
            #1;
            if (read_a_data !== expected[i] || read_b_data !== expected[7-i])
                $fatal(1, "word read index=%0d A=%h B=%h", i, read_a_data, read_b_data);
            if (gpr_state[i*16 +: 16] !== expected[i])
                $fatal(1, "state observation index=%0d", i);
            checks = checks + 1;
        end
    endtask

    initial begin
        for (integer i = 0; i < 8; i = i + 1) expected[i] = 16'h0000;
        tick();
        check_all();
        if (ip !== 16'hFFF0 || flags !== 16'h0002) $fatal(1, "reset IP/FLAGS");
        reset = 1'b0;

        // Each write must preserve all seven independent registers.
        for (integer i = 0; i < 8; i = i + 1) begin
            write_en = 1'b1;
            write_index = 3'(i);
            write_data = 16'hA150 + 16'(i * 257);
            #1;
            if (gpr_state[i*16 +: 16] !== expected[i]) $fatal(1, "asynchronous write");
            expected[i] = write_data;
            tick();
            write_en = 1'b0;
            check_all();
        end

        // x86 byte encoding: AL CL DL BL AH CH DH BH. Upper input byte is ignored.
        for (integer i = 0; i < 8; i = i + 1) begin
            write_en = 1'b1;
            write_byte = 1'b1;
            write_index = 3'(i);
            write_data = 16'hEE30 + 16'(i);
            if (i < 4) expected[i][7:0] = write_data[7:0];
            else expected[i-4][15:8] = write_data[7:0];
            tick();
            write_en = 1'b0;
            check_all();
        end
        for (integer i = 0; i < 8; i = i + 1) begin
            read_a_index = 3'(i);
            read_b_index = 3'(i);
            read_a_byte = 1'b1;
            read_b_byte = 1'b1;
            #1;
            if (read_a_data !== (16'h0030 + 16'(i)) || read_b_data !== read_a_data)
                $fatal(1, "byte read encoding=%0d A=%h B=%h", i, read_a_data, read_b_data);
            checks = checks + 1;
        end

        // Disabled writes, including changing selectors, must have no effect.
        write_index = 3'd7;
        write_data = 16'hFFFF;
        ip_write_data = 16'h1234;
        flags_write_data = 16'hFFFF;
        flags_write_mask = 16'hFFFF;
        tick();
        check_all();
        if (ip !== 16'hFFF0 || flags !== 16'h0002) $fatal(1, "disabled IP/FLAGS write");

        // Independent commit ports can update GPR, IP and FLAGS on the same edge.
        write_en = 1'b1;
        write_byte = 1'b0;
        write_index = 3'd4;
        write_data = 16'hFFFF;
        expected[4] = 16'hFFFF;
        ip_write_en = 1'b1;
        ip_write_data = 16'hFFFF;
        flags_write_en = 1'b1;
        tick();
        write_en = 1'b0;
        ip_write_en = 1'b0;
        flags_write_en = 1'b0;
        check_all();
        if (ip !== 16'hFFFF || flags !== 16'h7FD7) $fatal(1, "simultaneous commit");
        ip_write_en = 1'b1;
        ip_write_data = 16'h0000;
        tick();
        ip_write_en = 1'b0;
        if (ip !== 16'h0000) $fatal(1, "IP zero write");

        // Individually clear every bit; reserved bits remain fixed and other bits hold.
        for (integer i = 0; i < 16; i = i + 1) begin
            old_flags = flags;
            flags_write_en = 1'b1;
            flags_write_data = 16'h0000;
            flags_write_mask = 16'h0001 << i;
            tick();
            if (flags !== ((old_flags & ~flags_write_mask) | 16'h0002))
                $fatal(1, "masked FLAGS clear bit=%0d got=%h", i, flags);
            checks = checks + 1;
        end
        // Toggle each architectural bit independently; writes to reserved bits do nothing.
        for (integer i = 0; i < 16; i = i + 1) begin
            old_flags = flags;
            flags_write_data = 16'hFFFF;
            flags_write_mask = 16'h0001 << i;
            tick();
            if (flags !== (old_flags | (flags_write_mask & 16'h7FD5)))
                $fatal(1, "masked FLAGS set bit=%0d got=%h", i, flags);
            checks = checks + 1;
        end
        flags_write_mask = 16'h0000;
        flags_write_data = 16'h0000;
        tick();
        if (flags !== 16'h7FD7) $fatal(1, "empty mask changed FLAGS");

        // Reset wins over all pending writes, including a second reset after mutation.
        reset = 1'b1;
        write_en = 1'b1;
        ip_write_en = 1'b1;
        ip_write_data = 16'h2222;
        flags_write_mask = 16'hFFFF;
        tick();
        for (integer i = 0; i < 8; i = i + 1) expected[i] = 16'h0000;
        check_all();
        if (ip !== 16'hFFF0 || flags !== 16'h0002) $fatal(1, "reset priority");
        $display("REGISTERS PASS: %0d register/flag checks plus reset and commit cases", checks);
        $finish;
    end
endmodule
