`timescale 1ns/1ps

// Intel 80286 PRM 10.2.2, tables 10-1/10-2 and #NM B-2:
// ESC traps on EM || TS; WAIT traps on MP && TS, independent of PE/CPL.
// BUSY is inactive in the standalone no-NPX profile. No 80287 is modeled.
module spk286_npx_traps_tb;
    `include "spk286_npx_fixture.svh"

    task automatic run_case(input logic pe, input logic [1:0] cpl,
                            input logic [2:0] bits, input logic [7:0] op,
                            input integer form, input integer prefix_kind,
                            input logic [1:0] policy);
        integer deadline, length;
        logic expected_fault;
        string label;
        expected_fault = op == 8'h9B ? bits[2] && bits[0] : bits[2] || bits[1];
        label = $sformatf("PE=%b CPL=%d TS/EM/MP=%b opcode=%h form=%d prefix=%d policy=%d",
                          pe,cpl,bits,op,form,prefix_kind,policy);
        setup(pe,cpl,bits,op,form,prefix_kind,policy,length);
        deadline = 0;
        while (!event_completed && subject_retired == 0 && !unsupported_opcode &&
               !shutdown && deadline < 1200) begin tick(); deadline++; end
        check(!unsupported_opcode && !microcode_fault && !shutdown && deadline < 1200,
              {label," instruction completes or delivers #NM"});
        check(subject_reads == 0 && subject_writes == 0 && io_cycles == 0,
              {label," subject performs no operand or port access"});
        if (expected_fault) begin
            check(first_fault && first_vector == 7 && !first_error_valid &&
                  events_seen == 1 && debug_event_kind == 1 &&
                  debug_event_vector == 7 && !debug_event_error_valid,
                  {label," #NM has no error word"});
            check(subject_retired == 0 && fault_ip == 'h100 && fault_cs == caller_cs &&
                  fault_sp == 'h2000 && fault_flags == original_flags &&
                  fault_gpr == original_gpr && fault_selectors == original_selectors &&
                  fault_stream_ip == 16'('h101+prefix_kind),
                  {label," fault preserves source state and first prefix IP"});
            check(debug_cs == caller_cs && debug_ip == 'h300 && debug_gpr == original_gpr -
                  (128'h6 << 64) && debug_gpr[79:64] == 'h1FFA && frame_writes == 3 &&
                  read_word('h1FFA) == 'h100 && read_word('h1FFC) == caller_cs &&
                  read_word('h1FFE) == original_flags && read_word('h1FF8) == 'hA5A5,
                  {label," real handler frame contains only IP/CS/FLAGS"});
        end else begin
            check(!first_fault && events_seen == 0 && subject_retired == 1 &&
                  debug_ip == 16'('h100+length) && debug_gpr == original_gpr &&
                  debug_flags == original_flags && debug_segment_selectors == original_selectors,
                  {label," no-NPX instruction retires once with exact length and unchanged state"});
        end
        execute_enable = 0; observe = 0; cases++;
        if (cases % 1000 == 0) $display("NPX_TRAPS progress: %0d cases",cases);
    endtask

    task automatic recovery(input logic pe, input logic [7:0] op, input logic emulate,
                            input integer prefix_kind, input logic [1:0] policy);
        integer deadline, length;
        // Retry must target a valid memory pointer after CLTS clears TS.
        // Invalid-pointer priority is exercised separately by the truth matrix.
        setup(pe,0,emulate ? 3'b010 : (op == 8'h9B ? 3'b101 : 3'b100),op,3,prefix_kind,policy,length);
        if (emulate) begin
            // MOV BP,SP; ADD word [BP],instruction_length; IRET.
            // Only the saved IP is changed, as an emulation handler would do.
            memory['h300] = 8'h89; memory['h301] = 8'hE5;
            memory['h302] = 8'h83; memory['h303] = 8'h46;
            memory['h304] = 0; memory['h305] = 8'(length); memory['h306] = 8'hCF;
        end else begin
            memory['h300] = 8'h0F; memory['h301] = 8'h06; memory['h302] = 8'hCF;
        end
        deadline = 0;
        while (!(instruction_retired && debug_gpr[15:0] == 'hBEEF) &&
               !shutdown && !unsupported_opcode && deadline < 2000) begin tick(); deadline++; end
        check(deadline < 2000 && !shutdown && !unsupported_opcode && !microcode_fault &&
              events_seen == 1 && first_fault && first_vector == 7 && !first_error_valid,
              "recovery uses one #NM and reaches the follow-on instruction");
        check(subject_reads == 0 && subject_writes == 0 && io_cycles == 0 &&
              fault_ip == 'h100 && fault_gpr == original_gpr && fault_flags == original_flags,
              "recovery fault is restartable and does not access an operand");
        check(debug_gpr[79:64] == 'h2000 && debug_flags == original_flags &&
              debug_ip == 16'('h100+length+3) &&
              subject_retired == (emulate ? 0 : 1),
              "CLTS retries once; emulation advances the saved IP instead");
        check(debug_protected_msw[3:0] == (emulate ? (pe ? 4'h5 : 4'h4) :
              (op == 8'h9B ? (pe ? 4'h3 : 4'h2) : (pe ? 4'h1 : 4'h0))),
              "CLTS clears only TS; software emulation retains EM");
        execute_enable = 0; observe = 0; cases++;
    endtask

    task automatic pause_or_cancel(input logic pe, input logic [7:0] op,
                                   input logic cancel_subject, input logic [1:0] policy);
        integer deadline, length;
        logic [15:0] paused_ip;
        setup(pe,0,op == 8'h9B ? 3'b101 : 3'b010,op,1,2,policy,length);
        deadline = 0;
        while (!(debug_micro_active && debug_micro_instruction ==
                 (op == 8'h9B ? spk286_microcode_pkg::MC_CHECK_NPX_WAIT :
                                 spk286_microcode_pkg::MC_CHECK_NPX_ESC)) && deadline < 1200) begin
            tick(); deadline++;
        end
        check(deadline < 1200 && !first_fault,"pause reaches check before a clock accepts #NM");
        paused_ip = debug_ip;
        execute_enable = 0;
        repeat (8) tick();
        check(!first_fault && !dut.fault_request && events_seen == 0 && subject_retired == 0 &&
              debug_ip == paused_ip && debug_gpr == original_gpr && debug_flags == original_flags &&
              subject_reads == 0 && subject_writes == 0 && io_cycles == 0,
              "paused check has no fault, retirement, state write or operand/port request");
        if (cancel_subject) begin
            memory['h400] = 8'hB8; word_at('h401,'hBEEF);
            redirect = 1; ip_write_en = 1; ip_write_data = 'h400;
            tick(); redirect = 0; ip_write_en = 0;
        end
        execute_enable = 1;
        deadline = 0;
        while ((cancel_subject ? !(instruction_retired && debug_gpr[15:0] == 'hBEEF) :
                                 !event_completed) && !shutdown && !unsupported_opcode && deadline < 1200) begin
            tick(); deadline++;
        end
        check(deadline < 1200 && !shutdown && !unsupported_opcode && !microcode_fault,
              "resumed/canceled check reaches its architectural destination");
        if (cancel_subject)
            check(!first_fault && events_seen == 0 && subject_retired == 0 &&
                  debug_ip == 'h403 && debug_gpr[79:64] == 'h2000 && debug_flags == original_flags,
                  "redirect cancels old #NM and reaches the new stream without stale retirement");
        else
            check(first_fault && first_vector == 7 && !first_error_valid && events_seen == 1 &&
                  fault_ip == 'h100 && subject_retired == 0 && debug_ip == 'h300 &&
                  read_word('h1FFA) == 'h100 && frame_writes == 3,
                  "resume delivers exactly one restartable #NM");
        execute_enable = 0; observe = 0; cases++;
    endtask

    initial begin
        for (integer i = 0; i < 65536; i++) memory[i] = 0;
        if ($test$plusargs("wait_baseline")) begin
            run_case(0,0,0,8'h9B,0,0,0);
        end else if ($test$plusargs("lifecycle_only")) begin
            for (integer policy = 0; policy < 3; policy++)
                for (integer pe = 0; pe < 2; pe++)
                    for (integer cancel_subject = 0; cancel_subject < 2; cancel_subject++) begin
                        pause_or_cancel(1'(pe),8'hD8,1'(cancel_subject),2'(policy));
                        pause_or_cancel(1'(pe),8'h9B,1'(cancel_subject),2'(policy));
                    end
        end else begin
            // This first case rejects the historical EM-blind ESC passthrough.
            run_case(0,0,3'b010,8'hD8,0,0,0);
            for (integer policy = 0; policy < 3; policy++)
                for (integer ctx = 0; ctx < 5; ctx++)
                    for (integer bits = 0; bits < 8; bits++)
                        for (integer prefix_kind = 0; prefix_kind < 3; prefix_kind++) begin
                            run_case(ctx != 0,2'(ctx == 0 ? 0 : ctx-1),3'(bits),8'h9B,0,prefix_kind,2'(policy));
                            for (integer op = 'hD8; op <= 'hDF; op++)
                                for (integer form = 0; form < 3; form++)
                                    run_case(ctx != 0,2'(ctx == 0 ? 0 : ctx-1),3'(bits),8'(op),form,prefix_kind,2'(policy));
                        end
            for (integer policy = 0; policy < 3; policy++)
                for (integer pe = 0; pe < 2; pe++)
                    for (integer prefix_kind = 0; prefix_kind < 3; prefix_kind++) begin
                        recovery(1'(pe),8'hD8,0,prefix_kind,2'(policy));
                        recovery(1'(pe),8'h9B,0,prefix_kind,2'(policy));
                        recovery(1'(pe),8'hDF,1,prefix_kind,2'(policy));
                    end
            for (integer policy = 0; policy < 3; policy++)
                for (integer pe = 0; pe < 2; pe++)
                    for (integer cancel_subject = 0; cancel_subject < 2; cancel_subject++) begin
                        pause_or_cancel(1'(pe),8'hD8,1'(cancel_subject),2'(policy));
                        pause_or_cancel(1'(pe),8'h9B,1'(cancel_subject),2'(policy));
                    end
        end
        $display("NPX_TRAPS PASS: %0d checks / %0d cases",checks,cases);
        $finish;
    end
endmodule
