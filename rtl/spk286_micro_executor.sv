// SPDX-License-Identifier: MIT
// Functional micro-operation service. Physical fetch/READY belongs to the BIU.
`timescale 1ns/1ps

module spk286_micro_executor #(parameter bit USE_PARALLEL_SYSTEM_LIMIT = 1'b0) (
    input  logic clk,
    input  logic reset,
    input  logic cancel,
    input  logic start,
    input  logic operation_valid,
    input  logic [spk286_microcode_pkg::MC_WORD_WIDTH-1:0] operation,
    output logic operation_done, operation_retire, dispatch_request,
    input  logic byte_valid,
    input  logic [7:0] byte_data,
    output logic byte_ready,
    input  logic [2:0] destination, source_index,
    input  logic segment_pop_opcode,
    input  logic lock_prefix,
    input logic [15:0] target_read_data, effective_offset, address_base,
    input logic [15:0] segment_limit,
    input logic segment_expand_down, parallel_system_limit_fault,
    input logic [15:0] stack_segment_limit,
    /* Only the expand-down bit is consumed by the current stack-range
       predicate; the remaining access bits stay in the segment cache. */
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [7:0] stack_segment_access,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic operand_register_direct,
    input logic [2:0] operand_rm_index,
    output logic address_override,
    output logic [15:0] address_offset,
    output logic io_transfer,
    output logic [15:0] io_port,
    input logic port_immediate,
    input logic [15:0] port_register,
    output logic decode_operand,
    input  logic decode_done,
    input  logic decode_modrm_valid,
    input  logic decode_byte_ready,
    output logic operand_request, operand_write, operand_select_rm, operand_check, operand_byte,
    output logic stack_request,
    output logic [15:0] stack_offset,
    input logic [15:0] architectural_ip, stack_pointer, count_value,
    input logic push_enabled, push_return_ip, branch_taken, decrement_count,
    output logic redirect_request,
    output logic [15:0] redirect_target,
    input logic redirect_ready,
    output logic [15:0] operand_write_data,
    input  logic operand_done,
    // The ROM's flags for the current word (MC_FLAG_*). The task-skip
    // terms gate allowed, so they read these instead of comparing operation.
    input  logic [spk286_microcode_pkg::MC_FLAG_WIDTH-1:0] operation_flags,
    input  logic [15:0] operand_read_data,
    // Raw BIU response data. Descriptor, TSS and event-gate accesses always
    // select memory, so while one is active this equals operand_read_data.
    input  logic [15:0] memory_read_data,
    input  logic operand_gpr_write_en, operand_gpr_write_byte,
    input  logic [2:0] operand_gpr_write_index,
    input  logic [15:0] operand_gpr_write_data,
    output logic gpr_write_en, gpr_write_byte,
    output logic [2:0] gpr_write_index,
    output logic [15:0] gpr_write_data,
    input logic [15:0] destination_read_data,
    input logic [7:0] destination_byte_data,
    input logic carry_in,
    input logic [15:0] architectural_flags,
    input logic [15:0] direct_flags_data, direct_flags_mask,
    input logic if_value,
    input logic [15:0] event_flags, event_cs, event_ip,
    input logic event_error_valid,
    input logic [15:0] event_error_code,
    input logic [7:0] event_vector,
    input logic event_needs_ack, ack_done, event_active, event_software,
    output logic ack_request, software_event_request, halt_request,
    output logic [7:0] software_vector,
    output logic context_commit, vector_request,
    output logic [15:0] context_cs,
    output logic [15:0] vector_offset,
    input logic [2:0] alu_operation,
    input logic alu_byte, reverse_operands,
    input logic [2:0] shift_kind, adjust_kind,
    input logic [1:0] muldiv_kind,
    output logic arithmetic_fault,
    input logic string_byte, string_compare,
    input logic [1:0] repeat_kind,
    output logic string_request, string_destination, repeat_boundary, repeat_stepped,
    input logic [127:0] register_state,
    output logic counter_branch_request, range_fault, bounds_fault,
    input logic [15:0] segment_read_value,
    output logic segment_write,
    output logic [15:0] segment_write_data,
    input logic [1:0] segment_index,
    output logic protected_segment_commit_en,
    output logic [1:0] protected_segment_commit_index,
    output logic [15:0] protected_segment_commit_selector,
    output logic [23:0] protected_segment_commit_base,
    output logic [15:0] protected_segment_commit_limit,
    output logic [7:0] protected_segment_commit_access,
    output logic [3:0] protected_segment_commit_class,
    output logic protected_segment_commit_present, protected_segment_commit_protected,
    output logic [1:0] protected_segment_commit_dpl,
    output logic protected_segment_commit_table_indicator,
    output logic [1:0] protected_segment_commit_rpl,
    output logic protected_segment_commit_en2,
    output logic [1:0] protected_segment_commit_index2,
    output logic [15:0] protected_segment_commit_selector2,
    output logic [23:0] protected_segment_commit_base2,
    output logic [15:0] protected_segment_commit_limit2,
    output logic [7:0] protected_segment_commit_access2,
    output logic [3:0] protected_segment_commit_class2,
    output logic protected_segment_commit_present2, protected_segment_commit_protected2,
    output logic [1:0] protected_segment_commit_dpl2,
    output logic protected_segment_commit_table_indicator2,
    output logic [1:0] protected_segment_commit_rpl2,
    input logic result_write_allowed,
    input logic [15:0] decoded_flags_mask, decoded_undefined_mask,
    output logic flags_write_en,
    output logic [15:0] flags_write_data, flags_write_mask,
    input logic [15:0] protected_msw,
    input logic [15:0] protected_gdtr_limit, protected_idtr_limit,
    input logic [23:0] protected_gdtr_base, protected_idtr_base,
    input logic [15:0] protected_ldtr_selector, protected_tr_selector,
    input logic [23:0] protected_ldtr_base,
    input logic [15:0] protected_ldtr_limit,
    input logic protected_ldtr_valid, protected_ldtr_present,
    input logic [23:0] protected_tr_base,
    input logic [15:0] protected_tr_limit,
    input logic protected_tr_valid, protected_tr_present,
    input logic [15:0] protected_ss_selector,
    input logic [1:0] protected_cpl,
    output logic protected_msw_load_en,
    output logic [15:0] protected_msw_load_data, protected_msw_load_mask,
    output logic protected_gdtr_load_en, protected_idtr_load_en,
    output logic [15:0] protected_gdtr_load_limit, protected_idtr_load_limit,
    output logic [23:0] protected_gdtr_load_base, protected_idtr_load_base,
    output logic protected_ldtr_commit_en, protected_tr_commit_en,
    output logic [15:0] protected_ldtr_commit_selector, protected_tr_commit_selector,
    output logic [23:0] protected_ldtr_commit_base, protected_tr_commit_base,
    output logic [15:0] protected_ldtr_commit_limit, protected_tr_commit_limit,
    output logic [7:0] protected_ldtr_commit_access, protected_tr_commit_access,
    output logic [3:0] protected_ldtr_commit_class, protected_tr_commit_class,
    output logic protected_ldtr_commit_present, protected_tr_commit_present,
    output logic protected_ldtr_commit_valid, protected_tr_commit_valid,
    output logic protected_descriptor_access,
    output logic [23:0] protected_descriptor_address,
    output logic protected_gate_access,
    output logic protected_tss_access,
    output logic [23:0] protected_tss_address,
    output logic protected_call_stack_access,
    output logic [23:0] protected_call_stack_address,
    output logic [15:0] protected_call_stack_limit,
    output logic protected_call_stack_expand_down,
    output logic protected_event_access,
    output logic [23:0] protected_event_address,
    // Task-transfer service handshake and committed task image.
    output logic task_switch_start,
    output logic task_switch_nested_call,
    output logic task_switch_return_task,
    output logic [15:0] task_switch_target_selector,
    output logic [23:0] task_switch_target_base,
    output logic [15:0] task_switch_target_limit,
    output logic [7:0] task_switch_target_access,
    output logic [23:0] task_switch_target_descriptor_address,
    input logic task_service_busy, task_service_complete, task_service_fault,
    input logic task_service_commit_ready,
    input logic task_cache_commit,
    input logic [1:0] task_cache_commit_index,
    output logic protected_task_load,
    output logic task_state_loaded,
    output logic protected_segment_commit_valid,
    input logic task_fault_external,
    input logic [7:0] task_service_fault_vector,
    input logic [15:0] task_service_fault_error_code,
    input logic [15:0] task_loaded_ip, task_loaded_flags,
    input logic [127:0] task_loaded_gpr,
    input logic [15:0] task_loaded_ldtr,
    input logic [23:0] task_loaded_ldtr_base,
    input logic [15:0] task_loaded_ldtr_limit,
    input logic [7:0] task_loaded_ldtr_access,
    input logic [3:0] task_loaded_ldtr_class,
    input logic task_loaded_ldtr_valid, task_loaded_ldtr_present,
    input logic [15:0] task_loaded_tr_selector, task_loaded_tr_limit,
    input logic [23:0] task_loaded_tr_base,
    input logic [7:0] task_loaded_tr_access,
    input logic [63:0] task_cache_selectors,
    input logic [95:0] task_cache_bases,
    input logic [63:0] task_cache_limits,
    input logic [31:0] task_cache_access,
    input logic [15:0] task_cache_classes,
    input logic [3:0] task_cache_present, task_cache_protected, task_cache_tables,
    input logic [7:0] task_cache_dpl, task_cache_rpl,
    output logic task_flags_write_en,
    output logic system_limit_fault, system_fault,
    output logic [7:0] system_fault_vector,
    output logic [15:0] system_fault_error_code
);
    logic fetch_port, io_read, io_write, io_byte, io_operation, io_privilege_check, io_privilege_fault, if_control_operation;
    assign if_control_operation = allowed && operation == spk286_microcode_pkg::MC_SET_IF;
    assign io_privilege_check = allowed && operation == spk286_microcode_pkg::MC_CHECK_IO_PRIVILEGE;
    assign io_operation = allowed && (operation == spk286_microcode_pkg::MC_IO_READ8 || operation == spk286_microcode_pkg::MC_IO_READ16 ||
                                     operation == spk286_microcode_pkg::MC_IO_WRITE8 || operation == spk286_microcode_pkg::MC_IO_WRITE16);
    assign io_privilege_fault = protected_msw[0] && protected_cpl > architectural_flags[13:12] &&
                                (if_control_operation || io_privilege_check || io_operation);
    assign fetch_port = allowed && operation == spk286_microcode_pkg::MC_FETCH_PORT;
    assign io_read = allowed && !io_privilege_fault && temporary_valid_q[1] && (operation == spk286_microcode_pkg::MC_IO_READ8 || operation == spk286_microcode_pkg::MC_IO_READ16);
    assign io_write = allowed && !io_privilege_fault && &temporary_valid_q[1:0] && (operation == spk286_microcode_pkg::MC_IO_WRITE8 || operation == spk286_microcode_pkg::MC_IO_WRITE16);
    assign io_byte = operation == spk286_microcode_pkg::MC_IO_READ8 || operation == spk286_microcode_pkg::MC_IO_WRITE8;
    assign io_transfer = io_read || io_write;
    assign io_port = tmp1_q;
    logic string_step_source, string_step_dest, string_count, string_read0, string_read1, string_store;
    logic string_read_acc, string_write_acc, string_empty, string_continue, string_again;
    logic string_range_fault, string_count_write, string_index_write;
    logic [15:0] string_index, string_delta;
    assign string_empty = allowed && operation == spk286_microcode_pkg::MC_BRANCH_REPEAT_EMPTY;
    assign string_continue = allowed && operation == spk286_microcode_pkg::MC_BRANCH_REPEAT_CONTINUE;
    assign string_again = repeat_kind != 0 && count_value != 0 &&
                          (!string_compare || (architectural_flags[6] == (repeat_kind == 2)));
    assign repeat_boundary = (string_empty && repeat_kind != 0 && count_value != 0) || (string_continue && string_again);
    assign repeat_stepped = string_continue && string_again;
    assign string_step_source = allowed && operation == spk286_microcode_pkg::MC_STEP_STRING_SOURCE;
    assign string_step_dest = allowed && operation == spk286_microcode_pkg::MC_STEP_STRING_DEST;
    assign string_index_write = string_step_source || string_step_dest;
    assign string_index = string_step_source ? register_state[96 +: 16] : register_state[112 +: 16];
    assign string_delta = string_byte ? 16'd1 : 16'd2;
    assign string_count = allowed && operation == spk286_microcode_pkg::MC_REPEAT_COUNT;
    assign string_read0 = allowed && operation == spk286_microcode_pkg::MC_READ_STRING_TMP0 && address_override;
    assign string_read1 = allowed && operation == spk286_microcode_pkg::MC_READ_STRING_TMP1 && address_override;
    assign string_store = allowed && operation == spk286_microcode_pkg::MC_WRITE_STRING_TMP0 && address_override && temporary_valid_q[0];
    assign string_range_fault = string_store && !string_byte && address_offset == 16'hFFFF;
    // Pinned repeated store faults retain the next count decrement as well as
    // the attempted element's earlier decrement. This includes CX=1 -> FFFF.
    assign string_count_write = repeat_kind != 0 && (string_count || string_range_fault);
    assign string_request = string_read0 || string_read1 || (string_store && !string_range_fault);
    assign string_read_acc = allowed && operation == spk286_microcode_pkg::MC_READ_STRING_ACCUMULATOR;
    assign string_write_acc = allowed && operation == spk286_microcode_pkg::MC_WRITE_STRING_ACCUMULATOR && temporary_valid_q[0];
    logic check_push2, check_pop2, check_call_frame, copy_call_parameters, add_allocation_sp;
    assign check_push2=allowed && operation==spk286_microcode_pkg::MC_CHECK_PUSH2;
    assign check_pop2=allowed && operation==spk286_microcode_pkg::MC_CHECK_POP2;
    assign check_call_frame = allowed && operation == spk286_microcode_pkg::MC_CHECK_CALL_FRAME;
    assign copy_call_parameters = allowed && operation == spk286_microcode_pkg::MC_COPY_CALL_PARAMETERS;
    assign add_allocation_sp=allowed && operation==spk286_microcode_pkg::MC_ADD_ALLOCATION_SP && allocation_valid_q && !iret_outer_required;
    logic [15:0] auxiliary_q, allocation_q, frame_address_q;
    logic auxiliary_valid_q, allocation_valid_q, frame_address_valid_q, counter_valid_q;
    logic [4:0] counter_q;
    logic frame_read_gpr, frame_write_gpr, save_auxiliary, restore_auxiliary;
    logic save_allocation, load_counter, decrement_counter, counter_branch;
    logic check_push8, check_pop8, begin_stack_cursor, read_stack_cursor, check_stack_word, check_rm32, check_bounds;
    logic set_frame_address, read_frame_address, decrement_frame_address, allocate_stack, set_ea_plus2;
    logic push8_invalid, pop8_invalid, stack_cursor_valid_q, stack_arch_write;
    logic begin_return_cursor, protected_return_cursor_q, return_same_sp_commit, add_allocation_arch;
    logic segment_pop_sp_commit;
    logic [15:0] stack_cursor_q, return_stack_pointer;
    assign stack_arch_write = stack_write_sp && !(stack_cursor_valid_q || begin_return_cursor);
    // Keep a tentative SP until protected returns or POP Sreg validate all
    // descriptors. A fault must leave the original SS:SP restartable.
    assign begin_return_cursor = protected_msw[0] && (check_pop2 ||
                                 (allowed && operation == spk286_microcode_pkg::MC_TASK_RETURN && !architectural_flags[14]) ||
                                 (segment_pop_opcode && pop_operation && !stack_cursor_valid_q));
    assign return_stack_pointer = protected_return_cursor_q ? stack_cursor_q : stack_pointer;
    assign add_allocation_arch = add_allocation_sp && !protected_return_cursor_q;
    logic [2:0] frame_read_index, frame_write_index;
    logic [15:0] stack_native_offset;
    assign frame_read_gpr = allowed && operation >= spk286_microcode_pkg::MC_READ_AX_TMP0 && operation <= spk286_microcode_pkg::MC_READ_DI_TMP0;
    assign frame_write_gpr = allowed && operation >= spk286_microcode_pkg::MC_WRITE_AX_TMP0 && operation <= spk286_microcode_pkg::MC_WRITE_DI_TMP0 && temporary_valid_q[0];
    assign frame_read_index = 3'(operation - spk286_microcode_pkg::MC_READ_AX_TMP0);
    assign frame_write_index = 3'(operation - spk286_microcode_pkg::MC_WRITE_AX_TMP0);
    assign save_auxiliary = allowed && operation == spk286_microcode_pkg::MC_SAVE_AUX_TMP0 && temporary_valid_q[0];
    assign restore_auxiliary = allowed && operation == spk286_microcode_pkg::MC_RESTORE_AUX_TMP0 && auxiliary_valid_q;
    assign save_allocation = allowed && operation == spk286_microcode_pkg::MC_SAVE_ALLOCATION_TMP0 && temporary_valid_q[0];
    assign load_counter = allowed && operation == spk286_microcode_pkg::MC_LOAD_COUNTER_TMP1 && temporary_valid_q[1];
    assign decrement_counter = allowed && operation == spk286_microcode_pkg::MC_DECREMENT_COUNTER && counter_valid_q && counter_q != 0;
    assign counter_branch = allowed && counter_valid_q && (operation == spk286_microcode_pkg::MC_BRANCH_ZERO || operation == spk286_microcode_pkg::MC_BRANCH_NONZERO);
    assign counter_branch_request = (counter_branch && ((operation == spk286_microcode_pkg::MC_BRANCH_ZERO) == (counter_q == 0))) ||
                                    (string_empty && repeat_kind != 0 && count_value == 0) || (string_continue && string_again);
    assign check_push8 = allowed && operation == spk286_microcode_pkg::MC_CHECK_PUSH8;
    assign check_pop8 = allowed && operation == spk286_microcode_pkg::MC_CHECK_POP8;
    assign begin_stack_cursor = allowed && operation == spk286_microcode_pkg::MC_BEGIN_STACK_CURSOR;
    assign read_stack_cursor = allowed && operation == spk286_microcode_pkg::MC_READ_STACK_CURSOR_TMP0 && stack_cursor_valid_q;
    assign check_stack_word = allowed && operation == spk286_microcode_pkg::MC_CHECK_STACK_TMP0 && temporary_valid_q[0];
    assign check_rm32 = allowed && operation == spk286_microcode_pkg::MC_CHECK_RM32;
    assign check_bounds = allowed && operation == spk286_microcode_pkg::MC_CHECK_BOUNDS && auxiliary_valid_q && &temporary_valid_q[1:0];
    logic stack_range_fault;
    assign stack_range_fault = (check_push2 && stack_pointer[0] && stack_pointer<16'd4) ||
                         (check_pop2 && stack_pointer[0] && stack_pointer>=16'hFFFD) || (check_push8 && push8_invalid) || (check_pop8 && pop8_invalid) ||
                         (check_stack_word && tmp0_q == 16'hFFFF) || iret_outer_range_fault ||
                         call_stack_range_fault;
    assign range_fault = string_range_fault || stack_range_fault ||
                         (check_rm32 && effective_offset[0] && effective_offset > 16'hFFFC);
    assign bounds_fault = check_bounds && ($signed(tmp1_q) < $signed(auxiliary_q) || $signed(tmp1_q) > $signed(tmp0_q));
    assign set_frame_address = allowed && operation == spk286_microcode_pkg::MC_SET_STACK_ADDRESS_TMP0 && temporary_valid_q[0];
    assign read_frame_address = allowed && operation == spk286_microcode_pkg::MC_READ_STACK_ADDRESS_TMP0 && frame_address_valid_q;
    assign decrement_frame_address = allowed && operation == spk286_microcode_pkg::MC_DECREMENT_STACK_ADDRESS && frame_address_valid_q;
    assign allocate_stack = allowed && operation == spk286_microcode_pkg::MC_ALLOCATE_STACK && allocation_valid_q && stack_cursor_valid_q;
    assign set_ea_plus2 = allowed && operation == spk286_microcode_pkg::MC_SET_EA_PLUS2;
    // Finish the independent arithmetic before the late operation selector.
    // Keep these combinational boundaries to prevent an arithmetic-sharing
    // rewrite from moving the selector back into the carry path.
    (* keep *) logic [15:0] call_parameter_write_offset;
    (* keep *) logic [15:0] iret_parameter_bytes;
    (* keep *) logic [15:0] iret_outer_stack_offset;
    assign call_parameter_write_offset = stack_cursor_q - 16'd2;
    assign iret_parameter_bytes = allocation_valid_q ? allocation_q : 16'd0;
    assign iret_outer_stack_offset = return_stack_pointer + iret_parameter_bytes;
    logic call_parameter_read_data_select, call_parameter_write_data_select, iret_outer_data_select, frame_address_data_select;
    assign call_parameter_read_data_select = operation == spk286_microcode_pkg::MC_COPY_CALL_PARAMETERS &&
                                            call_gate_outer_required && call_parameter_active_q && call_parameter_phase_q == 2'd0;
    assign call_parameter_write_data_select = operation == spk286_microcode_pkg::MC_COPY_CALL_PARAMETERS &&
                                             call_gate_outer_required && call_parameter_active_q && call_parameter_phase_q == 2'd1;
    assign iret_outer_data_select = operation == spk286_microcode_pkg::MC_IRET_OUTER_FRAME &&
                                    iret_outer_required && iret_outer_phase_q < 2'd2;
    assign frame_address_data_select = operation == spk286_microcode_pkg::MC_READ_STACK_ADDRESS_TMP0 && frame_address_valid_q;
    assign stack_offset = call_parameter_read_data_select ? call_parameter_source_sp_q :
                          call_parameter_write_data_select ? call_parameter_write_offset :
                          iret_outer_data_select ? iret_outer_stack_offset :
                          frame_address_data_select ? frame_address_q : stack_native_offset;

    logic [15:0] tmp0_q, tmp1_q, tmp2_q, flags_q, flags_mask_q;
    logic system_active_q;
    logic [1:0] system_index_q;
    logic [15:0] system_limit_q;
    logic [23:0] system_base_q;
    logic system_operation, system_table_operation, system_table_store, system_table_load;
    logic system_msw_store, system_msw_load, system_ldtr_store, system_tr_store;
    logic system_verify_read, system_verify_write;
    logic system_privilege_fault, system_mode_fault, system_protected_check, system_privilege_check, halt_privilege_fault;
    logic arpl_check_operation, arpl_operation, arpl_adjust, arpl_commit, arpl_fault;
    logic clts_operation, clts_commit, clts_privilege_fault, clts_lock_fault, clts_fault;
    logic npx_esc_check, npx_wait_check, npx_fault;
    // Intel 286 PRM 10.2.2: ESC traps on EM || TS, WAIT on MP && TS.
    // These CPU-side checks apply in both modes and at every CPL. No NPX
    // interface is modeled; the no-coprocessor profile has BUSY inactive.
    assign npx_esc_check = allowed && operation == spk286_microcode_pkg::MC_CHECK_NPX_ESC;
    assign npx_wait_check = allowed && operation == spk286_microcode_pkg::MC_CHECK_NPX_WAIT;
    assign npx_fault = (npx_esc_check && (protected_msw[2] || protected_msw[3])) ||
                       (npx_wait_check && protected_msw[1] && protected_msw[3]);
    logic system_selector_store, system_operand_request, system_operand_write;
    logic system_operand_done, system_done, system_begin, system_is_gdtr;
    logic [15:0] system_write_data;
    logic [15:0] system_selected_limit;
    logic [23:0] system_selected_base;
    logic muldiv_request, muldiv_complete, muldiv_valid, muldiv_write, muldiv_fault;
    logic muldiv_byte, muldiv_immediate, unused_muldiv_ready, result_high_pending_q;
    logic write_result_ax, write_result_dx, fixed_result_write;
    logic [15:0] muldiv_low, muldiv_high, muldiv_flags, muldiv_mask;
    assign muldiv_byte = operation == spk286_microcode_pkg::MC_MULDIV8;
    assign muldiv_immediate = operation == spk286_microcode_pkg::MC_IMUL_IMM16;
    assign muldiv_request = allowed && (muldiv_byte || muldiv_immediate || operation == spk286_microcode_pkg::MC_MULDIV16) &&
                            temporary_valid_q[0] && (!muldiv_immediate || temporary_valid_q[1]) && !flags_valid_q;
    assign muldiv_complete = muldiv_request && muldiv_valid;
    assign write_result_ax = allowed && operation == spk286_microcode_pkg::MC_WRITE_RESULT_AX16 && temporary_valid_q[2];
    assign write_result_dx = allowed && operation == spk286_microcode_pkg::MC_WRITE_RESULT_DX16 && auxiliary_valid_q && result_high_pending_q;
    assign fixed_result_write = (write_result_ax || write_result_dx) && !result_suppress_q;
    spk286_muldiv muldiv_service (
        .clk(clk), .reset(reset), .cancel(cancel || start), .enable(operation_valid),
        .request_valid(muldiv_request), .request_ready(unused_muldiv_ready),
        .kind(muldiv_immediate ? 2'd1 : muldiv_kind), .operand_byte(muldiv_byte),
        .dividend(muldiv_immediate ? {16'd0,tmp1_q} : {register_state[32 +: 16],register_state[0 +: 16]}),
        .source(tmp0_q), .response_valid(muldiv_valid), .response_ready(muldiv_request),
        .result_low(muldiv_low), .result_high(muldiv_high), .candidate_flags(muldiv_flags), .flags_mask(muldiv_mask),
        .result_write(muldiv_write), .arithmetic_fault(muldiv_fault)
    );

    logic adjust_request, adjust_complete, adjust_valid, adjust_write, adjust_fault;
    logic unused_adjust_ready, arithmetic_fault_q, check_arithmetic;
    logic [15:0] adjust_result, adjust_flags, adjust_mask;
    assign adjust_request = allowed && operation == spk286_microcode_pkg::MC_ADJUST && &temporary_valid_q[1:0] && !flags_valid_q;
    assign adjust_complete = adjust_request && adjust_valid;
    assign check_arithmetic = allowed && operation == spk286_microcode_pkg::MC_CHECK_ARITHMETIC;
    assign arithmetic_fault = check_arithmetic && arithmetic_fault_q;
    logic read_segment;
    assign read_segment = allowed && operation == spk286_microcode_pkg::MC_READ_SEG16_TMP0;
    assign segment_write = allowed && operation == spk286_microcode_pkg::MC_WRITE_SEG16_TMP0 &&
                           temporary_valid_q[0] && !protected_msw[0];
    assign segment_write_data = tmp0_q;
    assign system_table_store = allowed && (operation == spk286_microcode_pkg::MC_SYSTEM_STORE_GDTR || operation == spk286_microcode_pkg::MC_SYSTEM_STORE_IDTR);
    assign system_table_load = allowed && (operation == spk286_microcode_pkg::MC_SYSTEM_LOAD_GDTR || operation == spk286_microcode_pkg::MC_SYSTEM_LOAD_IDTR);
    assign system_msw_store = allowed && operation == spk286_microcode_pkg::MC_SYSTEM_STORE_MSW;
    assign system_msw_load = allowed && operation == spk286_microcode_pkg::MC_SYSTEM_LOAD_MSW;
    assign system_ldtr_store = allowed && operation == spk286_microcode_pkg::MC_SYSTEM_STORE_LDTR;
    assign system_tr_store = allowed && operation == spk286_microcode_pkg::MC_SYSTEM_STORE_TR;
    // Mode/privilege checks are explicit microcode operations before the
    // operand read. SLDT/STR themselves are unprivileged in protected mode.
    assign system_protected_check = allowed && operation == spk286_microcode_pkg::MC_CHECK_PROTECTED_MODE;
    assign system_privilege_check = allowed && operation == spk286_microcode_pkg::MC_CHECK_SYSTEM_PRIVILEGE;
    assign system_mode_fault = !protected_msw[0] && (system_protected_check || system_privilege_check ||
                                                   system_ldtr_store || system_tr_store);
    assign system_privilege_fault = protected_msw[0] && protected_cpl != 2'd0 &&
                                    (system_table_load || system_msw_load || system_privilege_check ||
                                     descriptor_load_ldtr || descriptor_load_tr);
    assign system_verify_read = allowed && operation == spk286_microcode_pkg::MC_SYSTEM_VERIFY_READ;
    assign system_verify_write = allowed && operation == spk286_microcode_pkg::MC_SYSTEM_VERIFY_WRITE;
    assign arpl_check_operation = allowed && operation == spk286_microcode_pkg::MC_SYSTEM_ARPL_CHECK;
    assign arpl_operation = allowed && operation == spk286_microcode_pkg::MC_SYSTEM_ARPL && &temporary_valid_q[1:0];
    assign arpl_adjust = arpl_operation && (tmp0_q[1:0] < tmp1_q[1:0]);
    assign arpl_commit = arpl_operation && protected_msw[0] && !lock_prefix && (!arpl_adjust || operand_done);
    assign arpl_fault = arpl_check_operation && (lock_prefix || !protected_msw[0]);
    assign clts_operation = allowed && operation == spk286_microcode_pkg::MC_SYSTEM_CLTS;
    assign clts_lock_fault = clts_operation && lock_prefix;
    assign clts_privilege_fault = clts_operation && !lock_prefix && protected_msw[0] && protected_cpl != 2'd0;
    assign clts_fault = clts_lock_fault || clts_privilege_fault;
    assign clts_commit = clts_operation && !clts_fault;
    assign system_selector_store = system_ldtr_store || system_tr_store;
    assign system_table_operation = system_table_store || system_table_load;
    assign system_operation = system_table_operation || system_msw_store || system_msw_load || system_selector_store;
    assign system_is_gdtr = operation == spk286_microcode_pkg::MC_SYSTEM_STORE_GDTR || operation == spk286_microcode_pkg::MC_SYSTEM_LOAD_GDTR;
    assign system_selected_limit = system_is_gdtr ? protected_gdtr_limit : protected_idtr_limit;
    assign system_selected_base = system_is_gdtr ? protected_gdtr_base : protected_idtr_base;
    // Table operands span six bytes. Expand-down segments admit offsets
    // above their limit, with the same non-wrapping 16-bit upper boundary.
    assign system_limit_fault = system_table_operation && !operand_register_direct &&
                                (USE_PARALLEL_SYSTEM_LIMIT ? parallel_system_limit_fault : segment_expand_down ?
                                 (effective_offset <= segment_limit ||
                                  {1'b0, effective_offset} + 17'd5 > 17'h0FFFF) :
                                 ({1'b0, effective_offset} + 17'd5 > {1'b0, segment_limit}));
    assign system_begin = system_operation && !system_active_q && !system_limit_fault && !system_privilege_fault && !system_mode_fault;
    assign system_operand_request = system_active_q && system_operation && !system_limit_fault && !system_privilege_fault && !system_mode_fault;
    assign system_operand_write = system_operand_request && (system_table_store || system_msw_store || system_selector_store);
    assign system_operand_done = system_operand_request && operand_done;
    assign system_done = system_operand_done && (!system_table_operation || system_index_q == 2'd2);
    assign system_write_data = system_ldtr_store ? protected_ldtr_selector :
                               system_tr_store ? protected_tr_selector :
                               system_msw_store ? protected_msw :
                               system_index_q == 2'd0 ? system_selected_limit :
                               system_index_q == 2'd1 ? system_selected_base[15:0] :
                               // Intel leaves byte six undefined; use the
                               // 286 FF convention used by OS/2 and 86Box.
                               {8'hFF, system_selected_base[23:16]};
    assign protected_msw_load_en = task_commit_tr_write || (system_msw_load && system_operand_done) || clts_commit;
    assign protected_msw_load_data = task_commit_tr_write ? (protected_msw | 16'h0008) :
                                     clts_commit ? (protected_msw & 16'hFFF7) : operand_read_data;
    assign protected_msw_load_mask = task_commit_tr_write ? 16'h0008 : clts_commit ? 16'h0008 : 16'h000F;
    assign protected_gdtr_load_en = system_table_load && system_operand_done && system_index_q == 2'd2 && system_is_gdtr;
    assign protected_idtr_load_en = system_table_load && system_operand_done && system_index_q == 2'd2 && !system_is_gdtr;
    assign protected_gdtr_load_limit = system_limit_q;
    assign protected_idtr_load_limit = system_limit_q;
    assign protected_gdtr_load_base = {((system_index_q == 2'd2) ? operand_read_data[7:0] : system_base_q[23:16]), system_base_q[15:0]};
    assign protected_idtr_load_base = protected_gdtr_load_base;

    logic descriptor_active_q;
    logic [2:0] descriptor_phase_q;
    logic [15:0] descriptor_word0_q, descriptor_word1_q, descriptor_word2_q, descriptor_word3_q;
    logic descriptor_load_ldtr, descriptor_load_tr, descriptor_load_operation;
    logic descriptor_verify_read, descriptor_verify_write, descriptor_verify_operation;
    logic descriptor_load_access, descriptor_load_limit, descriptor_inspect_operation;
    logic segment_reload_operation, cs_validation_operation, call_ss_validation_operation;
    logic descriptor_segment_null_commit, descriptor_segment_success_live, descriptor_cs_success_live;
    logic descriptor_cs_access_valid;
    logic descriptor_begin, descriptor_operand_done, descriptor_operation_done;
    logic descriptor_write, descriptor_null_commit, descriptor_success_live, descriptor_success_q;
    logic descriptor_verify_success_live, descriptor_verify_negative, descriptor_inspect_negative;
    logic descriptor_inspect_success_live, descriptor_verify_flags_write, descriptor_inspect_flags_write;
    logic descriptor_result_write;
    logic [15:0] descriptor_result_data;
    logic descriptor_read_begin, descriptor_pre_fault, descriptor_post_fault;
    logic descriptor_low_valid, descriptor_low_reserved_valid, descriptor_high_word_valid;
    logic [15:0] descriptor_limit;
    logic [23:0] descriptor_base;
    logic [7:0] descriptor_access_rights;
    logic [3:0] descriptor_class;
    logic descriptor_valid, descriptor_reserved_valid, descriptor_present;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [12:0] descriptor_unused_index;
    logic [1:0] descriptor_unused_rpl;
    logic [20:0] descriptor_unused_end;
    logic descriptor_unused_selector_valid;
    logic descriptor_unused_segment, descriptor_unused_executable, descriptor_unused_conforming;
    logic descriptor_unused_expand_down, descriptor_unused_readable, descriptor_unused_writable, descriptor_unused_accessed;
    logic [1:0] descriptor_unused_dpl;
    logic [15:0] descriptor_unused_gate_selector, descriptor_unused_gate_offset;
    logic [4:0] descriptor_unused_gate_parameter_count;
    /* verilator lint_on UNUSEDSIGNAL */
    logic descriptor_selector_ti, descriptor_selector_null, descriptor_selector_limit_valid;
    logic [15:0] descriptor_selector_value;
    logic [23:0] descriptor_selector_address;
    logic descriptor_selector_carry;
    logic [15:0] descriptor_table_limit;
    logic [23:0] descriptor_table_base;
    logic [1:0] descriptor_effective_privilege;
    logic descriptor_cs_offset_fault, cs_validation_success_event;
    logic call_gate_validation_operation, call_gate_cs_validation_operation;
    logic jmp_gate_probe_operation, jmp_gate_cs_validation_operation, jmp_gate_target_begin;
    logic descriptor_call_gate_access_valid, descriptor_call_gate_cs_access_valid;
    logic call_stack_validation_operation, call_gate_stack_switch_operation;
    logic call_gate_stack_switch_begin, call_gate_stack_switch_active_q;
    logic call_gate_stack_write, call_gate_stack_write_done;
    logic [1:0] call_gate_stack_switch_phase_q;
    logic [15:0] call_gate_stack_data_q;
    logic call_parameter_active_q, call_parameter_read, call_parameter_write;
    logic call_parameter_read_done, call_parameter_write_done, call_parameter_operation_done;
    logic [1:0] call_parameter_phase_q;
    logic [4:0] call_parameter_remaining_q;
    logic [15:0] call_parameter_source_sp_q, call_parameter_data_q;
    logic call_gate_outer_required, call_tss_active_q, call_tss_active_state_q, call_tss_operand_done;
    logic call_tss_pre_fault, call_stack_ready_q, call_stack_range_fault;
    logic [1:0] call_tss_phase_q;
    logic [15:0] call_stack_sp_q, call_stack_ss_q, call_tss_phase_offset;
    logic [1:0] call_gate_target_dpl_q;
    logic [4:0] call_gate_parameter_count_q;
    logic call_ss_candidate_valid_q;
    logic [15:0] call_ss_selector_q, call_ss_limit_q;
    logic [23:0] call_ss_base_q;
    logic [7:0] call_ss_access_q;
    logic [3:0] call_ss_class_q;
    logic [1:0] call_ss_dpl_q, call_ss_rpl_q;
    logic call_ss_present_q, call_ss_table_q;
    logic [16:0] call_gate_frame_bytes;
    logic [5:0] call_gate_frame_words;
    logic [4:0] call_parameter_last_word;
    logic [16:0] call_parameter_last_byte;
    logic iret_cs_validation_operation, iret_ss_validation_operation;
    logic iret_outer_frame_operation, iret_outer_required;
    logic iret_outer_pop, iret_outer_pop_done, iret_outer_range_fault;
    logic iret_outer_ready_q, iret_ss_candidate_valid_q;
    logic [1:0] iret_outer_phase_q;
    logic [15:0] iret_outer_sp_q, iret_outer_ss_q;
    logic [15:0] iret_ss_selector_q, iret_ss_limit_q;
    logic [23:0] iret_ss_base_q;
    logic [7:0] iret_ss_access_q;
    logic [3:0] iret_ss_class_q;
    logic [1:0] iret_ss_dpl_q, iret_ss_rpl_q;
    logic iret_ss_present_q, iret_ss_table_q;
    logic descriptor_iret_cs_success_live, descriptor_iret_ss_success_live;
    logic descriptor_call_ss_success_live;
    logic descriptor_call_gate_success_live, descriptor_call_gate_cs_success_live;
    logic descriptor_cs_candidate_success_live;
    logic task_gate_success_live, task_gate_target_begin, task_gate_target_active_q;
    logic task_gate_nested_call_q;
    logic [15:0] task_gate_target_selector_q;

    logic event_gate_active_q;
    logic [2:0] event_gate_phase_q;
    logic [15:0] event_gate_word0_q, event_gate_word1_q, event_gate_word2_q, event_gate_word3_q;
    logic event_gate_operation, event_gate_ip_operation, event_gate_cs_operation;
    logic event_gate_begin, event_gate_operand_done, event_gate_pre_fault, event_gate_post_fault;
    logic event_gate_operation_done, event_gate_success_live, event_gate_limit_fault;
    logic event_gate_candidate_valid_q;
    logic [15:0] event_gate_target_selector_q, event_gate_target_offset_q;
    logic [3:0] event_gate_class_q;
    logic [15:0] event_gate_entry_offset;
    logic event_gate_low_valid, event_gate_low_reserved_valid, event_gate_high_word_valid;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] event_gate_limit;
    logic [7:0] event_gate_access_rights;
    logic [3:0] event_gate_class;
    logic event_gate_valid, event_gate_reserved_valid, event_gate_present;
    logic event_gate_unused_segment, event_gate_unused_executable, event_gate_unused_conforming;
    logic event_gate_unused_expand_down, event_gate_unused_readable, event_gate_unused_writable, event_gate_unused_accessed;
    logic [1:0] event_gate_dpl;
    logic [15:0] event_gate_target_selector, event_gate_target_offset;
    logic [4:0] event_gate_parameter_count;
    /* verilator lint_on UNUSEDSIGNAL */
    logic event_gate_vector_ip, event_gate_vector_cs, clear_event_flags;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [23:0] event_gate_unused_base;
    /* verilator lint_on UNUSEDSIGNAL */
    logic cs_candidate_valid_q;
    logic [15:0] cs_candidate_selector_q, cs_candidate_limit_q;
    logic [23:0] cs_candidate_base_q;
    logic [7:0] cs_candidate_access_q;
    logic [3:0] cs_candidate_class_q;
    logic [1:0] cs_candidate_dpl_q, cs_candidate_rpl_q;
    logic cs_candidate_present_q, cs_candidate_table_q;
    logic call_gate_candidate_valid_q;

    logic task_descriptor_candidate_valid_q;
    logic [15:0] task_descriptor_selector_q, task_descriptor_limit_q;
    logic [23:0] task_descriptor_base_q, task_descriptor_address_q;
    logic [7:0] task_descriptor_access_q;
    logic task_switch_operation, task_switch_skip;
    logic task_return_operation, task_return_start, task_return_skip;
    logic task_return_noop, task_return_commit_done, task_return_finish, task_return_started_q;
    logic task_descriptor_success_live;
    logic task_descriptor_privilege_valid;
    logic task_commit_active_q;
    logic task_event_switch_done_q, task_event_switch_skip;
    logic [3:0] task_commit_phase_q;
    logic task_commit_gpr_write, task_commit_flags_write, task_commit_redirect;
    logic task_commit_segment_write, task_commit_segment_write2, task_commit_tr_write, task_commit_ldtr_write;
    logic task_commit_done;
    logic task_commit_done_q;
    logic task_service_complete_q;
    logic [2:0] task_primary_cache_index, task_secondary_cache_index;

    assign descriptor_load_ldtr = allowed && operation == spk286_microcode_pkg::MC_SYSTEM_LOAD_LDTR;
    assign descriptor_load_tr = allowed && operation == spk286_microcode_pkg::MC_SYSTEM_LOAD_TR;
    assign descriptor_verify_read = system_verify_read;
    assign descriptor_verify_write = system_verify_write;
    assign descriptor_verify_operation = descriptor_verify_read || descriptor_verify_write;
    assign descriptor_load_access = allowed && operation == spk286_microcode_pkg::MC_SYSTEM_LOAD_ACCESS;
    assign descriptor_load_limit = allowed && operation == spk286_microcode_pkg::MC_SYSTEM_LOAD_LIMIT;
    assign descriptor_inspect_operation = descriptor_load_access || descriptor_load_limit;
    assign segment_reload_operation = allowed && operation == spk286_microcode_pkg::MC_WRITE_SEG16_TMP0 &&
                                     temporary_valid_q[0] && protected_msw[0];
    // A far CALL may name code directly. Only a resolved call gate grants
    // gate-target privilege rules; direct calls use the ordinary CS checks,
    // accessed-bit update and CPL-preserving cache commit shared with JMP.
    // VALIDATE_CS resolves a JMP call gate within the descriptor service.
    // An IDT event already has its own gate and must only validate code here.
    assign jmp_gate_cs_validation_operation = allowed && protected_msw[0] &&
                                              operation == spk286_microcode_pkg::MC_VALIDATE_CS &&
                                              call_gate_candidate_valid_q && !event_gate_candidate_valid_q;
    assign cs_validation_operation = allowed && protected_msw[0] &&
                                     ((operation == spk286_microcode_pkg::MC_VALIDATE_CS &&
                                       !jmp_gate_cs_validation_operation) ||
                                      (operation == spk286_microcode_pkg::MC_VALIDATE_CALL_CS &&
                                       !call_gate_candidate_valid_q));
    assign jmp_gate_probe_operation = cs_validation_operation &&
                                      operation == spk286_microcode_pkg::MC_VALIDATE_CS &&
                                      !event_gate_candidate_valid_q;
    assign call_gate_validation_operation = allowed && operation == spk286_microcode_pkg::MC_VALIDATE_CALL_GATE && protected_msw[0];
    assign call_gate_cs_validation_operation = jmp_gate_cs_validation_operation ||
                                               (allowed && operation == spk286_microcode_pkg::MC_VALIDATE_CALL_CS &&
                                                protected_msw[0] && call_gate_candidate_valid_q);
    assign call_stack_validation_operation = allowed && operation == spk286_microcode_pkg::MC_VALIDATE_CALL_STACK;
    assign call_ss_validation_operation = allowed && operation == spk286_microcode_pkg::MC_VALIDATE_CALL_SS && protected_msw[0];
    assign call_gate_stack_switch_operation = allowed && operation == spk286_microcode_pkg::MC_CALL_GATE_STACK_SWITCH;
    assign iret_cs_validation_operation = allowed && operation == spk286_microcode_pkg::MC_VALIDATE_IRET_CS && protected_msw[0];
    assign iret_outer_frame_operation = allowed && operation == spk286_microcode_pkg::MC_IRET_OUTER_FRAME;
    assign iret_ss_validation_operation = allowed && operation == spk286_microcode_pkg::MC_VALIDATE_IRET_SS && protected_msw[0];
    assign descriptor_load_operation = descriptor_load_ldtr || descriptor_load_tr || descriptor_verify_operation ||
                                      descriptor_inspect_operation || segment_reload_operation || cs_validation_operation ||
                                      call_gate_validation_operation || call_gate_cs_validation_operation || call_ss_validation_operation ||
                                      iret_cs_validation_operation || iret_ss_validation_operation;
    assign descriptor_selector_value = (cs_validation_operation || call_gate_validation_operation ||
                                        call_gate_cs_validation_operation || iret_cs_validation_operation) ?
                                       (task_gate_target_active_q ? task_gate_target_selector_q : tmp1_q) :
                                       iret_ss_validation_operation ? iret_outer_ss_q :
                                       call_ss_validation_operation ? call_stack_ss_q : tmp0_q;
    assign descriptor_begin = descriptor_load_operation &&
                              ((cs_validation_operation || call_gate_validation_operation || call_gate_cs_validation_operation ||
                                iret_cs_validation_operation) ? temporary_valid_q[1] :
                               iret_ss_validation_operation ? iret_outer_ready_q :
                               call_ss_validation_operation ? call_stack_ready_q : temporary_valid_q[0]) &&
                              !descriptor_active_q;
    assign descriptor_table_limit = descriptor_selector_ti ? protected_ldtr_limit : protected_gdtr_limit;
    assign descriptor_table_base = descriptor_selector_ti ? protected_ldtr_base : protected_gdtr_base;
    spk286_selector descriptor_selector (
        .selector(descriptor_selector_value), .table_limit(descriptor_table_limit), .table_base(descriptor_table_base),
        .index(descriptor_unused_index), .table_indicator(descriptor_selector_ti), .rpl(descriptor_unused_rpl),
        .null_selector(descriptor_selector_null), .descriptor_end(descriptor_unused_end),
        .descriptor_limit_valid(descriptor_selector_limit_valid),
        .descriptor_selector_valid(descriptor_unused_selector_valid),
        .descriptor_address(descriptor_selector_address), .descriptor_address_carry(descriptor_selector_carry)
    );
    assign descriptor_pre_fault = descriptor_begin &&
                                  (!protected_msw[0] ||
                                   ((descriptor_load_ldtr || descriptor_load_tr) &&
                                    (descriptor_selector_ti || descriptor_selector_carry ||
                                     (!descriptor_selector_null && !descriptor_selector_limit_valid) ||
                                     (descriptor_load_tr && descriptor_selector_null))) ||
                                   (segment_reload_operation &&
                                    (descriptor_selector_carry ||
                                     (!descriptor_selector_null && !descriptor_selector_limit_valid) ||
                                     (descriptor_selector_null && segment_index == 2'd2))) ||
                                   ((cs_validation_operation || call_gate_validation_operation || call_gate_cs_validation_operation ||
                                      iret_cs_validation_operation) &&
                                    (descriptor_selector_carry || descriptor_selector_null ||
                                     (!descriptor_selector_limit_valid) ||
                                     (descriptor_selector_ti && (!protected_ldtr_valid || !protected_ldtr_present)))) ||
                                   (call_ss_validation_operation &&
                                    (descriptor_selector_carry || descriptor_selector_null ||
                                     (!descriptor_selector_limit_valid) ||
                                     (descriptor_selector_ti && (!protected_ldtr_valid || !protected_ldtr_present)))) ||
                                   (iret_ss_validation_operation &&
                                    (descriptor_selector_carry || descriptor_selector_null ||
                                     (!descriptor_selector_limit_valid) ||
                                     (descriptor_selector_ti && (!protected_ldtr_valid || !protected_ldtr_present)))));
    assign descriptor_verify_negative = descriptor_begin && descriptor_verify_operation && !descriptor_pre_fault &&
                                       (descriptor_selector_null || descriptor_selector_carry ||
                                        !descriptor_selector_limit_valid ||
                                        (descriptor_selector_ti && (!protected_ldtr_valid || !protected_ldtr_present)));
    assign descriptor_inspect_negative = descriptor_begin && descriptor_inspect_operation && !descriptor_pre_fault &&
                                        (descriptor_selector_null || descriptor_selector_carry ||
                                         !descriptor_selector_limit_valid ||
                                         (descriptor_selector_ti && (!protected_ldtr_valid || !protected_ldtr_present)));
    assign descriptor_segment_null_commit = !descriptor_active_q && segment_reload_operation &&
                                           tmp0_q[15:2] == 14'd0 && segment_index != 2'd2;
    assign descriptor_read_begin = descriptor_begin && !descriptor_pre_fault && !system_privilege_fault && !descriptor_verify_negative && !descriptor_inspect_negative &&
                                   !descriptor_segment_null_commit && !descriptor_selector_null;
    // Only the reserved-form check uses word 3. Reduce both possible words
    // before the late operand-done select, rather than muxing sixteen bits
    // and then reducing them. Code/data segments ignore this word on a 286.
    // The arriving word is read straight from the BIU: a descriptor access
    // always selects memory, so this skips the register/memory operand mux.
    assign descriptor_high_word_valid = descriptor_unused_segment ||
                                       ((descriptor_operand_done && descriptor_phase_q == 3'd3) ?
                                        (memory_read_data == 16'h0000) : (descriptor_word3_q == 16'h0000));
    assign descriptor_valid = descriptor_low_valid && descriptor_high_word_valid;
    assign descriptor_reserved_valid = descriptor_low_reserved_valid && descriptor_high_word_valid;
    spk286_descriptor descriptor_parser (
        .raw_descriptor({16'h0000, descriptor_word2_q, descriptor_word1_q, descriptor_word0_q}), .limit(descriptor_limit), .base(descriptor_base),
        .access_rights(descriptor_access_rights), .descriptor_class(descriptor_class),
        .descriptor_valid(descriptor_low_valid), .reserved_form_valid(descriptor_low_reserved_valid),
        .present(descriptor_present), .segment(descriptor_unused_segment), .executable(descriptor_unused_executable),
        .conforming(descriptor_unused_conforming), .expand_down(descriptor_unused_expand_down),
        .readable(descriptor_unused_readable), .writable(descriptor_unused_writable), .accessed(descriptor_unused_accessed),
        .dpl(descriptor_unused_dpl), .gate_target_selector(descriptor_unused_gate_selector),
        .gate_offset(descriptor_unused_gate_offset), .gate_parameter_count(descriptor_unused_gate_parameter_count)
    );
    logic descriptor_system_access_valid;
    assign descriptor_system_access_valid = descriptor_valid && descriptor_reserved_valid &&
                                     ((descriptor_load_ldtr && descriptor_class == spk286_protected_pkg::DESC_LDT) ||
                                      (descriptor_load_tr && descriptor_class == spk286_protected_pkg::DESC_TSS_AVAIL &&
                                       descriptor_limit >= spk286_tss_pkg::TSS_MIN_LIMIT));
    assign descriptor_success_live = descriptor_system_access_valid && descriptor_present;
    // A TSS named by a task gate is authorized by the gate itself.  This
    // applies to both far CALL/JMP task gates and IDT task gates; the target
    // TSS DPL/RPL must not be re-applied as a direct-transfer check.
    assign task_descriptor_privilege_valid = task_gate_target_active_q ||
                                             (event_gate_candidate_valid_q &&
                                              event_gate_class_q == spk286_protected_pkg::DESC_TASK_GATE) ||
                                             (descriptor_unused_dpl >= protected_cpl &&
                                              descriptor_unused_dpl >= descriptor_unused_rpl);
    logic task_descriptor_access_valid;
    assign task_descriptor_access_valid = descriptor_valid && descriptor_reserved_valid &&
                                          !descriptor_selector_ti &&
                                          descriptor_class == spk286_protected_pkg::DESC_TSS_AVAIL &&
                                          task_descriptor_privilege_valid;
    assign task_descriptor_success_live = task_descriptor_access_valid && descriptor_present;
    assign descriptor_cs_access_valid = descriptor_valid && descriptor_reserved_valid &&
                                       descriptor_unused_segment && descriptor_class == spk286_protected_pkg::DESC_CODE &&
                                       (event_gate_candidate_valid_q ?
                                        // Gate targets ignore selector RPL. Both conforming
                                        // and non-conforming code require DPL <= source CPL;
                                        // the candidate publication chooses the resulting CPL.
                                        (descriptor_unused_dpl <= protected_cpl) :
                                        ((descriptor_unused_conforming && descriptor_unused_dpl <= protected_cpl) ||
                                         (!descriptor_unused_conforming && descriptor_unused_dpl == protected_cpl &&
                                          descriptor_unused_rpl <= protected_cpl)));
    assign descriptor_cs_success_live = descriptor_cs_access_valid && descriptor_present;
    logic descriptor_iret_cs_access_valid;
    assign descriptor_iret_cs_access_valid = descriptor_valid && descriptor_reserved_valid &&
                                             descriptor_unused_segment && descriptor_class == spk286_protected_pkg::DESC_CODE &&
                                             descriptor_unused_rpl >= protected_cpl &&
                                             ((descriptor_unused_conforming && descriptor_unused_dpl <= descriptor_unused_rpl) ||
                                              (!descriptor_unused_conforming && descriptor_unused_dpl == descriptor_unused_rpl));
    assign descriptor_iret_cs_success_live = descriptor_iret_cs_access_valid && descriptor_present;
    assign descriptor_call_gate_access_valid = descriptor_valid && descriptor_reserved_valid &&
                                              descriptor_class == spk286_protected_pkg::DESC_CALL_GATE &&
                                              descriptor_unused_dpl >= protected_cpl &&
                                              descriptor_unused_dpl >= descriptor_unused_rpl;
    assign descriptor_call_gate_success_live = descriptor_call_gate_access_valid && descriptor_present;
    assign jmp_gate_target_begin = descriptor_operand_done && descriptor_phase_q == 3'd3 &&
                                    jmp_gate_probe_operation && descriptor_call_gate_success_live;
    logic task_gate_access_valid;
    assign task_gate_access_valid = descriptor_valid && descriptor_reserved_valid &&
                                    descriptor_class == spk286_protected_pkg::DESC_TASK_GATE &&
                                    descriptor_unused_dpl >= protected_cpl &&
                                    descriptor_unused_dpl >= descriptor_unused_rpl;
    assign task_gate_success_live = task_gate_access_valid && descriptor_present;
    assign task_gate_target_begin = descriptor_operand_done && descriptor_phase_q == 3'd3 &&
                                    !task_gate_target_active_q &&
                                    (call_gate_validation_operation || cs_validation_operation) &&
                                    task_gate_success_live;
    // Gate target RPL is ignored. JMP preserves CPL: nonconforming code must
    // match it; conforming code may have a numerically smaller DPL. CALL may
    // additionally enter a more privileged nonconforming segment.
    assign descriptor_call_gate_cs_access_valid = descriptor_valid && descriptor_reserved_valid &&
                                                 descriptor_unused_segment && descriptor_class == spk286_protected_pkg::DESC_CODE &&
                                                 descriptor_unused_dpl <= protected_cpl &&
                                                 (!jmp_gate_cs_validation_operation || descriptor_unused_conforming ||
                                                  descriptor_unused_dpl == protected_cpl);
    assign descriptor_call_gate_cs_success_live = descriptor_call_gate_cs_access_valid && descriptor_present;
    assign descriptor_cs_candidate_success_live = call_gate_cs_validation_operation ? descriptor_call_gate_cs_success_live :
                                                   iret_cs_validation_operation ? descriptor_iret_cs_success_live : descriptor_cs_success_live;
    assign descriptor_effective_privilege = descriptor_unused_rpl > protected_cpl ? descriptor_unused_rpl : protected_cpl;
    assign descriptor_verify_success_live = descriptor_valid && descriptor_reserved_valid && descriptor_present &&
                                            descriptor_unused_segment &&
                                            ((descriptor_unused_conforming && descriptor_unused_dpl <= protected_cpl) ||
                                             (!descriptor_unused_conforming && descriptor_unused_dpl >= descriptor_effective_privilege)) &&
                                            ((descriptor_verify_read &&
                                              ((descriptor_class == spk286_protected_pkg::DESC_CODE && descriptor_unused_readable) ||
                                               descriptor_class == spk286_protected_pkg::DESC_DATA ||
                                               descriptor_class == spk286_protected_pkg::DESC_EXPAND_DOWN)) ||
                                             (descriptor_verify_write &&
                                             (descriptor_class == spk286_protected_pkg::DESC_DATA ||
                                               descriptor_class == spk286_protected_pkg::DESC_EXPAND_DOWN) && descriptor_unused_writable));
    // LAR/LSL inspect a visible descriptor even when its segment is absent.
    // In particular, Windows keeps loader metadata in an absent limit field.
    assign descriptor_inspect_success_live = descriptor_valid && descriptor_reserved_valid &&
                                             descriptor_unused_dpl >= descriptor_effective_privilege &&
                                             (descriptor_load_access ||
                                              (descriptor_load_limit &&
                                               ((descriptor_unused_segment && !descriptor_unused_conforming) ||
                                                descriptor_class == spk286_protected_pkg::DESC_TSS_AVAIL ||
                                                descriptor_class == spk286_protected_pkg::DESC_TSS_BUSY ||
                                                descriptor_class == spk286_protected_pkg::DESC_LDT)));
    logic descriptor_iret_ss_access_valid;
    assign descriptor_iret_ss_access_valid = descriptor_valid && descriptor_reserved_valid &&
                                             descriptor_unused_segment &&
                                             (descriptor_class == spk286_protected_pkg::DESC_DATA ||
                                              descriptor_class == spk286_protected_pkg::DESC_EXPAND_DOWN) &&
                                             descriptor_unused_writable &&
                                             descriptor_unused_dpl == tmp1_q[1:0] &&
                                             descriptor_unused_rpl == tmp1_q[1:0];
    assign descriptor_iret_ss_success_live = descriptor_iret_ss_access_valid && descriptor_present;
    logic descriptor_call_ss_access_valid;
    assign descriptor_call_ss_access_valid = descriptor_valid && descriptor_reserved_valid &&
                                             descriptor_unused_segment &&
                                             (descriptor_class == spk286_protected_pkg::DESC_DATA ||
                                              descriptor_class == spk286_protected_pkg::DESC_EXPAND_DOWN) &&
                                             descriptor_unused_writable &&
                                             descriptor_unused_dpl == call_gate_target_dpl_q &&
                                             descriptor_unused_rpl == call_gate_target_dpl_q;
    assign descriptor_call_ss_success_live = descriptor_call_ss_access_valid && descriptor_present;
    assign call_gate_outer_required = protected_msw[0] && call_gate_candidate_valid_q && cs_candidate_valid_q &&
                                     (call_gate_target_dpl_q < protected_cpl) &&
                                     !(cs_candidate_class_q == spk286_protected_pkg::DESC_CODE && cs_candidate_access_q[2]);
    assign call_tss_phase_offset = spk286_tss_pkg::TSS_SP0 +
                                   ({14'd0, call_gate_target_dpl_q} << 2);
    assign call_tss_pre_fault = call_stack_validation_operation && call_gate_outer_required && !call_stack_ready_q &&
                                (!protected_tr_valid || !protected_tr_present || call_gate_target_dpl_q > 2'd2 ||
                                 ({1'b0, call_tss_phase_offset} + 17'd3 > {1'b0, protected_tr_limit}));
    assign call_tss_active_q = call_tss_active_state_q;
    assign call_tss_operand_done = call_tss_active_q && operand_done;
    logic descriptor_segment_access_valid;
    assign descriptor_segment_access_valid = (descriptor_valid && descriptor_reserved_valid &&
                                               (segment_index == 2'd2 ?
                                                ((descriptor_class == spk286_protected_pkg::DESC_DATA ||
                                                  descriptor_class == spk286_protected_pkg::DESC_EXPAND_DOWN) &&
                                                 descriptor_unused_writable && descriptor_unused_dpl == protected_cpl &&
                                                 descriptor_unused_rpl == protected_cpl) :
                                                // Data reads from conforming code ignore DPL/RPL.
                                                (descriptor_unused_segment &&
                                                 (descriptor_unused_conforming ||
                                                  descriptor_unused_dpl >= descriptor_effective_privilege) &&
                                                 (descriptor_class != spk286_protected_pkg::DESC_CODE || descriptor_unused_readable))));
    assign descriptor_segment_success_live = descriptor_segment_null_commit ||
                                             (iret_cs_validation_operation ? descriptor_iret_cs_success_live :
                                              cs_validation_operation ? descriptor_cs_success_live :
                                              (descriptor_segment_access_valid && descriptor_present));
    assign descriptor_result_data = descriptor_load_access ? {descriptor_access_rights, 8'h00} : descriptor_limit;
    assign descriptor_result_write = descriptor_active_q && descriptor_operand_done && descriptor_phase_q == 3'd3 &&
                                     descriptor_inspect_operation && descriptor_inspect_success_live;
    assign descriptor_operand_done = descriptor_active_q && operand_done;
    assign descriptor_cs_offset_fault = (cs_validation_operation || call_gate_cs_validation_operation || iret_cs_validation_operation) && descriptor_operand_done &&
                                       descriptor_phase_q == 3'd3 && descriptor_cs_candidate_success_live &&
                                       ({1'b0, tmp0_q} > {1'b0, descriptor_limit});
    assign descriptor_post_fault = descriptor_operand_done && descriptor_phase_q == 3'd3 &&
                                    (call_gate_validation_operation ?
                                    (task_gate_target_active_q ? !task_descriptor_success_live :
                                     descriptor_class == spk286_protected_pkg::DESC_CALL_GATE ? !descriptor_call_gate_success_live :
                                     descriptor_class == spk286_protected_pkg::DESC_TASK_GATE ? !task_gate_success_live :
                                     descriptor_class == spk286_protected_pkg::DESC_CODE ? !descriptor_cs_success_live :
                                     !task_descriptor_success_live) :
                                   (call_gate_cs_validation_operation ?
                                    (descriptor_cs_offset_fault || !descriptor_call_gate_cs_success_live) :
                                   (call_ss_validation_operation ? !descriptor_call_ss_success_live :
                                   (iret_cs_validation_operation ?
                                   ((({1'b0, tmp0_q} > {1'b0, descriptor_limit}) && descriptor_iret_cs_success_live) || !descriptor_iret_cs_success_live) :
                                    (cs_validation_operation ?
                                     ((jmp_gate_probe_operation && descriptor_class == spk286_protected_pkg::DESC_CALL_GATE) ?
                                       !descriptor_call_gate_success_live :
                                      ((task_descriptor_success_live || task_gate_target_begin) ? 1'b0 :
                                       (descriptor_cs_offset_fault || !descriptor_cs_success_live))) :
                                   (iret_ss_validation_operation ? !descriptor_iret_ss_success_live :
                                    (segment_reload_operation ? !descriptor_segment_success_live :
                                    (!descriptor_verify_operation && !descriptor_inspect_operation && !descriptor_success_live))))))));

    assign event_gate_operation = allowed && operation == spk286_microcode_pkg::MC_VALIDATE_EVENT_GATE;
    assign event_gate_ip_operation = allowed && operation == spk286_microcode_pkg::MC_EVENT_GATE_IP;
    assign event_gate_cs_operation = allowed && operation == spk286_microcode_pkg::MC_EVENT_GATE_CS;
    assign event_gate_begin = event_gate_operation && protected_msw[0] && !event_gate_active_q;
    assign event_gate_entry_offset = {5'd0, event_vector, 3'b000};
    assign event_gate_limit_fault = event_gate_begin &&
                                    ({1'b0, event_gate_entry_offset} + 17'd7 > {1'b0, protected_idtr_limit});
    assign event_gate_pre_fault = event_gate_limit_fault;
    assign event_gate_operand_done = event_gate_active_q && operand_done;
    assign event_gate_high_word_valid = event_gate_unused_segment ||
                                       ((event_gate_operand_done && event_gate_phase_q == 3'd3) ?
                                        (memory_read_data == 16'h0000) : (event_gate_word3_q == 16'h0000));
    assign event_gate_valid = event_gate_low_valid && event_gate_high_word_valid;
    assign event_gate_reserved_valid = event_gate_low_reserved_valid && event_gate_high_word_valid;
    spk286_descriptor event_gate_parser (
        .raw_descriptor({16'h0000, event_gate_word2_q, event_gate_word1_q, event_gate_word0_q}), .limit(event_gate_limit), .base(event_gate_unused_base),
        .access_rights(event_gate_access_rights), .descriptor_class(event_gate_class),
        .descriptor_valid(event_gate_low_valid), .reserved_form_valid(event_gate_low_reserved_valid),
        .present(event_gate_present), .segment(event_gate_unused_segment), .executable(event_gate_unused_executable),
        .conforming(event_gate_unused_conforming), .expand_down(event_gate_unused_expand_down),
        .readable(event_gate_unused_readable), .writable(event_gate_unused_writable), .accessed(event_gate_unused_accessed),
        .dpl(event_gate_dpl), .gate_target_selector(event_gate_target_selector),
        .gate_offset(event_gate_target_offset), .gate_parameter_count(event_gate_parameter_count)
    );
    logic event_gate_access_valid;
    assign event_gate_access_valid = event_gate_valid && event_gate_reserved_valid &&
                                     ((event_gate_class == spk286_protected_pkg::DESC_INT_GATE) ||
                                      (event_gate_class == spk286_protected_pkg::DESC_TRAP_GATE) ||
                                      (event_gate_class == spk286_protected_pkg::DESC_TASK_GATE)) &&
                                     (!event_software || event_gate_dpl >= protected_cpl);
    assign event_gate_success_live = event_gate_access_valid && event_gate_present;
    assign event_gate_post_fault = event_gate_operand_done && event_gate_phase_q == 3'd3 && !event_gate_success_live;
    assign event_gate_operation_done = (event_gate_operation && !protected_msw[0]) ||
                                       event_gate_pre_fault || event_gate_post_fault ||
                                       (event_gate_operand_done && event_gate_phase_q == 3'd3 && event_gate_success_live) ||
                                       ((event_gate_ip_operation || event_gate_cs_operation) && event_gate_candidate_valid_q);
    assign event_gate_vector_ip = event_gate_ip_operation && !protected_msw[0] && !event_gate_candidate_valid_q;
    assign event_gate_vector_cs = event_gate_cs_operation && !protected_msw[0] && !event_gate_candidate_valid_q;
    assign protected_event_access = event_gate_active_q;
    always_comb begin
        protected_event_address = protected_idtr_base + {13'd0, event_vector, 3'b000};
        if (event_gate_phase_q == 3'd1) protected_event_address = protected_event_address + 24'd2;
        else if (event_gate_phase_q == 3'd2) protected_event_address = protected_event_address + 24'd4;
        else if (event_gate_phase_q == 3'd3) protected_event_address = protected_event_address + 24'd6;
    end
    assign descriptor_verify_flags_write = !descriptor_pre_fault &&
                                           (descriptor_verify_negative ||
                                            (descriptor_operand_done && descriptor_phase_q == 3'd3 && descriptor_verify_operation));
    assign descriptor_inspect_flags_write = !descriptor_pre_fault &&
                                            (descriptor_inspect_negative ||
                                             (descriptor_operand_done && descriptor_phase_q == 3'd3 && descriptor_inspect_operation));
    assign descriptor_write = descriptor_active_q && descriptor_phase_q == 3'd4 &&
                               (descriptor_load_tr ||
                                ((segment_reload_operation || cs_validation_operation || call_gate_cs_validation_operation ||
                                  call_ss_validation_operation || iret_cs_validation_operation || iret_ss_validation_operation) && descriptor_success_q));
    assign protected_descriptor_access = descriptor_active_q;
    assign protected_gate_access = event_gate_active_q ||
                                  (descriptor_active_q &&
                                   (call_gate_validation_operation || jmp_gate_probe_operation || task_gate_target_active_q));
    always_comb begin
        protected_descriptor_address = descriptor_selector_address;
        if (descriptor_phase_q == 3'd1) protected_descriptor_address = descriptor_selector_address + 24'd2;
        else if (descriptor_phase_q == 3'd2) protected_descriptor_address = descriptor_selector_address + 24'd4;
        else if (descriptor_phase_q == 3'd3) protected_descriptor_address = descriptor_selector_address + 24'd6;
        else if (descriptor_phase_q == 3'd4) protected_descriptor_address = descriptor_selector_address + 24'd5;
    end
    assign protected_tss_access = call_tss_active_q;
    always_comb begin
        protected_tss_address = protected_tr_base + {8'd0, call_tss_phase_offset};
        if (call_tss_phase_q == 2'd1) protected_tss_address = protected_tss_address + 24'd2;
    end
    assign protected_call_stack_access = call_gate_stack_switch_active_q && call_gate_outer_required &&
                                        stack_request && !read_frame_address && !call_parameter_read;
    assign protected_call_stack_address = call_ss_base_q + {8'd0, stack_offset};
    assign protected_call_stack_limit = call_ss_limit_q;
    assign protected_call_stack_expand_down = call_ss_access_q[2];
    assign descriptor_operation_done = descriptor_verify_negative || descriptor_inspect_negative || descriptor_null_commit ||
                                      (call_ss_validation_operation && !call_gate_outer_required) ||
                                      (descriptor_operand_done && descriptor_phase_q == 3'd3 && descriptor_load_ldtr && descriptor_success_live) ||
                                      (descriptor_operand_done && descriptor_phase_q == 3'd4 && descriptor_load_tr && descriptor_success_q) ||
                                      (descriptor_operand_done && descriptor_phase_q == 3'd3 && descriptor_verify_operation) ||
                                      (descriptor_operand_done && descriptor_phase_q == 3'd3 && descriptor_inspect_operation) ||
                                      descriptor_segment_null_commit ||
                                      (descriptor_operand_done && descriptor_phase_q == 3'd3 && segment_reload_operation &&
                                       descriptor_segment_success_live && descriptor_unused_accessed) ||
                                       (descriptor_operand_done && descriptor_phase_q == 3'd3 && segment_reload_operation &&
                                        !descriptor_segment_success_live) ||
                                      (descriptor_operand_done && descriptor_phase_q == 3'd4 && segment_reload_operation && descriptor_success_q) ||
                                      (descriptor_operand_done && descriptor_phase_q == 3'd3 && call_gate_validation_operation &&
                                        !task_gate_target_begin &&
                                        (task_gate_target_active_q ? task_descriptor_success_live :
                                         descriptor_class == spk286_protected_pkg::DESC_CALL_GATE ? descriptor_call_gate_success_live :
                                         descriptor_class == spk286_protected_pkg::DESC_TASK_GATE ? !task_gate_success_live :
                                         descriptor_class == spk286_protected_pkg::DESC_CODE ? descriptor_cs_success_live :
                                         task_descriptor_success_live)) ||
                                      (descriptor_operand_done && descriptor_phase_q == 3'd3 && call_ss_validation_operation &&
                                       (!descriptor_call_ss_success_live || descriptor_unused_accessed)) ||
                                      (descriptor_operand_done && descriptor_phase_q == 3'd4 && call_ss_validation_operation && descriptor_success_q) ||
                                      (descriptor_operand_done && descriptor_phase_q == 3'd3 && call_gate_cs_validation_operation &&
                                       (descriptor_cs_offset_fault || !descriptor_call_gate_cs_success_live || descriptor_unused_accessed)) ||
                                       (descriptor_operand_done && descriptor_phase_q == 3'd4 && call_gate_cs_validation_operation && descriptor_success_q) ||
                                      (descriptor_operand_done && descriptor_phase_q == 3'd3 && cs_validation_operation &&
                                         (!task_gate_target_begin && !jmp_gate_target_begin && (task_descriptor_success_live ||
                                          (!task_descriptor_success_live &&
                                           (descriptor_cs_offset_fault || !descriptor_cs_success_live || descriptor_unused_accessed))))) ||
                                      (descriptor_operand_done && descriptor_phase_q == 3'd4 && cs_validation_operation && descriptor_success_q) ||
                                      (descriptor_operand_done && descriptor_phase_q == 3'd3 && iret_cs_validation_operation &&
                                       ((({1'b0, tmp0_q} > {1'b0, descriptor_limit}) && descriptor_iret_cs_success_live) ||
                                        !descriptor_iret_cs_success_live || descriptor_unused_accessed)) ||
                                      (descriptor_operand_done && descriptor_phase_q == 3'd4 && iret_cs_validation_operation && descriptor_success_q) ||
                                      (iret_ss_validation_operation && !iret_outer_required) ||
                                      (descriptor_operand_done && descriptor_phase_q == 3'd3 && iret_ss_validation_operation &&
                                       (!descriptor_iret_ss_success_live || descriptor_unused_accessed)) ||
                                      (descriptor_operand_done && descriptor_phase_q == 3'd4 && iret_ss_validation_operation && descriptor_success_q);
    assign cs_validation_success_event = (cs_validation_operation || call_gate_cs_validation_operation || iret_cs_validation_operation) && !descriptor_pre_fault && !descriptor_post_fault &&
                                          ((descriptor_operand_done && descriptor_phase_q == 3'd3 &&
                                            descriptor_cs_candidate_success_live &&
                                            ({1'b0, tmp0_q} <= {1'b0, descriptor_limit}) &&
                                            descriptor_unused_accessed) ||
                                           (descriptor_operand_done && descriptor_phase_q == 3'd4 && descriptor_success_q));
    assign descriptor_null_commit = descriptor_begin && descriptor_selector_null && !descriptor_pre_fault && !system_privilege_fault && descriptor_load_ldtr;
    assign system_fault = npx_fault || task_service_fault || system_mode_fault || system_privilege_fault || io_privilege_fault || halt_privilege_fault || arpl_fault || clts_fault || call_tss_pre_fault || (stack_range_fault && protected_msw[0]) ||
                          descriptor_pre_fault || descriptor_post_fault ||
                          event_gate_pre_fault || event_gate_post_fault;
    // Type/privilege checks precede presence for each transfer class.
    logic descriptor_transfer_access_valid;
    assign descriptor_transfer_access_valid = task_gate_target_active_q ? task_descriptor_access_valid :
                                              descriptor_class == spk286_protected_pkg::DESC_CALL_GATE ? descriptor_call_gate_access_valid :
                                              descriptor_class == spk286_protected_pkg::DESC_TASK_GATE ? task_gate_access_valid :
                                              descriptor_class == spk286_protected_pkg::DESC_CODE ? descriptor_cs_access_valid :
                                              task_descriptor_access_valid;
    assign system_fault_vector = npx_fault ? 8'd7 : task_service_fault ? task_service_fault_vector : system_mode_fault ? 8'd6 : (system_privilege_fault || io_privilege_fault || halt_privilege_fault) ? 8'd13 :
                                 arpl_fault ? 8'd6 :
                                 clts_lock_fault ? 8'd6 :
                                 clts_privilege_fault ? 8'd13 :
                                 !protected_msw[0] ? 8'd6 :
                                 call_tss_pre_fault ? 8'd10 :
                                 stack_range_fault ? 8'd12 :
                                 event_gate_pre_fault ? 8'd13 :
                                 event_gate_post_fault ? (!event_gate_present && event_gate_access_valid ? 8'd11 : 8'd13) :
                                 // A new SS obtained from the TSS has #TS access
                                 // faults, unlike an explicit MOV/POP/return SS.
                                 call_ss_validation_operation ?
                                   (!descriptor_pre_fault && !descriptor_present && descriptor_call_ss_access_valid ? 8'd12 : 8'd10) :
                                 descriptor_pre_fault ? 8'd13 :
                                 jmp_gate_cs_validation_operation ?
                                   (!descriptor_present && descriptor_call_gate_cs_access_valid ? 8'd11 : 8'd13) :
                                 (jmp_gate_probe_operation && descriptor_class == spk286_protected_pkg::DESC_CALL_GATE) ?
                                   (!descriptor_present && descriptor_call_gate_access_valid ? 8'd11 : 8'd13) :
                                 // Direct code transfers check type/privilege before
                                 // presence. A valid absent target requests #NP so
                                 // the OS can load it and retry the instruction.
                                 ((call_gate_validation_operation || cs_validation_operation) &&
                                  descriptor_unused_segment) ?
                                    (!descriptor_present && descriptor_cs_access_valid ? 8'd11 : 8'd13) :
                                  call_gate_validation_operation ?
                                    (!descriptor_present && descriptor_transfer_access_valid ? 8'd11 : 8'd13) :
                                  call_gate_cs_validation_operation ?
                                    (!descriptor_present && descriptor_call_gate_cs_access_valid ? 8'd11 : 8'd13) :
                                  iret_ss_validation_operation ?
                                    (!descriptor_present && descriptor_iret_ss_access_valid ? 8'd12 : 8'd13) :
                                 iret_cs_validation_operation ?
                                   (!descriptor_present && descriptor_iret_cs_access_valid ? 8'd11 : 8'd13) :
                                 cs_validation_operation ?
                                   (!descriptor_present && descriptor_transfer_access_valid ? 8'd11 : 8'd13) :
                                 segment_reload_operation ?
                                   (!descriptor_present && descriptor_segment_access_valid ?
                                    (segment_index == 2'd2 ? 8'd12 : 8'd11) : 8'd13) :
                                 (!descriptor_present && descriptor_system_access_valid ? 8'd11 : 8'd13);
    assign system_fault_error_code = npx_fault ? 16'd0 : task_service_fault ?
                                       ((task_service_fault_error_code & 16'hFFFC) |
                                        (task_fault_external ? 16'h0001 : 16'h0000)) :
                                     (system_mode_fault || system_privilege_fault || io_privilege_fault) ? 16'd0 :
                                     call_tss_pre_fault ? ((protected_tr_selector & 16'hFFFC) |
                                                          (task_fault_external ? 16'h0001 : 16'h0000)) :
                                     (stack_range_fault && protected_msw[0]) ? 16'd0 :
                                     (event_gate_pre_fault || event_gate_post_fault) ?
                                       (event_gate_entry_offset | 16'h0002 | (task_fault_external ? 16'h0001 : 16'h0000)) :
                                     descriptor_cs_offset_fault ? 16'd0 :
                                     (descriptor_pre_fault || descriptor_post_fault) ?
                                       ((descriptor_selector_value & 16'hFFFC) |
                                        (task_fault_external ? 16'h0001 : 16'h0000)) : 16'd0;
    assign protected_ldtr_commit_en = task_commit_ldtr_write || descriptor_null_commit ||
                                       (descriptor_operand_done && descriptor_phase_q == 3'd3 && descriptor_load_ldtr && descriptor_success_live);
    assign protected_tr_commit_en = task_commit_tr_write ||
                                    (descriptor_operand_done && descriptor_phase_q == 3'd4 && descriptor_load_tr && descriptor_success_q);
    assign protected_ldtr_commit_selector = task_commit_ldtr_write ? task_loaded_ldtr : tmp0_q;
    assign protected_tr_commit_selector = task_commit_tr_write ? task_loaded_tr_selector : tmp0_q;
    assign protected_ldtr_commit_base = task_commit_ldtr_write ? task_loaded_ldtr_base : descriptor_base;
    assign protected_tr_commit_base = task_commit_tr_write ? task_loaded_tr_base : descriptor_base;
    assign protected_ldtr_commit_limit = task_commit_ldtr_write ? task_loaded_ldtr_limit : descriptor_limit;
    assign protected_tr_commit_limit = task_commit_tr_write ? task_loaded_tr_limit : descriptor_limit;
    assign protected_ldtr_commit_access = task_commit_ldtr_write ? task_loaded_ldtr_access : descriptor_access_rights;
    assign protected_tr_commit_access = task_commit_tr_write ? task_loaded_tr_access :
                                        descriptor_load_tr ? (descriptor_access_rights | 8'h02) :
                                        descriptor_access_rights;
    assign protected_ldtr_commit_class = task_commit_ldtr_write ? task_loaded_ldtr_class : descriptor_null_commit ? spk286_protected_pkg::DESC_INVALID : descriptor_class;
    assign protected_tr_commit_class = task_commit_tr_write ? spk286_protected_pkg::DESC_TSS_BUSY :
                                       descriptor_load_tr ? spk286_protected_pkg::DESC_TSS_BUSY :
                                       descriptor_class;
    assign protected_ldtr_commit_present = task_commit_ldtr_write ? task_loaded_ldtr_present : descriptor_null_commit ? 1'b0 : descriptor_present;
    assign protected_tr_commit_present = task_commit_tr_write ? 1'b1 : descriptor_present;
    assign protected_ldtr_commit_valid = task_commit_tr_write ? 1'b0 : task_commit_ldtr_write ? task_loaded_ldtr_valid : !descriptor_null_commit;
    assign protected_tr_commit_valid = 1'b1;
    assign protected_segment_commit_en = task_commit_segment_write || task_commit_segment_write2 ||
                                         (context_commit && protected_msw[0] && cs_candidate_valid_q) ||
                                         descriptor_segment_null_commit ||
                                         (descriptor_operand_done && descriptor_phase_q == 3'd3 && segment_reload_operation &&
                                          descriptor_segment_success_live && descriptor_unused_accessed) ||
                                         (descriptor_operand_done && descriptor_phase_q == 3'd4 && segment_reload_operation && descriptor_success_q);
    assign segment_pop_sp_commit = protected_return_cursor_q && segment_pop_opcode &&
                                   segment_reload_operation && protected_segment_commit_en;
    assign protected_segment_commit_index = task_commit_segment_write ? task_cache_commit_index : task_commit_segment_write2 ? 2'd2 :
                                           (context_commit && protected_msw[0] && cs_candidate_valid_q) ? 2'd1 : segment_index;
    assign protected_segment_commit_selector = task_commit_segment_write || task_commit_segment_write2 ?
                                              task_cache_selectors[task_primary_cache_index * 16 +: 16] :
                                              (context_commit && protected_msw[0] && cs_candidate_valid_q) ? cs_candidate_selector_q : tmp0_q;
    assign protected_segment_commit_base = task_commit_segment_write || task_commit_segment_write2 ?
                                           task_cache_bases[task_primary_cache_index * 24 +: 24] :
                                           (context_commit && protected_msw[0] && cs_candidate_valid_q) ? cs_candidate_base_q :
                                           (descriptor_segment_null_commit ? 24'h000000 : descriptor_base);
    assign protected_segment_commit_limit = task_commit_segment_write || task_commit_segment_write2 ?
                                            task_cache_limits[task_primary_cache_index * 16 +: 16] :
                                            (context_commit && protected_msw[0] && cs_candidate_valid_q) ? cs_candidate_limit_q :
                                            (descriptor_segment_null_commit ? 16'h0000 : descriptor_limit);
    assign protected_segment_commit_access = task_commit_segment_write || task_commit_segment_write2 ?
                                             task_cache_access[task_primary_cache_index * 8 +: 8] :
                                             (context_commit && protected_msw[0] && cs_candidate_valid_q) ? cs_candidate_access_q :
                                             (descriptor_segment_null_commit ? 8'h00 :
                                              descriptor_access_rights | ((descriptor_phase_q == 3'd4) ? 8'h01 : 8'h00));
    assign protected_segment_commit_class = task_commit_segment_write || task_commit_segment_write2 ?
                                            task_cache_classes[task_primary_cache_index * 4 +: 4] :
                                            (context_commit && protected_msw[0] && cs_candidate_valid_q) ? cs_candidate_class_q :
                                            (descriptor_segment_null_commit ? spk286_protected_pkg::DESC_INVALID : descriptor_class);
    assign protected_segment_commit_present = task_commit_segment_write || task_commit_segment_write2 ?
                                              task_cache_present[task_primary_cache_index[1:0]] :
                                              (context_commit && protected_msw[0] && cs_candidate_valid_q) ? cs_candidate_present_q :
                                              (!descriptor_segment_null_commit && descriptor_present);
    assign protected_segment_commit_protected = task_commit_segment_write || task_commit_segment_write2 ?
                                               task_cache_protected[task_primary_cache_index[1:0]] : 1'b1;
    assign protected_segment_commit_dpl = task_commit_segment_write || task_commit_segment_write2 ?
                                         task_cache_dpl[task_primary_cache_index * 2 +: 2] :
                                         (context_commit && protected_msw[0] && cs_candidate_valid_q) ? cs_candidate_dpl_q :
                                          (descriptor_segment_null_commit ? 2'd0 : descriptor_unused_dpl);
    assign protected_segment_commit_table_indicator = task_commit_segment_write || task_commit_segment_write2 ?
                                                       task_cache_tables[task_primary_cache_index[1:0]] :
                                                       (context_commit && protected_msw[0] && cs_candidate_valid_q) ? cs_candidate_table_q :
                                                      (descriptor_segment_null_commit ? 1'b0 : descriptor_selector_ti);
    assign protected_segment_commit_rpl = task_commit_segment_write || task_commit_segment_write2 ?
                                          task_cache_rpl[task_primary_cache_index * 2 +: 2] :
                                          (context_commit && protected_msw[0] && cs_candidate_valid_q) ? cs_candidate_rpl_q :
                                          (descriptor_selector_null ? tmp0_q[1:0] : descriptor_unused_rpl);
    assign protected_segment_commit_en2 = task_commit_segment_write || task_commit_segment_write2 ? 1'b0 :
                                         context_commit && protected_msw[0] &&
                                         (iret_ss_candidate_valid_q || call_ss_candidate_valid_q);
    assign protected_segment_commit_index2 = task_commit_segment_write ? 2'd1 : task_commit_segment_write2 ? 2'd3 : 2'd2;
    assign protected_segment_commit_selector2 = task_commit_segment_write || task_commit_segment_write2 ?
                                               task_cache_selectors[task_secondary_cache_index * 16 +: 16] :
                                               call_ss_candidate_valid_q ? call_ss_selector_q : iret_ss_selector_q;
    assign protected_segment_commit_base2 = task_commit_segment_write || task_commit_segment_write2 ?
                                            task_cache_bases[task_secondary_cache_index * 24 +: 24] :
                                            call_ss_candidate_valid_q ? call_ss_base_q : iret_ss_base_q;
    assign protected_segment_commit_limit2 = task_commit_segment_write || task_commit_segment_write2 ?
                                             task_cache_limits[task_secondary_cache_index * 16 +: 16] :
                                             call_ss_candidate_valid_q ? call_ss_limit_q : iret_ss_limit_q;
    assign protected_segment_commit_access2 = task_commit_segment_write || task_commit_segment_write2 ?
                                              task_cache_access[task_secondary_cache_index * 8 +: 8] :
                                              call_ss_candidate_valid_q ? call_ss_access_q : iret_ss_access_q;
    assign protected_segment_commit_class2 = task_commit_segment_write || task_commit_segment_write2 ?
                                             task_cache_classes[task_secondary_cache_index * 4 +: 4] :
                                             call_ss_candidate_valid_q ? call_ss_class_q : iret_ss_class_q;
    assign protected_segment_commit_present2 = task_commit_segment_write || task_commit_segment_write2 ?
                                               task_cache_present[task_secondary_cache_index[1:0]] :
                                               call_ss_candidate_valid_q ? call_ss_present_q : iret_ss_present_q;
    assign protected_segment_commit_protected2 = task_commit_segment_write || task_commit_segment_write2 ?
                                                 task_cache_protected[task_secondary_cache_index[1:0]] : 1'b1;
    assign protected_segment_commit_dpl2 = task_commit_segment_write || task_commit_segment_write2 ?
                                           task_cache_dpl[task_secondary_cache_index * 2 +: 2] :
                                           call_ss_candidate_valid_q ? call_ss_dpl_q : iret_ss_dpl_q;
    assign protected_segment_commit_table_indicator2 = task_commit_segment_write || task_commit_segment_write2 ?
                                                       task_cache_tables[task_secondary_cache_index[1:0]] :
                                                       call_ss_candidate_valid_q ? call_ss_table_q : iret_ss_table_q;
    assign protected_segment_commit_rpl2 = task_commit_segment_write || task_commit_segment_write2 ?
                                          task_cache_rpl[task_secondary_cache_index * 2 +: 2] :
                                          call_ss_candidate_valid_q ? call_ss_rpl_q : iret_ss_rpl_q;
    logic constant_zero, constant_ones;
    assign constant_zero = allowed && operation == spk286_microcode_pkg::MC_CONST_ZERO_TMP1;
    assign constant_ones = allowed && operation == spk286_microcode_pkg::MC_CONST_ONES_TMP1;
    assign dispatch_request = allowed && operation == spk286_microcode_pkg::MC_DISPATCH_DECODED;
    logic read_ea, read_target, move_source, write_reg_tmp1, set_address, add_base;
    assign read_ea = allowed && operation == spk286_microcode_pkg::MC_READ_EA;
    assign read_target = allowed && operation == spk286_microcode_pkg::MC_READ_TARGET16_TMP1;
    assign move_source = allowed && operation == spk286_microcode_pkg::MC_MOVE_SOURCE16_TMP1 && temporary_valid_q[1];
    assign write_reg_tmp1 = (operation == spk286_microcode_pkg::MC_WRITE_REG8_TMP1 || operation == spk286_microcode_pkg::MC_WRITE_REG16_TMP1) && temporary_valid_q[1];
    assign set_address = allowed && operation == spk286_microcode_pkg::MC_SET_ADDRESS_TMP1 && temporary_valid_q[1];
    assign add_base = allowed && operation == spk286_microcode_pkg::MC_ADD_BASE_TMP0_TMP1 && temporary_valid_q[0];
    logic [2:0] temporary_valid_q;
    logic high_byte_q, flags_valid_q, result_disposed_q;
    logic fetch_word, fetch_tmp1, fetch_signed_byte, move_word, allowed, read_operand;
    logic read_tmp1, read_destination, compute_alu, result_operation, discard_result;
    logic result_to_dst, commit_result, commit_flags;
    logic [15:0] alu_result, alu_flags;
    logic shift_request, shift_complete, shift_valid, shift_write, result_suppress_q, allow_result_write;
    logic unused_shift_ready, count_low;
    logic [15:0] shift_result, shift_flags, shift_mask;
    assign shift_request = allowed && operation == spk286_microcode_pkg::MC_SHIFT && &temporary_valid_q[1:0] && !flags_valid_q;
    assign shift_complete = shift_request && shift_valid;
    assign count_low = allowed && operation == spk286_microcode_pkg::MC_COUNT_LOW_TMP1;
    assign allow_result_write = result_write_allowed && !result_suppress_q;
    spk286_shift shift_service (
        .clk(clk), .reset(reset), .cancel(cancel || start), .enable(operation_valid),
        .request_valid(shift_request), .request_ready(unused_shift_ready),
        .kind(shift_kind), .operand_byte(alu_byte), .carry_in(carry_in),
        .operand(tmp0_q), .count(tmp1_q[7:0]), .response_valid(shift_valid),
        .response_ready(shift_request), .result(shift_result), .candidate_flags(shift_flags),
        .flags_mask(shift_mask), .result_write(shift_write)
    );
    logic push_operation, push_event_error, pop_operation, push_transfer, push_event_error_transfer, read_ip, target_relative, target_absolute;
    logic redirect_operation, adjust_stack, count_operation, stack_write_sp, check_operand;
    logic target_valid_q;
    logic [15:0] target_q, stack_next_sp;
    logic fetch_byte, fetch_byte_tmp1, read_flags, restore_flags, set_if, clear_if_tf;
    logic direct_flags, sign_extend_byte, sign_fill_word, constant_one;
    logic carry_fill_byte;
    assign carry_fill_byte = allowed && operation == spk286_microcode_pkg::MC_CARRY_FILL8 && temporary_valid_q[0];
    assign direct_flags = allowed && operation == spk286_microcode_pkg::MC_FLAGS_DECODED;
    assign sign_extend_byte = allowed && operation == spk286_microcode_pkg::MC_SIGN_EXTEND8 && temporary_valid_q[0];
    assign sign_fill_word = allowed && operation == spk286_microcode_pkg::MC_SIGN_FILL16 && temporary_valid_q[0];
    assign constant_one = allowed && operation == spk286_microcode_pkg::MC_CONST_ONE_TMP1;
    logic read_event_flags, read_event_cs, read_event_ip, vector_ip, vector_cs;
    logic commit_context, ack_operation, request_event, halt_operation, iret_commit, iret_outer_sp_commit, retf_outer_sp_commit, call_gate_sp_commit;
    spk286_stack stack_service (
        .request(push_transfer || push_event_error_transfer || pop_operation || call_gate_stack_write),
        .push(push_transfer || push_event_error_transfer || call_gate_stack_write), .adjust(adjust_stack), .operand_done(operand_done),
        .sp(stack_cursor_valid_q ? stack_cursor_q : stack_pointer), .adjustment(tmp1_q), .offset(stack_native_offset), .next_sp(stack_next_sp), .write_sp(stack_write_sp)
    );
    assign push_operation = allowed && operation == spk286_microcode_pkg::MC_PUSH16 && temporary_valid_q[0];
    assign push_event_error = allowed && operation == spk286_microcode_pkg::MC_PUSH_EVENT_ERROR;
    assign push_transfer = push_operation && push_enabled;
    assign push_event_error_transfer = push_event_error && push_enabled && event_error_valid;
    assign iret_outer_required = protected_msw[0] && protected_return_cursor_q &&
                                 temporary_valid_q[1] && (tmp1_q[1:0] > protected_cpl);
    assign iret_outer_pop = iret_outer_frame_operation && iret_outer_required && iret_outer_phase_q < 2'd2;
    assign iret_outer_pop_done = iret_outer_pop && operand_done;
    // Count in words before widening: 4 base words, up to 31 parameters,
    // and up to 2 event words. Keep the final byte arithmetic at 17 bits.
    assign call_gate_frame_words = {1'b0, call_gate_parameter_count_q} +
                                   (event_gate_candidate_valid_q ?
                                    (event_error_valid ? 6'd6 : 6'd5) : 6'd4);
    assign call_gate_frame_bytes = {10'd0, call_gate_frame_words, 1'b0};
    // For N != 0, 2*N-1 is {N-1, 1}. The wrapped N=0 value is unused;
    // the parameter-range predicate below retains its explicit N!=0 guard.
    assign call_parameter_last_word = call_gate_parameter_count_q - 5'd1;
    assign call_parameter_last_byte = {1'b0, stack_pointer} +
                                      {11'd0, call_parameter_last_word, 1'b1};
    logic [16:0] iret_outer_sum_bits, iret_outer_carry_bits, iret_outer_last_byte;
    // Carry-save reduction of SP + allocation + 3, followed by one wide adder.
    // Keep the original 17-bit wrapping arithmetic, including arbitrary state.
    assign iret_outer_sum_bits = {1'b0, return_stack_pointer} ^
                                 {1'b0, allocation_valid_q ? allocation_q : 16'd0} ^ 17'd3;
    assign iret_outer_carry_bits = (({1'b0, return_stack_pointer} &
                                    {1'b0, allocation_valid_q ? allocation_q : 16'd0}) |
                                   (({1'b0, return_stack_pointer} |
                                     {1'b0, allocation_valid_q ? allocation_q : 16'd0}) & 17'd3)) << 1;
    assign iret_outer_last_byte = iret_outer_sum_bits + iret_outer_carry_bits;
    assign iret_outer_range_fault = iret_outer_frame_operation && iret_outer_required &&
                                    iret_outer_phase_q == 2'd0 &&
                                    (stack_segment_access[2] ?
                                      ({1'b0, return_stack_pointer} <= {1'b0, stack_segment_limit} ||
                                       (iret_outer_last_byte > 17'h0FFFF)) :
                                      (iret_outer_last_byte >
                                       {1'b0, stack_segment_limit}));
    // Restoring outer SS:SP does not access the new stack. RETF validates
    // the source frame and target descriptor; a subsequent stack access
    // checks its own range. In particular, an empty stack may have
    // SP=limit+1, and RETF's immediate adjustment wraps at 16 bits.
    // The explicit SP<frame test handles subtraction underflow. Compare
    // SP with limit+frame directly; that sum fits in 17 bits (frame<=74).
    assign call_stack_range_fault = check_call_frame && (protected_msw[0] || !event_active) &&
                                   (call_gate_outer_required ?
                                    (!call_stack_ready_q ||
                                     {1'b0, call_stack_sp_q} < call_gate_frame_bytes ||
                                     (call_ss_access_q[2] ?
                                      ({1'b0, call_stack_sp_q} <= {1'b0, call_ss_limit_q} + call_gate_frame_bytes) :
                                      ({1'b0, call_stack_sp_q} > {1'b0, call_ss_limit_q} + 17'd2)) ||
                                     (call_gate_parameter_count_q != 5'd0 &&
                                      (stack_segment_access[2] ?
                                       ({1'b0, stack_pointer} <= {1'b0, stack_segment_limit} ||
                                        call_parameter_last_byte[16]) :
                                       (call_parameter_last_byte > {1'b0, stack_segment_limit}))) ) :
                                    (stack_pointer[0] && stack_pointer < 16'd4));
    assign call_gate_stack_switch_begin = call_gate_stack_switch_operation && call_gate_outer_required &&
                                          !call_gate_stack_switch_active_q;
    assign call_gate_stack_write = call_gate_stack_switch_operation && call_gate_stack_switch_active_q &&
                                   call_gate_stack_switch_phase_q < 2'd2;
    assign call_gate_stack_write_done = call_gate_stack_write && operand_done;
    assign call_parameter_read = copy_call_parameters && call_gate_outer_required &&
                                 call_parameter_active_q && call_parameter_phase_q == 2'd0;
    assign call_parameter_write = copy_call_parameters && call_gate_outer_required &&
                                  call_parameter_active_q && call_parameter_phase_q == 2'd1;
    assign call_parameter_read_done = call_parameter_read && operand_done;
    assign call_parameter_write_done = call_parameter_write && operand_done;
    assign call_parameter_operation_done = copy_call_parameters &&
                                           (!call_gate_outer_required || call_gate_parameter_count_q == 5'd0 ||
                                            (call_parameter_write_done && call_parameter_remaining_q == 5'd1));
    assign pop_operation = allowed && (operation == spk286_microcode_pkg::MC_POP16 ||
                                      operation == spk286_microcode_pkg::MC_POP16_TMP1 ||
                                      operation == spk286_microcode_pkg::MC_POP16_TMP2 || iret_outer_pop);
    // Of the range_fault terms only the IRET outer frame shares an operation
    // with these stack transfers; the others belong to CHECK_* and string
    // operations. Testing just that one keeps the unrelated range compares
    // off the stack request, segment and operand-completion path.
    assign stack_request = !iret_outer_range_fault &&
                           (push_transfer || push_event_error_transfer || pop_operation || read_frame_address ||
                            call_gate_stack_write || call_parameter_read || call_parameter_write);
    assign read_ip = allowed && operation == spk286_microcode_pkg::MC_READ_IP16;
    assign target_relative = allowed && operation == spk286_microcode_pkg::MC_TARGET_REL16 && temporary_valid_q[1];
    assign target_absolute = allowed && operation == spk286_microcode_pkg::MC_TARGET_ABS16 && temporary_valid_q[0];
    assign redirect_operation = allowed && operation == spk286_microcode_pkg::MC_REDIRECT && target_valid_q;
    assign task_commit_gpr_write = task_commit_active_q && task_commit_phase_q <= 4'd7;
    assign task_commit_flags_write = task_commit_active_q && task_commit_phase_q == 4'd8;
    // The early redirect publishes IP for late faults. Once CS is validated,
    // flush again so no byte fetched with the outgoing CS base can execute.
    assign task_commit_redirect = task_commit_flags_write || (task_commit_segment_write && task_cache_commit_index == 2'd1);
    assign task_commit_tr_write = task_commit_active_q && task_commit_phase_q == 4'd9;
    // Publish the incoming selector with TR, then refresh the hidden LDTR
    // once its descriptor is validated. Do not wait for segment success:
    // a later CS/SS/ES/DS fault must retain the already validated LDT.
    assign task_commit_ldtr_write = task_commit_tr_write ||
                                   (task_commit_active_q && task_commit_phase_q == 4'd10 && task_loaded_ldtr_valid);
    assign protected_task_load = task_commit_tr_write;
    assign task_state_loaded = task_commit_active_q && task_commit_phase_q == 4'd10;
    assign task_commit_segment_write = task_state_loaded && task_cache_commit;
    assign task_commit_segment_write2 = 1'b0;
    assign protected_segment_commit_valid = !task_commit_segment_write || task_cache_present[task_cache_commit_index];
    assign task_commit_done = task_state_loaded && task_service_complete_q;
    assign task_primary_cache_index = {1'b0, task_cache_commit_index};
    assign task_secondary_cache_index = task_commit_segment_write ? 3'd1 : 3'd3;
    assign redirect_request = (redirect_operation && branch_taken) || context_commit || task_commit_redirect;
    assign redirect_target = task_commit_redirect ? task_loaded_ip : (context_commit ? tmp0_q : target_q);
    assign adjust_stack = allowed && operation == spk286_microcode_pkg::MC_ADJUST_SP16 && temporary_valid_q[1];
    assign count_operation = allowed && operation == spk286_microcode_pkg::MC_COUNT;
    assign check_operand = allowed && operation == spk286_microcode_pkg::MC_CHECK_RM16;
    assign operand_check = check_operand;

    assign fetch_byte = allowed && operation == spk286_microcode_pkg::MC_FETCH_IMM8;
    assign fetch_byte_tmp1 = allowed && operation == spk286_microcode_pkg::MC_FETCH_IMM8_TMP1;
    assign read_flags = allowed && operation == spk286_microcode_pkg::MC_READ_FLAGS;
    assign restore_flags = allowed && operation == spk286_microcode_pkg::MC_RESTORE_FLAGS && temporary_valid_q[0];
    assign set_if = if_control_operation && !io_privilege_fault;
    assign clear_if_tf = allowed && operation == spk286_microcode_pkg::MC_CLEAR_IF_TF;
    assign read_event_flags = allowed && operation == spk286_microcode_pkg::MC_EVENT_FLAGS;
    assign read_event_cs = allowed && operation == spk286_microcode_pkg::MC_EVENT_CS;
    assign read_event_ip = allowed && operation == spk286_microcode_pkg::MC_EVENT_IP;
    assign vector_ip = allowed && operation == spk286_microcode_pkg::MC_VECTOR_IP;
    assign vector_cs = allowed && operation == spk286_microcode_pkg::MC_VECTOR_CS;
    assign vector_request = vector_ip || vector_cs || event_gate_vector_ip || event_gate_vector_cs;
    assign vector_offset = {6'b000000, event_vector, 2'b00} + ((vector_cs || event_gate_vector_cs) ? 16'd2 : 16'd0);
    assign clear_event_flags = allowed && operation == spk286_microcode_pkg::MC_CLEAR_EVENT_FLAGS;
    assign commit_context = allowed && operation == spk286_microcode_pkg::MC_CONTEXT_COMMIT && &temporary_valid_q[1:0];
    assign iret_commit = allowed && operation == spk286_microcode_pkg::MC_IRET_COMMIT && &temporary_valid_q;
    assign context_commit = ((iret_commit && (!protected_msw[0] || (cs_candidate_valid_q && (!iret_outer_required || iret_ss_candidate_valid_q)))) ||
                             (commit_context && (!protected_msw[0] || cs_candidate_valid_q || event_active) &&
                              (!call_gate_outer_required || call_ss_candidate_valid_q) &&
                              (!iret_outer_required || iret_ss_candidate_valid_q))) &&
                            redirect_ready;
    assign context_cs = tmp1_q;
    assign iret_outer_sp_commit = context_commit && iret_commit && iret_outer_required;
    assign retf_outer_sp_commit = context_commit && commit_context && iret_outer_required;
    assign return_same_sp_commit = context_commit && protected_return_cursor_q && !iret_outer_required;
    assign call_gate_sp_commit = context_commit && commit_context && call_gate_outer_required;
    assign ack_operation = allowed && operation == spk286_microcode_pkg::MC_EVENT_ACK;
    assign ack_request = ack_operation && event_needs_ack;
    assign request_event = allowed && operation == spk286_microcode_pkg::MC_REQUEST_EVENT;
    assign software_event_request = request_event;
    assign software_vector = tmp0_q[7:0];
    assign halt_operation = allowed && operation == spk286_microcode_pkg::MC_HALT;
    // HLT is always privileged on a protected-mode 286, even with IOPL=3.
    // Extenders use its #GP(0) path for service stubs; a denied HLT must not
    // enter the event controller's halted state before fault delivery.
    assign halt_privilege_fault = halt_operation && protected_msw[0] && protected_cpl != 2'd0;
    assign halt_request = halt_operation && !halt_privilege_fault;

    // A direct far CALL/JMP may have selected an available 80286 TSS in the
    // preceding descriptor service. TASK_SWITCH is deliberately a no-op for
    // the ordinary code-segment path, while the validated TSS path owns the
    // complete serialized transfer below.
    assign task_switch_operation = allowed && operation == spk286_microcode_pkg::MC_TASK_SWITCH;
    assign task_return_operation = allowed && operation == spk286_microcode_pkg::MC_TASK_RETURN &&
                                   protected_msw[0] && architectural_flags[14];
    assign task_return_noop = operation == spk286_microcode_pkg::MC_TASK_RETURN &&
                              !task_return_started_q && (!protected_msw[0] || !architectural_flags[14]);
    assign task_return_start = task_return_operation && !task_return_started_q &&
                               !task_service_busy && !task_service_complete && !task_commit_active_q;
    assign task_return_commit_done = task_return_started_q && task_commit_done;
    assign task_return_finish = task_return_started_q && operation_valid &&
                                operation == spk286_microcode_pkg::MC_END;
    assign task_return_skip = task_return_started_q && !operation_flags[spk286_microcode_pkg::MC_FLAG_TASK_RETURN] &&
                              !task_commit_done;
    assign task_switch_nested_call = task_switch_operation &&
                                     ((event_gate_candidate_valid_q &&
                                       event_gate_class_q == spk286_protected_pkg::DESC_TASK_GATE) ||
                                      task_gate_nested_call_q);
    assign task_switch_return_task = task_return_start;
    assign task_switch_start = (task_switch_operation && task_descriptor_candidate_valid_q &&
                                !task_service_busy && !task_service_complete && !task_commit_active_q &&
                                !task_commit_done_q) ||
                               task_return_start;
    assign task_switch_target_selector = task_descriptor_selector_q;
    assign task_switch_target_base = task_descriptor_base_q;
    assign task_switch_target_limit = task_descriptor_limit_q;
    assign task_switch_target_access = task_descriptor_access_q;
    assign task_switch_target_descriptor_address = task_descriptor_address_q;
    assign task_switch_skip = task_descriptor_candidate_valid_q &&
                              !operation_flags[spk286_microcode_pkg::MC_FLAG_TASK_SWITCH] &&
                              !(event_gate_candidate_valid_q &&
                                event_gate_class_q == spk286_protected_pkg::DESC_TASK_GATE) &&
                              !task_service_busy && !task_service_complete && !task_commit_active_q;
    // An IDT task gate completes the event by publishing the incoming task
    // image.  Do not run the ordinary interrupt-frame tail after that commit;
    // it would overwrite the task-loaded CS/IP and create a second frame.
    // A task-gate event has no ordinary interrupt frame, but an exception
    // error word is still pushed on the new task's stack.  Keep only that
    // micro-op live after the task commit; the remaining frame tail is stale.
    assign task_event_switch_skip = task_event_switch_done_q &&
                                    !operation_flags[spk286_microcode_pkg::MC_FLAG_PUSH_EVENT_ERROR];


    spk286_stack_range stack_range (
        .sp(stack_pointer), .push8_invalid(push8_invalid), .pop8_invalid(pop8_invalid)
    );

    spk286_adjust adjust_service (
        .clk(clk), .reset(reset), .cancel(cancel || start), .enable(operation_valid),
        .request_valid(adjust_request), .request_ready(unused_adjust_ready),
        .kind(adjust_kind), .operand(tmp0_q), .radix(tmp1_q[7:0]),
        .carry_in(architectural_flags[0]), .auxiliary_in(architectural_flags[4]),
        .response_valid(adjust_valid), .response_ready(adjust_request),
        .result(adjust_result), .candidate_flags(adjust_flags), .flags_mask(adjust_mask),
        .result_write(adjust_write), .arithmetic_fault(adjust_fault)
    );

    // Capture both register operands before the execution stage. Memory forms
    // still use the original operand service and explicit microcode fallback.
    logic register_decode, register_alu, register_byte, register_destination_rm;
    logic unary_register, unary_direct;
    logic register_capture, direct_register_capture, register_pending_q, register_complete, register_write;
    logic [2:0] register_destination_q, register_a_index, register_b_index;
    logic [15:0] register_a_value, register_b_value;
    logic sequential_gpr_write_en, sequential_gpr_write_byte;
    logic [2:0] sequential_gpr_write_index;
    logic [15:0] sequential_gpr_write_data;
    logic sequential_flags_write_en;
    logic [15:0] sequential_flags_write_data, sequential_flags_write_mask;
    logic immediate_operation, immediate_alu, immediate_byte, immediate_rm;
    logic immediate_word, immediate_signed, immediate_register, immediate_fetch;
    logic immediate_last, immediate_capture;
    logic [15:0] immediate_value;
    always_comb begin
        immediate_operation = 1'b1;
        immediate_alu = 1'b0;
        immediate_byte = 1'b0;
        immediate_rm = 1'b0;
        immediate_word = 1'b1;
        immediate_signed = 1'b0;
        case (operation)
            spk286_microcode_pkg::MC_FETCH_ALU_DST16_IMM16: immediate_alu = 1'b1;
            spk286_microcode_pkg::MC_FETCH_ALU_DST8_IMM8: begin immediate_alu = 1'b1; immediate_byte = 1'b1; immediate_word = 1'b0; end
            spk286_microcode_pkg::MC_FETCH_ALU_RM16_IMM16: begin immediate_alu = 1'b1; immediate_rm = 1'b1; end
            spk286_microcode_pkg::MC_FETCH_ALU_RM16_IMM8S: begin immediate_alu = 1'b1; immediate_rm = 1'b1; immediate_word = 1'b0; immediate_signed = 1'b1; end
            spk286_microcode_pkg::MC_FETCH_ALU_RM8_IMM8: begin immediate_alu = 1'b1; immediate_rm = 1'b1; immediate_byte = 1'b1; immediate_word = 1'b0; end
            spk286_microcode_pkg::MC_FETCH_MOV_DST16_IMM16: begin end
            spk286_microcode_pkg::MC_FETCH_MOV_DST8_IMM8: begin immediate_byte = 1'b1; immediate_word = 1'b0; end
            spk286_microcode_pkg::MC_FETCH_MOV_RM16_IMM16: immediate_rm = 1'b1;
            spk286_microcode_pkg::MC_FETCH_MOV_RM8_IMM8: begin immediate_rm = 1'b1; immediate_byte = 1'b1; immediate_word = 1'b0; end
            default: immediate_operation = 1'b0;
        endcase
    end
    // ModR/M and all displacement bytes have already completed before these
    // controls. Never consume the next opcode while a register commit is pending.
    assign immediate_register = !immediate_rm || (decode_modrm_valid && operand_register_direct);
    assign immediate_fetch = allowed && immediate_operation && !register_pending_q &&
                             (!immediate_rm || decode_modrm_valid);
    assign immediate_last = immediate_fetch && byte_valid && (!immediate_word || high_byte_q);
    assign immediate_capture = immediate_last && immediate_register;
    assign immediate_value = immediate_word ? {byte_data, (immediate_register || immediate_alu) ? tmp1_q[7:0] : tmp0_q[7:0]} :
                             {{8{immediate_signed && byte_data[7]}}, byte_data};
    always_comb begin
        register_decode = 1'b1;
        register_alu = 1'b0;
        register_byte = 1'b0;
        register_destination_rm = 1'b0;
        unary_register = 1'b0;
        unary_direct = 1'b0;
        case (operation)
            spk286_microcode_pkg::MC_DECODE_ALU_RM16_REG16: begin register_alu = 1'b1; register_destination_rm = 1'b1; end
            spk286_microcode_pkg::MC_DECODE_ALU_REG16_RM16: register_alu = 1'b1;
            spk286_microcode_pkg::MC_DECODE_ALU_RM8_REG8: begin register_alu = 1'b1; register_byte = 1'b1; register_destination_rm = 1'b1; end
            spk286_microcode_pkg::MC_DECODE_ALU_REG8_RM8: begin register_alu = 1'b1; register_byte = 1'b1; end
            spk286_microcode_pkg::MC_DECODE_MOV_RM16_REG16: register_destination_rm = 1'b1;
            spk286_microcode_pkg::MC_DECODE_MOV_REG16_RM16: begin end
            spk286_microcode_pkg::MC_DECODE_MOV_RM8_REG8: begin register_byte = 1'b1; register_destination_rm = 1'b1; end
            spk286_microcode_pkg::MC_DECODE_MOV_REG8_RM8: register_byte = 1'b1;
            spk286_microcode_pkg::MC_DECODE_UNARY_RM16: begin
                register_alu = 1'b1; unary_register = 1'b1; register_destination_rm = 1'b1;
            end
            spk286_microcode_pkg::MC_DECODE_UNARY_RM8: begin
                register_alu = 1'b1; register_byte = 1'b1; unary_register = 1'b1;
                register_destination_rm = 1'b1;
            end
            spk286_microcode_pkg::MC_EXEC_INC_DEC_DST16: begin
                register_alu = 1'b1; unary_register = 1'b1; unary_direct = 1'b1;
            end
            default: register_decode = 1'b0;
        endcase
        if (immediate_operation) begin
            register_alu = immediate_alu;
            register_byte = immediate_byte;
        end
    end
    assign register_a_index = immediate_operation ? (immediate_rm ? operand_rm_index : destination) :
                             unary_direct ? destination :
                             register_destination_rm ? byte_data[2:0] : byte_data[5:3];
    assign register_b_index = register_destination_rm ? byte_data[5:3] : byte_data[2:0];
    assign register_a_value = register_byte ?
        {8'd0, register_state[register_a_index[1:0]*16 + (register_a_index[2] ? 8 : 0) +: 8]} :
        register_state[register_a_index*16 +: 16];
    assign register_b_value = unary_register ?
        (alu_operation == 3'd6 ? (register_byte ? 16'h00FF : 16'hFFFF) :
         reverse_operands ? 16'h0000 : 16'h0001) :
        register_byte ?
        {8'd0, register_state[register_b_index[1:0]*16 + (register_b_index[2] ? 8 : 0) +: 8]} :
        register_state[register_b_index*16 +: 16];
    // Only the accepted ModR/M may capture operands, never displacement bytes.
    assign register_capture = allowed && register_decode && !decode_modrm_valid &&
                              decode_byte_ready && byte_valid && byte_data[7:6] == 2'b11;
    assign direct_register_capture = allowed && unary_direct && !register_pending_q;
    assign register_complete = allowed && register_pending_q &&
                               ((register_decode && operand_register_direct && decode_done) ||
                                (immediate_operation && immediate_register) || unary_direct);
    assign register_write = register_complete && (!register_alu || result_write_allowed);
    assign operation_retire = register_complete;
    assign gpr_write_en = sequential_gpr_write_en || register_write;
    assign gpr_write_byte = register_write ? register_byte : sequential_gpr_write_byte;
    assign gpr_write_index = register_write ? register_destination_q : sequential_gpr_write_index;
    assign gpr_write_data = register_write ? (register_alu ? alu_result : tmp1_q) : sequential_gpr_write_data;
    assign flags_write_en = sequential_flags_write_en || (register_complete && register_alu);
    assign flags_write_data = register_complete && register_alu ? alu_flags : sequential_flags_write_data;
    assign flags_write_mask = register_complete && register_alu ?
                              decoded_flags_mask & ~decoded_undefined_mask : sequential_flags_write_mask;

    spk286_alu alu (.operation(alu_operation), .operand_a(reverse_operands ? tmp1_q : tmp0_q), .operand_b(reverse_operands ? tmp0_q : tmp1_q),
                   .carry_in(carry_in), .operand_byte(alu_byte), .result(alu_result), .candidate_flags(alu_flags));
    // start is not repeated here: an instruction or event starts only while
    // the microsequencer is idle (start_ready), and operation_valid holds
    // only while it is active, so the two never coincide. Leaving start out
    // keeps instruction-head decode off every micro-operation's path.
    assign allowed = operation_valid && !reset && !cancel &&
                     !task_switch_skip && !task_return_skip && !task_event_switch_skip;
    assign fetch_tmp1 = operation == spk286_microcode_pkg::MC_FETCH_IMM16_TMP1;
    assign fetch_word = allowed && (operation == spk286_microcode_pkg::MC_FETCH_IMM16 || fetch_tmp1);
    assign fetch_signed_byte = allowed && (operation == spk286_microcode_pkg::MC_FETCH_IMM8S_TMP1 || operation == spk286_microcode_pkg::MC_FETCH_IMM8S_TMP0);
    assign move_word = allowed && (operation == spk286_microcode_pkg::MC_MOVE || operation == spk286_microcode_pkg::MC_MOVE8) && temporary_valid_q[0];
    assign read_destination = allowed && (operation == spk286_microcode_pkg::MC_READ_DST16 || operation == spk286_microcode_pkg::MC_READ_DST8);
    assign decode_operand = allowed && (operation == spk286_microcode_pkg::MC_DECODE_MODRM ||
                                        (register_decode && !unary_direct));
    assign read_tmp1 = string_read1 || operation == spk286_microcode_pkg::MC_READ_REG16_TMP1 || operation == spk286_microcode_pkg::MC_READ_RM16_TMP1 || operation == spk286_microcode_pkg::MC_READ_REG8_TMP1 || operation == spk286_microcode_pkg::MC_READ_RM8_TMP1;
    assign result_operation = operation == spk286_microcode_pkg::MC_WRITE_RESULT_REG8 || operation == spk286_microcode_pkg::MC_WRITE_RESULT_RM8 || operation == spk286_microcode_pkg::MC_WRITE_RESULT_REG16 || operation == spk286_microcode_pkg::MC_WRITE_RESULT_RM16 ||
                              (operation == spk286_microcode_pkg::MC_WRITE_RESULT_DST || operation == spk286_microcode_pkg::MC_WRITE_RESULT_DST8);
    assign commit_result = allowed && result_operation && temporary_valid_q[2] && !result_disposed_q;
    assign discard_result = commit_result && !allow_result_write;
    assign result_to_dst = commit_result && allow_result_write && (operation == spk286_microcode_pkg::MC_WRITE_RESULT_DST || operation == spk286_microcode_pkg::MC_WRITE_RESULT_DST8);
    assign operand_request = descriptor_active_q || event_gate_active_q || call_tss_active_q || system_operand_request || io_transfer || string_request || vector_request || stack_request || check_operand || (arpl_operation && arpl_adjust) || (allowed &&
                             (write_reg_tmp1 || operation == spk286_microcode_pkg::MC_READ_REG16 || operation == spk286_microcode_pkg::MC_READ_RM16 || operation == spk286_microcode_pkg::MC_READ_REG8 || operation == spk286_microcode_pkg::MC_READ_RM8 || read_tmp1 ||
                              ((operation == spk286_microcode_pkg::MC_WRITE_REG16 || operation == spk286_microcode_pkg::MC_WRITE_RM16 || operation == spk286_microcode_pkg::MC_WRITE_REG8 || operation == spk286_microcode_pkg::MC_WRITE_RM8) && temporary_valid_q[0]) ||
                              (commit_result && allow_result_write && operation != spk286_microcode_pkg::MC_WRITE_RESULT_DST && operation != spk286_microcode_pkg::MC_WRITE_RESULT_DST8)));
    assign operand_write = descriptor_write || system_operand_write || io_write || string_store || write_reg_tmp1 || push_transfer || push_event_error_transfer || call_gate_stack_write || call_parameter_write || (arpl_operation && arpl_adjust) || operation == spk286_microcode_pkg::MC_WRITE_REG16 || operation == spk286_microcode_pkg::MC_WRITE_RM16 || operation == spk286_microcode_pkg::MC_WRITE_REG8 || operation == spk286_microcode_pkg::MC_WRITE_RM8 || result_operation;
    assign operand_select_rm = descriptor_active_q || event_gate_active_q || call_tss_active_q || system_operation || io_transfer || string_request || vector_request || stack_request || check_operand || operation == spk286_microcode_pkg::MC_READ_RM16 || operation == spk286_microcode_pkg::MC_READ_RM16_TMP1 ||
                               operation == spk286_microcode_pkg::MC_WRITE_RM16 || operation == spk286_microcode_pkg::MC_WRITE_RESULT_RM16 ||
                               operation == spk286_microcode_pkg::MC_READ_RM8 || operation == spk286_microcode_pkg::MC_READ_RM8_TMP1 || operation == spk286_microcode_pkg::MC_WRITE_RM8 || operation == spk286_microcode_pkg::MC_WRITE_RESULT_RM8 || arpl_operation;
    assign operand_byte = (descriptor_write) || (system_table_load && system_index_q == 2'd2) || io_byte || (string_request && string_byte) || operation == spk286_microcode_pkg::MC_WRITE_REG8_TMP1 || operation == spk286_microcode_pkg::MC_READ_REG8 || operation == spk286_microcode_pkg::MC_READ_RM8 ||
                          operation == spk286_microcode_pkg::MC_READ_REG8_TMP1 || operation == spk286_microcode_pkg::MC_READ_RM8_TMP1 ||
                          operation == spk286_microcode_pkg::MC_WRITE_REG8 || operation == spk286_microcode_pkg::MC_WRITE_RM8 ||
                          operation == spk286_microcode_pkg::MC_WRITE_RESULT_REG8 || operation == spk286_microcode_pkg::MC_WRITE_RESULT_RM8;
    assign operand_write_data = arpl_operation && arpl_adjust ? {tmp0_q[15:2], tmp1_q[1:0]} : call_gate_stack_write ? call_gate_stack_data_q : call_parameter_write ? call_parameter_data_q : descriptor_write ?
                                {8'd0, descriptor_access_rights | (descriptor_load_tr ? 8'h02 : 8'h01)} :
                                system_operand_write ? system_write_data :
                                push_event_error_transfer ? event_error_code :
                                (push_transfer && push_return_ip ? architectural_ip :
                                 (write_reg_tmp1 ? tmp1_q : (result_operation ? tmp2_q : tmp0_q)));
    assign read_operand = operand_request && !descriptor_active_q && !operand_check && !operand_write;
    assign compute_alu = allowed && operation == spk286_microcode_pkg::MC_ALU && temporary_valid_q[0] && temporary_valid_q[1] && !flags_valid_q;
    assign commit_flags = allowed && operation == spk286_microcode_pkg::MC_COMMIT_FLAGS && flags_valid_q && result_disposed_q;
    assign byte_ready = immediate_fetch || fetch_word || fetch_signed_byte || fetch_byte || fetch_byte_tmp1 || (fetch_port && port_immediate) || decode_byte_ready;
    assign operation_done = register_complete || (immediate_last && !immediate_register) || muldiv_complete || write_result_ax || write_result_dx || (fetch_port && (!port_immediate || byte_valid)) || string_empty || string_continue || string_index_write || string_count || string_read_acc || string_write_acc || add_allocation_sp || ((check_push2 || check_pop2) && !range_fault) || frame_read_gpr || frame_write_gpr || save_auxiliary || restore_auxiliary || save_allocation || load_counter ||
                            carry_fill_byte || decrement_counter || counter_branch || begin_stack_cursor || read_stack_cursor || set_frame_address || decrement_frame_address || allocate_stack || set_ea_plus2 ||
                            ((check_push8 || check_pop8 || check_stack_word || check_rm32 || check_call_frame) && !range_fault) ||
                            (call_stack_validation_operation && (!call_gate_outer_required || call_stack_ready_q || (call_tss_operand_done && call_tss_phase_q == 2'd1))) ||
                            (call_gate_stack_switch_operation && (!call_gate_outer_required || (call_gate_stack_write_done && call_gate_stack_switch_phase_q == 2'd1))) ||
                            call_parameter_operation_done ||
                            (check_bounds && !bounds_fault) || read_segment || segment_write || adjust_complete || (check_arithmetic && !arithmetic_fault_q) || dispatch_request || constant_zero || constant_ones || read_ea || read_target || move_source || set_address || add_base || shift_complete || count_low || direct_flags || sign_extend_byte || sign_fill_word || constant_one || read_flags || restore_flags || set_if || clear_if_tf || read_event_flags || read_event_cs || read_event_ip ||
                            context_commit || request_event || halt_operation || system_protected_check || system_privilege_check || io_privilege_check ||
                            ((npx_esc_check || npx_wait_check) && !npx_fault) ||
                            clear_event_flags || (push_event_error && (!event_error_valid || push_event_error_transfer && operand_done)) || (ack_operation && (!event_needs_ack || ack_done)) || ((fetch_byte || fetch_byte_tmp1) && byte_valid) ||
                            read_ip || target_relative || target_absolute || adjust_stack || count_operation ||
                            (push_operation && !push_enabled) || (redirect_operation && (!branch_taken || redirect_ready)) || move_word || read_destination || compute_alu || commit_flags || discard_result || result_to_dst ||
                            (fetch_word && byte_valid && high_byte_q) || (fetch_signed_byte && byte_valid) ||
                            (decode_operand && decode_done) || system_done || descriptor_operation_done || event_gate_operation_done ||
                             ((task_switch_operation && !task_descriptor_candidate_valid_q) ||
                             // Task completion belongs to TASK_SWITCH. Keeping
                             // it true for the tail would finish PUSH_EVENT_ERROR
                             // before its bus response/SP commit (double-fault gate).
                             (task_switch_operation && task_commit_done_q && task_service_complete_q) || task_switch_skip ||
                             task_event_switch_skip ||
                             task_return_noop || task_return_commit_done || task_return_skip) ||
                             (arpl_check_operation && protected_msw[0]) || arpl_fault || arpl_commit || clts_commit || clts_fault ||
                            (allowed && (operation == spk286_microcode_pkg::MC_VALIDATE_CS || operation == spk286_microcode_pkg::MC_VALIDATE_CALL_GATE ||
                                         operation == spk286_microcode_pkg::MC_VALIDATE_CALL_CS || operation == spk286_microcode_pkg::MC_VALIDATE_CALL_SS || operation == spk286_microcode_pkg::MC_VALIDATE_IRET_CS ||
                                         operation == spk286_microcode_pkg::MC_VALIDATE_IRET_SS) && !protected_msw[0]) ||
                            (iret_outer_frame_operation && (!iret_outer_required || (iret_outer_phase_q == 2'd1 && operand_done))) ||
                            (operation == spk286_microcode_pkg::MC_ADD_ALLOCATION_SP && iret_outer_required) ||
                            ((operand_request && operand_done) && !system_operand_request && !descriptor_active_q && !event_gate_active_q &&
                             !iret_outer_frame_operation && !call_tss_active_q && !call_gate_stack_write && !copy_call_parameters);
    assign sequential_gpr_write_en = task_commit_gpr_write || iret_outer_sp_commit || retf_outer_sp_commit || return_same_sp_commit || call_gate_sp_commit || segment_pop_sp_commit || descriptor_result_write || fixed_result_write || string_index_write || string_count_write || string_write_acc || add_allocation_arch || frame_write_gpr || allocate_stack || move_source || stack_arch_write || (count_operation && decrement_count) || move_word || result_to_dst || (operand_gpr_write_en && !system_msw_load);
    assign sequential_gpr_write_byte = (task_commit_gpr_write || iret_outer_sp_commit || retf_outer_sp_commit || return_same_sp_commit || call_gate_sp_commit || segment_pop_sp_commit) ? 1'b0 :
                            ((string_write_acc && string_byte) ||
                             (!descriptor_result_write && !fixed_result_write && !string_index_write && !string_count_write && !string_write_acc &&
                              (!add_allocation_arch && !frame_write_gpr && !allocate_stack && !stack_arch_write && !count_operation &&
                               ((move_word && operation == spk286_microcode_pkg::MC_MOVE8) ||
                                (result_to_dst && operation == spk286_microcode_pkg::MC_WRITE_RESULT_DST8) || operand_gpr_write_byte))));
    assign sequential_gpr_write_index = task_commit_gpr_write ? task_commit_phase_q[2:0] : (iret_outer_sp_commit || retf_outer_sp_commit || return_same_sp_commit || call_gate_sp_commit || segment_pop_sp_commit) ? 3'd4 : descriptor_result_write ? shift_kind : fixed_result_write ? (write_result_dx ? 3'd2 : 3'd0) : string_index_write ? (string_step_source ? 3'd6 : 3'd7) : string_count_write ? 3'd1 : string_write_acc ? 3'd0 : add_allocation_arch ? 3'd4 : frame_write_gpr ? frame_write_index : allocate_stack ? 3'd4 : move_source ? source_index : stack_arch_write ? 3'd4 : (count_operation ? 3'd1 : (move_word || result_to_dst ? destination : operand_gpr_write_index));
    // Preserve the original complete priority, but separate selection from
    // the 16-bit data reduction so a late completion need not cross a mux chain.
    logic [19:0] gpr_data_requests;
    (* keep *) logic [19:0] gpr_data_onehot;
    logic [319:0] gpr_data_values;
    function automatic logic [15:0] reduce_gpr_data(
        input logic [19:0] enables, input logic [319:0] values
    );
        reduce_gpr_data = 16'd0;
        for (integer i = 0; i < 20; i = i + 1)
            reduce_gpr_data = reduce_gpr_data | ({16{enables[i]}} & values[i*16 +: 16]);
    endfunction
    genvar gpr_data_index;
    generate
    for (gpr_data_index = 0; gpr_data_index < 20; gpr_data_index = gpr_data_index + 1) begin : g_gpr_data_priority
        if (gpr_data_index == 0) begin : g_first
            assign gpr_data_onehot[gpr_data_index] = gpr_data_requests[gpr_data_index];
        end else begin : g_remaining
            assign gpr_data_onehot[gpr_data_index] = gpr_data_requests[gpr_data_index] &&
                                                   !(|gpr_data_requests[gpr_data_index-1:0]);
        end
    end
    endgenerate
    assign gpr_data_requests = {1'b1, move_word, result_to_dst, count_operation, stack_arch_write, move_source, allocate_stack, frame_write_gpr, add_allocation_arch, string_write_acc, string_count_write, string_index_write, fixed_result_write, descriptor_result_write, segment_pop_sp_commit, call_gate_sp_commit, return_same_sp_commit, retf_outer_sp_commit, iret_outer_sp_commit, task_commit_gpr_write};
    assign gpr_data_values = {
        (operand_gpr_write_data),
        (tmp0_q),
        (tmp2_q),
        (count_value - 16'd1),
        (stack_next_sp),
        (tmp1_q),
        (stack_cursor_q - allocation_q),
        (tmp0_q),
        (stack_pointer+allocation_q),
        (tmp0_q),
        (count_value-16'd1),
        (architectural_flags[10] ? string_index-string_delta : string_index+string_delta),
        (write_result_dx ? auxiliary_q : tmp2_q),
        (descriptor_result_data),
        (stack_cursor_q),
        (stack_cursor_q),
        (stack_cursor_q + ((commit_context && allocation_valid_q) ? allocation_q : 16'd0)),
        (iret_outer_sp_q + allocation_q),
        (iret_outer_sp_q),
        (task_loaded_gpr[task_commit_phase_q[2:0] * 16 +: 16])
    };
    assign sequential_gpr_write_data = reduce_gpr_data(gpr_data_onehot, gpr_data_values);
    assign sequential_flags_write_en = !reset && (task_commit_flags_write || arpl_commit || direct_flags || descriptor_verify_flags_write || descriptor_inspect_flags_write || commit_flags || restore_flags || set_if || clear_if_tf || clear_event_flags || iret_commit);
    assign task_flags_write_en = !reset && task_commit_flags_write;
    assign sequential_flags_write_data = task_commit_flags_write ? task_loaded_flags : arpl_commit ? (arpl_adjust ? 16'h0040 : 16'h0000) : direct_flags ? direct_flags_data : descriptor_verify_flags_write ? (descriptor_verify_success_live ? 16'h0040 : 16'h0000) : descriptor_inspect_flags_write ? (descriptor_inspect_success_live ? 16'h0040 : 16'h0000) : restore_flags ? tmp0_q : (iret_commit ? tmp2_q : (set_if ? {6'd0, if_value, 9'd0} : ((clear_if_tf || clear_event_flags) ? 16'd0 : flags_q)));
    // POPF and ordinary IRET share the 286 FLAGS privilege rules. Use the
    // executing CPL and old IOPL, before an outer return publishes its CPL.
    // Real mode preserves NT/IOPL; protected mode always restores NT, permits
    // IOPL only at CPL0, and permits IF only when CPL <= the old IOPL.
    logic [15:0] stack_flags_write_mask;
    assign stack_flags_write_mask = !protected_msw[0] ? 16'h0FD5 :
                                   protected_cpl == 2'd0 ? 16'h7FD5 :
                                   protected_cpl <= architectural_flags[13:12] ? 16'h4FD5 : 16'h4DD5;
    assign sequential_flags_write_mask = task_commit_flags_write ? 16'hFFFF : arpl_commit ? 16'h0040 : direct_flags ? direct_flags_mask : descriptor_verify_flags_write ? 16'h0040 : descriptor_inspect_flags_write ? 16'h0040 : restore_flags ?
                              stack_flags_write_mask :
                              iret_commit ? stack_flags_write_mask : (set_if ? 16'h0200 : (clear_if_tf ? 16'h0300 : (clear_event_flags ?
                              // Ordinary protected gates save old FLAGS first,
                              // then clear NT/TF and, for an interrupt gate, IF.
                              // Task entry has its own FLAGS publication path.
                              (!protected_msw[0] ? 16'h0300 :
                               event_gate_class_q == spk286_protected_pkg::DESC_INT_GATE ? 16'h4300 : 16'h4100) : flags_mask_q)));

    always_ff @(posedge clk) begin
        if (reset || cancel || start) begin
            register_pending_q <= 1'b0;
            register_destination_q <= 3'd0;
            string_destination <= 1'b0;
            stack_cursor_q <= 16'd0; stack_cursor_valid_q <= 1'b0; protected_return_cursor_q <= 1'b0;
            auxiliary_q <= 16'd0; allocation_q <= 16'd0; frame_address_q <= 16'd0; counter_q <= 5'd0;
            auxiliary_valid_q <= 1'b0; allocation_valid_q <= 1'b0; frame_address_valid_q <= 1'b0; counter_valid_q <= 1'b0;
            arithmetic_fault_q <= 1'b0; result_high_pending_q <= 1'b0;
            address_override <= 1'b0; address_offset <= 16'd0;
            target_q <= 16'h0000; target_valid_q <= 1'b0;
            tmp0_q <= 16'h0000; tmp1_q <= 16'h0000; tmp2_q <= 16'h0000;
            flags_q <= 16'h0000; flags_mask_q <= 16'h0000;
            system_active_q <= 1'b0; system_index_q <= 2'd0;
            system_limit_q <= 16'h0000; system_base_q <= 24'h000000;
            descriptor_active_q <= 1'b0; descriptor_phase_q <= 3'd0;
            descriptor_word0_q <= 16'h0000; descriptor_word1_q <= 16'h0000;
            descriptor_word2_q <= 16'h0000; descriptor_word3_q <= 16'h0000;
            descriptor_success_q <= 1'b0;
            event_gate_active_q <= 1'b0; event_gate_phase_q <= 3'd0;
            event_gate_word0_q <= 16'h0000; event_gate_word1_q <= 16'h0000;
            event_gate_word2_q <= 16'h0000; event_gate_word3_q <= 16'h0000;
            event_gate_candidate_valid_q <= 1'b0;
            event_gate_target_selector_q <= 16'h0000; event_gate_target_offset_q <= 16'h0000;
            event_gate_class_q <= spk286_protected_pkg::DESC_INVALID;
            cs_candidate_valid_q <= 1'b0;
            cs_candidate_selector_q <= 16'h0000; cs_candidate_limit_q <= 16'h0000;
            cs_candidate_base_q <= 24'h000000; cs_candidate_access_q <= 8'h00;
            cs_candidate_class_q <= spk286_protected_pkg::DESC_INVALID;
            cs_candidate_dpl_q <= 2'd0; cs_candidate_rpl_q <= 2'd0;
            cs_candidate_present_q <= 1'b0; cs_candidate_table_q <= 1'b0;
            call_gate_candidate_valid_q <= 1'b0;
            task_descriptor_candidate_valid_q <= 1'b0;
            task_descriptor_selector_q <= 16'h0000; task_descriptor_limit_q <= 16'h0000;
            task_descriptor_base_q <= 24'h000000; task_descriptor_access_q <= 8'h00;
            task_descriptor_address_q <= 24'h000000;
            task_gate_target_active_q <= 1'b0;
            task_gate_target_selector_q <= 16'h0000;
            task_gate_nested_call_q <= 1'b0;
            call_gate_target_dpl_q <= 2'd0;
            call_gate_parameter_count_q <= 5'd0;
            call_tss_active_state_q <= 1'b0; call_tss_phase_q <= 2'd0;
            call_stack_ready_q <= 1'b0; call_stack_sp_q <= 16'h0000; call_stack_ss_q <= 16'h0000;
            call_gate_stack_switch_active_q <= 1'b0; call_gate_stack_switch_phase_q <= 2'd0;
            call_gate_stack_data_q <= 16'h0000;
            call_parameter_active_q <= 1'b0; call_parameter_phase_q <= 2'd0;
            call_parameter_remaining_q <= 5'd0; call_parameter_source_sp_q <= 16'h0000;
            call_parameter_data_q <= 16'h0000;
            call_ss_candidate_valid_q <= 1'b0;
            call_ss_selector_q <= 16'h0000; call_ss_limit_q <= 16'h0000; call_ss_base_q <= 24'h000000;
            call_ss_access_q <= 8'h00; call_ss_class_q <= spk286_protected_pkg::DESC_INVALID;
            call_ss_dpl_q <= 2'd0; call_ss_rpl_q <= 2'd0; call_ss_present_q <= 1'b0; call_ss_table_q <= 1'b0;
            iret_outer_phase_q <= 2'd0;
            iret_outer_ready_q <= 1'b0;
            iret_outer_sp_q <= 16'h0000;
            iret_outer_ss_q <= 16'h0000;
            iret_ss_candidate_valid_q <= 1'b0;
            iret_ss_selector_q <= 16'h0000; iret_ss_limit_q <= 16'h0000;
            iret_ss_base_q <= 24'h000000; iret_ss_access_q <= 8'h00;
            iret_ss_class_q <= spk286_protected_pkg::DESC_INVALID;
            iret_ss_dpl_q <= 2'd0; iret_ss_rpl_q <= 2'd0;
            iret_ss_present_q <= 1'b0; iret_ss_table_q <= 1'b0;
            task_commit_active_q <= 1'b0;
            task_commit_phase_q <= 4'd0;
            task_commit_done_q <= 1'b0;
            task_service_complete_q <= 1'b0;
            task_event_switch_done_q <= 1'b0;
            task_return_started_q <= 1'b0;
            high_byte_q <= 1'b0; temporary_valid_q <= 3'b000;
            flags_valid_q <= 1'b0; result_disposed_q <= 1'b0; result_suppress_q <= 1'b0;
        end else begin
            if (system_begin) begin
                system_active_q <= 1'b1;
                system_index_q <= 2'd0;
                system_limit_q <= 16'h0000;
                system_base_q <= 24'h000000;
                if (system_table_operation) begin
                    address_override <= 1'b1;
                    address_offset <= effective_offset;
                end
            end
            if (descriptor_read_begin) begin
                descriptor_active_q <= 1'b1;
                descriptor_phase_q <= 3'd0;
                descriptor_success_q <= 1'b0;
            end
            if (call_stack_validation_operation && call_gate_outer_required && !call_stack_ready_q &&
                !call_tss_active_state_q && !call_tss_pre_fault) begin
                call_tss_active_state_q <= 1'b1;
                call_tss_phase_q <= 2'd0;
            end
            if (call_tss_operand_done) begin
                if (call_tss_phase_q == 2'd0) call_stack_sp_q <= operand_read_data;
                else begin
                    call_stack_ss_q <= operand_read_data;
                    call_stack_ready_q <= 1'b1;
                    call_tss_active_state_q <= 1'b0;
                end
                call_tss_phase_q <= call_tss_phase_q + 2'd1;
            end
            if (event_gate_begin) begin
                event_gate_active_q <= 1'b1;
                event_gate_phase_q <= 3'd0;
                event_gate_candidate_valid_q <= 1'b0;
            end
            if (iret_outer_frame_operation && !iret_outer_required) begin
                iret_outer_ready_q <= 1'b0;
                iret_ss_candidate_valid_q <= 1'b0;
            end
            if (iret_outer_pop_done) begin
                if (iret_outer_phase_q == 2'd0) iret_outer_sp_q <= operand_read_data;
                else begin
                    iret_outer_ss_q <= operand_read_data;
                    iret_outer_ready_q <= 1'b1;
                end
                iret_outer_phase_q <= iret_outer_phase_q + 2'd1;
            end
            if (cs_validation_success_event) begin
                cs_candidate_valid_q <= 1'b1;
                // RETF/IRET use the saved selector RPL for both conforming
                // and non-conforming targets. Direct transfers and intra-level
                // events retain CPL; inter-level events use the target DPL.
                cs_candidate_selector_q <= {tmp1_q[15:2],
                                            iret_cs_validation_operation ?
                                                descriptor_unused_rpl :
                                            call_gate_cs_validation_operation ?
                                                (descriptor_unused_conforming ? protected_cpl : descriptor_unused_dpl) :
                                            ((event_gate_candidate_valid_q && !descriptor_unused_conforming &&
                                              descriptor_unused_dpl < protected_cpl) ? descriptor_unused_dpl : protected_cpl)};
                cs_candidate_limit_q <= descriptor_limit;
                cs_candidate_base_q <= descriptor_base;
                cs_candidate_access_q <= descriptor_access_rights | ((descriptor_phase_q == 3'd4) ? 8'h01 : 8'h00);
                cs_candidate_class_q <= descriptor_class;
                cs_candidate_dpl_q <= descriptor_unused_dpl;
                cs_candidate_rpl_q <= iret_cs_validation_operation ?
                                      descriptor_unused_rpl :
                                      call_gate_cs_validation_operation ?
                                          (descriptor_unused_conforming ? protected_cpl : descriptor_unused_dpl) :
                                      ((event_gate_candidate_valid_q && !descriptor_unused_conforming &&
                                        descriptor_unused_dpl < protected_cpl) ? descriptor_unused_dpl : protected_cpl);
                cs_candidate_present_q <= descriptor_present;
                cs_candidate_table_q <= descriptor_selector_ti;
                if (call_gate_cs_validation_operation ||
                    (event_gate_candidate_valid_q && !descriptor_unused_conforming && descriptor_unused_dpl < protected_cpl)) begin
                    call_gate_target_dpl_q <= call_gate_cs_validation_operation && descriptor_unused_conforming ?
                                              protected_cpl : descriptor_unused_dpl;
                end
                if (event_gate_candidate_valid_q && !descriptor_unused_conforming && descriptor_unused_dpl < protected_cpl) begin
                    // Reuse the inter-level stack-switch service for an
                    // inter-level event frame.  The event path never copies
                    // call-gate parameters, so its count remains zero.
                    call_gate_candidate_valid_q <= 1'b1;
                    call_gate_parameter_count_q <= 5'd0;
                end
            end
            if (descriptor_operand_done && descriptor_phase_q == 3'd3 &&
                (call_gate_validation_operation || jmp_gate_target_begin) &&
                descriptor_call_gate_success_live) begin
                call_gate_candidate_valid_q <= 1'b1;
                call_gate_parameter_count_q <= descriptor_unused_gate_parameter_count;
                tmp0_q <= descriptor_unused_gate_offset;
                tmp1_q <= descriptor_unused_gate_selector;
                temporary_valid_q[0] <= 1'b1;
                temporary_valid_q[1] <= 1'b1;
            end
            if (descriptor_operand_done && descriptor_phase_q == 3'd3 &&
                (call_gate_validation_operation || cs_validation_operation) &&
                task_descriptor_success_live) begin
                task_descriptor_candidate_valid_q <= 1'b1;
                task_descriptor_selector_q <= task_gate_target_active_q ? task_gate_target_selector_q : tmp1_q;
                task_descriptor_limit_q <= descriptor_limit;
                task_descriptor_base_q <= descriptor_base;
                task_descriptor_access_q <= descriptor_access_rights;
                task_descriptor_address_q <= descriptor_selector_address;
            end
            if (descriptor_operand_done && descriptor_phase_q == 3'd3 && call_ss_validation_operation &&
                descriptor_call_ss_success_live && descriptor_unused_accessed) begin
                call_ss_candidate_valid_q <= 1'b1;
                call_ss_selector_q <= call_stack_ss_q;
                call_ss_limit_q <= descriptor_limit;
                call_ss_base_q <= descriptor_base;
                call_ss_access_q <= descriptor_access_rights;
                call_ss_class_q <= descriptor_class;
                call_ss_dpl_q <= descriptor_unused_dpl;
                call_ss_rpl_q <= descriptor_unused_rpl;
                call_ss_present_q <= descriptor_present;
                call_ss_table_q <= descriptor_selector_ti;
            end
            if (descriptor_operand_done && descriptor_phase_q == 3'd4 && call_ss_validation_operation && descriptor_success_q) begin
                call_ss_candidate_valid_q <= 1'b1;
                call_ss_selector_q <= call_stack_ss_q;
                call_ss_limit_q <= descriptor_limit;
                call_ss_base_q <= descriptor_base;
                call_ss_access_q <= descriptor_access_rights | 8'h01;
                call_ss_class_q <= descriptor_class;
                call_ss_dpl_q <= descriptor_unused_dpl;
                call_ss_rpl_q <= descriptor_unused_rpl;
                call_ss_present_q <= descriptor_present;
                call_ss_table_q <= descriptor_selector_ti;
            end
            if (call_gate_stack_switch_begin) begin
                call_gate_stack_switch_active_q <= 1'b1;
                call_gate_stack_switch_phase_q <= 2'd0;
                call_gate_stack_data_q <= protected_ss_selector;
                stack_cursor_q <= call_stack_sp_q;
                stack_cursor_valid_q <= 1'b1;
            end
            if (call_gate_stack_write_done) begin
                if (call_gate_stack_switch_phase_q == 2'd0) begin
                    call_gate_stack_data_q <= stack_pointer;
                    call_gate_stack_switch_phase_q <= 2'd1;
                end else begin
                    call_gate_stack_switch_phase_q <= 2'd2;
                end
            end
            if (copy_call_parameters && call_gate_outer_required && !call_parameter_active_q &&
                call_gate_parameter_count_q != 5'd0) begin
                call_parameter_active_q <= 1'b1;
                call_parameter_phase_q <= 2'd0;
                call_parameter_remaining_q <= call_gate_parameter_count_q;
                call_parameter_source_sp_q <= 16'(stack_pointer +
                                               {11'd0, call_gate_parameter_count_q, 1'b0} - 16'd2);
            end
            if (call_parameter_read_done) begin
                call_parameter_data_q <= operand_read_data;
                call_parameter_phase_q <= 2'd1;
            end
            if (call_parameter_write_done) begin
                stack_cursor_q <= stack_cursor_q - 16'd2;
                if (call_parameter_remaining_q == 5'd1) begin
                    call_parameter_active_q <= 1'b0;
                    call_parameter_phase_q <= 2'd0;
                    call_parameter_remaining_q <= 5'd0;
                end else begin
                    call_parameter_phase_q <= 2'd0;
                    call_parameter_remaining_q <= call_parameter_remaining_q - 5'd1;
                    call_parameter_source_sp_q <= call_parameter_source_sp_q - 16'd2;
                end
            end
            if (descriptor_operand_done && descriptor_phase_q == 3'd3 && iret_ss_validation_operation &&
                descriptor_iret_ss_success_live && descriptor_unused_accessed) begin
                iret_ss_candidate_valid_q <= 1'b1;
                iret_ss_selector_q <= iret_outer_ss_q;
                iret_ss_limit_q <= descriptor_limit;
                iret_ss_base_q <= descriptor_base;
                iret_ss_access_q <= descriptor_access_rights;
                iret_ss_class_q <= descriptor_class;
                iret_ss_dpl_q <= descriptor_unused_dpl;
                iret_ss_rpl_q <= descriptor_unused_rpl;
                iret_ss_present_q <= descriptor_present;
                iret_ss_table_q <= descriptor_selector_ti;
            end
            if (descriptor_operand_done && descriptor_phase_q == 3'd4 && iret_ss_validation_operation && descriptor_success_q) begin
                iret_ss_candidate_valid_q <= 1'b1;
                iret_ss_selector_q <= iret_outer_ss_q;
                iret_ss_limit_q <= descriptor_limit;
                iret_ss_base_q <= descriptor_base;
                iret_ss_access_q <= descriptor_access_rights | 8'h01;
                iret_ss_class_q <= descriptor_class;
                iret_ss_dpl_q <= descriptor_unused_dpl;
                iret_ss_rpl_q <= descriptor_unused_rpl;
                iret_ss_present_q <= descriptor_present;
                iret_ss_table_q <= descriptor_selector_ti;
            end
            if (descriptor_operand_done) begin
                case (descriptor_phase_q)
                    3'd0: begin descriptor_word0_q <= operand_read_data; descriptor_phase_q <= 3'd1; end
                    3'd1: begin descriptor_word1_q <= operand_read_data; descriptor_phase_q <= 3'd2; end
                    3'd2: begin descriptor_word2_q <= operand_read_data; descriptor_phase_q <= 3'd3; end
                    3'd3: begin
                        descriptor_word3_q <= operand_read_data;
                        if (jmp_gate_target_begin) begin
                            // Keep VALIDATE_CS pending, but start a fresh read
                            // so null, table-limit and LDTR checks run on the
                            // target selector before any target descriptor bus cycle.
                            descriptor_active_q <= 1'b0;
                            descriptor_phase_q <= 3'd0;
                            descriptor_success_q <= 1'b0;
                        end else if (task_gate_target_begin) begin
                            task_gate_target_active_q <= 1'b1;
                            task_gate_target_selector_q <= descriptor_unused_gate_selector;
                            task_gate_nested_call_q <= call_gate_validation_operation;
                            descriptor_phase_q <= 3'd0;
                            descriptor_success_q <= 1'b0;
                        end else if ((descriptor_load_tr && descriptor_success_live) ||
                            (segment_reload_operation && descriptor_segment_success_live && !descriptor_unused_accessed) ||
                            (cs_validation_operation && descriptor_cs_success_live && !descriptor_unused_accessed) ||
                            (call_gate_cs_validation_operation && descriptor_call_gate_cs_success_live &&
                             !descriptor_cs_offset_fault && !descriptor_unused_accessed) ||
                            (call_ss_validation_operation && descriptor_call_ss_success_live && !descriptor_unused_accessed) ||
                            (iret_cs_validation_operation && descriptor_iret_cs_success_live &&
                             ({1'b0, tmp0_q} <= {1'b0, descriptor_limit}) && !descriptor_unused_accessed) ||
                            (iret_ss_validation_operation && descriptor_iret_ss_success_live && !descriptor_unused_accessed)) begin
                            descriptor_success_q <= 1'b1;
                            descriptor_phase_q <= 3'd4;
                        end else descriptor_active_q <= 1'b0;
                    end
                    default: descriptor_active_q <= 1'b0;
                endcase
            end
            if (event_gate_operand_done) begin
                case (event_gate_phase_q)
                    3'd0: begin event_gate_word0_q <= operand_read_data; event_gate_phase_q <= 3'd1; end
                    3'd1: begin event_gate_word1_q <= operand_read_data; event_gate_phase_q <= 3'd2; end
                    3'd2: begin event_gate_word2_q <= operand_read_data; event_gate_phase_q <= 3'd3; end
                    3'd3: begin
                        event_gate_word3_q <= operand_read_data;
                        event_gate_active_q <= 1'b0;
                        if (event_gate_success_live) begin
                            event_gate_candidate_valid_q <= 1'b1;
                            event_gate_target_selector_q <= event_gate_target_selector;
                            event_gate_target_offset_q <= event_gate_target_offset;
                            event_gate_class_q <= event_gate_class;
                        end
                    end
                    default: event_gate_active_q <= 1'b0;
                endcase
            end
            if (system_operand_done && system_table_operation) begin
                if (system_table_load) begin
                    if (system_index_q == 2'd0) system_limit_q <= operand_read_data;
                    else if (system_index_q == 2'd1) system_base_q[15:0] <= operand_read_data;
                    else system_base_q[23:16] <= operand_read_data[7:0];
                end
                if (system_index_q < 2'd2) begin
                    system_index_q <= system_index_q + 2'd1;
                    address_override <= 1'b1;
                    address_offset <= effective_offset + (system_index_q == 2'd0 ? 16'd2 : 16'd4);
                end
            end
            if (fetch_port && operation_done) begin
                tmp1_q <= port_immediate ? {8'd0, byte_data} : port_register; temporary_valid_q[1] <= 1'b1;
            end
            if (string_index_write) begin
                address_override <= 1'b1; address_offset <= string_index; string_destination <= string_step_dest;
            end
            if (string_read_acc) begin
                tmp0_q <= string_byte ? {8'd0,register_state[7:0]} : register_state[15:0]; temporary_valid_q[0] <= 1'b1;
            end
            if (string_continue) address_override <= 1'b0;
            if (begin_stack_cursor) begin stack_cursor_q <= stack_pointer; stack_cursor_valid_q <= 1'b1; end
            if (begin_return_cursor) begin
                stack_cursor_q <= stack_pointer;
                stack_cursor_valid_q <= 1'b1;
                protected_return_cursor_q <= 1'b1;
            end
            if (stack_write_sp && (stack_cursor_valid_q || begin_return_cursor)) stack_cursor_q <= stack_next_sp;
            if (read_stack_cursor) begin tmp0_q <= stack_cursor_q; temporary_valid_q[0] <= 1'b1; end
            if (frame_read_gpr) begin tmp0_q <= register_state[frame_read_index*16 +: 16]; temporary_valid_q[0] <= 1'b1; end
            if (save_auxiliary) begin auxiliary_q <= tmp0_q; auxiliary_valid_q <= 1'b1; end
            if (restore_auxiliary) begin tmp0_q <= auxiliary_q; temporary_valid_q[0] <= 1'b1; end
            if (save_allocation) begin allocation_q <= tmp0_q; allocation_valid_q <= 1'b1; end
            if (load_counter) begin counter_q <= tmp1_q[4:0]; counter_valid_q <= 1'b1; end
            if (decrement_counter) counter_q <= counter_q - 5'd1;
            if (set_frame_address) begin frame_address_q <= tmp0_q; frame_address_valid_q <= 1'b1; end
            if (decrement_frame_address) frame_address_q <= frame_address_q - 16'd2;
            if (set_ea_plus2) begin address_override <= 1'b1; address_offset <= effective_offset + 16'd2; end
            if (read_segment) begin tmp0_q <= segment_read_value; temporary_valid_q[0] <= 1'b1; end
            if (read_ea) begin tmp0_q <= effective_offset; temporary_valid_q[0] <= 1'b1; end
            if (read_target) begin tmp1_q <= target_read_data; temporary_valid_q[1] <= 1'b1; end
            if (add_base) begin tmp1_q <= address_base + tmp0_q; temporary_valid_q[1] <= 1'b1; end
            if (set_address) begin address_override <= 1'b1; address_offset <= tmp1_q; end
            if (sign_extend_byte) tmp0_q <= {{8{tmp0_q[7]}}, tmp0_q[7:0]};
            if (carry_fill_byte) tmp0_q <= {8'h00, {8{tmp0_q[0]}}};
            if (sign_fill_word) tmp0_q <= {16{tmp0_q[15]}};
            if (constant_one || constant_zero || constant_ones) begin tmp1_q <= constant_zero ? 16'd0 : constant_ones ? 16'hFFFF : 16'd1; temporary_valid_q[1] <= 1'b1; end
            if (count_low) begin tmp1_q <= {8'd0, count_value[7:0]}; temporary_valid_q[1] <= 1'b1; end
            if (fetch_word && byte_valid) begin
                if (fetch_tmp1) begin
                    if (high_byte_q) tmp1_q[15:8] <= byte_data;
                    else tmp1_q[7:0] <= byte_data;
                    temporary_valid_q[1] <= high_byte_q;
                end else begin
                    if (high_byte_q) tmp0_q[15:8] <= byte_data;
                    else tmp0_q[7:0] <= byte_data;
                    temporary_valid_q[0] <= high_byte_q;
                end
                high_byte_q <= !high_byte_q;
            end
            if (fetch_signed_byte && byte_valid) begin
                if (operation == spk286_microcode_pkg::MC_FETCH_IMM8S_TMP0) begin
                    tmp0_q <= {{8{byte_data[7]}}, byte_data}; temporary_valid_q[0] <= 1'b1;
                end else begin
                    tmp1_q <= {{8{byte_data[7]}}, byte_data}; temporary_valid_q[1] <= 1'b1;
                end
            end
            if (read_operand && operand_done) begin
                if (call_tss_operand_done) begin
                    // The TSS service owns SPn/SSn; these reads must not
                    // overwrite the instruction temporaries.
                end
                else if (iret_outer_pop_done) begin
                    // The outer IRET frame words have dedicated candidates;
                    // do not overwrite the validated IP/CS/FLAGS temporaries.
                end
                else if (call_parameter_read) begin
                    // Parameter-copy reads have a dedicated data latch; the
                    // gate target offset must remain in TMP0 for the tail.
                end
                else if (operation == spk286_microcode_pkg::MC_POP16_TMP2) begin tmp2_q <= operand_read_data; temporary_valid_q[2] <= 1'b1; end
                else if (read_tmp1 || vector_cs || event_gate_vector_cs || operation == spk286_microcode_pkg::MC_POP16_TMP1) begin tmp1_q <= operand_read_data; temporary_valid_q[1] <= 1'b1; end
                else begin tmp0_q <= operand_read_data; temporary_valid_q[0] <= 1'b1; end
                if (event_gate_vector_ip) event_gate_target_offset_q <= operand_read_data;
                if (event_gate_vector_cs) begin
                    event_gate_target_selector_q <= operand_read_data;
                    event_gate_candidate_valid_q <= 1'b1;
                end
            end
            if (fetch_byte_tmp1 && byte_valid) begin tmp1_q <= {8'd0, byte_data}; temporary_valid_q[1] <= 1'b1; end
            if (fetch_byte && byte_valid) begin tmp0_q <= {8'd0, byte_data}; temporary_valid_q[0] <= 1'b1; end
            if (read_flags || read_event_flags || read_event_cs || read_event_ip) begin
                tmp0_q <= read_flags ? architectural_flags : (read_event_flags ? event_flags : (read_event_cs ? event_cs : event_ip));
                temporary_valid_q[0] <= 1'b1;
            end
            if (event_gate_ip_operation && event_gate_candidate_valid_q) begin
                tmp0_q <= event_gate_target_offset_q;
                temporary_valid_q[0] <= 1'b1;
            end
            if (event_gate_cs_operation && event_gate_candidate_valid_q) begin
                tmp1_q <= event_gate_target_selector_q;
                temporary_valid_q[1] <= 1'b1;
            end
            if (read_ip) begin tmp0_q <= architectural_ip; temporary_valid_q[0] <= 1'b1; end
            if (target_relative || target_absolute) begin
                target_q <= target_relative ? architectural_ip + tmp1_q : tmp0_q;
                target_valid_q <= 1'b1;
            end
            if (redirect_operation && operation_done) target_valid_q <= 1'b0;
            if (read_destination) begin tmp0_q <= operation == spk286_microcode_pkg::MC_READ_DST8 ? {8'd0, destination_byte_data} : destination_read_data; temporary_valid_q[0] <= 1'b1; end
            if (muldiv_complete) begin
                tmp2_q <= muldiv_low; temporary_valid_q[2] <= 1'b1;
                auxiliary_q <= muldiv_high; auxiliary_valid_q <= 1'b1;
                arithmetic_fault_q <= muldiv_fault; result_suppress_q <= !muldiv_write;
                flags_q <= muldiv_flags; flags_mask_q <= muldiv_mask;
                flags_valid_q <= 1'b1; result_disposed_q <= 1'b0;
                result_high_pending_q <= !muldiv_byte && !muldiv_immediate;
            end
            if (write_result_ax) begin
                temporary_valid_q[2] <= 1'b0; result_disposed_q <= !result_high_pending_q;
            end
            if (write_result_dx) begin
                auxiliary_valid_q <= 1'b0; result_high_pending_q <= 1'b0; result_disposed_q <= 1'b1;
            end
            if (immediate_fetch && byte_valid) begin
                if (immediate_word) high_byte_q <= !high_byte_q;
                if (immediate_register || immediate_alu) begin
                    tmp1_q <= (immediate_word && !high_byte_q) ? {8'd0, byte_data} : immediate_value;
                    temporary_valid_q[1] <= immediate_last;
                end else begin
                    tmp0_q <= (immediate_word && !high_byte_q) ? {8'd0, byte_data} : immediate_value;
                    temporary_valid_q[0] <= immediate_last;
                end
            end
            if (register_capture || direct_register_capture || immediate_capture) begin
                tmp0_q <= register_a_value;
                tmp1_q <= immediate_capture ? immediate_value : register_b_value;
                temporary_valid_q[1:0] <= 2'b11;
                register_destination_q <= register_a_index;
                register_pending_q <= 1'b1;
            end
            if (register_complete) register_pending_q <= 1'b0;
            if (compute_alu || shift_complete || adjust_complete) begin
                arithmetic_fault_q <= adjust_complete && adjust_fault;
                result_suppress_q <= adjust_complete ? !adjust_write : shift_complete && !shift_write;
                tmp2_q <= adjust_complete ? adjust_result : shift_complete ? shift_result : alu_result; temporary_valid_q[2] <= 1'b1;
                flags_q <= adjust_complete ? adjust_flags : shift_complete ? shift_flags : alu_flags;
                flags_mask_q <= adjust_complete ? adjust_mask : shift_complete ? shift_mask : (decoded_flags_mask & ~decoded_undefined_mask);
                flags_valid_q <= 1'b1; result_disposed_q <= 1'b0;
            end
            if (commit_result && operation_done) begin
                temporary_valid_q[2] <= 1'b0;
                result_disposed_q <= 1'b1;
            end
            if (commit_flags) flags_valid_q <= 1'b0;
            if (task_service_commit_ready && !task_commit_active_q) begin
                task_commit_active_q <= 1'b1;
                task_commit_phase_q <= 4'd0;
            end else if (task_commit_active_q) begin
                if (task_commit_done) begin
                    task_commit_active_q <= 1'b0;
                    task_commit_phase_q <= 4'd0;
                end else if (task_commit_phase_q == 4'd10 && !task_service_complete_q) begin
                    task_commit_phase_q <= task_commit_phase_q;
                end else task_commit_phase_q <= task_commit_phase_q + 4'd1;
            end
            if (task_service_complete) task_service_complete_q <= 1'b1;
            if (task_switch_start) begin
                task_commit_done_q <= 1'b0;
                task_service_complete_q <= 1'b0;
                task_event_switch_done_q <= 1'b0;
            end
            if (task_commit_done) task_commit_done_q <= 1'b1;
            if ((task_commit_done || task_commit_done_q) && task_service_complete_q && event_gate_candidate_valid_q &&
                event_gate_class_q == spk286_protected_pkg::DESC_TASK_GATE)
                task_event_switch_done_q <= 1'b1;
            if (task_return_start) task_return_started_q <= 1'b1;
            if (task_return_finish) task_return_started_q <= 1'b0;
        end
    end
endmodule
