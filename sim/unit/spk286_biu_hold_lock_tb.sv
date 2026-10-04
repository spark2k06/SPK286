`timescale 1ns/1ps

module spk286_biu_hold_lock_tb;
    logic clk = 1'b0, reset = 1'b1, cancel_data = 1'b0, ready = 1'b0;
    logic hold_request = 1'b0, lock_request = 1'b0;
    logic ack_request = 1'b0, ack_response_ready = 1'b0;
    wire hlda, ack_request_ready, ack_response_valid, bus_lock;
    wire [7:0] ack_vector;
    logic [15:0] data_in = 16'h0000;
    logic code_valid = 1'b0, code_bhe_n = 1'b1;
    logic [23:0] code_address = 24'h001000;
    wire code_ready;
    logic data_request = 1'b0, data_write = 1'b0, data_byte = 1'b0, data_io = 1'b0;
    logic [23:0] data_address = 24'h001001;
    logic [15:0] data_write_data = 16'hBEEF;
    wire data_request_ready, data_response_valid;
    logic data_response_ready = 1'b0;
    wire [15:0] data_read_data;
    wire [23:0] address;
    wire [15:0] data_out;
    wire data_oe, bus_valid, bus_write, bus_bhe_n;
    wire [3:0] bus_status;
    wire [7:0] debug_detail;
    integer checks = 0, writes = 0, physical_cycles = 0;

    spk286_biu dut (.*);

    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1)
            $fatal(1, "%s address=%h status=%h hlda=%b lock=%b valid=%b",
                   message, address, bus_status, hlda, bus_lock, bus_valid);
    endtask

    task automatic tick;
        #1;
        if (!reset && bus_valid && ready && bus_write) begin
            writes = writes + 1;
            physical_cycles = physical_cycles + 1;
        end
        #4;
        clk = 1'b1; #5; clk = 1'b0; #1;
    endtask

    task automatic initialize;
        reset = 1'b1; hold_request = 1'b0; lock_request = 1'b0;
        ready = 1'b0; data_request = 1'b0; data_response_ready = 1'b0;
        tick(); reset = 1'b0; #1;
        check(!hlda && !bus_valid && data_request_ready, "reset clears ownership");
    endtask

    initial begin
        // Establish HLDA at a legal free boundary, then raise LOCK while the
        // request remains asserted.  The stale grant must be withdrawn.
        initialize();
        hold_request = 1'b1; ready = 1'b1; tick();
        check(hlda && !bus_valid && bus_lock == 1'b0, "HOLD is granted before LOCK");
        lock_request = 1'b1; ready = 1'b0; #1;
        check(hlda && bus_lock && !bus_valid, "collision reproduces stale HLDA boundary");
        tick();
        check(!hlda && bus_lock && !bus_valid, "LOCK releases stale HLDA without dropping HOLD");

        // The locked word may now be accepted and must retain its owner while
        // READY is low.  Both bytes of the odd word are one logical request.
        data_request = 1'b1; data_write = 1'b1; data_byte = 1'b0;
        data_address = 24'h001001; data_write_data = 16'hBEEF;
        tick(); data_request = 1'b0;
        check(bus_valid && bus_write && address == 24'h001001 && !bus_bhe_n,
              "locked odd word starts on the low lane");
        repeat (3) begin
            check(bus_valid && bus_write && address == 24'h001001 && !bus_bhe_n &&
                  data_out == 16'hEF00 && bus_lock, "READY wait retains locked beat");
            tick();
        end
        ready = 1'b1; tick(); ready = 1'b0;
        check(bus_valid && bus_write && address == 24'h001002 && bus_bhe_n && bus_lock,
              "locked odd word advances to its high byte exactly once");
        ready = 1'b1; tick(); ready = 1'b0;
        check(data_response_valid && !bus_valid, "locked word publishes one response");
        data_response_ready = 1'b1; tick(); data_response_ready = 1'b0;
        check(!data_response_valid && writes == 2 && physical_cycles == 2,
              "locked word completes with two writes and no duplicate response");

        // LOCK has ended; the still asserted HOLD is granted only at this
        // later legal boundary.
        lock_request = 1'b0; ready = 1'b1; tick();
        check(hlda && !bus_valid && bus_lock == 1'b0,
              "HOLD is granted after the locked transaction drains");
        hold_request = 1'b0; tick();
        check(!hlda && !bus_valid, "HOLD release returns to idle");
        $display("BIU_HOLD_LOCK PASS: %0d checks; %0d physical writes", checks, physical_cycles);
        $finish;
    end
endmodule
