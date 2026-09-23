`timescale 1ns/1ps
module spk286_muldiv_instructions_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:1114111];
    logic [7:0] code [0:7];
    logic [127:0] initial_gpr, expected_gpr;
    logic [15:0] initial_flags, expected_flags, offset, initial_memory, expected_memory;
    integer file_handle, total, fields, vector_word, length, segment, target;
    integer cases = 0, checks = 0, reads, writes, expected_reads, expected_writes, retires;
    integer wait_length, wait_count, timeout_count, blocked;
    integer immediate_stalls=0;
    logic waiting, byte_width;
    logic [23:0] held_address;
    logic [15:0] held_data;
    logic [3:0] held_status;
    logic held_write, held_bhe;
    string path;
    spk286 dut (.*);
    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1)
            $fatal(1, "%s case=%0d opcode=%h modrm=%h IP=%h flags=%h expected=%h pc=%h reads=%0d writes=%0d",
                   message, cases, debug_opcode, debug_modrm, debug_ip, debug_flags, expected_flags,
                   debug_micro_pc, reads, writes);
    endtask
    task automatic scan;
        fields = $fscanf(file_handle, "%h", vector_word);
        if (fields != 1) $fatal(1, "malformed instruction vector");
    endtask
    task automatic tick;
        #1;
        data_in = 16'hF4F4;
        if (bus_valid && address < 24'd1114112)
            data_in = {memory[{address[20:1],1'b1}],memory[{address[20:1],1'b0}]};
        if (bus_valid && address[0]) data_in[7:0] = 8'hA3;
        if (bus_valid && bus_bhe_n) data_in[15:8] = 8'hC7;
        #4;
        if (execute_enable && debug_micro_active && !dut.queue_consume_valid &&
            (debug_micro_instruction == spk286_microcode_pkg::MC_FETCH_IMM8_TMP1 || debug_micro_instruction == spk286_microcode_pkg::MC_FETCH_IMM8 ||
             debug_micro_instruction == spk286_microcode_pkg::MC_FETCH_IMM16_TMP1 ||
             debug_micro_instruction == spk286_microcode_pkg::MC_FETCH_IMM8S_TMP1 ||
             dut.micro_executor.immediate_fetch))
            immediate_stalls=immediate_stalls+1;
        if (bus_valid && ready && !reset && (bus_status == 5 || bus_status == 6)) begin
            check(blocked != 1 && (expected_reads != 0 || expected_writes != 0), "unexpected data transaction");
            check(int'(address) == target + ((bus_write ? writes : reads) == 1 ? 1 : 0), "data address/order");
            check(bus_bhe_n == (byte_width ? !address[0] : ((bus_write ? writes : reads) == 1)), "data word byte lanes");
            check(data_oe == bus_write, "data drive direction");
            if (bus_write) begin
                check(reads == expected_reads, "result write follows full operand read");
                if (address[0]) memory[address[20:0]] = data_out[15:8];
                else begin
                    memory[address[20:0]] = data_out[7:0];
                    if (!bus_bhe_n) memory[address+1] = data_out[15:8];
                end
                writes = writes + 1;
            end else reads = reads + 1;
            check(reads <= expected_reads && writes <= expected_writes, "no duplicate or CMP data write");
        end
        if (dut.internal_flags_write_en) begin
            check(reads == expected_reads && writes == expected_writes, "FLAGS follows complete memory write");
            check(execute_enable && !reset && !redirect, "FLAGS commit enabled only during execution");
        end
        clk = 1; #5; clk = 0; #1;
        if (instruction_retired) retires = retires + 1;
        check(debug_prefetch_count <= 6 && !microcode_fault, "queue and microcode valid");
    endtask
    task automatic service;
        #1;
        if (waiting) check(bus_valid && address == held_address && data_out == held_data &&
                           bus_status == held_status && bus_write == held_write && bus_bhe_n == held_bhe,
                           "READY retains transaction owner and data");
        ready = bus_valid && wait_count >= wait_length;
        waiting = bus_valid && !ready;
        if (waiting) begin
            held_address = address; held_data = data_out; held_status = bus_status;
            held_write = bus_write; held_bhe = bus_bhe_n; wait_count = wait_count + 1;
        end else wait_count = 0;
        if (bus_status == 5 || bus_status == 6) check(!dut.queue_flush, "data access preserves prefetch");
        tick();
    endtask
    task automatic setup;
        execute_enable = 0; reset = 1; ready = 0;
        gpr_write_en = 0; flags_write_en = 0; ip_write_en = 0; redirect = 0; segment_load_en = 0;
        waiting = 0; wait_count = 0; reads = 0; writes = 0; retires = 0;
        tick(); reset = 0;
        for (integer r = 0; r < 8; r = r + 1) begin
            gpr_write_en = 1; gpr_write_index = 3'(r); gpr_write_data = initial_gpr[r*16 +: 16]; tick();
        end
        gpr_write_en = 0; flags_write_en = 1; flags_write_mask = 16'hFFFF;
        flags_write_data = initial_flags; tick(); flags_write_en = 0;
        for (integer s = 0; s < 4; s = s + 1) begin
            segment_load_en = 1; segment_load_index = 2'(s);
            segment_load_selector = s == 1 ? 16'h1000 : (s == 2 ? 16'h8000 : 16'h4000);
            redirect = s == 1; ip_write_en = s == 1; ip_write_data = 16'h0100; tick();
        end
        segment_load_en = 0; redirect = 0; ip_write_en = 0; execute_enable = 1;
    endtask
    initial begin
        if (!$value$plusargs("instruction_vectors=%s", path)) $fatal(1, "missing instruction vectors");
        file_handle = $fopen(path, "r");
        if (file_handle == 0) $fatal(1, "cannot open instruction vectors");
        scan(); total = vector_word;
        for (integer i = 0; i < total; i = i + 1) begin
            scan(); byte_width = vector_word != 0; scan(); length = vector_word;
            for (integer b = 0; b < 8; b = b + 1) begin scan(); code[b] = 8'(vector_word); memory[65792+b] = code[b]; end
            scan(); initial_flags = 16'(vector_word);
            for (integer r = 0; r < 8; r = r + 1) begin scan(); initial_gpr[r*16 +: 16] = 16'(vector_word); end
            scan(); expected_flags = 16'(vector_word);
            for (integer r = 0; r < 8; r = r + 1) begin scan(); expected_gpr[r*16 +: 16] = 16'(vector_word); end
            scan(); offset = 16'(vector_word); scan(); segment = vector_word;
            scan(); initial_memory = 16'(vector_word); scan(); expected_memory = 16'(vector_word);
            scan(); expected_reads = vector_word * (!byte_width && offset[0] ? 2 : 1);
            scan(); expected_writes = vector_word * (!byte_width && offset[0] ? 2 : 1);
            scan(); wait_length = vector_word; scan(); blocked = vector_word;
            target = (segment == 2 ? 524288 : 262144) + int'(offset);
            memory[target-1] = 8'h5A; memory[target] = initial_memory[7:0];
            memory[target+1] = initial_memory[15:8]; memory[target+2] = 8'hA5;
            setup(); timeout_count = 0;
            while (!instruction_retired && !operand_blocked && !dut.arithmetic_fault && timeout_count < 500) begin
                service(); timeout_count = timeout_count + 1;
                check(!unsupported_opcode, "supported integer arithmetic instruction");
            end
            if (blocked != 0) begin
                execute_enable = 0; // Inspect the fault producer; event suite checks delivery.
                repeat (6) service();
                check(retires==0 && writes==0 && reads==expected_reads,"fault suppresses result stores and retirement after required reads");
                check(blocked==1 ? operand_blocked && reads==0 : dut.micro_executor.arithmetic_fault_q,"precise operand/arithmetic fault producer");
            end else begin
                check(retires == 1 && debug_ip == 16'h0100 + 16'(length), "exact IP and single retirement");
                check(reads == expected_reads && writes == expected_writes, "complete data traffic before END");
            end
            check(debug_gpr == expected_gpr, "exact GPR result/preservation");
            check(debug_flags == expected_flags, "exact FLAGS and preserved bits");
            check({memory[target+1],memory[target]} == expected_memory, "exact memory result/preservation");
            check(memory[target-1] == 8'h5A && memory[target+2] == 8'hA5, "memory neighbors preserved");
            execute_enable = 0;
            repeat (3) service();
            check(retires == (blocked != 0 ? 0 : 1), "no duplicated retirement");
            cases = cases + 1;
        end
        $fclose(file_handle);
        check(cases == 19556, "complete arithmetic instruction vector set");
        check(immediate_stalls>0,"immediate-byte starvation exercised");
        $display("MULDIV_INSTRUCTIONS PASS: %0d directed CPU cases; %0d checks; %0d immediate stalls", cases, checks, immediate_stalls);
        $finish;
    end
endmodule
