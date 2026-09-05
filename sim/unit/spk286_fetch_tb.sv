`timescale 1ns/1ps

module spk286_fetch_tb;
    logic clk = 1'b0, reset = 1'b1, ready = 1'b0;
    logic [15:0] data_in = 16'h0000;
    logic [23:0] code_base = 24'hFF0000;
    logic [15:0] code_limit = 16'hFFFF;
    logic restart = 1'b0;
    logic [15:0] restart_ip = 16'hFFF0;
    logic request = 1'b0, response_ready = 1'b0;
    wire request_ready, response_valid, blocked;
    wire [15:0] response_data, response_ip;
    wire [1:0] response_count;
    wire [16:0] cursor;
    wire bus_valid, bus_bhe_n;
    wire [23:0] address;
    integer checks = 0;

    spk286_fetch dut (.*);

    task automatic tick;
        #5; clk = 1'b1; #5; clk = 1'b0; #1;
    endtask

    task automatic expect_bus(input logic [23:0] expected_address);
        if (bus_valid !== 1'b1 || address !== expected_address || bus_bhe_n !== 1'b0)
            $fatal(1, "bus valid=%b address=%h expected=%h BHE=%b", bus_valid, address, expected_address, bus_bhe_n);
        checks = checks + 1;
    endtask

    task automatic complete_read(input logic [15:0] data,
                                 input logic [15:0] expected_data,
                                 input logic [1:0] count,
                                 input logic [15:0] ip);
        data_in = data;
        ready = 1'b1;
        tick();
        ready = 1'b0;
        if (bus_valid !== 1'b0 || response_valid !== 1'b1 ||
            response_data !== expected_data || response_count !== count || response_ip !== ip)
            $fatal(1, "response valid=%b data=%h count=%d ip=%h", response_valid, response_data, response_count, response_ip);
        checks = checks + 1;
    endtask

    task automatic consume;
        response_ready = 1'b1;
        tick();
        response_ready = 1'b0;
        if (response_valid !== 1'b0) $fatal(1, "response did not retire");
    endtask

    task automatic redirect(input logic [23:0] new_base, input logic [15:0] new_ip);
        restart = 1'b1;
        restart_ip = new_ip;
        tick();
        // Architectural caches change on the redirect edge, before restart issues.
        code_base = new_base;
        restart = 1'b0;
        tick();
    endtask

    initial begin
        tick();
        if (bus_valid !== 1'b0 || response_valid !== 1'b0) $fatal(1, "reset bus activity");
        reset = 1'b0;
        tick();
        expect_bus(24'hFFFFF0);
        // Inputs may change while a request is in flight; its address is latched.
        code_base = 24'h012340;
        data_in = 16'hBAD0;
        repeat (7) begin
            tick();
            expect_bus(24'hFFFFF0);
            if (response_valid !== 1'b0 || cursor !== 17'h0FFF0 || request_ready !== 1'b0)
                $fatal(1, "wait-state side effect");
        end
        complete_read(16'hBBAA, 16'hBBAA, 2'd2, 16'hFFF0);
        if (cursor !== 17'h0FFF2) $fatal(1, "word cursor advance");
        // Backpressure preserves the response, even with unsolicited READY/request.
        request = 1'b1;
        ready = 1'b1;
        data_in = 16'hDEAD;
        repeat (4) begin
            tick();
            if (response_data !== 16'hBBAA || response_valid !== 1'b1 || bus_valid !== 1'b0 || request_ready !== 1'b0)
                $fatal(1, "response backpressure");
        end
        ready = 1'b0;
        request = 1'b0;
        consume();
        code_base = 24'hFF0000;
        request = 1'b1;
        tick();
        request = 1'b0;
        expect_bus(24'hFFFFF2);
        complete_read(16'h2211, 16'h2211, 2'd2, 16'hFFF2);

        // A restart invalidates buffered bytes and starts the new stream.
        redirect(24'h0FFFF0, 16'h0011);
        expect_bus(24'h100001);
        if (response_valid !== 1'b0) $fatal(1, "stale buffered response after restart");
        complete_read(16'hCC55, 16'h00CC, 2'd1, 16'h0011);
        if (cursor !== 17'h00012) $fatal(1, "odd cursor advance");
        consume();
        request = 1'b1;
        tick();
        request = 1'b0;
        expect_bus(24'h100002);

        // Restart during a wait drains the old request without exposing old bytes.
        restart = 1'b1;
        restart_ip = 16'h0100;
        tick();
        restart = 1'b0;
        code_base = 24'h020000;
        repeat (3) begin tick(); expect_bus(24'h100002); end
        // A second restart while draining must retain the latest target.
        restart = 1'b1;
        restart_ip = 16'h0200;
        tick();
        restart = 1'b0;
        code_base = 24'h030000;
        ready = 1'b1;
        data_in = 16'hDEAD;
        tick();
        ready = 1'b0;
        if (response_valid !== 1'b0 || cursor !== 17'h00200) $fatal(1, "canceled completion changed stream");
        tick();
        expect_bus(24'h030200);
        // Same-edge READY/restart also discards the old completion.
        restart = 1'b1;
        restart_ip = 16'h0040;
        ready = 1'b1;
        tick();
        restart = 1'b0;
        ready = 1'b0;
        if (response_valid !== 1'b0) $fatal(1, "READY/restart race");
        tick();
        expect_bus(24'h030040);
        complete_read(16'h4433, 16'h4433, 2'd2, 16'h0040);

        // Fetch never wraps into offset zero after reaching the segment end.
        redirect(24'hFF0000, 16'hFFFE);
        expect_bus(24'hFFFFFE);
        complete_read(16'h6655, 16'h6655, 2'd2, 16'hFFFE);
        if (cursor !== 17'h10000 || blocked !== 1'b1) $fatal(1, "segment end not retained");
        consume();
        request = 1'b1;
        repeat (3) tick();
        if (bus_valid !== 1'b0 || request_ready !== 1'b0) $fatal(1, "fetch crossed segment end");
        request = 1'b0;
        redirect(24'h000000, 16'hFFFF);
        expect_bus(24'h00FFFF);
        complete_read(16'hAACC, 16'h00AA, 2'd1, 16'hFFFF);
        if (cursor !== 17'h10000) $fatal(1, "last odd byte cursor");

        // A last even byte must use only the lower lane; inactive high byte is ignored.
        code_limit = 16'h0100;
        redirect(24'h000000, 16'h0100);
        if (bus_valid !== 1'b1 || address !== 24'h000100 || bus_bhe_n !== 1'b1)
            $fatal(1, "last even byte lane");
        complete_read(16'hDDEE, 16'h00EE, 2'd1, 16'h0100);
        if (blocked !== 1'b1) $fatal(1, "limit exhaustion");
        redirect(24'h000000, 16'h0101);
        if (bus_valid !== 1'b0 || blocked !== 1'b1) $fatal(1, "out-of-limit request");

        // Synchronous reset aborts an active bus operation and clears responses.
        code_limit = 16'hFFFF;
        redirect(24'h000000, 16'h0000);
        reset = 1'b1;
        ready = 1'b1;
        tick();
        if (bus_valid !== 1'b0 || response_valid !== 1'b0 || cursor !== 17'h0FFF0)
            $fatal(1, "reset priority while active");
        code_base = 24'hFF0000;
        reset = 1'b0;
        ready = 1'b0;
        tick();
        expect_bus(24'hFFFFF0);
        $display("FETCH PASS: %0d bus/response checks plus waits, cancellation, backpressure and limits", checks);
        $finish;
    end
endmodule
