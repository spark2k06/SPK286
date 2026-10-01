`timescale 1ns/1ps
// Physical D8 captures require a first-word check even without an NPX.
// Intel 286 PRM 7.4 / 9.6.3: later NPX words are a separately scoped #9 path.
module spk286_esc_boundaries_tb;
    `include "spk286_npx_fixture.svh"

    task automatic boundary_case(input logic pe, input logic [1:0] cpl,
                                 input logic [2:0] bits, input logic [7:0] op,
                                 input logic [1:0] seg, input logic [15:0] limit,
                                 input logic [15:0] offset, input logic [7:0] access_byte,
                                 input logic null_selector, input logic reg_form,
                                 input logic [1:0] policy);
        integer length, deadline, prefix_kind, frame_size;
        logic bad_pointer, expected_fault, expected_error;
        logic [7:0] expected_vector;
        string label;
        fixture_custom = 1; fixture_segment = seg; fixture_limit = limit;
        // LOADALL restores the hidden cache directly. A null segment loaded
        // normally has an empty cache; selector zero with AR=93 is a different,
        // undocumented LOADALL state and does not represent that case.
        fixture_offset = offset; fixture_access = null_selector ? 8'd0 : access_byte;
        fixture_null = null_selector;
        prefix_kind = seg == 0 ? 3 : seg == 1 ? 1 : seg == 2 ? 2 : 0;
        bad_pointer = !reg_form &&
                      ((pe && (null_selector || (seg == 1 && !access_byte[1]))) ||
                       (pe && seg != 1 && access_byte[2] ?
                        (offset <= limit || offset == 16'hFFFF) :
                        ({1'b0,offset}+17'd1 > {1'b0,limit})));
        expected_fault = bits[2] || bits[1] || bad_pointer;
        expected_vector = bits[2] || bits[1] ? 7 : pe && seg == 2 ? 12 : 13;
        expected_error = pe && expected_vector != 7;
        label = $sformatf("PE=%b CPL=%d bits=%b op=%h seg=%d limit=%h offset=%h AR=%h null=%b reg=%b policy=%d",
                         pe,cpl,bits,op,seg,limit,offset,access_byte,null_selector,reg_form,policy);
        setup(pe,cpl,bits,op,reg_form ? 0 : 4,prefix_kind,policy,length);
        deadline = 0;
        while (!event_completed && subject_retired == 0 && !shutdown &&
               !unsupported_opcode && deadline < 1200) begin tick(); deadline++; end
        check(deadline < 1200 && !shutdown && !unsupported_opcode && !microcode_fault,
              {label," reaches retirement or handler"});
        check(subject_reads == 0 && subject_writes == 0 && io_cycles == 0,
              {label," validation has no operand or port bus traffic"});
        if (expected_fault) begin
            frame_size = expected_error ? 8 : 6;
            check(first_fault && first_vector == expected_vector && events_seen == 1 &&
                  first_error_valid == expected_error && first_error == 0 &&
                  debug_event_error_valid == expected_error && debug_event_error_code == 0 &&
                  debug_event_vector == expected_vector && subject_retired == 0,
                  {label," precise #NM/#GP/#SS and error-word routing"});
            check(fault_ip == 'h100 && fault_gpr == original_gpr && fault_flags == original_flags &&
                  fault_selectors == original_selectors && fault_sp == 'h2000,
                  {label," first prefix and source state remain restartable"});
            check(debug_ip == 'h300 && debug_cs == caller_cs &&
                  debug_gpr == original_gpr - (128'(frame_size) << 64) &&
                  frame_writes == frame_size/2 &&
                  read_word('h1FFA) == 'h100 && read_word('h1FFC) == caller_cs &&
                  read_word('h1FFE) == original_flags &&
                  read_word('h2000-frame_size-2) == 'hA5A5 &&
                  (!expected_error || read_word('h1FF8) == 0),
                  {label," exact frame, unchanged GPRs and no extra writes"});
        end else
            check(!first_fault && events_seen == 0 && subject_retired == 1 &&
                  debug_ip == 16'('h100+length) && debug_gpr == original_gpr &&
                  debug_segment_selectors == original_selectors && debug_flags == original_flags,
                  {label," valid first word/register form retires once"});
        execute_enable = 0; observe = 0; cases++;
    endtask

    task automatic check_lifecycle(input logic pe, input logic cancel_subject,
                                   input logic [1:0] policy);
        integer length, deadline;
        logic [15:0] paused_ip;
        fixture_custom = 1; fixture_segment = 3; fixture_limit = 'hFFFF;
        fixture_offset = 'hFFFF; fixture_access = 'h93; fixture_null = 0;
        setup(pe,0,0,8'hDF,4,0,policy,length);
        deadline = 0;
        while (!(debug_micro_active && debug_micro_instruction == spk286_microcode_pkg::MC_CHECK_RM16) &&
               deadline < 1200) begin tick(); deadline++; end
        check(deadline < 1200 && !first_fault,"lifecycle reaches pointer check before acceptance");
        paused_ip = debug_ip; execute_enable = 0;
        repeat (8) tick();
        check(!first_fault && !dut.fault_request && !operand_blocked && events_seen == 0 &&
              subject_retired == 0 && debug_gpr == original_gpr && debug_ip == paused_ip &&
              subject_reads == 0 && subject_writes == 0,"paused pointer check has no effect");
        if (cancel_subject) begin
            memory['h400] = 8'hB8; word_at('h401,'hBEEF);
            redirect = 1; ip_write_en = 1; ip_write_data = 'h400;
            tick(); redirect = 0; ip_write_en = 0;
        end
        execute_enable = 1; deadline = 0;
        while ((cancel_subject ? !(instruction_retired && debug_gpr[15:0] == 'hBEEF) : !event_completed) &&
               !shutdown && !unsupported_opcode && deadline < 1200) begin tick(); deadline++; end
        check(deadline < 1200 && !shutdown && !unsupported_opcode && !microcode_fault,
              "resumed or canceled pointer check reaches destination");
        if (cancel_subject)
            check(!first_fault && events_seen == 0 && subject_retired == 0 && debug_ip == 'h403 &&
                  debug_gpr[79:64] == 'h2000,"redirect cancels pending pointer fault without stale retirement");
        else
            check(first_fault && first_vector == 13 && events_seen == 1 && fault_ip == 'h100 &&
                  subject_retired == 0 && debug_ip == 'h300,"resume delivers one restartable pointer fault");
        execute_enable = 0; observe = 0; cases++;
    endtask

    initial begin
        for (integer i = 0; i < 65536; i++) memory[i] = 0;
        // First case reproduces the historical FFFF physical failure.
        boundary_case(0,0,0,8'hD8,3,'hFFFF,'hFFFF,'h93,0,0,0);
        for (integer policy = 0; policy <= 2; policy += 2)
            for (integer ctx = 0; ctx < 5; ctx++)
                for (integer op = 'hD8; op <= 'hDF; op++)
                    for (integer seg = 0; seg < 4; seg++) begin
                        for (integer control = 0; control < 3; control++) begin
                            boundary_case(ctx != 0,2'(ctx == 0 ? 0 : ctx-1),3'(control == 0 ? 0 : control == 1 ? 2 : 4),
                                          8'(op),2'(seg),'hFFFF,'hFFFE,seg == 1 ? 8'h9B : 8'h93,0,0,2'(policy));
                            boundary_case(ctx != 0,2'(ctx == 0 ? 0 : ctx-1),3'(control == 0 ? 0 : control == 1 ? 2 : 4),
                                          8'(op),2'(seg),'hFFFF,'hFFFF,seg == 1 ? 8'h9B : 8'h93,0,0,2'(policy));
                        end
                        if (ctx != 0) begin
                            boundary_case(1,2'(ctx-1),0,8'(op),2'(seg),'h3FFF,'h3FFE,seg == 1 ? 8'h9B : 8'h93,0,0,2'(policy));
                            boundary_case(1,2'(ctx-1),0,8'(op),2'(seg),'h3FFF,'h3FFF,seg == 1 ? 8'h9B : 8'h93,0,0,2'(policy));
                            boundary_case(1,2'(ctx-1),0,8'(op),2'(seg),'h3FFF,'h4000,seg == 1 ? 8'h9B : 8'h93,0,0,2'(policy));
                            boundary_case(1,2'(ctx-1),0,8'(op),2'(seg),'hFFFF,'hFFFE,seg == 1 ? 8'h99 : 8'h91,0,0,2'(policy));
                            if (seg != 1) begin
                                boundary_case(1,2'(ctx-1),0,8'(op),2'(seg),'h1000,'h1000,'h97,0,0,2'(policy));
                                boundary_case(1,2'(ctx-1),0,8'(op),2'(seg),'h1000,'h1001,'h97,0,0,2'(policy));
                            end
                            if (seg == 0 || seg == 3) begin
                                boundary_case(1,2'(ctx-1),0,8'(op),2'(seg),'hFFFF,'hFFFE,'h97,0,0,2'(policy));
                                boundary_case(1,2'(ctx-1),0,8'(op),2'(seg),'hFFFF,'h4000,'h93,1,0,2'(policy));
                                boundary_case(1,2'(ctx-1),0,8'(op),2'(seg),'hFFFF,'hFFFF,'h97,1,1,2'(policy));
                                boundary_case(1,2'(ctx-1),2,8'(op),2'(seg),'hFFFF,'hFFFF,'h97,1,0,2'(policy));
                            end
                        end
                    end
        for (integer policy = 0; policy <= 2; policy += 2)
            for (integer pe = 0; pe < 2; pe++)
                for (integer cancel_subject = 0; cancel_subject < 2; cancel_subject++)
                    check_lifecycle(1'(pe),1'(cancel_subject),2'(policy));
        $display("ESC_BOUNDARIES PASS: %0d checks / %0d cases",checks,cases);
        $finish;
    end
endmodule
