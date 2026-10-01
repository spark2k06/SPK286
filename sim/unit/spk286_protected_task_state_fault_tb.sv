`timescale 1ns/1ps

// Integrated incoming-task image validation.  Incoming task-state faults are
// intentionally late: the TSS save/load effects are visible before the new
// LDTR/segment/IP validation reports the fault.
module spk286_protected_task_state_fault_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer cycles = 0;
    integer checks = 0;
    logic fault_request_reported = 1'b0;
    logic [7:0] first_fault_vector = 8'h00;
    logic [15:0] first_fault_error_code = 16'h0000;
    logic [15:0] case_es_selector = 16'h0008;
    logic [15:0] case_cs_selector = 16'h0028;
    logic [15:0] case_ss_selector = 16'h0008;
    logic [15:0] case_ds_selector = 16'h0008;
    logic [15:0] case_gdtr_limit = 16'h007F;
    logic [15:0] case_aux_limit = 16'hFFFF;
    logic [7:0] case_data_access = 8'h93;
    logic [7:0] case_aux_access = 8'h93;
    logic [15:0] case_aux_reserved_word = 16'h0000;

    spk286 dut (.*);

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "%s: CS=%h IP=%h TR=%h FLAGS=%h MSW=%h fault=%h err=%h bus=%h seg=%h expected=%h/%h/%h/%h",
                       message, debug_cs, debug_ip, debug_tr_selector, debug_flags,
                       debug_protected_msw, first_fault_vector, dut.fault_error_code, bus_status,
                       debug_segment_selectors, case_es_selector, case_cs_selector,
                       case_ss_selector, case_ds_selector);
        end
    endtask

    task automatic write_word(input integer address, input logic [15:0] value);
        begin
            memory[address] = value[7:0];
            memory[address + 1] = value[15:8];
        end
    endtask

    task automatic write_descriptor(
        input integer address,
        input logic [23:0] base,
        input logic [15:0] limit,
        input logic [7:0] access
    );
        begin
            write_word(address, limit);
            write_word(address + 2, base[15:0]);
            memory[address + 4] = base[23:16];
            memory[address + 5] = access;
            memory[address + 6] = 8'h00;
            memory[address + 7] = 8'h00;
        end
    endtask

    task automatic tick;
        begin
            #1;
            if (!fault_request_reported && dut.fault_request) begin
                fault_request_reported = 1'b1;
                first_fault_vector = dut.fault_vector;
                first_fault_error_code = dut.fault_error_code;
            end
            ready = bus_valid && ((cycles % 4) != 1);
            data_in = 16'h0000;
            if (bus_valid && !bus_write) begin
                if (bus_status == 4'h0) data_in = 16'h0022;
                else if (address[0]) data_in = {memory[address[15:0]], 8'h00};
                else if (bus_bhe_n) data_in = {8'h00, memory[address[15:0]]};
                else data_in = {memory[address[15:0] + 16'd1], memory[address[15:0]]};
            end
            if (bus_valid && ready && bus_write && bus_status == 4'h6) begin
                if (address[0]) memory[address[15:0]] = data_out[15:8];
                else begin
                    memory[address[15:0]] = data_out[7:0];
                    if (!bus_bhe_n) memory[address[15:0] + 16'd1] = data_out[15:8];
                end
            end
            #4; clk = 1'b1; #5; clk = 1'b0; #1;
            cycles = cycles + 1;
        end
    endtask

    task automatic far_restart(input logic [15:0] cs, input logic [15:0] ip);
        begin
            segment_load_en = 1'b1;
            segment_load_index = 2'd1;
            segment_load_selector = cs;
            ip_write_en = 1'b1;
            ip_write_data = ip;
            redirect = 1'b1;
            tick();
            segment_load_en = 1'b0;
            ip_write_en = 1'b0;
            redirect = 1'b0;
            tick();
        end
    endtask

    task automatic reset_cpu;
        begin
            reset = 1'b1;
            execute_enable = 1'b0;
            ready = 1'b0;
            repeat (8) tick();
            reset = 1'b0;
            execute_enable = 1'b1;
        end
    endtask

    task automatic reset_case;
        begin
            case_es_selector = 16'h0008;
            case_cs_selector = 16'h0028;
            case_ss_selector = 16'h0008;
            case_ds_selector = 16'h0008;
            case_gdtr_limit = 16'h007F;
            case_aux_limit = 16'hFFFF;
            case_data_access = 8'h93;
            case_aux_access = 8'h93;
            case_aux_reserved_word = 16'h0000;
        end
    endtask

    task automatic initialize_case(
        input logic [15:0] incoming_ip,
        input logic [15:0] code_limit,
        input logic [7:0] code_access,
        input logic [7:0] stack_access,
        input logic do_call
    );
        begin
            for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;

            // Real-mode setup: LGDT, LMSW and a protected-mode far jump.
            memory[16'h0000] = 8'h0F; memory[16'h0001] = 8'h01; memory[16'h0002] = 8'h16;
            memory[16'h0003] = 8'h00; memory[16'h0004] = 8'h03;
            memory[16'h0005] = 8'hB8; memory[16'h0006] = 8'h01; memory[16'h0007] = 8'h00;
            memory[16'h0008] = 8'h0F; memory[16'h0009] = 8'h01; memory[16'h000A] = 8'hF0;
            memory[16'h000B] = 8'hEA; memory[16'h000C] = 8'h00; memory[16'h000D] = 8'h01;
            memory[16'h000E] = 8'h10; memory[16'h000F] = 8'h00;

            // LTR current TSS, then direct far CALL/JMP to the target TSS.
            memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'h18; memory[16'h0102] = 8'h00;
            memory[16'h0103] = 8'h0F; memory[16'h0104] = 8'h00; memory[16'h0105] = 8'hD8;
            memory[16'h0106] = do_call ? 8'h9A : 8'hEA;
            memory[16'h0107] = 8'h00; memory[16'h0108] = 8'h00;
            memory[16'h0109] = 8'h20; memory[16'h010A] = 8'h00;

            // GDT at 2000h: bootstrap data/code, current TSS, target TSS,
            // then the parameterized incoming code and auxiliary descriptors.
            write_descriptor(32'h2000 + 32'd8 * 1, 24'h000000, 16'hFFFF, case_data_access);
            write_descriptor(32'h2000 + 32'd8 * 2, 24'h000000, 16'hFFFF, 8'h9A);
            write_descriptor(32'h2000 + 32'd8 * 3, 24'h004000, 16'h002B, 8'h81);
            write_descriptor(32'h2000 + 32'd8 * 4, 24'h005000, 16'h002B, 8'h81);
            write_descriptor(32'h2000 + 32'd8 * 5, 24'h000000, code_limit, code_access);
            write_descriptor(32'h2000 + 32'd8 * 6, 24'h000000, case_aux_limit, case_aux_access);
            write_word(32'h2000 + 32'd8 * 6 + 32'd6, case_aux_reserved_word);
            write_word(32'h0300, 16'h002F);
            memory[16'h0302] = 8'h00; memory[16'h0303] = 8'h20; memory[16'h0304] = 8'h00;
            write_word(32'h0300, case_gdtr_limit);

            // Incoming image is structurally valid except for the selected
            // fault condition.  ES/SS/DS use the GDT data descriptor.
            write_word(32'h5000 + 32'h000E, incoming_ip);
            write_word(32'h5000 + 32'h0010, 16'h0202);
            write_word(32'h5000 + 32'h0012, 16'hBEEF);
            write_word(32'h5000 + 32'h0022, case_es_selector); // ES
            write_word(32'h5000 + 32'h0024, case_cs_selector); // CS
            write_word(32'h5000 + 32'h0026, case_ss_selector); // SS selector
            write_word(32'h5000 + 32'h0028, case_ds_selector); // DS
            write_word(32'h5000 + 32'h002A, 16'h0000); // null LDTR
            // The stack descriptor is shared with ES/DS; rewrite its access
            // byte only for the non-writable-SS case.
            if (case_ss_selector[15:3] == 13'd1)
                memory[16'h200D] = stack_access;
        end
    endtask

    task automatic run_valid_case(input logic [7:0] code_access, input string message,
                                  input logic do_call);
        integer deadline;
        begin
            initialize_case(16'h0200, 16'hFFFF, code_access, case_data_access, do_call);
            cycles = 0;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            first_fault_error_code = 16'h0000;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            deadline = 0;
            while (!fault_request_reported &&
                   (debug_tr_selector != 16'h0020 ||
                    debug_segment_selectors[15:0] != case_es_selector ||
                    debug_segment_selectors[31:16] != case_cs_selector ||
                    debug_segment_selectors[47:32] != case_ss_selector ||
                    debug_segment_selectors[63:48] != case_ds_selector) &&
                   deadline < 2400) begin
                tick();
                deadline = deadline + 1;
            end
            check(!fault_request_reported && debug_tr_selector == 16'h0020, message);
            check(debug_cs == case_cs_selector && debug_segment_selectors[47:32] == case_ss_selector,
                  "valid incoming CPL matrix publishes CS and SS selectors");
            check(debug_segment_selectors[15:0] == case_es_selector &&
                  debug_segment_selectors[63:48] == case_ds_selector,
                  "valid incoming CPL matrix publishes ES and DS selectors");
            check(memory[16'h201D] == (do_call ? 8'h83 : 8'h81),
                  do_call ? "valid incoming task CALL keeps the outgoing TSS busy" :
                            "valid incoming task JMP frees the outgoing TSS");
            check(memory[16'h5000] == (do_call ? 8'h18 : 8'h00) &&
                  memory[16'h5001] == 8'h00,
                  do_call ? "valid incoming task CALL writes backlink" :
                            "valid incoming task JMP does not write backlink");
        end
    endtask

    task automatic run_fault_case(
        input logic [15:0] incoming_ip,
        input logic [15:0] code_limit,
        input logic [7:0] code_access,
        input logic [7:0] stack_access,
        input logic [7:0] expected_vector,
        input string message,
        input logic do_call
    );
        integer deadline;
        logic [15:0] expected_fault_code;
        begin
            initialize_case(incoming_ip, code_limit, code_access, stack_access, do_call);
            cycles = 0;
            fault_request_reported = 1'b0;
            first_fault_vector = 8'h00;
            first_fault_error_code = 16'h0000;
            reset_cpu();
            far_restart(16'h0000, 16'h0000);
            deadline = 0;
            while (!fault_request_reported && deadline < 2400) begin
                tick();
                deadline = deadline + 1;
            end
            check(fault_request_reported && first_fault_vector == expected_vector,
                  message);
            check(debug_tr_selector == 16'h0020 && debug_ip == incoming_ip &&
                  debug_gpr[15:0] == 16'hBEEF && debug_flags[14] == do_call,
                  "late incoming task fault publishes TSS registers and flags");
            // Intel SWITCH_TASKS publishes all visible selectors and invalidates
            // outgoing caches before validating LDTR, SS, CS and ES/DS.
            check(debug_cs == case_cs_selector &&
                  debug_segment_selectors == {case_ds_selector,case_ss_selector,case_cs_selector,case_es_selector},
                  "late incoming task fault retains incoming visible selectors");
            if (expected_vector == 8'h0D)
                check(dut.protected_segment_valid == 4'b1111,
                      "IP check follows all non-null segment cache loads");
            else if (case_ss_selector != 16'h0008 || stack_access != 8'h93)
                check(dut.protected_segment_valid == 4'b0000,
                      "invalid incoming SS retains no outgoing cache");
            else if (code_access != 8'h9A)
                check(dut.protected_segment_valid == 4'b0100,
                      "invalid incoming CS preserves only validated SS");
            else
                check(dut.protected_segment_valid == 4'b0110,
                      "invalid incoming ES preserves validated SS and CS");
            check({memory[16'h400F], memory[16'h400E]} == 16'h010B,
                  "late incoming task fault saves the outgoing IP");
            check(memory[16'h2025] == 8'h83 &&
                  memory[16'h201D] == (do_call ? 8'h83 : 8'h81) &&
                  memory[16'h5000] == (do_call ? 8'h18 : 8'h00) &&
                  memory[16'h5001] == 8'h00,
                  "late incoming task fault preserves CALL/JMP BUSY and backlink effects");
            if (expected_vector == 8'h0D)
                expected_fault_code = 16'h0000;
            else if (case_es_selector != case_ss_selector)
                expected_fault_code = case_es_selector & 16'hFFFC;
            else if (case_ss_selector != 16'h0008 || stack_access != 8'h93)
                expected_fault_code = case_ss_selector & 16'hFFFC;
            else
                expected_fault_code = case_cs_selector & 16'hFFFC;
            check(first_fault_error_code == expected_fault_code,
                  "late task fault carries the architectural error-code form");
        end
    endtask

    task automatic run_valid_pair(input logic [7:0] code_access, input string message);
        begin
            run_valid_case(code_access, message, 1'b1);
            run_valid_case(code_access, message, 1'b0);
        end
    endtask

    task automatic run_fault_pair(
        input logic [15:0] incoming_ip,
        input logic [15:0] code_limit,
        input logic [7:0] code_access,
        input logic [7:0] stack_access,
        input logic [7:0] expected_vector,
        input string message
    );
        begin
            run_fault_case(incoming_ip, code_limit, code_access, stack_access,
                           expected_vector, message, 1'b1);
            run_fault_case(incoming_ip, code_limit, code_access, stack_access,
                           expected_vector, message, 1'b0);
        end
    endtask

    initial begin
        reset_case();

        // The fixed TSS path accepts a complete incoming segment image at
        // each architectural CPL when CS/SS and the data descriptors agree.
        for (integer level = 0; level < 4; level = level + 1) begin
            reset_case();
            case_cs_selector = 16'h0028 + (16'(level));
            case_ss_selector = 16'h0008 + (16'(level));
            case_es_selector = case_ss_selector;
            case_ds_selector = case_ss_selector;
            case_data_access = 8'h93 | (8'(level) << 5);
            run_valid_pair(8'h9A | (8'(level) << 5),
                           "incoming task CPL0-CPL3 segment image is accepted");
        end

        // ES and DS may be null, while CS and SS remain mandatory.
        reset_case();
        case_es_selector = 16'h0000;
        case_ds_selector = 16'h0000;
        run_valid_pair(8'h9A, "incoming task accepts null ES and DS");

        // Readable code is legal in ES/DS as data; non-readable code is not.
        reset_case();
        case_es_selector = 16'h0030;
        case_aux_access = 8'h9A;
        run_valid_pair(8'h9A, "incoming task accepts readable code as ES");
        reset_case();
        case_es_selector = 16'h0030;
        case_aux_access = 8'h98;
        run_fault_pair(16'h0200, 16'hFFFF, 8'h9A, 8'h93, 8'h0A,
                       "incoming task rejects non-readable code as ES");

            // A valid descriptor with IP beyond CS.limit is a late #GP(0).
            reset_case();
        run_fault_pair(16'h0200, 16'h01FF, 8'h9A, 8'h93, 8'h0D,
                       "incoming task IP beyond CS limit raises #GP(0)");

        // CS presence and type remain task-segment faults before IP use.
        reset_case();
        run_fault_pair(16'h0200, 16'hFFFF, 8'h1A, 8'h93, 8'h0B,
                       "incoming task not-present CS raises #NP");
        reset_case();
        run_fault_pair(16'h0200, 16'hFFFF, 8'h93, 8'h93, 8'h0A,
                       "incoming task data CS raises #TS");
        reset_case();
        run_fault_pair(16'h0200, 16'hFFFF, 8'hFA, 8'h93, 8'h0A,
                       "incoming task CS DPL mismatch raises #TS");

        // SS must be a present writable data segment at the new CPL.
        reset_case();
        run_fault_pair(16'h0200, 16'hFFFF, 8'h9A, 8'h91, 8'h0A,
                       "incoming task non-writable SS raises #TS");
        reset_case();
        case_ss_selector = 16'h000B;
        run_fault_pair(16'h0200, 16'hFFFF, 8'h9A, 8'h93, 8'h0A,
                       "incoming task SS RPL mismatch raises #TS");
        reset_case();
        case_es_selector = 16'h0030;
        case_aux_access = 8'h13;
        run_fault_pair(16'h0200, 16'hFFFF, 8'h9A, 8'h93, 8'h0B,
                       "incoming task not-present ES raises #NP");
        reset_case();
        case_es_selector = 16'h0030;
        case_gdtr_limit = 16'h002F;
        run_fault_pair(16'h0200, 16'hFFFF, 8'h9A, 8'h93, 8'h0A,
                       "incoming task selector beyond GDT limit raises #TS");
        reset_case();
        case_es_selector = 16'h0030;
        case_aux_reserved_word = 16'h0001;
        // Intel 386 PRM 13.3.2 documents that 286 programs may use the
        // final descriptor word; it is not a 286 segment-validation fault.
        run_valid_pair(8'h9A, "incoming task accepts data descriptor with nonzero upper word");
        reset_case();
        case_es_selector = 16'h000C;
        run_fault_pair(16'h0200, 16'hFFFF, 8'h9A, 8'h93, 8'h0A,
                       "incoming task LDT selector without LDTR raises #TS");
        reset_case();
        case_es_selector = 16'h0009;
        run_fault_pair(16'h0200, 16'hFFFF, 8'h9A, 8'h93, 8'h0A,
                       "incoming task data RPL above DPL raises #TS");

        $display("PROTECTED_TASK_STATE_FAULT PASS: %0d checks, cases=36 (CALL/JMP)", checks);
        $finish;
    end
endmodule
