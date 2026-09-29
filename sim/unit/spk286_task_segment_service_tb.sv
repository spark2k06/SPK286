`timescale 1ns/1ps

module spk286_task_segment_service_tb;
    logic clk = 1'b0, reset = 1'b1, cancel = 1'b0, start = 1'b0;
    logic [63:0] task_segments = 64'h0048003800280018;
    logic [15:0] gdtr_limit = 16'h007F, ldtr_limit = 16'h007F;
    logic [23:0] gdtr_base = 24'h000100, ldtr_base = 24'h000200;
    logic ldtr_valid = 1'b1, ldtr_present = 1'b1;
    logic update_accessed = 1'b1;
    logic memory_done = 1'b0;
    logic [15:0] memory_read_data = 16'h0000;
    wire memory_request, memory_write, memory_byte, busy, complete, fault, commit_valid;
    wire [23:0] memory_address;
    wire [15:0] memory_write_data, fault_error_code;
    wire [7:0] fault_vector;
    wire [63:0] cache_selectors, cache_limits;
    wire [95:0] cache_bases;
    wire [31:0] cache_access;
    wire [15:0] cache_classes;
    wire [3:0] cache_present, cache_protected, cache_tables;
    wire [7:0] cache_dpl, cache_rpl;
    logic [7:0] memory [0:1023];
    integer checks = 0;

    spk286_task_segment_service dut (.*);

    task automatic check(input logic condition, input string message);
        begin checks = checks + 1; if (condition !== 1'b1) $fatal(1, "%s", message); end
    endtask
    task automatic write_word(input integer address, input logic [15:0] data);
        begin memory[address] = data[7:0]; memory[address + 1] = data[15:8]; end
    endtask
    task automatic write_descriptor(input integer address, input logic [23:0] base,
                                    input logic [15:0] limit, input logic [7:0] access);
        logic [63:0] raw;
        begin
            raw = 64'h0; raw[15:0] = limit; raw[31:16] = base[15:0];
            raw[39:32] = base[23:16]; raw[47:40] = access;
            write_word(address, raw[15:0]); write_word(address + 2, raw[31:16]);
            write_word(address + 4, raw[47:32]); write_word(address + 6, raw[63:48]);
        end
    endtask
    task automatic tick(input logic respond);
        begin
            #1; memory_done = 1'b0;
            if (respond && memory_request) begin
                if (memory_write) begin
                    memory[memory_address[9:0]] = memory_write_data[7:0];
                end else begin
                    memory_read_data = {memory[memory_address[9:0] + 1], memory[memory_address[9:0]]};
                end
                memory_done = 1'b1;
            end
            #1; clk = 1'b1; #1; clk = 1'b0; #1; memory_done = 1'b0;
        end
    endtask
    task automatic run_to_end;
        integer deadline;
        begin
            deadline = 0;
            while (!complete && !fault && deadline < 100) begin tick(1'b1); deadline = deadline + 1; end
            check((complete || fault) && !busy, "task segment transaction terminates");
        end
    endtask

    initial begin
        for (integer i = 0; i < 1024; i = i + 1) memory[i] = 8'h00;
        // GDT: ES data, CS code DPL0, SS writable data DPL0, DS data.
        write_descriptor(32'h00000118, 24'h110000, 16'hFFFF, 8'h92);
        write_descriptor(32'h00000128, 24'h220000, 16'h7FFF, 8'h9A);
        write_descriptor(32'h00000138, 24'h330000, 16'hFFFF, 8'h92);
        write_descriptor(32'h00000148, 24'h440000, 16'hFFFF, 8'h92);
        reset = 1'b1; tick(1'b0); reset = 1'b0;
        start = 1'b1; tick(1'b0); start = 1'b0;
        tick(1'b0);
        check(memory_request && memory_address == 24'h000118, "task segment read starts at ES");
        tick(1'b0);
        check(memory_request && memory_address == 24'h000118, "task segment read holds under READY stall");
        run_to_end();
        check(complete && commit_valid && cache_selectors == task_segments, "all task selectors commit together");
        check(cache_bases[23:0] == 24'h110000 && cache_bases[47:24] == 24'h220000 &&
              cache_bases[71:48] == 24'h330000 && cache_bases[95:72] == 24'h440000,
              "all hidden bases are constructed");
        check(cache_access[7:0] == 8'h93 && cache_access[15:8] == 8'h9B,
              "accessed bits are reflected in candidates");
        check(memory[10'h11D] == 8'h93 && memory[10'h12D] == 8'h9B,
              "descriptor accessed bytes are written before commit");
        check(memory[10'h11C] == 8'h11 && memory[10'h12C] == 8'h22 &&
              memory[10'h13C] == 8'h33 && memory[10'h14C] == 8'h44,
              "accessed updates preserve every descriptor's high base byte");
        tick(1'b0);

        // Null ES/DS are empty caches; CS/SS remain mandatory.
        for (integer rpl = 0; rpl < 4; rpl = rpl + 1) begin
            task_segments = {16'(rpl), 16'h0038, 16'h0028, 16'(rpl)};
            reset = 1'b1; tick(1'b0); reset = 1'b0; start = 1'b1; tick(1'b0); start = 1'b0; tick(1'b0); run_to_end();
            check(complete && cache_present[0] == 1'b0 && cache_present[3] == 1'b0,
                  "null ES and DS become empty caches");
            tick(1'b0);
        end

        // LDT entry zero is non-null for every RPL. Exercise incoming code
        // and data/stack caches, with matching CPL/DPL and an exact limit.
        ldtr_limit = 16'h0007;
        for (integer rpl = 0; rpl < 4; rpl = rpl + 1) begin
            write_descriptor(32'h00000200, 24'h550000, 16'h7FFF, 8'h9A | (8'(rpl) << 5));
            write_descriptor(32'h00000138, 24'h330000, 16'hFFFF, 8'h92 | (8'(rpl) << 5));
            task_segments = {16'h0000, (16'h0038 | 16'(rpl)), (16'h0004 | 16'(rpl)), 16'h0000};
            reset = 1'b1; tick(1'b0); reset = 1'b0; start = 1'b1; tick(1'b0); start = 1'b0; tick(1'b0); run_to_end();
            check(complete && commit_valid && cache_selectors == task_segments &&
                  cache_bases[47:24] == 24'h550000 && cache_tables[1] && cache_present[1],
                  "incoming CS resolves LDT entry zero for each CPL/RPL/DPL");
            check(memory[10'h205] == (8'h9B | (8'(rpl) << 5)),
                  "LDT entry-zero code accessed bit is written");
            check(memory[10'h204] == 8'h55, "LDT accessed update does not corrupt the code base");

            write_descriptor(32'h00000200, 24'h660000, 16'hFFFF, 8'h92 | (8'(rpl) << 5));
            write_descriptor(32'h00000128, 24'h220000, 16'h7FFF, 8'h9A | (8'(rpl) << 5));
            task_segments = {(16'h0004 | 16'(rpl)), (16'h0004 | 16'(rpl)),
                             (16'h0028 | 16'(rpl)), (16'h0004 | 16'(rpl))};
            reset = 1'b1; tick(1'b0); reset = 1'b0; start = 1'b1; tick(1'b0); start = 1'b0; tick(1'b0); run_to_end();
            check(complete && commit_valid && cache_selectors == task_segments &&
                  cache_tables == 4'b1101 && cache_present == 4'b1111 &&
                  cache_bases[23:0] == 24'h660000 && cache_bases[71:48] == 24'h660000 &&
                  cache_bases[95:72] == 24'h660000,
                  "incoming ES/SS/DS resolve LDT entry zero rather than becoming null");
        end
        write_descriptor(32'h00000128, 24'h220000, 16'h7FFF, 8'h9A);
        write_descriptor(32'h00000138, 24'h330000, 16'hFFFF, 8'h92);
        write_descriptor(32'h00000200, 24'h550000, 16'h7FFF, 8'h9A);
        task_segments = 64'h0000003800040000;
        ldtr_limit = 16'h0006;
        reset = 1'b1; tick(1'b0); reset = 1'b0; start = 1'b1; tick(1'b0); start = 1'b0; tick(1'b0); run_to_end();
        check(fault && fault_vector == 8'd10 && fault_error_code == 16'h0004,
              "LDT entry zero beyond the table limit still raises #TS");
        ldtr_limit = 16'h0007; ldtr_valid = 1'b0;
        reset = 1'b1; tick(1'b0); reset = 1'b0; start = 1'b1; tick(1'b0); start = 1'b0; tick(1'b0); run_to_end();
        check(fault && fault_vector == 8'd10 && fault_error_code == 16'h0004,
              "LDT entry zero requires a valid incoming LDT");
        ldtr_valid = 1'b1; ldtr_limit = 16'h007F;

        // A non-writable SS is rejected as an invalid task state.
        write_descriptor(32'h00000138, 24'h330000, 16'hFFFF, 8'h91);
        task_segments = 64'h0048003800280018;
        reset = 1'b1; tick(1'b0); reset = 1'b0; start = 1'b1; tick(1'b0); start = 1'b0; tick(1'b0); run_to_end();
        check(fault && fault_vector == 8'd10, "non-writable SS raises #TS");

        // A structurally valid but absent SS is a stack fault, and its
        // selector must win over a later ES/DS absence.
        write_descriptor(32'h00000138, 24'h330000, 16'hFFFF, 8'h12);
        task_segments = 64'h0048003800280018;
        reset = 1'b1; tick(1'b0); reset = 1'b0; start = 1'b1; tick(1'b0); start = 1'b0; tick(1'b0); run_to_end();
        check(fault && fault_vector == 8'd12 && fault_error_code == 16'h0038,
              "not-present SS raises #SS with the SS selector");

        // Intel 286 B-13: task-loaded ES/DS may reference readable conforming
        // code at any DPL or selector RPL. CS and SS still use task CPL rules.
        for (integer cpl = 0; cpl < 4; cpl = cpl + 1)
            for (integer dpl = 0; dpl < 4; dpl = dpl + 1)
                for (integer rpl = 0; rpl < 4; rpl = rpl + 1) begin
                    write_descriptor(32'h00000118, 24'h110000, 16'hFFFF,
                                     8'h9E | (8'(dpl) << 5));
                    write_descriptor(32'h00000128, 24'h220000, 16'h7FFF,
                                     8'h9A | (8'(cpl) << 5));
                    write_descriptor(32'h00000138, 24'h330000, 16'hFFFF,
                                     8'h92 | (8'(cpl) << 5));
                    write_descriptor(32'h00000148, 24'h440000, 16'hFFFF,
                                     8'h9E | (8'(dpl) << 5));
                    task_segments = {(16'h0048 | 16'(rpl)), (16'h0038 | 16'(cpl)),
                                     (16'h0028 | 16'(cpl)), (16'h0018 | 16'(rpl))};
                    reset = 1'b1; tick(1'b0); reset = 1'b0;
                    start = 1'b1; tick(1'b0); start = 1'b0; tick(1'b0);
                    run_to_end();
                    check(complete && commit_valid && !fault && cache_selectors == task_segments &&
                          cache_access[7:0] == (8'h9F | (8'(dpl) << 5)) &&
                          cache_access[31:24] == (8'h9F | (8'(dpl) << 5)) &&
                          cache_dpl[1:0] == 2'(dpl) && cache_dpl[7:6] == 2'(dpl) &&
                          memory[10'h11D] == (8'h9F | (8'(dpl) << 5)) &&
                          memory[10'h14D] == (8'h9F | (8'(dpl) << 5)),
                          $sformatf("task conforming ES/DS CPL=%0d DPL=%0d RPL=%0d", cpl, dpl, rpl));
                    tick(1'b0);
                end

        // Execute-only code is not a readable data register target. Presence
        // faults must remain distinct from type/privilege faults.
        task_segments = 64'h0048003800280018;
        write_descriptor(32'h00000128, 24'h220000, 16'h7FFF, 8'h9A);
        write_descriptor(32'h00000138, 24'h330000, 16'hFFFF, 8'h92);
        write_descriptor(32'h00000148, 24'h440000, 16'hFFFF, 8'h93);
        write_descriptor(32'h00000118, 24'h110000, 16'hFFFF, 8'h9C);
        reset = 1'b1; tick(1'b0); reset = 1'b0;
        start = 1'b1; tick(1'b0); start = 1'b0; tick(1'b0); run_to_end();
        check(fault && fault_vector == 8'd10 && fault_error_code == 16'h0018 && !commit_valid,
              "task execute-only ES raises #TS without publishing caches");
        write_descriptor(32'h00000118, 24'h110000, 16'hFFFF, 8'h1E);
        reset = 1'b1; tick(1'b0); reset = 1'b0;
        start = 1'b1; tick(1'b0); start = 1'b0; tick(1'b0); run_to_end();
        check(fault && fault_vector == 8'd11 && fault_error_code == 16'h0018 && !commit_valid,
              "task absent readable conforming ES raises #NP");
        $display("TASK_SEGMENT_SERVICE PASS: %0d checks", checks);
        $finish;
    end
endmodule
