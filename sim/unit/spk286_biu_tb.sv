`timescale 1ns/1ps
module spk286_biu_tb;
    logic clk = 0, reset = 1, cancel_data = 0, ready = 0;
    logic [15:0] data_in = 0;
    logic code_valid = 0, code_bhe_n = 0;
    logic [23:0] code_address = 24'h100000;
    wire code_ready;
    logic data_request = 0, data_write = 0;
    logic [23:0] data_address = 0;
    logic [15:0] data_write_data = 0;
    wire data_request_ready, data_response_valid;
    logic data_response_ready = 0;
    wire [15:0] data_read_data;
    wire [23:0] address;
    wire [15:0] data_out;
    wire data_oe, bus_valid, bus_write, bus_bhe_n;
    wire [3:0] bus_status;
    integer checks = 0, cases = 0, physical_data_cycles = 0, logical_responses = 0;
    spk286_biu dut (.*);
    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1) $fatal(1, "%s case=%d address=%h status=%h data=%h response=%b",
                                      message, cases, address, bus_status, data_out, data_response_valid);
    endtask
    task automatic tick;
        #5;
        if (!reset) begin
            if (bus_valid && ready && (bus_status == 5 || bus_status == 6))
                physical_data_cycles = physical_data_cycles + 1;
            if (data_response_valid && data_response_ready && !cancel_data)
                logical_responses = logical_responses + 1;
        end
        clk = 1; #5; clk = 0; #1;
    endtask
    task automatic initialize;
        reset = 1; cancel_data = 0; ready = 0; code_valid = 0;
        data_request = 0; data_response_ready = 0; tick(); reset = 0; #1;
        physical_data_cycles = 0; logical_responses = 0;
        check(!bus_valid && data_request_ready && !data_response_valid && !data_oe, "reset clears request/response/owner");
    endtask
    task automatic request_word(input logic wr, input logic [23:0] addr);
        check(data_request_ready, "logical request accepted only when available");
        data_request = 1; data_write = wr; data_address = addr; data_write_data = 16'hBEEF;
        tick(); data_request = 0;
        // A changing requester may not alter the already accepted word.
        data_address = 24'hABCDEF; data_write_data = 16'h1234; data_write = !wr; #1;
        check(!data_request_ready, "one outstanding data word");
    endtask
    task automatic complete_cycle(input logic wr, input logic [23:0] addr, input logic bhe,
                                   input logic [15:0] driven, input logic [15:0] sampled,
                                   input integer waits);
        ready = 0;
        for (integer w = 0; w <= waits; w = w + 1) begin
            #1;
            check(bus_valid && address == addr && bus_bhe_n == bhe && bus_write == wr && data_oe == wr,
                  "stable data-cycle address/direction/lanes");
            check(bus_status == (wr ? 6 : 5) && !code_ready && !data_response_valid, "data owner/completion routing");
            if (wr) check(data_out == driven, "write data snapshot/lane placement");
            if (w < waits) begin data_in = 16'(w*257); tick(); end
        end
        data_in = sampled; ready = 1; tick(); ready = 0;
    endtask
    initial begin
        for (integer wr = 0; wr < 2; wr = wr + 1)
            for (integer odd = 0; odd < 2; odd = odd + 1)
                for (integer first_wait = 0; first_wait < 5; first_wait = first_wait + 1)
                    for (integer second_wait = 0; second_wait < 5; second_wait = second_wait + 1) begin
                        initialize(); request_word(1'(wr), 24'h100100 + 24'(odd));
                        if (odd != 0) begin
                            complete_cycle(1'(wr), 24'h100101, 0, 16'hEF00, 16'h7E19, first_wait);
                            check(!data_response_valid && !data_request_ready, "first odd byte cannot complete logical word");
                            complete_cycle(1'(wr), 24'h100102, 1, 16'h00BE, 16'hA5C1, second_wait);
                        end else complete_cycle(1'(wr), 24'h100100, 0, 16'hBEEF, 16'hC17E, first_wait);
                        check(data_response_valid && data_read_data == 16'hC17E && !bus_valid, "one complete little-endian word");
                        data_request = 1;
                        repeat (5) begin
                            data_in = 16'hDEAD; ready = 1; tick();
                            check(data_response_valid && data_read_data == 16'hC17E && !bus_valid && !data_request_ready,
                                  "held response/backpressure prevents repeat transactions");
                        end
                        data_response_ready = 1; tick(); data_request = 0; data_response_ready = 0; ready = 0;
                        check(!data_response_valid && data_request_ready, "consume completion once");
                        cases = cases + 1;
                    end
        // A waiting code fetch retains ownership when a data word is accepted.
        initialize(); code_valid = 1; ready = 0; tick();
        request_word(0, 24'h200100);
        repeat (4) begin
            check(bus_valid && address == code_address && bus_status == 13 && !data_response_valid, "data cannot preempt active code");
            tick();
        end
        ready = 1; #1; check(code_ready, "READY routed to code owner only"); tick(); code_valid = 0; ready = 0;
        complete_cycle(0, 24'h200100, 0, 0, 16'hC17E, 3);
        check(data_response_valid && data_read_data == 16'hC17E, "pending data follows code");
        // Data wins the next free boundary and code resumes without a data response leak.
        initialize(); request_word(0, 24'h200101); code_valid = 1;
        complete_cycle(0, 24'h200101, 0, 0, 16'h7E00, 2);
        complete_cycle(0, 24'h200102, 1, 0, 16'h00C1, 4);
        check(bus_status == 13 && data_response_valid && data_read_data == 16'hC17E, "code resumes with independent held data response");
        // Cancellation drains accepted words, including both halves of a write,
        // while suppressing the obsolete logical response. Reset can abort them.
        for (integer wr = 0; wr < 2; wr = wr + 1)
            for (integer part = 0; part < 2; part = part + 1) begin
                initialize(); request_word(1'(wr), 24'h200101);
                if (part != 0) complete_cycle(1'(wr), 24'h200101, 0, 16'hEF00, 16'h7E00, 1);
                cancel_data = 1; tick(); cancel_data = 0;
                if (part == 0) complete_cycle(1'(wr), 24'h200101, 0, 16'hEF00, 16'h7E00, 2);
                complete_cycle(1'(wr), 24'h200102, 1, 16'h00BE, 16'h00C1, 3);
                check(!data_response_valid && data_request_ready && !bus_valid, "canceled word cannot publish completion");
                initialize(); request_word(1'(wr), 24'h200101);
                if (part != 0) complete_cycle(1'(wr), 24'h200101, 0, 16'hEF00, 16'h7E00, 0);
                reset = 1; #1; check(!bus_valid && !data_oe, "reset inhibits physical cycle"); tick(); reset = 0;
                repeat (3) begin ready = 1; tick(); check(!data_response_valid && !bus_valid, "no stale response after reset"); end
                cases = cases + 1;
            end
        // The first visible CODE cycle and logical data acceptance coincide.
        // Check both immediate READY and a newly acquired waiting code owner.
        for (integer code_wait = 0; code_wait < 2; code_wait = code_wait + 1) begin
            initialize(); code_valid = 1; ready = code_wait == 0;
            request_word(0, 24'h200101);
            if (code_wait != 0) begin
                repeat (3) begin
                    check(bus_status == 13 && !code_ready && physical_data_cycles == 0,
                          "new code owner cannot be stolen on data acceptance edge"); tick();
                end
                ready = 1; #1; check(code_ready, "waiting code gets its own READY"); tick();
            end
            code_valid = 0; ready = 1; data_in = 16'h7E19; #1;
            check(bus_status == 5 && address == 24'h200101 && !code_ready, "data follows completed code");
            tick(); data_in = 16'hA5C1; #1;
            check(!data_response_valid && address == 24'h200102 && bus_bhe_n,
                  "continuous READY still requires a second odd cycle");
            tick(); data_response_ready = 1; tick(); data_response_ready = 0;
            repeat (3) tick();
            check(physical_data_cycles == 2 && logical_responses == 1 && !data_response_valid,
                  "continuous READY produces exactly two physical cycles and one response");
            cases = cases + 1;
        end
        // Cancel and READY coincide on either odd subcycle. Unlike reset,
        // cancellation must still drain the full accepted logical word.
        for (integer wr = 0; wr < 2; wr = wr + 1)
            for (integer part = 0; part < 2; part = part + 1) begin
                initialize(); request_word(1'(wr), 24'h0FFFFF); code_valid = 1;
                if (part != 0) complete_cycle(1'(wr), 24'h0FFFFF, 0, 16'hEF00, 16'h7E19, 2);
                cancel_data = 1;
                complete_cycle(1'(wr), part == 0 ? 24'h0FFFFF : 24'h100000,
                               1'(part), part == 0 ? 16'hEF00 : 16'h00BE,
                               part == 0 ? 16'h7E19 : 16'hA5C1, 0);
                cancel_data = 0;
                if (part == 0) complete_cycle(1'(wr), 24'h100000, 1, 16'h00BE, 16'hA5C1, 3);
                data_response_ready = 1; ready = 1; #1;
                check(bus_status == 13 && code_ready && !data_response_valid, "code resumes after canceled A20-crossing word");
                tick(); code_valid = 0;
                repeat (3) tick();
                check(physical_data_cycles == 2 && logical_responses == 0 && data_request_ready,
                      "coincident cancel cannot publish or duplicate completion");
                cases = cases + 1;
            end
        initialize(); request_word(0, 24'h200100);
        complete_cycle(0, 24'h200100, 0, 0, 16'hC17E, 1);
        cancel_data = 1; data_response_ready = 1; tick();
        check(!data_response_valid && logical_responses == 0 && !data_request_ready, "cancel discards held response on consumption edge");
        cancel_data = 0; #1; check(data_request_ready, "admission resumes after cancel is removed");
        initialize(); cancel_data = 1; data_request = 1; ready = 1; tick();
        check(!bus_valid && !data_request_ready && physical_data_cycles == 0, "cancel before acceptance admits no physical work");
        data_request = 0; cancel_data = 0; tick();
        check(!bus_valid && !data_response_valid, "unaccepted canceled request cannot reappear");
        $display("BIU PASS: %0d word/reset/cancel cases plus arbitration; %0d checks", cases, checks);
        $finish;
    end
endmodule
