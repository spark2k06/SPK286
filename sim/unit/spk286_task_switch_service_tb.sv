`timescale 1ns/1ps

module spk286_task_switch_service_tb;
    logic clk = 1'b0, reset = 1'b1, cancel = 1'b0, start = 1'b0;
    logic nested_call = 1'b1, jump_task = 1'b0, return_task = 1'b0;
    logic state_loaded = 1'b1;
    wire cache_commit;
    wire [1:0] cache_commit_index;
    logic [15:0] target_selector = 16'h0028, target_limit = 16'h002B;
    logic [23:0] target_base = 24'h002000, target_descriptor_address = 24'h000030;
    logic [7:0] target_access = 8'h81;
    logic [15:0] current_selector = 16'h0018, current_limit = 16'h002B;
    logic [23:0] current_base = 24'h001000, current_descriptor_address = 24'h000020;
    logic [7:0] current_access = 8'h83;
    logic [15:0] current_ip = 16'h1234, current_flags = 16'h0202, current_ldtr = 16'h0040;
    logic [127:0] current_gpr = 128'h887766554433221100FFEEDDCCBBAA99;
    logic [63:0] current_segments = 64'h0048003800280018;
    logic [15:0] gdtr_limit = 16'h007F; logic [23:0] gdtr_base = 24'h000100;
    logic memory_done = 1'b0; logic [15:0] memory_read_data = 16'h0;
    wire memory_request, memory_write, memory_byte, memory_lock, commit_ready, busy, complete, fault, commit_valid;
    wire [23:0] memory_address; wire [15:0] memory_write_data;
    wire [7:0] fault_vector; wire [15:0] fault_error_code;
    wire [15:0] loaded_ip, loaded_flags, loaded_ldtr, loaded_backlink, loaded_tr_selector, loaded_tr_limit;
    wire [23:0] loaded_ldtr_base; wire [15:0] loaded_ldtr_limit; wire [7:0] loaded_ldtr_access;
    wire [3:0] loaded_ldtr_class; wire loaded_ldtr_valid, loaded_ldtr_present;
    wire [23:0] loaded_tr_base; wire [7:0] loaded_tr_access;
    wire [127:0] loaded_gpr; wire [63:0] loaded_segments;
    wire [63:0] cache_selectors, cache_limits; wire [95:0] cache_bases;
    wire [31:0] cache_access; wire [15:0] cache_classes;
    wire [3:0] cache_present, cache_protected, cache_tables; wire [7:0] cache_dpl, cache_rpl;
    logic [7:0] memory [0:65535]; integer checks = 0; integer image_address; integer wait_deadline; logic [15:0] image_value;
    integer gdt_zero_reads=0;

    spk286_task_switch_service dut (.*);

    task automatic check(input logic condition, input string message);
        begin checks = checks + 1; if (condition !== 1'b1) $fatal(1, "%s", message); end
    endtask
    task automatic write_word(input integer address, input logic [15:0] data);
        begin memory[address] = data[7:0]; memory[address + 1] = data[15:8]; end
    endtask
    task automatic write_descriptor(input integer address, input logic [23:0] base,
                                    input logic [15:0] limit, input logic [7:0] access);
        logic [63:0] raw;
        begin raw = 64'h0; raw[15:0] = limit; raw[31:16] = base[15:0]; raw[39:32] = base[23:16]; raw[47:40] = access;
            write_word(address, raw[15:0]); write_word(address+2, raw[31:16]);
            write_word(address+4, raw[47:32]); write_word(address+6, raw[63:48]); end
    endtask
    task automatic tick(input logic respond);
        begin #1; memory_done = 1'b0;
            if (respond && memory_request) begin
                if (memory_write) begin
                    memory[memory_address[15:0]] = memory_write_data[7:0];
                    if (!memory_byte) memory[memory_address[15:0]+1] = memory_write_data[15:8];
                end else begin
                    memory_read_data = {memory[memory_address[15:0]+1], memory[memory_address[15:0]]};
                    if (memory_address>=24'h100 && memory_address<24'h108) gdt_zero_reads++;
                end
                memory_done = 1'b1;
            end
            #1; clk = 1'b1; #1; clk = 1'b0; #1; memory_done = 1'b0; end
    endtask
    task automatic run_to_end;
        integer deadline;
        begin deadline = 0; while (!complete && !fault && deadline < 500) begin tick(1'b1); deadline = deadline+1; end
            check((complete || fault) && !busy, "task switch terminates"); end
    endtask

    task automatic initialize_ldtr_case(
        input logic [15:0] case_ldtr_selector,
        input logic [15:0] case_gdtr_limit,
        input logic [23:0] case_ldtr_base,
        input logic [15:0] case_ldtr_limit,
        input logic [7:0] case_ldtr_access,
        input logic [15:0] case_ldtr_reserved_word
    );
        integer descriptor_address;
        begin
            for (integer i=0; i<65536; i=i+1) memory[i]=8'h00;
            gdt_zero_reads=0;
            gdtr_limit = case_gdtr_limit;
            memory[16'h0025] = current_access;
            memory[16'h0035] = target_access;

            // Current/target TSS descriptors and the incoming segment image.
            write_descriptor(32'h00000118, 24'h110000, 16'hFFFF, 8'h92);
            write_descriptor(32'h00000128, 24'h220000, 16'hFFFF, 8'h9A);
            write_descriptor(32'h00000138, 24'h330000, 16'hFFFF, 8'h92);
            write_descriptor(32'h00000148, 24'h440000, 16'hFFFF, 8'h92);

            // Add the candidate descriptor only when the selector would pass
            // the table-address precheck.  TI=1 and over-limit selectors must
            // fault without reading a descriptor.
            if (!case_ldtr_selector[2] && case_ldtr_selector[15:3] != 13'd0 &&
                ({1'b0, case_ldtr_selector[15:3], 3'b000} + 17'd7 <=
                 {1'b0, case_gdtr_limit})) begin
                descriptor_address = 32'h00000100 + ({19'd0, case_ldtr_selector[15:3]} << 3);
                write_descriptor(descriptor_address, case_ldtr_base, case_ldtr_limit,
                                 case_ldtr_access);
                write_word(descriptor_address + 6, case_ldtr_reserved_word);
            end

            for (integer i=0; i<15; i=i+1) begin
                image_address=32'h0000200E+i*2;
                case (i)
                    1: image_value = 16'h0202;
                    10: image_value = 16'h0018;
                    11: image_value = 16'h0028;
                    12: image_value = 16'h0038;
                    13: image_value = 16'h0048;
                    14: image_value = case_ldtr_selector;
                    default: image_value = 16'hA000 + 16'(i);
                endcase
                write_word(image_address, image_value);
            end
        end
    endtask

    task automatic run_ldtr_case(
        input logic [15:0] case_ldtr_selector,
        input logic [15:0] case_gdtr_limit,
        input logic [23:0] case_ldtr_base,
        input logic [15:0] case_ldtr_limit,
        input logic [7:0] case_ldtr_access,
        input logic [15:0] case_ldtr_reserved_word,
        input logic [7:0] expected_fault_vector,
        input string message
    );
        begin
            initialize_ldtr_case(case_ldtr_selector, case_gdtr_limit, case_ldtr_base,
                                 case_ldtr_limit, case_ldtr_access, case_ldtr_reserved_word);
            reset=1'b1; start=1'b0; tick(1'b0);
            reset=1'b0; start=1'b1; tick(1'b0); start=1'b0;
            run_to_end();
            if (expected_fault_vector == 8'h00) begin
                if (case_ldtr_selector[15:2] == 14'd0)
                    check(complete && commit_valid && loaded_ldtr == case_ldtr_selector &&
                          loaded_ldtr_base == 24'h000000 && loaded_ldtr_limit == 16'h0000 &&
                          loaded_ldtr_class == 4'd0 && !loaded_ldtr_valid && !loaded_ldtr_present,
                          message);
                else
                    check(complete && commit_valid && loaded_ldtr == case_ldtr_selector &&
                          loaded_ldtr_base == case_ldtr_base && loaded_ldtr_limit == case_ldtr_limit &&
                          loaded_ldtr_class == 4'd10 && loaded_ldtr_valid && loaded_ldtr_present,
                          message);
                check(memory[16'h100E]==8'h34 && memory[16'h0035]==8'h83,
                      "valid incoming LDTR commits only after TSS save and target busy update");
            end else begin
                check(fault && fault_vector == expected_fault_vector &&
                      fault_error_code == (case_ldtr_selector & 16'hFFFC) &&
                      memory[16'h100E]==8'h34 && memory[16'h0035]==8'h83,
                      message);
            end
            if (case_ldtr_selector<8) check(gdt_zero_reads==0,"null or TI LDTR does not fetch GDT entry zero");
        end
    endtask

    initial begin
        for (integer i=0; i<65536; i=i+1) memory[i]=8'h00;
        write_descriptor(32'h00000118, 24'h110000, 16'hFFFF, 8'h92);
        // The synthetic incoming IP is A000; keep the valid CS image within
        // its architectural limit now that the composite validates IP:CS.
        write_descriptor(32'h00000128, 24'h220000, 16'hFFFF, 8'h9A);
        write_descriptor(32'h00000138, 24'h330000, 16'hFFFF, 8'h92);
        write_descriptor(32'h00000148, 24'h440000, 16'hFFFF, 8'h92);
        for (integer i=0; i<15; i=i+1) begin
            image_address=32'h0000200E+i*2;
            case (i)
                1: image_value = 16'h0202;
                10: image_value = 16'h0018;
                11: image_value = 16'h0028;
                12: image_value = 16'h0038;
                13: image_value = 16'h0048;
                14: image_value = 16'h0000;
                default: image_value = 16'hA000 + 16'(i);
            endcase
            write_word(image_address, image_value);
        end
        reset=1'b1; tick(1'b0); reset=1'b0; start=1'b1; tick(1'b0); start=1'b0;
        wait_deadline = 0;
        while (!memory_request && wait_deadline < 10) begin tick(1'b0); wait_deadline = wait_deadline + 1; end
        check(memory_request && memory_write && memory_lock && memory_address==24'h000035,
                          "task switch locks and sets target BUSY before saving the current task");
        tick(1'b0); check(memory_request && memory_address==24'h000035,
                          "BUSY update holds under READY");
        state_loaded=0;
        wait_deadline=0;
        while (!commit_ready && wait_deadline<300) begin tick(1'b1); wait_deadline++; end
        check(commit_ready,"loaded TSS requests architectural publication");
        tick(1'b0);
        repeat (16) begin
            check(busy && !memory_request && !complete && !fault && !cache_commit,
                  "late validation waits for published task state without bus activity");
            tick(1'b0);
        end
        state_loaded=1;
        run_to_end();
        check(complete && commit_valid && loaded_ip==16'hA000 && loaded_flags==16'h4202,
              "nested task image is loaded with NT");
        check(loaded_gpr[15:0]==16'hA002 && loaded_segments==64'h0048003800280018 && loaded_ldtr==16'h0000,
              "incoming registers, segments and LDT are loaded");
        check(memory[16'h100E]==8'h34 && memory[16'h1010]==8'h02 &&
              memory[16'h2000]==8'h18 && memory[16'h0035]==8'h83,
              "outgoing state, backlink and target busy write are ordered");
        check(cache_bases[23:0]==24'h110000 && cache_bases[47:24]==24'h220000 &&
              cache_bases[71:48]==24'h330000 && cache_bases[95:72]==24'h440000,
              "validated hidden caches accompany the task commit");
        tick(1'b0);

        // An invalid non-null incoming LDTR faults after the architectural
        // save/load sequence, in the incoming task context.
        write_word(32'h00002000 + 32'h0000002A, 16'h0040);
        reset=1'b1; tick(1'b0); reset=1'b0; start=1'b1; tick(1'b0); start=1'b0; run_to_end();
        check(fault && fault_vector==8'd10 && fault_error_code==16'h0040 &&
              memory[16'h100E]==8'h34 && memory[16'h0035]==8'h83,
              "non-null incoming LDTR faults after TSS save and busy update");
        write_word(32'h00002000 + 32'h0000002A, 16'h0000);

        // An invalid incoming CS must fail after the current TSS is changed.
        write_word(32'h00002000 + 32'h00000024, 16'h0018);
        reset=1'b1; tick(1'b0); reset=1'b0; start=1'b1; tick(1'b0); start=1'b0; run_to_end();
        check(fault && fault_vector==8'd10 && memory[16'h100E]==8'h34 && memory[16'h0035]==8'h83,
              "invalid incoming CS faults after TSS save and busy update");

        // PM5u: exhaustive incoming LDTR selector/descriptor classification.
        // Null and the exact last-descriptor boundary are valid; table,
        // selector, type, presence and reserved-form failures are atomic.
        run_ldtr_case(16'h0000, 16'h007F, 24'h000000, 16'h0000, 8'h00, 16'h0000,
                      8'h00, "null incoming LDTR clears the hidden cache");
        for (integer rpl=1;rpl<4;rpl++)
            run_ldtr_case(16'(rpl), 16'h007F, 0, 0, 0, 0, 0,
                          "null LDTR accepts nonzero RPL and preserves visible selector");
        for (integer rpl=0;rpl<4;rpl++)
            run_ldtr_case(16'(4+rpl), 16'h007F, 0, 0, 0, 0, 8'd10,
                          "TI LDTR rejects entry zero with normalized #TS error");
        for (integer rpl=1;rpl<4;rpl++) begin
            run_ldtr_case(16'('h40+rpl), 16'h007F, 24'h660000, 16'h001F, 8'h82, 0, 0,
                          "valid non-null LDT preserves RPL without a privilege check");
            run_ldtr_case(16'('h40+rpl), 16'h007F, 0, 16'h001F, 8'h02, 0, 8'd10,
                          "absent non-null LDT error clears selector RPL");
        end
        run_ldtr_case(16'h0040, 16'h007F, 24'h660000, 16'h001F, 8'h82, 16'h0000,
                      8'h00, "present LDT descriptor loads the incoming LDTR cache");
        run_ldtr_case(16'h0078, 16'h007F, 24'h770000, 16'h002B, 8'h82, 16'h0000,
                      8'h00, "incoming LDTR accepts the exact GDTR limit boundary");
        // Start another switch without resetting the service: the previous
        // LDT metadata must not remain usable during a failing new load.
        tick(1'b0);
        write_word(32'h202A, 16'h0044);
        start=1'b1; tick(1'b0); start=1'b0;
        check(!loaded_ldtr_valid && !loaded_ldtr_present && loaded_ldtr_base == 0 && loaded_ldtr_limit == 0,
              "next task invalidates stale incoming LDT metadata before validation");
        run_to_end();
        check(fault && fault_vector == 8'd10 && !loaded_ldtr_valid,
              "invalid next LDTR cannot retain the previous task's valid cache");
        run_ldtr_case(16'h0080, 16'h007F, 24'h000000, 16'h001F, 8'h82, 16'h0000,
                      8'd10, "incoming LDTR selector beyond GDTR limit raises #TS");
        run_ldtr_case(16'h0044, 16'h007F, 24'h000000, 16'h001F, 8'h82, 16'h0000,
                      8'd10, "incoming LDTR selector with TI set raises #TS");
        run_ldtr_case(16'h0040, 16'h007F, 24'h000000, 16'hFFFF, 8'h92, 16'h0000,
                      8'd10, "incoming data descriptor type raises #TS");
        run_ldtr_case(16'h0040, 16'h007F, 24'h000000, 16'h0000, 8'h81, 16'h0000,
                      8'd10, "incoming available-TSS descriptor type raises #TS");
        run_ldtr_case(16'h0040, 16'h007F, 24'h000000, 16'h0000, 8'h83, 16'h0000,
                      8'd10, "incoming busy-TSS descriptor type raises #TS");
        run_ldtr_case(16'h0040, 16'h007F, 24'h000000, 16'h0000, 8'h84, 16'h0000,
                      8'd10, "incoming call-gate descriptor type raises #TS");
        run_ldtr_case(16'h0040, 16'h007F, 24'h000000, 16'h0000, 8'h85, 16'h0000,
                      8'd10, "incoming task-gate descriptor type raises #TS");
        run_ldtr_case(16'h0040, 16'h007F, 24'h000000, 16'h0000, 8'h86, 16'h0000,
                      8'd10, "incoming interrupt-gate descriptor type raises #TS");
        run_ldtr_case(16'h0040, 16'h007F, 24'h000000, 16'h0000, 8'h87, 16'h0000,
                      8'd10, "incoming trap-gate descriptor type raises #TS");
        run_ldtr_case(16'h0040, 16'h007F, 24'h000000, 16'h001F, 8'h02, 16'h0000,
                      8'd10, "incoming not-present LDT descriptor raises #TS");
        run_ldtr_case(16'h0040, 16'h007F, 24'h000000, 16'h001F, 8'h82, 16'h0001,
                      8'd10, "incoming LDT reserved form raises #TS");

        $display("TASK_SWITCH_SERVICE PASS: %0d checks", checks); $finish;
    end
endmodule
