`timescale 1ns/1ps

module spk286_segments_tb;
    logic clk = 1'b0, reset = 1'b1;
    logic load_en = 1'b0;
    logic [1:0] load_index = 2'd0, read_index = 2'd0;
    logic [15:0] load_selector = 16'h0000, offset = 16'h0000;
    wire [15:0] selector, limit;
    wire [23:0] base, physical_address;
    wire [7:0] access_rights;
    wire [63:0] selector_state, limit_state;
    wire [95:0] base_state;
    wire [31:0] access_state;
    logic [15:0] expected_selector [0:3];
    logic [23:0] expected_base [0:3];
    integer checks = 0;

    spk286_segments dut (.*);

    task automatic tick;
        #5; clk = 1'b1; #5; clk = 1'b0; #1;
    endtask

    task automatic check_segments;
        for (integer i = 0; i < 4; i = i + 1) begin
            read_index = 2'(i);
            #1;
            if (selector !== expected_selector[i] || base !== expected_base[i])
                $fatal(1, "segment %0d selector=%h base=%h", i, selector, base);
            if (limit !== 16'hFFFF || access_rights !== 8'h93)
                $fatal(1, "segment %0d cache limit=%h access=%h", i, limit, access_rights);
            if (selector_state[i*16 +: 16] !== selector || base_state[i*24 +: 24] !== base ||
                limit_state[i*16 +: 16] !== limit || access_state[i*8 +: 8] !== access_rights)
                $fatal(1, "segment %0d observation differs from datapath", i);
            checks = checks + 1;
        end
    endtask

    task automatic check_address(input logic [1:0] seg,
                                 input logic [15:0] off,
                                 input logic [23:0] expected_address);
        read_index = seg;
        offset = off;
        #1;
        if (physical_address !== expected_address)
            $fatal(1, "address seg=%0d off=%h got=%h expected=%h", seg, off, physical_address, expected_address);
        checks = checks + 1;
    endtask

    initial begin
        for (integer i = 0; i < 4; i = i + 1) begin
            expected_selector[i] = (i == 1) ? 16'hF000 : 16'h0000;
            expected_base[i] = (i == 1) ? 24'hFF0000 : 24'h000000;
        end
        tick();
        check_segments();
        check_address(2'd1, 16'hFFF0, 24'hFFFFF0);
        check_address(2'd1, 16'hFFFF, 24'hFFFFFF);
        check_address(2'd1, 16'h0000, 24'hFF0000);
        check_address(2'd2, 16'hFFFF, 24'h00FFFF);
        reset = 1'b0;

        // Disabled reloads cannot destroy the special reset CS cache.
        load_index = 2'd1;
        load_selector = 16'hF000;
        tick();
        check_segments();
        // Reloading the same visible CS value must still replace its hidden base.
        load_en = 1'b1;
        expected_base[1] = 24'h0F0000;
        tick();
        load_en = 1'b0;
        check_segments();
        check_address(2'd1, 16'hFFF0, 24'h0FFFF0);

        for (integer i = 0; i < 4; i = i + 1) begin
            load_en = 1'b1;
            load_index = 2'(i);
            load_selector = 16'h1234 + 16'(i * 4096);
            expected_selector[i] = load_selector;
            expected_base[i] = 24'h012340 + 24'(i * 65536);
            tick();
            load_en = 1'b0;
            check_segments();
        end
        check_address(2'd0, 16'h0020, 24'h012360);
        check_address(2'd3, 16'hFFFF, 24'h05233F);

        // Exhaust every paragraph value for every segment. Oracle uses integer
        // multiplication/addition, not the RTL concatenation expression.
        for (integer seg = 0; seg < 4; seg = seg + 1) begin
            read_index = 2'(seg);
            load_index = 2'(seg);
            load_en = 1'b1;
            for (integer value = 0; value < 65536; value = value + 1) begin
                load_selector = 16'(value);
                offset = 16'hFFFF;
                tick();
                if (selector !== 16'(value) || base !== 24'(value * 16) ||
                    physical_address !== 24'(value * 16 + 65535) || limit !== 16'hFFFF ||
                    access_rights !== 8'h93)
                    $fatal(1, "paragraph sweep segment=%0d value=%h", seg, load_selector);
                checks = checks + 1;
            end
            expected_selector[seg] = 16'hFFFF;
            expected_base[seg] = 24'h0FFFF0;
            load_en = 1'b0;
            check_segments();
        end
        check_address(2'd1, 16'h000F, 24'h0FFFFF);
        check_address(2'd1, 16'h0010, 24'h100000);
        check_address(2'd1, 16'hFFFF, 24'h10FFEF);

        // Reset is repeatable and overrides a simultaneous real-mode reload.
        reset = 1'b1;
        load_en = 1'b1;
        tick();
        for (integer i = 0; i < 4; i = i + 1) begin
            expected_selector[i] = (i == 1) ? 16'hF000 : 16'h0000;
            expected_base[i] = (i == 1) ? 24'hFF0000 : 24'h000000;
        end
        check_segments();
        $display("SEGMENTS PASS: %0d cache/address checks including 262144 paragraph loads", checks);
        $finish;
    end
endmodule
