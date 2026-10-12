// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module spk286_encoding_preview_tb;
    logic clk = 1'b0;
    always #5 clk = !clk;
    logic reset = 1'b1, cancel = 1'b0, start = 1'b0, enable = 1'b1;
    logic byte_valid = 1'b0, abort_fetch = 1'b0;
    logic [7:0] byte_data = 8'd0;
    wire byte_ready, complete, valid_length;
    wire invalid_opcode, unsupported, overlength, fetch_fault;
    wire [3:0] length;
    integer checks = 0;
    spk286_encoding_preview dut (.*);

    task automatic begin_preview;
        @(negedge clk); start = 1'b1; byte_valid = 1'b0; abort_fetch = 1'b0;
        @(posedge clk); #1;
        if (complete || byte_ready) $fatal(1, "start must reset without acceptance");
        @(negedge clk); start = 1'b0;
    endtask
    task automatic put(input logic [7:0] value);
        byte_data = value; byte_valid = 1'b1; #1;
        if (!byte_ready) $fatal(1, "not ready before expected byte %h", value);
        @(posedge clk); #1;
        @(negedge clk); byte_valid = 1'b0;
    endtask
    task automatic check_terminal(input integer expected_length, input integer reason);
        // reason0 full encoding,1 opcode#UD,2 unsupported,3 overlength,4fetch.
        @(posedge clk); #1;
        if (!complete || byte_ready || length != 4'(expected_length) ||
            valid_length !== (reason == 0) || invalid_opcode !== (reason == 1) ||
            unsupported !== (reason == 2) || overlength !== (reason == 3) ||
            fetch_fault !== (reason == 4))
            $fatal(1, "terminal len%0d reason%0d got%0d %b%b%b%b%b%b", expected_length,
                   reason, length, complete, valid_length, invalid_opcode, unsupported, overlength, fetch_fault);
        @(negedge clk); byte_valid = 1'b1; byte_data = 8'hAA;
        repeat (2) @(posedge clk);
        #1;
        if (length != 4'(expected_length) || byte_ready) $fatal(1, "terminal must be held");
        @(negedge clk); byte_valid = 1'b0; checks = checks + 1;
    endtask
    task automatic test_immediate(input logic [7:0] opcode, input integer bytes_after);
        begin_preview(); put(opcode);
        for (integer i = 0; i < bytes_after; i = i + 1) begin
            if (complete) $fatal(1, "premature immediate %h", opcode);
            put(8'hA5);
        end
        check_terminal(1 + bytes_after, 0);
    endtask
    task automatic test_modrm(input logic [7:0] opcode, input logic extended_map,
                               input logic [7:0] encoded, input integer immediate,
                               input integer reason);
        integer disp, count;
        begin_preview();
        if (extended_map) put(8'h0F);
        put(opcode); put(encoded);
        disp = encoded[7:6] == 1 ? 1 : (encoded[7:6] == 2 || encoded == {2'b00, encoded[5:3], 3'd6}) ? 2 : 0;
        count = (extended_map ? 3 : 2);
        if (reason == 0) begin
            for (integer j = 0; j < disp + immediate; j = j + 1) begin
                if (complete) $fatal(1, "premature ModRM %h/%h", opcode, encoded);
                put(8'hA5); count = count + 1;
            end
        end
        check_terminal(count, reason);
    endtask
    initial begin
        repeat (2) @(posedge clk);
        @(negedge clk); reset = 1'b0;
        test_immediate(8'h40, 0); test_immediate(8'h90, 0);
        test_immediate(8'hB0, 1); test_immediate(8'hB8, 2);
        test_immediate(8'h05, 2); test_immediate(8'h04, 1);
        test_immediate(8'hA0, 2); test_immediate(8'hA1, 2);
        test_immediate(8'h9A, 4); test_immediate(8'hEA, 4);
        test_immediate(8'hC8, 3); test_immediate(8'hC2, 2);
        test_immediate(8'hE4, 1); test_immediate(8'hE5, 1);
        test_immediate(8'hEC, 0); test_immediate(8'hED, 0);
        test_immediate(8'h6C, 0); test_immediate(8'h6F, 0);
        for (integer m = 0; m < 256; m = m + 1) begin
            test_modrm(8'h8B, 1'b0, 8'(m), 0, 0);
            test_modrm(8'h81, 1'b0, 8'(m), 2, 0);
            test_modrm(8'h83, 1'b0, 8'(m), 1, 0);
            test_modrm(8'h69, 1'b0, 8'(m), 2, 0);
            test_modrm(8'h6B, 1'b0, 8'(m), 1, 0);
            test_modrm(8'hD8, 1'b0, 8'(m), 0, 0);
            test_modrm(8'hF6, 1'b0, 8'(m), m[5:3] == 0 ? 1 : 0, m[5:3] == 1 ? 2 : 0);
            test_modrm(8'hF7, 1'b0, 8'(m), m[5:3] == 0 ? 2 : 0, m[5:3] == 1 ? 2 : 0);
            test_modrm(8'hFF, 1'b0, 8'(m), 0, m[5:3] == 7 ? 2 : 0);
            test_modrm(8'h02, 1'b1, 8'(m), 0, 0);
            test_modrm(8'h00, 1'b1, 8'(m), 0, m[5:3] > 5 ? 2 : 0);
            test_modrm(8'h01, 1'b1, 8'(m), 0, m[5:3] == 5 || m[5:3] == 7 ? 2 : 0);
        end
        begin_preview(); put(8'h0F); put(8'h05); check_terminal(2, 0);
        begin_preview(); put(8'h0F); put(8'h06); check_terminal(2, 0);
        begin_preview(); put(8'h64); check_terminal(1, 1);
        begin_preview(); put(8'h0F); put(8'h80); check_terminal(2, 1);
        begin_preview(); put(8'h82); check_terminal(1, 2);
        // Prefixes contribute to the full target length, with max10 bytes.
        for (integer n = 0; n <= 9; n = n + 1) begin
            begin_preview();
            for (integer p = 0; p < n; p = p + 1) put(8'h26);
            put(8'h40); check_terminal(n + 1, 0);
        end
        begin_preview();
        for (integer p = 0; p < 10; p = p + 1) put(8'hF3);
        check_terminal(10, 3);
        begin_preview();
        for (integer p = 0; p < 8; p = p + 1) put(8'h36);
        put(8'hB8); put(8'h01); check_terminal(10, 3);
        begin_preview(); put(8'hB8);
        enable = 1'b0; byte_valid = 1'b1; byte_data = 8'hAA;
        repeat (3) @(posedge clk);
        #1; if (byte_ready || length != 1 || complete) $fatal(1, "disabled preview changed");
        @(negedge clk); byte_valid = 1'b0; enable = 1'b1;
        put(8'h12); put(8'h34); check_terminal(3, 0);
        begin_preview(); put(8'hB8);
        abort_fetch = 1'b1; byte_valid = 1'b1;
        check_terminal(1, 4);
        begin_preview(); put(8'h26);
        cancel = 1'b1; byte_valid = 1'b1;
        @(posedge clk); #1;
        if (complete || byte_ready || length != 0) $fatal(1, "cancel leaked context");
        @(negedge clk); cancel = 1'b0; byte_valid = 1'b0;
        if (byte_ready) $fatal(1, "cancel needs new start");
        test_immediate(8'h40, 0);
        $display("ENCODING PREVIEW PASS checks=%0d", checks);
        $finish;
    end
endmodule
