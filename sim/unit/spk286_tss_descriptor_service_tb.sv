// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module spk286_tss_descriptor_service_tb;
    logic clk = 1'b0, reset = 1'b1, cancel = 1'b0, start = 1'b0;
    logic return_task = 1'b0, enforce_dpl = 1'b1;
    logic [15:0] selector = 16'h0028;
    logic [1:0] current_cpl = 2'd0;
    logic [15:0] gdtr_limit = 16'h007F, ldtr_limit = 16'h007F;
    logic [23:0] gdtr_base = 24'h000100, ldtr_base = 24'h000200;
    logic ldtr_selector_valid = 1'b1, ldtr_present = 1'b1;
    logic memory_done = 1'b0;
    logic [15:0] memory_read_data = 16'h0000;
    wire memory_request, busy, complete, fault, candidate_valid;
    wire [23:0] memory_address, candidate_base, candidate_descriptor_address;
    wire [7:0] fault_vector, candidate_access;
    wire [15:0] fault_error_code, candidate_selector, candidate_limit;
    logic [7:0] memory [0:1023];
    integer checks = 0;

    spk286_tss_descriptor_service dut (.*);

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) $fatal(1, "%s", message);
        end
    endtask

    task automatic write_word(input integer address, input logic [15:0] data);
        begin
            memory[address] = data[7:0];
            memory[address + 1] = data[15:8];
        end
    endtask

    task automatic write_descriptor(input integer address, input logic [23:0] base,
                                    input logic [15:0] limit, input logic [7:0] access,
                                    input logic [15:0] reserved_hi);
        logic [63:0] raw;
        begin
            raw = 64'h0;
            raw[15:0] = limit;
            raw[31:16] = base[15:0];
            raw[39:32] = base[23:16];
            raw[47:40] = access;
            raw[63:48] = reserved_hi;
            write_word(address + 0, raw[15:0]);
            write_word(address + 2, raw[31:16]);
            write_word(address + 4, raw[47:32]);
            write_word(address + 6, raw[63:48]);
        end
    endtask

    task automatic tick(input logic respond);
        begin
            #1;
            memory_done = 1'b0;
            if (respond && memory_request) begin
                memory_read_data = {memory[memory_address[9:0] + 1], memory[memory_address[9:0]]};
                memory_done = 1'b1;
            end
            #1; clk = 1'b1; #1; clk = 1'b0; #1;
            memory_done = 1'b0;
        end
    endtask

    task automatic reset_dut;
        begin
            reset = 1'b1; tick(1'b0); reset = 1'b0;
        end
    endtask

    task automatic start_request;
        begin
            start = 1'b1; tick(1'b0); start = 1'b0;
        end
    endtask

    task automatic run_reads;
        integer deadline;
        begin
            deadline = 0;
            while (!complete && !fault && deadline < 20) begin
                tick(1'b1);
                deadline = deadline + 1;
            end
            check((complete || fault) && !busy, "descriptor request terminates");
        end
    endtask

    initial begin
        for (integer i = 0; i < 1024; i = i + 1) memory[i] = 8'h00;

        // GDT selector 0028 -> offset 28h, base 234567h, available TSS.
        write_descriptor(32'h00000128, 24'h234567, 16'h0030, 8'h81, 16'h0000);
        reset_dut();
        start_request();
        tick(1'b0);
        check(busy && memory_request && memory_address == 24'h000128,
              "GDT lookup starts at the selected descriptor");
        tick(1'b0);
        check(busy && memory_request && memory_address == 24'h000128,
              "READY stall holds the first descriptor address");
        run_reads();
        check(complete && candidate_valid && candidate_selector == selector &&
              candidate_base == 24'h234567 && candidate_limit == 16'h0030 &&
              candidate_access == 8'h81 && candidate_descriptor_address == 24'h000128,
              "available GDT TSS produces a committed candidate");
        tick(1'b0);

        // LDT selector 000Ch -> offset 08h, busy TSS accepted for IRET.
        selector = 16'h000C; return_task = 1'b1; current_cpl = 2'd3;
        write_descriptor(32'h00000208, 24'h345678, 16'h002B, 8'hE3, 16'h0000);
        reset_dut(); start_request(); tick(1'b0); run_reads();
        check(complete && candidate_base == 24'h345678 && candidate_access == 8'hE3,
              "busy LDT TSS is accepted for task return");
        tick(1'b0);

        // A short image is rejected after descriptor fetch, before a candidate.
        selector = 16'h0028; return_task = 1'b0;
        write_descriptor(32'h00000128, 24'h234567, 16'h002A, 8'h81, 16'h0000);
        reset_dut(); start_request(); tick(1'b0); run_reads();
        check(fault && fault_vector == 8'd10 && fault_error_code == selector && !candidate_valid,
              "short TSS raises #TS");
        tick(1'b0);

        // Present=0 is #NP, and never becomes a candidate.
        write_descriptor(32'h00000128, 24'h234567, 16'h0030, 8'h01, 16'h0000);
        reset_dut(); start_request(); tick(1'b0); run_reads();
        check(fault && fault_vector == 8'd11 && fault_error_code == selector,
              "not-present TSS raises #NP");
        tick(1'b0);

        // A code descriptor is not a valid TSS target.
        write_descriptor(32'h00000128, 24'h234567, 16'h0030, 8'h9B, 16'h0000);
        reset_dut(); start_request(); tick(1'b0); run_reads();
        check(fault && fault_vector == 8'd10, "non-TSS descriptor raises #TS");
        tick(1'b0);

        // Reserved high words invalidate an otherwise well-formed TSS.
        write_descriptor(32'h00000128, 24'h234567, 16'h0030, 8'h81, 16'h0001);
        reset_dut(); start_request(); tick(1'b0); run_reads();
        check(fault && fault_vector == 8'd10, "reserved TSS form raises #TS");
        tick(1'b0);

        // DPL must dominate both CPL and selector RPL for direct transfers.
        enforce_dpl = 1'b1; current_cpl = 2'd2; selector = 16'h002B;
        write_descriptor(32'h00000128, 24'h234567, 16'h0030, 8'hA1, 16'h0000);
        reset_dut(); start_request(); run_reads();
        check(fault && fault_vector == 8'd10, "insufficient TSS DPL raises #TS");
        $display("TSS_DESCRIPTOR_SERVICE PASS: %0d checks", checks);
        $finish;
    end
endmodule
