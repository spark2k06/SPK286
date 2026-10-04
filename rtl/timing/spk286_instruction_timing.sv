// Compact instruction minima for provisional historical CPU profiles.
// Reuses the functional decoder's entry and current-instruction metadata;
// this module neither decodes instruction bytes nor advances the CPU/BIU.
// Intel 80286 Programmer's Reference Manual 210498-005, Appendix B supplies
// documented bases. These are total lower bounds, not additional EU delays.
// Add the B-6 EA correction and actual extra MEMORY READ waits separately.
// Add +2 once for EACH actual odd-word reference, including stack/descriptor
// references: operand_odd is retained for ABI compatibility, not charged here.
// READY, operand/result availability, ownership, redirect and commit remain
// real dependencies even after a deadline. WRITE/IO waits are not EU charges.
// estimated identifies omitted target-length/gate/task distinctions, native
// fallback and undocumented forms; it is not a claim of cycle accuracy.
`ifndef SPK286_INSTRUCTION_TIMING_SV_INCLUDED
`define SPK286_INSTRUCTION_TIMING_SV_INCLUDED
`timescale 1ns/1ps
module spk286_instruction_timing (
    input logic [7:0] opcode,
    input logic extended_opcode,
    input logic [spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] micro_entry,
    input logic modrm_valid,
    input logic [1:0] modrm_mode,
    input logic [2:0] modrm_reg, modrm_rm,
    input logic protected_mode,
    input logic [1:0] CPL,
    input logic operand_odd,
    input logic branch_known, branch_taken,
    input logic count_known,
    input logic [4:0] count,
    input logic [1:0] repeat_kind,
    output logic qualified, estimated,
    output logic requires_modrm, requires_outcome, requires_count,
    output logic [9:0] base_clocks,
    output logic [9:0] repeat_setup_clocks, repeat_iteration_clocks,
    output logic permits_read_wait,
    output logic [2:0] ea_clocks
);
    import spk286_microcode_pkg::*;
    wire memory_form = modrm_mode != 2'b11;
    // Privilege validity and escape decoding belong to the real decoder and
    // services. This table never grants permission to an invalid instruction.
    wire unused_context = ^{extended_opcode, CPL, operand_odd};
    logic string_form;

    always_comb begin
        // An unclassified legal entry explicitly remains a positive estimated
        // lower bound. It cannot stall boot awaiting metadata it does not use.
        base_clocks = 10'd2;
        estimated = 1'b0;
        requires_modrm = 1'b0;
        requires_outcome = 1'b0;
        requires_count = 1'b0;
        repeat_setup_clocks = 10'd0;
        repeat_iteration_clocks = 10'd0;
        permits_read_wait = 1'b1;
        string_form = 1'b0;
        ea_clocks = 3'd0;
        case (micro_entry)
            MC_ENTRY_MOV_R16_IMM16, MC_ENTRY_MOV_R8_IMM8: begin
                base_clocks = 10'd2; permits_read_wait = 1'b0;
            end
            MC_ENTRY_MOV_RM16_R16, MC_ENTRY_MOV_RM8_R8,
            MC_ENTRY_MOV_RM16_IMM16, MC_ENTRY_MOV_RM8_IMM8,
            MC_ENTRY_MOV_RM16_SEG: begin
                requires_modrm = 1'b1;
                base_clocks = memory_form ? 10'd3 : 10'd2;
                permits_read_wait = 1'b0;
            end
            MC_ENTRY_MOV_R16_RM16, MC_ENTRY_MOV_R8_RM8: begin
                requires_modrm = 1'b1;
                base_clocks = memory_form ? 10'd5 : 10'd2;
            end
            MC_ENTRY_MOV_SEG_RM16: begin
                requires_modrm = 1'b1;
                base_clocks = protected_mode ? (memory_form ? 10'd19 : 10'd17) :
                                              (memory_form ? 10'd5 : 10'd2);
            end
            MC_ENTRY_ALU_RM16_R16, MC_ENTRY_ALU_RM8_R8: begin
                requires_modrm = 1'b1;
                base_clocks = memory_form ?
                    ((opcode == 8'h84 || opcode == 8'h85) ? 10'd6 : 10'd7) : 10'd2;
            end
            MC_ENTRY_ALU_R16_RM16, MC_ENTRY_ALU_R8_RM8: begin
                requires_modrm = 1'b1;
                base_clocks = memory_form ? (opcode[5:3] == 3'd7 ? 10'd6 : 10'd7) : 10'd2;
            end
            MC_ENTRY_ALU_AX_IMM16, MC_ENTRY_ALU_AL_IMM8: begin
                base_clocks = 10'd3; permits_read_wait = 1'b0;
            end
            MC_ENTRY_ALU_RM16_IMM16, MC_ENTRY_ALU_RM16_IMM8S,
            MC_ENTRY_ALU_RM8_IMM8: begin
                requires_modrm = 1'b1;
                base_clocks = memory_form ? (modrm_reg == 3'd7 ? 10'd6 : 10'd7) : 10'd3;
            end
            MC_ENTRY_INC_DEC_R16, MC_ENTRY_EXTEND_BYTE, MC_ENTRY_EXTEND_WORD,
            MC_ENTRY_LOAD_FLAGS_BYTE, MC_ENTRY_CONTROL_FLAGS,
            MC_ENTRY_SYSTEM_CLTS: begin
                base_clocks = 10'd2; permits_read_wait = 1'b0;
            end
            MC_ENTRY_CONTROL_IF: begin
                base_clocks = opcode == 8'hFA ? 10'd3 : 10'd2;
                permits_read_wait = 1'b0;
            end
            MC_ENTRY_HALT_CPU: begin
                base_clocks = 10'd2; permits_read_wait = 1'b0;
            end
            MC_ENTRY_ADJUST_DIRECT: begin
                base_clocks = 10'd3; permits_read_wait = 1'b0;
            end
            MC_ENTRY_ADJUST_RADIX: begin
                base_clocks = opcode == 8'hD4 ? 10'd16 : 10'd14;
                permits_read_wait = 1'b0;
            end
            MC_ENTRY_INC_DEC_RM8, MC_ENTRY_INC_DEC_RM16,
            MC_ENTRY_NOT_RM8, MC_ENTRY_NOT_RM16, MC_ENTRY_NEG_RM8, MC_ENTRY_NEG_RM16: begin
                requires_modrm = 1'b1;
                base_clocks = memory_form ? 10'd7 : 10'd2;
            end
            MC_ENTRY_EXCHANGE_RM8_R8, MC_ENTRY_EXCHANGE_RM16_R16: begin
                requires_modrm = 1'b1;
                base_clocks = memory_form ? 10'd5 : 10'd3;
            end
            MC_ENTRY_EXCHANGE_SOURCE_TARGET16: begin
                base_clocks = 10'd3; permits_read_wait = 1'b0;
            end
            MC_ENTRY_LEA_R16_M: begin
                requires_modrm = 1'b1;
                base_clocks = 10'd3; permits_read_wait = 1'b0;
            end
            MC_ENTRY_LOAD_DIRECT8, MC_ENTRY_LOAD_DIRECT16, MC_ENTRY_LOAD_BASE_INDEX8:
                base_clocks = 10'd5;
            MC_ENTRY_STORE_DIRECT8, MC_ENTRY_STORE_DIRECT16: begin
                base_clocks = 10'd3; permits_read_wait = 1'b0;
            end
            MC_ENTRY_PUSH_R16, MC_ENTRY_PUSH_SEG, MC_ENTRY_PUSH_IMM16,
            MC_ENTRY_PUSH_IMM8S, MC_ENTRY_PUSH_FLAGS: begin
                base_clocks = 10'd3; permits_read_wait = 1'b0;
            end
            MC_ENTRY_POP_R16, MC_ENTRY_POP_RM16, MC_ENTRY_POP_FLAGS,
            MC_ENTRY_LEAVE_FRAME: begin
                base_clocks = 10'd5;
                requires_modrm = micro_entry == MC_ENTRY_POP_RM16;
            end
            MC_ENTRY_POP_SEG: base_clocks = protected_mode ? 10'd20 : 10'd5;
            MC_ENTRY_PUSH_ALL: begin
                base_clocks = 10'd17; permits_read_wait = 1'b0;
            end
            MC_ENTRY_POP_ALL: base_clocks = 10'd19;
            MC_ENTRY_ENTER_FRAME: begin
                requires_count = 1'b1;
                // count is the INITIAL nesting level, not the live loop counter.
                base_clocks = count == 5'd0 ? 10'd11 : count == 5'd1 ? 10'd15 :
                              10'd12 + {3'd0, count, 2'b00};
            end
            MC_ENTRY_CHECK_BOUNDS: begin
                requires_modrm = 1'b1; base_clocks = 10'd13;
            end
            MC_ENTRY_LOAD_POINTER: begin
                requires_modrm = 1'b1;
                base_clocks = protected_mode ? 10'd21 : 10'd7;
            end
            MC_ENTRY_SHIFT_RM8_ONE, MC_ENTRY_SHIFT_RM16_ONE: begin
                requires_modrm = 1'b1;
                base_clocks = memory_form ? 10'd7 : 10'd2;
            end
            MC_ENTRY_SHIFT_RM8_CL, MC_ENTRY_SHIFT_RM16_CL,
            MC_ENTRY_SHIFT_RM8_IMM8, MC_ENTRY_SHIFT_RM16_IMM8: begin
                requires_modrm = 1'b1; requires_count = 1'b1;
                // Intel B-90/B-97: count is masked to five bits, before any
                // functional rotate modulo8/9/16/17 reduction.
                base_clocks = (memory_form ? 10'd8 : 10'd5) + {5'd0, count};
            end
            MC_ENTRY_GROUP3_DISPATCH, MC_ENTRY_MULDIV_RM8, MC_ENTRY_MULDIV_RM16: begin
                requires_modrm = 1'b1;
                case (modrm_reg)
                    3'd0: base_clocks = memory_form ? 10'd6 : 10'd3; // TEST
                    3'd2, 3'd3: base_clocks = memory_form ? 10'd7 : 10'd2;
                    3'd4, 3'd5: base_clocks = (opcode[0] ? 10'd21 : 10'd13) +
                                                    (memory_form ? 10'd3 : 10'd0);
                    3'd6: base_clocks = (opcode[0] ? 10'd22 : 10'd14) +
                                                    (memory_form ? 10'd3 : 10'd0);
                    3'd7: base_clocks = (opcode[0] ? 10'd25 : 10'd17) +
                                                    (memory_form ? 10'd3 : 10'd0);
                    default: begin base_clocks = 10'd2; estimated = 1'b1; end
                endcase
            end
            MC_ENTRY_IMUL_R16_RM16_IMM16, MC_ENTRY_IMUL_R16_RM16_IMM8S: begin
                requires_modrm = 1'b1;
                base_clocks = memory_form ? 10'd24 : 10'd21;
            end
            MC_ENTRY_GROUP5_DISPATCH, MC_ENTRY_GROUP5_NEAR: begin
                requires_modrm = 1'b1;
                case (modrm_reg)
                    3'd0, 3'd1: base_clocks = memory_form ? 10'd7 : 10'd2;
                    3'd2, 3'd4: begin
                        base_clocks = memory_form ? 10'd11 : 10'd7;
                        estimated = 1'b1; // next target instruction length absent
                    end
                    3'd3: begin
                        base_clocks = protected_mode ? 10'd29 : 10'd16;
                        estimated = 1'b1; // gate/task and target length absent
                    end
                    3'd5: begin
                        base_clocks = protected_mode ? 10'd26 : 10'd15;
                        estimated = 1'b1;
                    end
                    3'd6: base_clocks = memory_form ? 10'd5 : 10'd3;
                    default: begin base_clocks = 10'd2; estimated = 1'b1; end
                endcase
            end
            MC_ENTRY_CALL_REL16, MC_ENTRY_JMP_REL16: begin
                base_clocks = 10'd7; estimated = 1'b1;
            end
            MC_ENTRY_BRANCH_REL8: begin
                requires_outcome = opcode != 8'hEB;
                base_clocks = (opcode == 8'hEB || branch_taken) ? 10'd7 : 10'd3;
                estimated = opcode == 8'hEB || !branch_known || branch_taken;
            end
            MC_ENTRY_LOOP_REL8: begin
                requires_outcome = 1'b1;
                base_clocks = branch_taken ? 10'd8 : 10'd4;
                estimated = opcode == 8'hE3 && (!branch_known || branch_taken);
            end
            MC_ENTRY_RET_NEAR, MC_ENTRY_RET_IMM16: begin
                base_clocks = 10'd11; estimated = 1'b1;
            end
            MC_ENTRY_CALL_FAR_IMM: begin
                base_clocks = protected_mode ? 10'd26 : 10'd13; estimated = 1'b1;
            end
            MC_ENTRY_JMP_FAR_IMM: begin
                base_clocks = protected_mode ? 10'd23 : 10'd11; estimated = 1'b1;
            end
            MC_ENTRY_CALL_FAR_RM: begin
                requires_modrm = 1'b1;
                base_clocks = protected_mode ? 10'd29 : 10'd16; estimated = 1'b1;
            end
            MC_ENTRY_JMP_FAR_RM: begin
                requires_modrm = 1'b1;
                base_clocks = protected_mode ? 10'd26 : 10'd15; estimated = 1'b1;
            end
            MC_ENTRY_RET_FAR, MC_ENTRY_RET_FAR_IMM: begin
                base_clocks = protected_mode ? 10'd25 : 10'd15; estimated = 1'b1;
            end
            MC_ENTRY_INTERRUPT_RETURN: begin
                base_clocks = protected_mode ? 10'd31 : 10'd17; estimated = 1'b1;
            end
            MC_ENTRY_SOFTWARE_EVENT, MC_ENTRY_SOFTWARE_EVENT_IMM8: begin
                requires_outcome = opcode == 8'hCE;
                base_clocks = opcode == 8'hCE && !branch_taken ? 10'd3 :
                    protected_mode ? 10'd40 : opcode == 8'hCE ? 10'd24 : 10'd23;
                estimated = !(opcode == 8'hCE && branch_known && !branch_taken);
            end
            MC_ENTRY_EVENT_ENTRY: begin
                base_clocks = 10'd23; estimated = 1'b1;
            end
            MC_ENTRY_EVENT_ENTRY_PROTECTED: begin
                base_clocks = 10'd40; estimated = 1'b1;
            end
            MC_ENTRY_STRING_MOVE, MC_ENTRY_STRING_INPUT_BYTE, MC_ENTRY_STRING_INPUT_WORD,
            MC_ENTRY_STRING_OUTPUT_BYTE, MC_ENTRY_STRING_OUTPUT_WORD: begin
                string_form = 1'b1; base_clocks = 10'd5;
                repeat_setup_clocks = 10'd5; repeat_iteration_clocks = 10'd4;
            end
            MC_ENTRY_STRING_COMPARE: begin
                string_form = 1'b1; base_clocks = 10'd8;
                repeat_setup_clocks = 10'd5; repeat_iteration_clocks = 10'd9;
            end
            MC_ENTRY_STRING_STORE: begin
                string_form = 1'b1; base_clocks = 10'd3; permits_read_wait = 1'b0;
                repeat_setup_clocks = 10'd4; repeat_iteration_clocks = 10'd3;
            end
            MC_ENTRY_STRING_LOAD: begin
                string_form = 1'b1; base_clocks = 10'd5;
                // REP LODS is accepted functionally; Intel B-92 gives no row.
                repeat_setup_clocks = 10'd5; repeat_iteration_clocks = 10'd5;
                estimated = repeat_kind != 2'd0;
            end
            MC_ENTRY_STRING_SCAN: begin
                string_form = 1'b1; base_clocks = 10'd7;
                repeat_setup_clocks = 10'd5; repeat_iteration_clocks = 10'd5;
            end
            MC_ENTRY_IN_AL_PORT, MC_ENTRY_IN_AX_PORT: begin
                base_clocks = 10'd5; permits_read_wait = 1'b0;
            end
            MC_ENTRY_OUT_PORT_AL, MC_ENTRY_OUT_PORT_AX: begin
                base_clocks = 10'd3; permits_read_wait = 1'b0;
            end
            MC_ENTRY_WAIT_NO_COPROCESSOR: begin
                base_clocks = 10'd3; permits_read_wait = 1'b0;
            end
            MC_ENTRY_ESC_NO_COPROCESSOR: begin
                // CPU syntax/fault path only. No invented 80287 duration.
                requires_modrm = 1'b1; base_clocks = 10'd2; estimated = 1'b1;
            end
            MC_ENTRY_SYSTEM_GROUP_0F00: begin
                requires_modrm = 1'b1;
                case (modrm_reg)
                    3'd0, 3'd1: begin
                        base_clocks = memory_form ? 10'd3 : 10'd2;
                        permits_read_wait = 1'b0;
                    end
                    3'd2, 3'd3: base_clocks = memory_form ? 10'd19 : 10'd17;
                    3'd4, 3'd5: base_clocks = memory_form ? 10'd16 : 10'd14;
                    default: begin base_clocks = 10'd2; estimated = 1'b1; end
                endcase
            end
            MC_ENTRY_SYSTEM_GROUP_0F01: begin
                requires_modrm = 1'b1;
                case (modrm_reg)
                    3'd0, 3'd2: base_clocks = 10'd11;
                    3'd1, 3'd3: base_clocks = 10'd12;
                    3'd4: base_clocks = memory_form ? 10'd3 : 10'd2;
                    3'd6: base_clocks = memory_form ? 10'd6 : 10'd3;
                    default: begin base_clocks = 10'd2; estimated = 1'b1; end
                endcase
                if (modrm_reg <= 3'd1 || modrm_reg == 3'd4) permits_read_wait = 1'b0;
            end
            MC_ENTRY_SYSTEM_STORE_GDTR, MC_ENTRY_SYSTEM_LOAD_GDTR: begin
                requires_modrm = 1'b1; base_clocks = 10'd11;
                permits_read_wait = micro_entry == MC_ENTRY_SYSTEM_LOAD_GDTR;
            end
            MC_ENTRY_SYSTEM_STORE_IDTR, MC_ENTRY_SYSTEM_LOAD_IDTR: begin
                requires_modrm = 1'b1; base_clocks = 10'd12;
                permits_read_wait = micro_entry == MC_ENTRY_SYSTEM_LOAD_IDTR;
            end
            MC_ENTRY_SYSTEM_STORE_MSW, MC_ENTRY_SYSTEM_STORE_LDTR, MC_ENTRY_SYSTEM_STORE_TR: begin
                requires_modrm = 1'b1; base_clocks = memory_form ? 10'd3 : 10'd2;
                permits_read_wait = 1'b0;
            end
            MC_ENTRY_SYSTEM_LOAD_MSW: begin
                requires_modrm = 1'b1; base_clocks = memory_form ? 10'd6 : 10'd3;
            end
            MC_ENTRY_SYSTEM_LOAD_LDTR, MC_ENTRY_SYSTEM_LOAD_TR: begin
                requires_modrm = 1'b1; base_clocks = memory_form ? 10'd19 : 10'd17;
            end
            MC_ENTRY_SYSTEM_VERIFY_READ, MC_ENTRY_SYSTEM_VERIFY_WRITE,
            MC_ENTRY_SYSTEM_LOAD_ACCESS, MC_ENTRY_SYSTEM_LOAD_LIMIT: begin
                requires_modrm = 1'b1; base_clocks = memory_form ? 10'd16 : 10'd14;
            end
            MC_ENTRY_SYSTEM_ARPL: begin
                requires_modrm = 1'b1; base_clocks = memory_form ? 10'd11 : 10'd10;
            end
            MC_ENTRY_LOADALL: begin
                // Undocumented instruction: native86Box x86_ops_misc.h
                // opLOADALL uses195. This explicit fallback is estimated.
                base_clocks = 10'd195; estimated = 1'b1;
            end
            MC_ENTRY_LOAD_CARRY_BYTE: begin
                // Undocumented SALC: native opSETALC uses timing_rr (=2).
                base_clocks = 10'd2; estimated = 1'b1; permits_read_wait = 1'b0;
            end
            default: begin base_clocks = 10'd2; estimated = 1'b1; end
        endcase
        // B-6 correction applies once to base+index+displacement, not once per
        // micro-operation or operand reference. Register/direct forms add0.
        if (requires_modrm && modrm_valid && memory_form &&
            (modrm_mode == 2'd1 || modrm_mode == 2'd2) && modrm_rm <= 3'd3)
            ea_clocks = 3'd1;
        if (!string_form || repeat_kind == 2'd0) begin
            repeat_setup_clocks = 10'd0;
            repeat_iteration_clocks = 10'd0;
            // Non-string REP has no documented duration; preserve semantics.
            if (!string_form && repeat_kind != 2'd0) estimated = 1'b1;
        end else if (repeat_kind == 2'd1 &&
                     micro_entry != MC_ENTRY_STRING_COMPARE && micro_entry != MC_ENTRY_STRING_SCAN)
            estimated = 1'b1; // REPNE on unconditional strings not tabulated
        qualified = (!requires_modrm || modrm_valid) &&
                    (!requires_outcome || branch_known) &&
                    (!requires_count || count_known);
    end
endmodule
`endif
