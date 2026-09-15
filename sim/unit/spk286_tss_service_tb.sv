`timescale 1ns/1ps

module spk286_tss_service_tb;
    logic clk = 1'b0, reset = 1'b1, cancel = 1'b0, start = 1'b0;
    logic nested_call = 1'b0, jump_task = 1'b0, return_task = 1'b0;
    logic [15:0] target_selector = 16'h0028, target_limit = 16'h002B;
    logic [23:0] target_base = 24'h002000, target_descriptor_address = 24'h000030;
    logic [7:0] target_access = 8'h81;
    logic [15:0] current_selector = 16'h0018, current_limit = 16'h002B;
    logic [23:0] current_base = 24'h001000, current_descriptor_address = 24'h000020;
    logic [7:0] current_access = 8'h83;
    logic [15:0] current_ip = 16'h1234, current_flags = 16'h0202, current_ldtr = 16'h0040;
    logic [127:0] current_gpr = 128'h887766554433221100FFEEDDCCBBAA99;
    logic [63:0] current_segments = 64'h0061005900510049;
    logic memory_done = 1'b0;
    logic [15:0] memory_read_data = 16'h0000;
    wire memory_request, memory_write, memory_byte, memory_lock, busy, complete, fault, commit_valid;
    wire [23:0] memory_address, descriptor_update_address;
    wire [15:0] memory_write_data, fault_error_code, loaded_ip, loaded_flags, loaded_backlink;
    wire [127:0] loaded_gpr;
    wire [63:0] loaded_segments;
    wire [15:0] loaded_ldtr, loaded_tr_selector, loaded_tr_limit;
    wire [23:0] loaded_tr_base;
    wire [7:0] fault_vector, descriptor_update_data, loaded_tr_access;
    wire descriptor_update;
    logic [7:0] memory [0:65535];
    integer checks = 0;
    integer image_word;
    integer image_address;

    spk286_tss_service dut (.*);

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) $fatal(1, "%s", message);
        end
    endtask

    task automatic tick;
        begin
            #1;
            memory_done = 1'b0;
            if (memory_request) begin
                if (memory_write) begin
                    if (memory_byte) memory[memory_address[15:0]] = memory_write_data[7:0];
                    else begin
                        memory[memory_address[15:0]] = memory_write_data[7:0];
                        memory[memory_address[15:0] + 16'd1] = memory_write_data[15:8];
                    end
                end else begin
                    memory_read_data = {memory[memory_address[15:0] + 16'd1], memory[memory_address[15:0]]};
                end
                memory_done = 1'b1;
            end
            #1; clk = 1'b1; #1; clk = 1'b0; #1;
            memory_done = 1'b0;
        end
    endtask

    task automatic run_to_complete;
        integer deadline;
        begin
            deadline = 0;
            while (!complete && !fault && deadline < 100) begin
                tick();
                deadline = deadline + 1;
            end
            check(complete && !fault, "task image completes without fault");
        end
    endtask

    initial begin
        for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;
        // Independent fixed-layout checks against the Intel 80286 TSS table.
        // Keep these literals separate from the service's address generation so
        // a shared symbolic offset cannot make the test self-consistent only.
        check(spk286_tss_pkg::TSS_WORD_COUNT == 22, "80286 TSS has 22 words");
        check(spk286_tss_pkg::TSS_MIN_LIMIT == 16'h002B, "80286 TSS minimum limit is 002B");
        check(spk286_tss_pkg::TSS_BACKLINK == 16'h0000, "TSS backlink offset is 00h");
        check(spk286_tss_pkg::TSS_SP0 == 16'h0002, "TSS SP0 offset is 02h");
        check(spk286_tss_pkg::TSS_SS0 == 16'h0004, "TSS SS0 offset is 04h");
        check(spk286_tss_pkg::TSS_SP1 == 16'h0006, "TSS SP1 offset is 06h");
        check(spk286_tss_pkg::TSS_SS1 == 16'h0008, "TSS SS1 offset is 08h");
        check(spk286_tss_pkg::TSS_SP2 == 16'h000A, "TSS SP2 offset is 0Ah");
        check(spk286_tss_pkg::TSS_SS2 == 16'h000C, "TSS SS2 offset is 0Ch");
        check(spk286_tss_pkg::TSS_IP == 16'h000E, "TSS IP offset is 0Eh");
        check(spk286_tss_pkg::TSS_FLAGS == 16'h0010, "TSS FLAGS offset is 10h");
        check(spk286_tss_pkg::TSS_AX == 16'h0012, "TSS AX offset is 12h");
        check(spk286_tss_pkg::TSS_CX == 16'h0014, "TSS CX offset is 14h");
        check(spk286_tss_pkg::TSS_DX == 16'h0016, "TSS DX offset is 16h");
        check(spk286_tss_pkg::TSS_BX == 16'h0018, "TSS BX offset is 18h");
        check(spk286_tss_pkg::TSS_SP == 16'h001A, "TSS SP offset is 1Ah");
        check(spk286_tss_pkg::TSS_BP == 16'h001C, "TSS BP offset is 1Ch");
        check(spk286_tss_pkg::TSS_SI == 16'h001E, "TSS SI offset is 1Eh");
        check(spk286_tss_pkg::TSS_DI == 16'h0020, "TSS DI offset is 20h");
        check(spk286_tss_pkg::TSS_ES == 16'h0022, "TSS ES offset is 22h");
        check(spk286_tss_pkg::TSS_CS == 16'h0024, "TSS CS offset is 24h");
        check(spk286_tss_pkg::TSS_SS == 16'h0026, "TSS SS offset is 26h");
        check(spk286_tss_pkg::TSS_DS == 16'h0028, "TSS DS offset is 28h");
        check(spk286_tss_pkg::TSS_LDT == 16'h002A, "TSS LDT offset is 2Ah");
        check(spk286_tss_pkg::TSS_LDT + 16'd2 == spk286_tss_pkg::TSS_MIN_LIMIT + 16'd1,
              "TSS LDT end matches the 2Ch fixed image size");
        // Target task image: IP, FLAGS, AX..DI, ES/CS/SS/DS, LDT.
        for (integer i = 0; i < 15; i = i + 1) begin
            image_word = 32'h0000A000 + i;
            image_address = 32'h0000200E + i*2;
            memory[image_address] = image_word[7:0];
            memory[image_address + 1] = image_word[15:8];
        end
        reset = 1'b1; tick(); reset = 1'b0;
        nested_call = 1'b1; start = 1'b1; tick(); start = 1'b0;
        run_to_complete();
        check(memory[16'h100E] == 8'h34 && memory[16'h100F] == 8'h12, "outgoing IP saved at 0E");
        check(memory[16'h1010] == 8'h02 && memory[16'h1011] == 8'h02, "outgoing FLAGS saved at 10");
        check(memory[16'h1012] == 8'h99 && memory[16'h1013] == 8'hAA, "outgoing AX saved at 12");
        check(memory[16'h102A] == 8'h40 && memory[16'h102B] == 8'h00, "outgoing LDT saved at 2A");
        check(memory[16'h2000] == 8'h18 && memory[16'h2001] == 8'h00, "nested backlink saved in target TSS");
        check(memory[16'h0035] == 8'h83, "target TSS busy bit set");
        check(loaded_ip == 16'hA000 && loaded_flags == 16'hE001, "target state loaded with nested NT");
        check(loaded_gpr[15:0] == 16'hA002 && loaded_gpr[112 +: 16] == 16'hA009, "target GPR image loaded");
        check(loaded_segments[15:0] == 16'hA00A && loaded_segments[48 +: 16] == 16'hA00D, "target segment image loaded");
        check(loaded_ldtr == 16'hA00E && loaded_tr_selector == target_selector && loaded_tr_base == target_base,
              "target TR candidate returned");
        check(loaded_tr_access == 8'h83 && commit_valid, "commit pulse exposes busy TR candidate");
        tick();

        // A JMP task transfer preserves the NT value supplied by the target
        // TSS.  This is the compatibility behavior required by the original
        // Supersoft two-task loop; unlike CALL, JMP does not synthesize NT.
        memory[16'h2010] = 8'h01;
        memory[16'h2011] = 8'h40;
        target_limit = 16'h002B; nested_call = 1'b0; jump_task = 1'b1;
        start = 1'b1; tick(); start = 1'b0;
        run_to_complete();
        check(loaded_flags == 16'h4001, "JMP task image preserves incoming NT");
        tick();

        // A short TSS is rejected before the first physical transaction.
        target_limit = 16'h002A; nested_call = 1'b0; jump_task = 1'b1; start = 1'b1; tick(); start = 1'b0;
        check(fault && fault_vector == 8'd10 && fault_error_code == target_selector && !memory_request,
              "short target TSS raises #TS before memory access");
        $display("TSS_SERVICE PASS: %0d checks", checks);
        $finish;
    end
endmodule
