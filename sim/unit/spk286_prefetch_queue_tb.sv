`timescale 1ns/1ps

module spk286_prefetch_queue_tb;
    logic clk = 1'b0, reset = 1'b1, flush = 1'b0;
    logic fill_valid = 1'b0;
    logic [15:0] fill_data = 16'h0000;
    logic [1:0] fill_count = 2'd0;
    wire fill_ready, consume_valid;
    wire [7:0] consume_data;
    logic consume_ready = 1'b0;
    wire [3:0] count;
    integer checks = 0;

    spk286_prefetch_queue dut (.*);

    task automatic tick;
        #5; clk = 1'b1; #5; clk = 1'b0; #1;
    endtask

    task automatic fill(input logic [15:0] value, input logic [1:0] amount);
        fill_data = value;
        fill_count = amount;
        fill_valid = 1'b1;
        #1;
        if (amount == 2'd0 || !fill_ready)
            $fatal(1, "fill unexpectedly rejected value=%h count=%d queue=%d", value, amount, count);
        tick();
        fill_valid = 1'b0;
        fill_count = 2'd0;
        checks = checks + 1;
    endtask

    task automatic pop(input logic [7:0] expected);
        consume_ready = 1'b1;
        #1;
        if (!consume_valid || consume_data !== expected)
            $fatal(1, "queue order got=%h expected=%h count=%d", consume_data, expected, count);
        tick();
        consume_ready = 1'b0;
        checks = checks + 1;
    endtask

    task automatic pop_with_fill(input logic [7:0] expected,
                                 input logic [15:0] value,
                                 input logic [1:0] amount);
        fill_data = value;
        fill_count = amount;
        fill_valid = 1'b1;
        consume_ready = 1'b1;
        #1;
        if (!consume_valid || consume_data !== expected || !fill_ready)
            $fatal(1, "simultaneous pop/fill rejected data=%h expected=%h count=%d", consume_data, expected, count);
        tick();
        fill_valid = 1'b0;
        fill_count = 2'd0;
        consume_ready = 1'b0;
        checks = checks + 1;
    endtask

    initial begin
        tick();
        if (count !== 4'd0 || consume_valid !== 1'b0)
            $fatal(1, "reset did not create an empty queue");
        reset = 1'b0;

        fill(16'hBBAA, 2'd2);
        if (count !== 4'd2) $fatal(1, "word fill count");
        pop(8'hAA);
        pop(8'hBB);
        if (count !== 4'd0) $fatal(1, "queue not empty after consumption");

        // Fill to capacity and verify that a seventh byte cannot enter.
        fill(16'h2211, 2'd2);
        fill(16'h4433, 2'd2);
        fill(16'h6655, 2'd2);
        fill_data = 16'h8877;
        fill_count = 2'd2;
        #1;
        if (fill_ready !== 1'b0 || count !== 4'd6)
            $fatal(1, "full queue accepted an overfill");
        fill_count = 2'd0;

        // Consume and refill together after the pointers have wrapped.
        pop(8'h11);
        pop(8'h22);
        pop(8'h33);
        pop(8'h44);
        fill(16'h8877, 2'd2);
        pop_with_fill(8'h55, 16'hAA99, 2'd2);
        pop(8'h66);
        pop(8'h77);
        pop(8'h88);
        pop(8'h99);
        pop(8'hAA);
        if (count !== 4'd0) $fatal(1, "wrapped queue did not drain");

        fill(16'h1234, 2'd2);
        flush = 1'b1;
        tick();
        flush = 1'b0;
        if (count !== 4'd0 || consume_valid !== 1'b0)
            $fatal(1, "flush retained stale bytes");
        fill(16'h5678, 2'd2);
        reset = 1'b1;
        tick();
        if (count !== 4'd0 || consume_valid !== 1'b0)
            $fatal(1, "reset retained queue state");

        $display("PREFETCH_QUEUE PASS: %0d ordering/capacity/refill/flush checks", checks);
        $finish;
    end
endmodule
