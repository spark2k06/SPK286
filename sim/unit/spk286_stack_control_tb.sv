`timescale 1ns/1ps
module spk286_stack_control_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:1114111];
    logic [7:0] code [0:7];
    logic [127:0] initial_gpr, expected_gpr;
    logic [15:0] initial_flags, expected_flags, initial_ip, expected_ip;
    integer file_handle, total, fields, vector_word, length;
    integer cases = 0, checks = 0, reads, writes, retires;
    integer wait_length, wait_count, timeout_count, blocked, redirects, expected_redirects;
    integer memory_count, transaction_count, transaction_index;
    integer memory_addresses[0:255], expected_bytes[0:255];
    integer transaction_address[0:7], transaction_data[0:7], transaction_write[0:7], transaction_bhe[0:7];
    logic waiting;
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
        if (bus_valid && ready && !reset && (bus_status == 5 || bus_status == 6)) begin
            check(transaction_index < transaction_count, "unexpected data transaction");
            check(int'(address) == transaction_address[transaction_index], "ordered data address");
            check(int'(bus_write) == transaction_write[transaction_index], "ordered transfer direction");
            check(int'(bus_bhe_n) == transaction_bhe[transaction_index], "word byte lanes");
            check(data_oe == bus_write, "bus drive direction");
            if (bus_write) begin
                if (address[0]) begin
                    check(data_out[15:8] == 8'(transaction_data[transaction_index] >> 8), "upper write byte");
                    memory[address[20:0]] = data_out[15:8];
                end else begin
                    check(data_out[7:0] == 8'(transaction_data[transaction_index]), "lower write byte");
                    memory[address[20:0]] = data_out[7:0];
                    if (!bus_bhe_n) begin
                        check(data_out == 16'(transaction_data[transaction_index]), "aligned write word");
                        memory[address+1] = data_out[15:8];
                    end
                end
                writes = writes+1;
            end else reads = reads+1;
            transaction_index = transaction_index+1;
        end
        if (dut.internal_redirect) redirects = redirects+1;
        check(!dut.internal_flags_write_en, "stack/control preserves FLAGS");
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
        waiting = 0; wait_count = 0; reads = 0; writes = 0; retires = 0; redirects = 0; transaction_index = 0;
        tick(); reset = 0;
        for (integer r = 0; r < 8; r = r + 1) begin
            gpr_write_en = 1; gpr_write_index = 3'(r); gpr_write_data = initial_gpr[r*16 +: 16]; tick();
        end
        gpr_write_en = 0; flags_write_en = 1; flags_write_mask = 16'hFFFF;
        flags_write_data = initial_flags; tick(); flags_write_en = 0;
        for (integer s = 0; s < 4; s = s + 1) begin
            segment_load_en = 1; segment_load_index = 2'(s);
            segment_load_selector = s == 1 ? 16'h1000 : (s == 2 ? 16'h8000 : 16'h4000);
            redirect = s == 1; ip_write_en = s == 1; ip_write_data = initial_ip; tick();
        end
        segment_load_en = 0; redirect = 0; ip_write_en = 0; execute_enable = 1;
    endtask
    initial begin
        if (!$value$plusargs("instruction_vectors=%s", path)) $fatal(1, "missing instruction vectors");
        file_handle = $fopen(path, "r");
        if (file_handle == 0) $fatal(1, "cannot open instruction vectors");
        scan(); total = vector_word;
        for (integer i = 0; i < total; i = i + 1) begin
            scan(); length = vector_word;
            for (integer b = 0; b < 8; b = b + 1) begin scan(); code[b] = 8'(vector_word); end
            scan(); initial_ip=16'(vector_word);
            for (integer b=0; b<8; b=b+1) memory[65536+int'(initial_ip)+b]=code[b];
            scan(); initial_flags = 16'(vector_word); expected_flags = initial_flags;
            for (integer r = 0; r < 8; r = r + 1) begin scan(); initial_gpr[r*16 +: 16] = 16'(vector_word); end
            scan(); expected_ip=16'(vector_word);
            for (integer r = 0; r < 8; r = r + 1) begin scan(); expected_gpr[r*16 +: 16] = 16'(vector_word); end
            scan(); blocked=vector_word; scan(); expected_redirects=vector_word; scan(); wait_length=vector_word;
            scan(); memory_count=vector_word;
            check(memory_count<=256,"memory vector capacity");
            for (integer m=0; m<memory_count; m=m+1) begin
                scan(); memory_addresses[m]=vector_word;
                scan(); memory[memory_addresses[m]]=8'(vector_word);
                scan(); expected_bytes[m]=vector_word;
            end
            scan(); transaction_count=vector_word;
            check(transaction_count<=8,"bus vector capacity");
            for (integer t=0; t<transaction_count; t=t+1) begin
                scan(); transaction_write[t]=vector_word; scan(); transaction_address[t]=vector_word;
                scan(); transaction_data[t]=vector_word; scan(); transaction_bhe[t]=vector_word;
            end
            setup(); timeout_count = 0;
            while (!instruction_retired && !operand_blocked && timeout_count < 400) begin
                service(); timeout_count = timeout_count + 1;
                check(!unsupported_opcode, "supported stack/control instruction");
            end
            if (blocked != 0) begin
                // Preserve the original fault-producer check under debug pause.
                // Completed delivery and frame effects are covered by the event benches.
                execute_enable = 0;
                repeat (6) service();
                check(operand_blocked && retires == 0 && writes == 0, "whole word blocks without effects");
            end else begin
                check(retires == 1 && debug_ip == expected_ip, "exact IP and single retirement");
                check(transaction_index == transaction_count, "complete ordered data traffic before END");
            end
            check(transaction_index == transaction_count, "all modeled pre-delivery word effects");
            check(debug_gpr == expected_gpr, "exact GPR result/preservation");
            check(debug_flags == expected_flags, "exact FLAGS and preserved bits");
            check(redirects == expected_redirects, "exact taken/not-taken queue flush count");
            check(debug_segment_selectors == 64'h4000800010004000 &&
                  debug_segment_limits == 64'hFFFFFFFFFFFFFFFF, "CS and segment caches preserved");
            for (integer m=0; m<memory_count; m=m+1)
                check(memory[memory_addresses[m]] == 8'(expected_bytes[m]), "exact memory and neighbor preservation");
            execute_enable = 0;
            repeat (3) service();
            check(retires == (blocked != 0 ? 0 : 1), "no duplicated retirement");
            cases = cases + 1;
        end
        $fclose(file_handle);
        check(cases == total && total > 8000, "complete instruction vector set");
        $display("STACK_CONTROL PASS: %0d directed CPU cases; %0d checks", cases, checks);
        $finish;
    end
endmodule
