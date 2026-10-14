// SPDX-License-Identifier: MIT
// Standalone CPU: decoder -> generated microcode -> functional datapath service.
// Architectural state, prefetch storage and physical fetch retain separate owners.
`timescale 1ns/1ps

module spk286 (
    input  logic         clk,
    input  logic         reset,
    input  logic         ready,
    input  logic [15:0]  data_in,
    input  logic         execute_enable,
    input  logic [1:0]   timing_policy_request,
    input  logic         intr, nmi, hold_request,
    output logic         halted, shutdown, event_completed,
    output logic [7:0]   debug_event_vector,
    output logic [2:0]   debug_event_kind,
    output logic         debug_event_error_valid,
    output logic [15:0]  debug_event_error_code,
    output logic [7:0]   debug_fault_vector,
    output logic [15:0]  debug_fault_error_code,
    output logic [15:0]  debug_instruction_ip,
    output logic         debug_nmi_pending, debug_nmi_blocked, debug_sti_shadow,

    input  logic [2:0]   gpr_read_a_index,
    input  logic [2:0]   gpr_read_b_index,
    input  logic         gpr_read_a_byte,
    input  logic         gpr_read_b_byte,
    output logic [15:0]  gpr_read_a_data,
    output logic [15:0]  gpr_read_b_data,
    input  logic         gpr_write_en,
    input  logic         gpr_write_byte,
    input  logic [2:0]   gpr_write_index,
    input  logic [15:0]  gpr_write_data,
    input  logic         ip_write_en,
    input  logic [15:0]  ip_write_data,
    input  logic         flags_write_en,
    input  logic [15:0]  flags_write_data,
    input  logic [15:0]  flags_write_mask,
    input  logic         segment_load_en,
    input  logic [1:0]   segment_load_index,
    input  logic [15:0]  segment_load_selector,
    input  logic [1:0]   segment_read_index,
    input  logic [15:0]  segment_offset,
    output logic [15:0]  segment_selector,
    output logic [23:0]  segment_base,
    output logic [15:0]  segment_limit,
    output logic [7:0]   segment_access,
    output logic [23:0]  segment_address,
    input  logic         redirect,
    output logic         control_error,
    output logic         unsupported_opcode,
    output logic [7:0]   debug_opcode,
    output logic         instruction_retired,
    output logic         microcode_fault,
    output logic         operand_blocked,
    output logic [7:0]   debug_modrm,
    output logic [15:0]  debug_displacement,
    output logic [15:0]  debug_effective_offset,
    output logic [1:0]   debug_operand_segment,

    input  logic         fetch_request,
    output logic         fetch_request_ready,
    input  logic         fetch_ready,
    output logic         fetch_valid,
    output logic [15:0]  fetch_data,
    output logic [15:0]  fetch_ip,
    output logic [1:0]   fetch_count,
    output logic         fetch_blocked,

    output logic [23:0]  address,
    output logic [15:0]  data_out,
    output logic         data_oe,
    output logic         bus_valid,
    output logic         bus_write,
    output logic         bus_bhe_n,
    output logic [3:0]   bus_status,
    output logic         bus_lock,
    output logic         hlda,

    output logic [15:0]  debug_cs,
    output logic [23:0]  debug_cs_base,
    output logic [15:0]  debug_ip,
    output logic [15:0]  debug_flags,
    output logic [127:0] debug_gpr,
    output logic [63:0]  debug_segment_selectors,
    output logic [95:0]  debug_segment_bases,
    output logic [63:0]  debug_segment_limits,
    output logic [31:0]  debug_segment_access,
    output logic [15:0]  debug_protected_msw,
    output logic [15:0]  debug_gdtr_limit, debug_idtr_limit,
    output logic [23:0]  debug_gdtr_base, debug_idtr_base,
    output logic [15:0]  debug_ldtr_selector, debug_tr_selector,
    output logic [15:0]  debug_ldtr_limit, debug_tr_limit,
    output logic [23:0]  debug_ldtr_base, debug_tr_base,
    output logic [16:0]  debug_fetch_cursor,
    output logic [11:0]  debug_micro_pc,
    output logic [11:0]  debug_micro_entry,
    output logic [spk286_microcode_pkg::MC_WORD_WIDTH-1:0] debug_micro_instruction,
    output logic         debug_micro_active,
    output logic [3:0]   debug_prefetch_count,
    output logic [3:0]   debug_bus_state,
    output logic [3:0]   debug_bus_transaction,
    output logic [63:0]  debug_timing_cycle_count,
    output logic [63:0]  debug_timing_biu_busy_cycles,
    output logic [63:0]  debug_timing_accepted_transfers,
    output logic [63:0]  debug_timing_ready_wait_cycles,
    output logic [63:0]  debug_timing_prefetch_requests,
    output logic [63:0]  debug_timing_prefetch_responses,
    output logic [63:0]  debug_timing_queue_consumes,
    output logic [63:0]  debug_timing_queue_empty_cycles,
    output logic [63:0]  debug_timing_redirects,
    output logic [63:0]  debug_timing_cancels,
    output logic [63:0]  debug_timing_operand_wait_cycles,
    output logic [63:0]  debug_timing_event_requests,
    output logic [63:0]  debug_timing_event_completes,
    output logic [63:0]  debug_timing_compatibility_delay_cycles,
    output logic [3:0]   debug_timing_queue_count,
    output logic [7:0]   debug_timing_schema_version,
    output logic [1:0]   debug_timing_policy,
    output logic         debug_timing_policy_error,
    output logic         debug_timing_policy_locked,
    output logic         debug_timing_trace_valid,
    output logic [63:0]  debug_timing_trace_cycle,
    output logic [23:0]  debug_timing_trace_address,
    output logic [3:0]   debug_timing_trace_status,
    output logic [15:0]  debug_timing_trace_data,
    output logic [1:0]   debug_timing_trace_lane_mask,
    output logic         debug_timing_trace_write,
    output logic [1:0]   debug_timing_trace_owner,
    output logic         debug_timing_trace_lock,
    output logic         debug_timing_trace_hold,
    output logic         debug_timing_trace_hlda,
    output logic         debug_timing_trace_ready,
    output logic [2:0]   debug_timing_trace_phase
);
    logic commit_allowed;
    logic restart, stream_restart, internal_redirect;
    logic [15:0] internal_target, stream_ip, stack_offset, service_offset;
    logic [1:0] service_segment;
    logic stack_request, operand_check, condition_taken, branch_taken;
    logic push_enabled, push_return_ip, decrement_count, form_supported;
    logic [23:0] fetch_address;
    logic fetch_bus_valid, fetch_bus_bhe_n;
    logic fetch_bus_ready;
    logic fetch_response_ready;
    logic fetch_request_internal, fetch_request_ready_internal;
    logic fetch_response_valid;
    logic [15:0] fetch_response_data, fetch_response_ip;
    logic [1:0] fetch_response_count;
    logic [1:0] timing_policy_active;

    logic queue_flush, queue_fill_ready;
    logic queue_consume_valid, queue_consume_ready;
    logic [7:0] queue_consume_data;
    logic [3:0] queue_count;

    logic [2:0] destination_q, source_index_q;
    logic [15:0] direct_flags_data, direct_flags_mask;
    logic [7:0] opcode_q;
    logic unsupported_q;
    logic is_prefix, prefix_accept, context_active, segment_override, lock_prefix, length_fault, extended_opcode_active;
    logic [1:0] override_segment, repeat_kind;
    logic io_transfer;
    logic [15:0] io_port;
    logic string_byte, string_compare, string_request, string_destination, repeat_boundary, repeat_stepped;
    logic [3:0] instruction_bytes;
    logic execution_allowed, decode_supported, decode_ready, micro_start;
    logic [2:0] decode_destination, decode_source_index;
    logic [spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] decode_entry, micro_pc, micro_entry;
    logic [spk286_microcode_pkg::MC_WORD_WIDTH-1:0] micro_word;
    logic dispatch_request, dispatch_valid, reverse_operands, arithmetic_fault;
    logic [2:0] adjust_kind;
    logic [1:0] muldiv_kind;
    logic counter_branch_request, range_fault, bounds_fault;
    logic [spk286_microcode_pkg::MC_ADDR_WIDTH:0] counter_branch_target;
    assign counter_branch_target = spk286_microcode_pkg::micro_branch_target(micro_pc);
    logic [spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] dispatch_entry;
    logic micro_active, micro_valid, micro_end, operation_valid, operation_done, operation_retire;
    logic executor_done, executor_byte_ready;
    logic internal_gpr_write_en, internal_gpr_write_byte, internal_ip_write_en;
    logic [2:0] internal_gpr_write_index;
    logic [15:0] internal_gpr_write_data, internal_ip_write_data;
    logic effective_gpr_write_en, effective_ip_write_en, effective_flags_write_en;
    logic [2:0] effective_gpr_write_index;
    logic [15:0] effective_gpr_write_data, effective_ip_write_data;
    logic [127:0] register_state;
    logic operand_decode_enable, operand_decode_done, operand_byte_ready, operand_context_valid;
    logic [1:0] operand_mode, operand_segment;
    logic [2:0] operand_reg, operand_rm;
    logic operand_register_direct;
    logic [15:0] operand_displacement, operand_offset;
    logic address_override, implicit_lock;
    logic [15:0] address_offset;
    logic operand_request, operand_write, operand_select_rm, operand_done, operand_byte;
    logic unlimited_memory_done, executor_operand_done;
    logic [15:0] operand_write_data, operand_read_data, executor_operand_read_data;
    logic operand_gpr_write_en, operand_gpr_write_byte;
    logic [2:0] operand_gpr_write_index;
    logic [15:0] operand_gpr_write_data;
    logic memory_request, memory_request_ready, memory_write, memory_byte;
    logic [23:0] memory_address;
    logic [15:0] memory_write_data, memory_read_data;
    logic memory_response_valid, memory_response_ready;
    logic operand_memory_request, operand_memory_write, operand_memory_byte;
    logic [23:0] operand_memory_address;
    logic [15:0] operand_memory_write_data;
    logic operand_memory_response_ready;
    logic operand_service_wait;
    logic task_memory_request, task_memory_write, task_memory_byte;
    logic [23:0] task_memory_address;
    logic [15:0] task_memory_write_data;
    logic task_memory_done;
    logic task_service_busy, task_service_complete, task_service_commit_ready, task_service_fault;
    logic task_memory_lock;
    logic loadall_memory_request, loadall_memory_done;
    logic loadall_memory_write, loadall_memory_byte;
    logic [23:0] loadall_memory_address;
    logic [15:0] loadall_memory_write_data;
    logic loadall_complete, loadall_fault, loadall_commit_valid;
    logic [7:0] loadall_fault_vector;
    logic [15:0] loadall_fault_error_code;
    logic [15:0] loadall_msw, loadall_ip, loadall_flags;
    logic [127:0] loadall_gpr;
    logic [15:0] loadall_gdtr_limit, loadall_idtr_limit;
    logic [23:0] loadall_gdtr_base, loadall_idtr_base;
    logic [15:0] loadall_ldtr_selector, loadall_tr_selector;
    logic [23:0] loadall_ldtr_base, loadall_tr_base;
    logic [15:0] loadall_ldtr_limit, loadall_tr_limit;
    logic [7:0] loadall_ldtr_access, loadall_tr_access;
    logic [3:0] loadall_ldtr_class, loadall_tr_class;
    logic loadall_ldtr_valid, loadall_ldtr_present, loadall_tr_valid, loadall_tr_present;
    logic [63:0] loadall_segment_selectors, loadall_segment_limits;
    logic [95:0] loadall_segment_bases;
    logic [31:0] loadall_segment_access;
    logic [15:0] loadall_segment_classes;
    logic [3:0] loadall_segment_valid, loadall_segment_present;
    logic [3:0] loadall_segment_protected, loadall_segment_tables;
    logic [7:0] loadall_segment_dpl, loadall_segment_rpl;
    logic loadall_start;
    logic [7:0] task_service_fault_vector;
    logic [15:0] task_service_fault_error_code;
    logic task_switch_start;
    logic [15:0] task_switch_target_selector, task_switch_target_limit;
    logic [23:0] task_switch_target_base, task_switch_target_descriptor_address;
    logic [7:0] task_switch_target_access;
    logic [15:0] task_loaded_ip, task_loaded_flags, task_loaded_ldtr, task_loaded_ldtr_limit;
    logic [23:0] task_loaded_ldtr_base;
    logic [7:0] task_loaded_ldtr_access;
    logic [3:0] task_loaded_ldtr_class;
    logic task_loaded_ldtr_valid, task_loaded_ldtr_present;
    logic [127:0] task_loaded_gpr;
    logic [63:0] task_loaded_segments;
    logic [15:0] task_loaded_tr_selector, task_loaded_tr_limit;
    logic [23:0] task_loaded_tr_base;
    logic [7:0] task_loaded_tr_access;
    logic [63:0] task_cache_selectors, task_cache_limits;
    logic [95:0] task_cache_bases;
    logic [31:0] task_cache_access;
    logic [15:0] task_cache_classes;
    logic [3:0] task_cache_present, task_cache_protected, task_cache_tables;
    logic [7:0] task_cache_dpl, task_cache_rpl;
    logic [2:0] alu_operation;
    logic result_write_allowed, internal_flags_write_en, alu_byte;
    logic [15:0] decoded_flags_mask, decoded_undefined_mask;
    logic [15:0] internal_flags_write_data, internal_flags_write_mask;
    logic internal_task_flags_write;
    logic event_active, event_cancel, event_dispatch, event_request, event_software, event_needs_ack, event_external;
    logic [2:0] event_kind;
    logic [15:0] event_ip, event_cs, event_flags;
    logic event_error_valid;
    logic [15:0] event_error_code;
    logic opcode_start, service_start, raw_retired, context_commit, vector_request, halt_request;
    logic software_request, software_taken, fault_request, invalid_form, demanded_code_fault;
    logic opcode_invalid, invalid_opcode_fault;
    logic [7:0] software_vector, selected_software_vector, fault_vector;
    logic [15:0] context_cs, vector_offset;
    logic ack_request, ack_request_ready, ack_response_valid, ack_response_ready, ack_pending_q, ack_done;
    logic [7:0] ack_vector;
    logic internal_segment_write, unused_ss_shadow;
    logic [1:0] decoded_segment_index;
    logic [15:0] internal_segment_data;
    logic semantic_cancel;
    logic [3:0] biu_status;
    logic [23:0] biu_address;
    logic timing_prefetch_response_accept, timing_queue_consume;
    logic [15:0] protected_msw, protected_gdtr_limit, protected_idtr_limit;
    logic [23:0] protected_gdtr_base, protected_idtr_base;
    logic protected_msw_load_en, protected_gdtr_load_en, protected_idtr_load_en;
    logic [15:0] protected_msw_load_data, protected_msw_load_mask;
    logic [15:0] protected_gdtr_load_limit, protected_idtr_load_limit;
    logic [23:0] protected_gdtr_load_base, protected_idtr_load_base;
    logic protected_ldtr_commit_en, protected_tr_commit_en;
    logic [15:0] protected_ldtr_commit_selector, protected_tr_commit_selector;
    logic [23:0] protected_ldtr_commit_base, protected_tr_commit_base;
    logic [15:0] protected_ldtr_commit_limit, protected_tr_commit_limit;
    logic [7:0] protected_ldtr_commit_access, protected_tr_commit_access;
    logic [3:0] protected_ldtr_commit_class, protected_tr_commit_class;
    logic protected_ldtr_commit_present, protected_tr_commit_present;
    logic protected_ldtr_commit_valid, protected_tr_commit_valid;
    logic task_nested_call, task_jump_task, task_return_task;
    logic task_switch_nested_call, task_switch_return_task;
    logic protected_descriptor_access;
    logic [23:0] protected_descriptor_address;
    logic protected_gate_access;
    logic protected_tss_access;
    logic [23:0] protected_tss_address;
    logic protected_call_stack_access;
    logic [23:0] protected_call_stack_address;
    logic [15:0] protected_call_stack_limit;
    logic protected_call_stack_expand_down;
    logic protected_event_access;
    logic [23:0] protected_event_address;
    logic system_limit_fault, system_fault;
    logic [7:0] system_fault_vector;
    logic [15:0] system_fault_error_code;
    logic task_fault_external;
    logic fault_error_valid;
    logic [15:0] fault_error_code;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] protected_ldtr_selector, protected_ldtr_limit, protected_tr_selector, protected_tr_limit;
    logic [23:0] protected_ldtr_base, protected_tr_base;
    logic [7:0] protected_ldtr_access, protected_tr_access;
    logic [3:0] protected_ldtr_class, protected_tr_class;
    logic protected_ldtr_valid, protected_ldtr_present, protected_tr_valid, protected_tr_present;
    logic [63:0] protected_segment_selectors, protected_segment_limits;
    logic [95:0] protected_segment_bases;
    logic [31:0] protected_segment_access;
    logic [15:0] protected_segment_classes;
    logic [3:0] protected_segment_valid, protected_segment_present, protected_segment_protected, protected_segment_tables;
    logic protected_outer_return_commit;
    logic [7:0] protected_segment_dpl, protected_segment_rpl;
    logic [1:0] current_cpl;
    logic protected_segment_commit_en;
    logic [1:0] protected_segment_commit_index;
    logic [15:0] protected_segment_commit_selector, protected_segment_commit_limit;
    logic [23:0] protected_segment_commit_base;
    logic [7:0] protected_segment_commit_access;
    logic [3:0] protected_segment_commit_class;
    logic protected_segment_commit_present, protected_segment_commit_protected;
    logic [1:0] protected_segment_commit_dpl, protected_segment_commit_rpl;
    logic protected_segment_commit_table_indicator;
    logic protected_segment_commit_en2;
    logic [1:0] protected_segment_commit_index2;
    logic [15:0] protected_segment_commit_selector2, protected_segment_commit_limit2;
    logic [23:0] protected_segment_commit_base2;
    logic [7:0] protected_segment_commit_access2;
    logic [3:0] protected_segment_commit_class2;
    logic protected_segment_commit_present2, protected_segment_commit_protected2;
    logic [1:0] protected_segment_commit_dpl2, protected_segment_commit_rpl2;
    logic protected_segment_commit_table_indicator2;
    logic segment_state_commit_en;
    logic [1:0] segment_state_commit_index, segment_state_commit_dpl, segment_state_commit_rpl;
    logic [15:0] segment_state_commit_selector, segment_state_commit_limit;
    logic [23:0] segment_state_commit_base;
    logic [7:0] segment_state_commit_access;
    logic [3:0] segment_state_commit_class;
    logic segment_state_commit_present, segment_state_commit_protected, segment_state_commit_table_indicator;
    logic [15:0] real_segment_selector, real_segment_limit;
    logic [23:0] real_segment_base, real_segment_address, operand_physical_address;
    logic [7:0] real_segment_access;
    logic [63:0] real_segment_selectors, real_segment_limits;
    logic [95:0] real_segment_bases;
    logic [31:0] real_segment_access_state;
    logic protected_access_fault, protected_access_ss_fault, protected_fetch_fault, protected_fetch_invalid;
    logic protected_task_load, task_state_loaded, task_cache_commit, protected_segment_commit_valid;
    logic [1:0] task_cache_commit_index;
    logic protected_segment_is_expand_down, protected_segment_is_code, protected_segment_is_readable, protected_segment_is_writable;
    logic protected_segment_is_present, protected_segment_is_valid, protected_segment_is_loaded;
    logic [1:0] selected_segment_index;
    logic [15:0] selected_segment_selector, selected_segment_limit;
    logic [23:0] selected_segment_base;
    logic [7:0] selected_segment_access;
    /* verilator lint_on UNUSEDSIGNAL */

    // A CS reload requires a coordinated IP write and fetch restart. Reject a
    // malformed controller transaction as a whole, without partial state writes.
    // This is an internal protocol error, not an architectural CPU exception.
    assign control_error = !reset && ((redirect && !ip_write_en) ||
                           (segment_load_en && segment_load_index == 2'd1 && !redirect));
    assign commit_allowed = !control_error;
    assign restart = redirect && commit_allowed;
    assign semantic_cancel = restart || event_cancel;
    // EXT identifies an event external to the program, not every exception.
    // Intel 286 PRM B-1 includes INTR/NMI, single step and NPX #NM/#9;
    // software INT and instruction-generated protection faults keep EXT=0.
    // The event controller retains the original provenance across exception
    // replacement, whose current kind/vector can be #GP/#DF.
    assign task_fault_external = event_active && event_external;
    assign stream_restart = restart || internal_redirect || event_cancel || loadall_commit_valid;
    assign stream_ip = restart ? ip_write_data :
                       (internal_redirect ? internal_target :
                        (loadall_commit_valid ? loadall_ip : debug_ip));
    assign queue_flush = stream_restart;
    assign service_segment = string_request ? (string_destination ? 2'd0 : (segment_override ? override_segment : 2'd3)) : stack_request ? 2'd2 : (segment_override ? override_segment : operand_segment);
    assign implicit_lock = micro_active && !event_active && operand_context_valid && !operand_register_direct && (opcode_q == 8'h86 || opcode_q == 8'h87);
    assign service_offset = io_transfer ? 16'd0 : address_override && !stack_request && !vector_request ? address_offset : vector_request ? vector_offset : (stack_request ? stack_offset : operand_offset);
    assign execution_allowed = execute_enable && commit_allowed && !reset && !restart && !operand_blocked && !unsupported_q &&
                               !shutdown && (!halted || micro_active);

    // Protected-mode segment state is the architectural cache source. During
    // Real Mode the same cache is mirrored from the existing real-mode segment
    // service so PE preserves the currently loaded hidden state until an
    // explicit protected reload commits a descriptor candidate.
    assign segment_state_commit_en = protected_segment_commit_en || protected_segment_commit_en2 ||
                                     (!protected_msw[0] && commit_allowed &&
                                      (segment_load_en || context_commit || internal_segment_write));
    assign segment_state_commit_index = protected_segment_commit_en ? protected_segment_commit_index :
                                        context_commit ? 2'd1 : internal_segment_write ? decoded_segment_index : segment_load_index;
    assign segment_state_commit_selector = protected_segment_commit_en ? protected_segment_commit_selector :
                                           context_commit ? context_cs : internal_segment_write ? internal_segment_data : segment_load_selector;
    assign segment_state_commit_base = protected_segment_commit_en ? protected_segment_commit_base :
                                       {4'h0, segment_state_commit_selector, 4'h0};
    assign segment_state_commit_limit = protected_segment_commit_en ? protected_segment_commit_limit : 16'hFFFF;
    assign segment_state_commit_access = protected_segment_commit_en ? protected_segment_commit_access : 8'h93;
    assign segment_state_commit_class = protected_segment_commit_en ? protected_segment_commit_class : spk286_protected_pkg::DESC_INVALID;
    assign segment_state_commit_present = protected_segment_commit_en ? protected_segment_commit_present : 1'b1;
    assign segment_state_commit_protected = protected_segment_commit_en ? protected_segment_commit_protected : 1'b0;
    assign segment_state_commit_dpl = protected_segment_commit_en ? protected_segment_commit_dpl : 2'd0;
    assign segment_state_commit_table_indicator = protected_segment_commit_en ? protected_segment_commit_table_indicator : 1'b0;
    assign segment_state_commit_rpl = protected_segment_commit_en ? protected_segment_commit_rpl : segment_state_commit_selector[1:0];

    // LMSW preserves the real-mode CS value/cache. Its low selector bits
    // are not a privilege level until a protected CS load has committed.
    // Protected loads normalize CS.RPL to CPL, including conforming code.
    assign current_cpl = protected_segment_protected[1] ? debug_cs[1:0] : 2'd0;
    assign protected_outer_return_commit = context_commit && protected_msw[0] &&
                                           protected_segment_commit_en && protected_segment_commit_en2 &&
                                           protected_segment_commit_index == 2'd1 &&
                                           protected_segment_commit_index2 == 2'd2 &&
                                           protected_segment_commit_selector[1:0] > current_cpl;

    assign selected_segment_index = execute_enable ? service_segment : segment_read_index;
    assign debug_segment_selectors = protected_msw[0] ? protected_segment_selectors : real_segment_selectors;
    assign debug_segment_bases = protected_msw[0] ? protected_segment_bases : real_segment_bases;
    assign debug_segment_limits = protected_msw[0] ? protected_segment_limits : real_segment_limits;
    assign debug_segment_access = protected_msw[0] ? protected_segment_access : real_segment_access_state;
    assign selected_segment_selector = protected_msw[0] ? protected_segment_selectors[selected_segment_index * 16 +: 16] : real_segment_selectors[selected_segment_index * 16 +: 16];
    assign selected_segment_base = protected_msw[0] ? protected_segment_bases[selected_segment_index * 24 +: 24] : real_segment_bases[selected_segment_index * 24 +: 24];
    assign selected_segment_limit = protected_msw[0] ? protected_segment_limits[selected_segment_index * 16 +: 16] : real_segment_limits[selected_segment_index * 16 +: 16];
    assign selected_segment_access = protected_msw[0] ? protected_segment_access[selected_segment_index * 8 +: 8] : real_segment_access_state[selected_segment_index * 8 +: 8];
    assign segment_selector = selected_segment_selector;
    assign segment_base = selected_segment_base;
    assign segment_limit = selected_segment_limit;
    assign segment_access = selected_segment_access;
    assign segment_address = selected_segment_base + {8'h00, (execute_enable ? service_offset : segment_offset)};
    always_comb begin
        operand_physical_address = segment_address;
        if (vector_request) operand_physical_address = {8'd0, vector_offset};
        if (io_transfer) operand_physical_address = {8'd0, io_port};
        if (protected_call_stack_access) operand_physical_address = protected_call_stack_address;
        if (protected_tss_access) operand_physical_address = protected_tss_address;
        if (protected_descriptor_access) operand_physical_address = protected_descriptor_address;
        if (protected_event_access) operand_physical_address = protected_event_address;
    end

    assign protected_segment_is_loaded = protected_msw[0] && protected_segment_protected[service_segment];
    assign protected_segment_is_valid = protected_segment_valid[service_segment];
    assign protected_segment_is_present = protected_segment_present[service_segment];
    assign protected_segment_is_code = selected_segment_access[3];
    assign protected_segment_is_readable = selected_segment_access[1];
    assign protected_segment_is_writable = !protected_segment_is_code && selected_segment_access[1];
    assign protected_segment_is_expand_down = !protected_segment_is_code && selected_segment_access[2];
    // Compare each offset source before the late stack/address selection.
    // I/O and vector accesses are excluded by the common fault qualifier.
    function automatic logic protected_range_exceeded(
        input logic [15:0] offset_value, limit_value,
        input logic expand_down, is_byte
    );
        protected_range_exceeded = expand_down ?
            (offset_value <= limit_value || (!is_byte && offset_value == 16'hFFFF)) :
            (offset_value > limit_value || (!is_byte && offset_value == limit_value));
    endfunction
    logic protected_selected_range_fault, protected_call_range_fault;
    assign protected_selected_range_fault = !parallel_operand_within_limit;
    // Compare cache ranges before selecting the cache and offset sources.
    // Keep real-mode hidden limits, vector/I-O overlap and LOADALL state exact.
    (* keep *) logic [3:0] operand_io_ranges, operand_address_ranges, operand_stack_ranges;
    (* keep *) logic [3:0] operand_regular_ranges, operand_vector_ranges;
    (* keep *) logic [3:0] operand_system_ranges;
    logic parallel_operand_within_limit, parallel_system_cache_fault;
    genvar operand_cache_index;
    generate
    for (operand_cache_index = 0; operand_cache_index < 4; operand_cache_index = operand_cache_index + 1) begin : g_operand_cache_range
        wire [15:0] cache_limit = protected_msw[0] ?
            protected_segment_limits[operand_cache_index*16 +: 16] :
            real_segment_limits[operand_cache_index*16 +: 16];
        wire cache_expand_down = protected_msw[0] &&
            !protected_segment_access[operand_cache_index*8+3] &&
            protected_segment_access[operand_cache_index*8+2];
        assign operand_io_ranges[operand_cache_index] =
            !protected_range_exceeded(16'd0, cache_limit, cache_expand_down, operand_byte);
        assign operand_address_ranges[operand_cache_index] =
            !protected_range_exceeded(address_offset, cache_limit, cache_expand_down, operand_byte);
        assign operand_stack_ranges[operand_cache_index] =
            !protected_range_exceeded(stack_offset, cache_limit, cache_expand_down, operand_byte);
        assign operand_regular_ranges[operand_cache_index] =
            !protected_range_exceeded(operand_offset, cache_limit, cache_expand_down, operand_byte);
        assign operand_vector_ranges[operand_cache_index] =
            !protected_range_exceeded(io_transfer ? 16'd0 : vector_offset, 16'hFFFF, cache_expand_down, operand_byte);
        // Six-byte table operands use the ordinary effective offset.
        // Complete each cache's range comparison before the late index mux.
        assign operand_system_ranges[operand_cache_index] = cache_expand_down ?
            (operand_offset <= cache_limit || operand_offset > 16'hFFFA) :
            ({1'b0, operand_offset} + 17'd5 > {1'b0, cache_limit});
    end
    endgenerate
    assign parallel_operand_within_limit =
        (protected_event_access || protected_descriptor_access || protected_tss_access || protected_call_stack_access) ? 1'b1 :
        vector_request ? operand_vector_ranges[selected_segment_index] :
        io_transfer ? operand_io_ranges[selected_segment_index] :
        address_override && !stack_request ? operand_address_ranges[selected_segment_index] :
        stack_request ? operand_stack_ranges[selected_segment_index] :
        operand_regular_ranges[selected_segment_index];
    assign parallel_system_cache_fault = operand_system_ranges[selected_segment_index];
    assign protected_call_range_fault = stack_request ?
        protected_range_exceeded(stack_offset, protected_call_stack_limit, protected_call_stack_expand_down, operand_byte) :
        address_override ? protected_range_exceeded(address_offset, protected_call_stack_limit, protected_call_stack_expand_down, operand_byte) :
        protected_range_exceeded(operand_offset, protected_call_stack_limit, protected_call_stack_expand_down, operand_byte);
    // Compare the starting offset in parallel with the late width bit.
    // offset + !byte > limit iff offset > limit || (!byte && offset == limit).
    assign protected_access_fault = operand_request && operand_select_rm && !operand_register_direct &&
                                   !protected_descriptor_access && !protected_tss_access && !protected_event_access &&
                                   !io_transfer && !vector_request &&
                                    (protected_call_stack_access ?
                                    (service_segment != 2'd2 || protected_call_range_fault) :
                                    (protected_segment_is_loaded &&
                                     (!protected_segment_is_valid || !protected_segment_is_present ||
                                      (protected_segment_is_code ? (!protected_segment_is_readable || operand_write) :
                                       (stack_request ? (!protected_segment_is_writable || service_segment != 2'd2) :
                                        (operand_write && !protected_segment_is_writable))) ||
                                      protected_selected_range_fault)));
    assign protected_access_ss_fault = protected_access_fault && service_segment == 2'd2;
    assign protected_fetch_invalid = protected_msw[0] && protected_segment_protected[2'd1] &&
                                   (!protected_segment_valid[2'd1] || !protected_segment_present[2'd1] ||
                                    !protected_segment_access[1*8 + 3]);
    // An invalid incoming CS cache is expected while SWITCH_TASKS or event
    // delivery validates it. Only demand a fetch exception at dispatch.
    assign protected_fetch_fault = protected_fetch_invalid && execution_allowed && !event_active && !micro_active;

    // The external state ports remain the setup/debug path. Once execution is
    // enabled, the microcode path owns GPR/IP writeback, while an explicit redirect
    // still has priority for the architectural IP and CS cache transaction.
    assign effective_gpr_write_en = execute_enable ? internal_gpr_write_en : gpr_write_en;
    assign effective_gpr_write_index = execute_enable ? internal_gpr_write_index : gpr_write_index;
    assign effective_gpr_write_data = execute_enable ? internal_gpr_write_data : gpr_write_data;
    assign effective_ip_write_en = restart ? ip_write_en :
                                   (execute_enable ? internal_ip_write_en : ip_write_en);
    assign effective_ip_write_data = restart ? ip_write_data :
                                     (execute_enable ? internal_ip_write_data : ip_write_data);
    assign effective_flags_write_en = execute_enable ? internal_flags_write_en : flags_write_en;

    // Reserve every staged response and the current bus beat before granting
    // another maximum two-byte fetch. A prepared request cannot complete
    // until the previous response leaves its slot; total reserved bytes still
    // fit the six-byte queue even when consumption stops on the next edge.
    logic [4:0] fetch_reserved_bytes;
    assign fetch_reserved_bytes = {1'b0, queue_count} +
        (fetch_response_valid ? {3'b000, fetch_response_count} : 5'd0) +
        (fetch_bus_valid ? 5'd2 : 5'd0);
    assign fetch_request_internal = execute_enable && !event_active && !halted && !shutdown && !unsupported_q && !microcode_fault && !operand_blocked &&
                                    !protected_fetch_invalid && (fetch_reserved_bytes <= 5'd4);
    assign fetch_response_ready = execute_enable ? queue_fill_ready : fetch_ready;

    spk286_registers registers (
        .clk(clk), .reset(reset),
        .read_a_index(gpr_read_a_index), .read_b_index(gpr_read_b_index),
        .read_a_byte(gpr_read_a_byte), .read_b_byte(gpr_read_b_byte),
        .read_a_data(gpr_read_a_data), .read_b_data(gpr_read_b_data),
        .write_en(effective_gpr_write_en && commit_allowed),
        .write_byte(execute_enable ? internal_gpr_write_byte : gpr_write_byte),
        .write_index(effective_gpr_write_index), .write_data(effective_gpr_write_data),
        .ip_write_en(effective_ip_write_en && commit_allowed), .ip_write_data(effective_ip_write_data),
        .flags_write_en(effective_flags_write_en && commit_allowed),
        .flags_write_data(execute_enable ? internal_flags_write_data : flags_write_data),
        .flags_write_mask(execute_enable ? internal_flags_write_mask : flags_write_mask),
        .flags_write_protected_task(execute_enable && internal_task_flags_write),
        .loadall_commit_en(loadall_commit_valid), .loadall_gpr(loadall_gpr),
        .loadall_ip(loadall_ip), .loadall_flags(loadall_flags),
        .gpr_state(register_state), .ip(debug_ip), .flags(debug_flags)
    );

    spk286_protected_state protected_state (
        .clk(clk), .reset(reset),
        .msw_load_en(protected_msw_load_en), .msw_load_data(protected_msw_load_data), .msw_load_mask(protected_msw_load_mask), .msw(protected_msw),
        .gdtr_load_en(protected_gdtr_load_en), .gdtr_load_limit(protected_gdtr_load_limit), .gdtr_load_base(protected_gdtr_load_base),
        .gdtr_limit(protected_gdtr_limit), .gdtr_base(protected_gdtr_base),
        .idtr_load_en(protected_idtr_load_en), .idtr_load_limit(protected_idtr_load_limit), .idtr_load_base(protected_idtr_load_base),
        .idtr_limit(protected_idtr_limit), .idtr_base(protected_idtr_base),
        .ldtr_commit_en(protected_ldtr_commit_en), .ldtr_commit_valid(protected_ldtr_commit_valid),
        .ldtr_commit_selector(protected_ldtr_commit_selector), .ldtr_commit_base(protected_ldtr_commit_base),
        .ldtr_commit_limit(protected_ldtr_commit_limit), .ldtr_commit_access(protected_ldtr_commit_access),
        .ldtr_commit_class(protected_ldtr_commit_class), .ldtr_commit_present(protected_ldtr_commit_present),
        .ldtr_selector(protected_ldtr_selector), .ldtr_base(protected_ldtr_base), .ldtr_limit(protected_ldtr_limit),
        .ldtr_access(protected_ldtr_access), .ldtr_class(protected_ldtr_class), .ldtr_valid(protected_ldtr_valid), .ldtr_present(protected_ldtr_present),
        .tr_commit_en(protected_tr_commit_en), .tr_commit_valid(protected_tr_commit_valid),
        .tr_commit_selector(protected_tr_commit_selector), .tr_commit_base(protected_tr_commit_base),
        .tr_commit_limit(protected_tr_commit_limit), .tr_commit_access(protected_tr_commit_access),
        .tr_commit_class(protected_tr_commit_class), .tr_commit_present(protected_tr_commit_present),
        .tr_selector(protected_tr_selector), .tr_base(protected_tr_base), .tr_limit(protected_tr_limit),
        .tr_access(protected_tr_access), .tr_class(protected_tr_class), .tr_valid(protected_tr_valid), .tr_present(protected_tr_present),
        .segment_commit_en(segment_state_commit_en), .segment_commit_valid(protected_segment_commit_valid), .segment_commit_index(segment_state_commit_index),
        .segment_commit_selector(segment_state_commit_selector), .segment_commit_base(segment_state_commit_base),
        .segment_commit_limit(segment_state_commit_limit), .segment_commit_access(segment_state_commit_access),
        .segment_commit_class(segment_state_commit_class), .segment_commit_present(segment_state_commit_present),
        .segment_commit_protected(segment_state_commit_protected), .segment_commit_dpl(segment_state_commit_dpl),
        .segment_commit_table_indicator(segment_state_commit_table_indicator), .segment_commit_rpl(segment_state_commit_rpl),
        .segment_commit_en2(protected_segment_commit_en2), .segment_commit_valid2(1'b1), .segment_commit_index2(protected_segment_commit_index2),
        .segment_commit_selector2(protected_segment_commit_selector2), .segment_commit_base2(protected_segment_commit_base2),
        .segment_commit_limit2(protected_segment_commit_limit2), .segment_commit_access2(protected_segment_commit_access2),
        .segment_commit_class2(protected_segment_commit_class2), .segment_commit_present2(protected_segment_commit_present2),
        .segment_commit_protected2(protected_segment_commit_protected2), .segment_commit_dpl2(protected_segment_commit_dpl2),
        .segment_commit_table_indicator2(protected_segment_commit_table_indicator2), .segment_commit_rpl2(protected_segment_commit_rpl2),
        .outer_return_commit(protected_outer_return_commit),
        .outer_return_cpl(protected_segment_commit_selector[1:0]),
        .task_load_en(protected_task_load), .task_load_segments(task_loaded_segments),
        .loadall_commit_en(loadall_commit_valid), .loadall_msw(loadall_msw),
        .loadall_gdtr_limit(loadall_gdtr_limit), .loadall_gdtr_base(loadall_gdtr_base),
        .loadall_idtr_limit(loadall_idtr_limit), .loadall_idtr_base(loadall_idtr_base),
        .loadall_ldtr_selector(loadall_ldtr_selector), .loadall_ldtr_base(loadall_ldtr_base),
        .loadall_ldtr_limit(loadall_ldtr_limit), .loadall_ldtr_access(loadall_ldtr_access),
        .loadall_ldtr_class(loadall_ldtr_class), .loadall_ldtr_valid(loadall_ldtr_valid),
        .loadall_ldtr_present(loadall_ldtr_present), .loadall_tr_selector(loadall_tr_selector),
        .loadall_tr_base(loadall_tr_base), .loadall_tr_limit(loadall_tr_limit),
        .loadall_tr_access(loadall_tr_access), .loadall_tr_class(loadall_tr_class),
        .loadall_tr_valid(loadall_tr_valid), .loadall_tr_present(loadall_tr_present),
        .loadall_segment_selectors(loadall_segment_selectors), .loadall_segment_bases(loadall_segment_bases),
        .loadall_segment_limits(loadall_segment_limits), .loadall_segment_access(loadall_segment_access),
        .loadall_segment_classes(loadall_segment_classes), .loadall_segment_valid(loadall_segment_valid),
        .loadall_segment_present(loadall_segment_present), .loadall_segment_protected(loadall_segment_protected),
        .loadall_segment_tables(loadall_segment_tables), .loadall_segment_dpl(loadall_segment_dpl),
        .loadall_segment_rpl(loadall_segment_rpl),
        .segment_selector_state(protected_segment_selectors), .segment_base_state(protected_segment_bases), .segment_limit_state(protected_segment_limits),
        .segment_access_state(protected_segment_access), .segment_class_state(protected_segment_classes), .segment_valid_state(protected_segment_valid),
        .segment_present_state(protected_segment_present), .segment_protected_state(protected_segment_protected), .segment_dpl_state(protected_segment_dpl),
        .segment_table_state(protected_segment_tables), .segment_rpl_state(protected_segment_rpl)
    );

    assign task_nested_call = task_switch_nested_call || opcode_q == 8'h9A || (opcode_q == 8'hFF && operand_reg == 3'd3);
    assign task_jump_task = !task_switch_nested_call && (opcode_q == 8'hEA || (opcode_q == 8'hFF && operand_reg == 3'd5));
    assign task_return_task = task_switch_return_task;

    /* The executor consumes the composite completion/fault and the loaded
       architectural image; backlink and child commit pulses remain internal
       service metadata until task-return integration. */
    /* verilator lint_off PINCONNECTEMPTY */
    spk286_task_switch_service task_switch_service (
        .clk(clk), .reset(reset), .cancel(semantic_cancel), .start(task_switch_start), .state_loaded(task_state_loaded),
        .nested_call(task_nested_call), .jump_task(task_jump_task), .return_task(task_return_task),
        .target_selector(task_switch_target_selector), .target_base(task_switch_target_base),
        .target_limit(task_switch_target_limit), .target_access(task_switch_target_access),
        .target_descriptor_address(task_switch_target_descriptor_address),
        .current_selector(protected_tr_selector), .current_base(protected_tr_base),
        .current_limit(protected_tr_limit), .current_access(protected_tr_access),
        .current_descriptor_address(protected_gdtr_base + {8'd0, protected_tr_selector[15:3], 3'b000}),
        .current_ip(event_active ? event_ip : debug_ip),
        .current_flags(event_active ? event_flags : debug_flags), .current_gpr(register_state),
        .current_segments(protected_segment_selectors), .current_ldtr(protected_ldtr_selector),
        .gdtr_limit(protected_gdtr_limit), .gdtr_base(protected_gdtr_base),
        .memory_done(task_memory_done), .memory_read_data(memory_read_data),
        .memory_request(task_memory_request), .memory_write(task_memory_write),
        .memory_byte(task_memory_byte), .memory_address(task_memory_address),
        .memory_write_data(task_memory_write_data), .busy(task_service_busy),
        .commit_ready(task_service_commit_ready), .memory_lock(task_memory_lock),
        .cache_commit(task_cache_commit), .cache_commit_index(task_cache_commit_index),
        .complete(task_service_complete), .fault(task_service_fault),
        .fault_vector(task_service_fault_vector), .fault_error_code(task_service_fault_error_code),
        .commit_valid(), .loaded_ip(task_loaded_ip), .loaded_flags(task_loaded_flags),
        .loaded_gpr(task_loaded_gpr), .loaded_segments(task_loaded_segments),
        .loaded_ldtr(task_loaded_ldtr), .loaded_ldtr_base(task_loaded_ldtr_base),
        .loaded_ldtr_limit(task_loaded_ldtr_limit), .loaded_ldtr_access(task_loaded_ldtr_access),
        .loaded_ldtr_class(task_loaded_ldtr_class), .loaded_ldtr_valid(task_loaded_ldtr_valid),
        .loaded_ldtr_present(task_loaded_ldtr_present), .loaded_backlink(),
        .loaded_tr_selector(task_loaded_tr_selector), .loaded_tr_base(task_loaded_tr_base),
        .loaded_tr_limit(task_loaded_tr_limit), .loaded_tr_access(task_loaded_tr_access),
        .cache_selectors(task_cache_selectors), .cache_bases(task_cache_bases),
        .cache_limits(task_cache_limits), .cache_access(task_cache_access),
        .cache_classes(task_cache_classes), .cache_present(task_cache_present),
        .cache_protected(task_cache_protected), .cache_dpl(task_cache_dpl),
        .cache_tables(task_cache_tables), .cache_rpl(task_cache_rpl)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // LOADALL owns a complete staged image.  It does not reuse the task
    // switch service because the 80286 instruction reads a fixed physical
    // image and commits every architectural/cache field atomically.
    /* verilator lint_off PINMISSING */
    spk286_loadall_service loadall_service (
        .clk(clk), .reset(reset), .cancel(semantic_cancel), .start(loadall_start),
        .current_protected(protected_msw[0]), .current_cpl(current_cpl),
        .memory_done(loadall_memory_done), .memory_read_data(memory_read_data),
        .memory_request(loadall_memory_request), .memory_write(loadall_memory_write),
        .memory_byte(loadall_memory_byte), .memory_address(loadall_memory_address),
        .memory_write_data(loadall_memory_write_data),
        .complete(loadall_complete), .fault(loadall_fault),
        .fault_vector(loadall_fault_vector), .fault_error_code(loadall_fault_error_code),
        .commit_valid(loadall_commit_valid), .loaded_msw(loadall_msw),
        .loaded_ip(loadall_ip), .loaded_flags(loadall_flags), .loaded_gpr(loadall_gpr),
        .loaded_gdtr_limit(loadall_gdtr_limit), .loaded_gdtr_base(loadall_gdtr_base),
        .loaded_idtr_limit(loadall_idtr_limit), .loaded_idtr_base(loadall_idtr_base),
        .loaded_ldtr_selector(loadall_ldtr_selector), .loaded_ldtr_base(loadall_ldtr_base),
        .loaded_ldtr_limit(loadall_ldtr_limit), .loaded_ldtr_access(loadall_ldtr_access),
        .loaded_ldtr_class(loadall_ldtr_class), .loaded_ldtr_valid(loadall_ldtr_valid),
        .loaded_ldtr_present(loadall_ldtr_present), .loaded_tr_selector(loadall_tr_selector),
        .loaded_tr_base(loadall_tr_base), .loaded_tr_limit(loadall_tr_limit),
        .loaded_tr_access(loadall_tr_access), .loaded_tr_class(loadall_tr_class),
        .loaded_tr_valid(loadall_tr_valid), .loaded_tr_present(loadall_tr_present),
        .cache_selectors(loadall_segment_selectors), .cache_bases(loadall_segment_bases),
        .cache_limits(loadall_segment_limits), .cache_access(loadall_segment_access),
        .cache_classes(loadall_segment_classes), .cache_valid(loadall_segment_valid),
        .cache_present(loadall_segment_present), .cache_protected(loadall_segment_protected),
        .cache_dpl(loadall_segment_dpl), .cache_tables(loadall_segment_tables),
        .cache_rpl(loadall_segment_rpl)
    );
    /* verilator lint_on PINMISSING */

    spk286_segments segments (
        .clk(clk), .reset(reset),
        .load_en((segment_load_en || context_commit || internal_segment_write) && commit_allowed && !protected_msw[0]),
        .load_index(context_commit ? 2'd1 : internal_segment_write ? decoded_segment_index : segment_load_index), .load_selector(context_commit ? context_cs : internal_segment_write ? internal_segment_data : segment_load_selector),
        .loadall_commit_en(loadall_commit_valid), .loadall_selectors(loadall_segment_selectors),
        .loadall_bases(loadall_segment_bases), .loadall_limits(loadall_segment_limits),
        .loadall_access(loadall_segment_access),
        .read_index(execute_enable ? service_segment : segment_read_index),
        .offset(execute_enable ? service_offset : segment_offset),
        .selector(real_segment_selector), .base(real_segment_base), .limit(real_segment_limit),
        .access_rights(real_segment_access), .physical_address(real_segment_address),
        .selector_state(real_segment_selectors), .base_state(real_segment_bases),
        .limit_state(real_segment_limits), .access_state(real_segment_access_state)
    );

    spk286_fetch #(.READY_CHAINING(1'b1)) fetch (
        .clk(clk), .reset(reset), .ready(fetch_bus_ready), .data_in(data_in),
        .code_base(debug_segment_bases[24 +: 24]),
        .code_limit(debug_segment_limits[16 +: 16]),
        .wrap_ip(!protected_msw[0]),
        .restart(stream_restart), .restart_ip(stream_ip),
        .request(execute_enable ? fetch_request_internal : fetch_request),
        .suspend(event_active || halted || shutdown),
        .request_ready(fetch_request_ready_internal),
        .response_ready(fetch_response_ready), .response_valid(fetch_response_valid),
        .response_data(fetch_response_data), .response_ip(fetch_response_ip),
        .response_count(fetch_response_count),
        .cursor(debug_fetch_cursor), .blocked(fetch_blocked),
        .bus_valid(fetch_bus_valid), .bus_bhe_n(fetch_bus_bhe_n), .address(fetch_address)
    );

    spk286_prefetch_queue prefetch_queue (
        .clk(clk), .reset(reset), .flush(queue_flush),
        .fill_valid(fetch_response_valid && execute_enable), .fill_data(fetch_response_data),
        .fill_count(fetch_response_count), .fill_ready(queue_fill_ready),
        .consume_valid(queue_consume_valid), .consume_data(queue_consume_data),
        .consume_ready(queue_consume_ready), .count(queue_count)
    );

    assign fetch_request_ready = fetch_request_ready_internal;
    assign fetch_valid = fetch_response_valid;
    assign fetch_data = fetch_response_data;
    assign fetch_ip = fetch_response_ip;
    assign fetch_count = fetch_response_count;
    spk286_biu biu (
        .clk(clk), .reset(reset), .cancel_data(semantic_cancel), .ready(ready), .data_in(data_in),
        .hold_request(hold_request), .lock_request(lock_prefix || implicit_lock || task_memory_lock), .hlda(hlda), .bus_lock(bus_lock),
        .ack_request(ack_request && !ack_pending_q), .ack_request_ready(ack_request_ready),
        .ack_response_valid(ack_response_valid), .ack_response_ready(ack_response_ready), .ack_vector(ack_vector),
        .code_valid(fetch_bus_valid), .code_bhe_n(fetch_bus_bhe_n),
        .code_address(fetch_address), .code_ready(fetch_bus_ready),
        .data_request(memory_request), .data_request_ready(memory_request_ready),
        .data_write(memory_write), .data_byte(memory_byte), .data_io(io_transfer), .data_address(memory_address), .data_write_data(memory_write_data),
        .data_response_valid(memory_response_valid), .data_response_ready(memory_response_ready),
        .data_read_data(memory_read_data), .address(biu_address), .data_out(data_out), .data_oe(data_oe),
        .bus_valid(bus_valid), .bus_write(bus_write), .bus_bhe_n(bus_bhe_n), .bus_status(biu_status)
    );

    assign timing_prefetch_response_accept = fetch_response_valid && fetch_response_ready;
    assign timing_queue_consume = queue_consume_valid && queue_consume_ready;

    spk286_timing_policy timing_policy (
        .clk(clk), .reset(reset), .requested_policy(timing_policy_request),
        .active_policy(timing_policy_active), .selection_error(debug_timing_policy_error),
        .selection_locked(debug_timing_policy_locked)
    );

    spk286_timing_trace timing_trace (
        .clk(clk), .reset(reset), .ready(ready),
        .bus_valid(bus_valid), .bus_write(bus_write), .bus_bhe_n(bus_bhe_n),
        .bus_status(biu_status), .address(biu_address), .data_in(data_in),
        .data_out(data_out), .bus_lock(bus_lock), .hold_request(hold_request),
        .hlda(hlda), .prefetch_request_valid(fetch_bus_valid),
        .prefetch_response_accept(timing_prefetch_response_accept),
        .queue_count(queue_count), .queue_consume(timing_queue_consume),
        .execution_enable(execute_enable), .stream_restart(stream_restart),
        .cancel_event(semantic_cancel),
        .operand_wait(operand_service_wait),
        .event_request(event_request), .event_complete(event_completed),
        .timing_policy(timing_policy_active),
        .cycle_count(debug_timing_cycle_count),
        .biu_busy_cycles(debug_timing_biu_busy_cycles),
        .accepted_transfers(debug_timing_accepted_transfers),
        .ready_wait_cycles(debug_timing_ready_wait_cycles),
        .prefetch_requests(debug_timing_prefetch_requests),
        .prefetch_responses(debug_timing_prefetch_responses),
        .queue_consume_count(debug_timing_queue_consumes),
        .queue_empty_cycles(debug_timing_queue_empty_cycles),
        .redirect_count(debug_timing_redirects),
        .cancel_count(debug_timing_cancels),
        .operand_wait_cycles(debug_timing_operand_wait_cycles),
        .event_request_count(debug_timing_event_requests),
        .event_complete_count(debug_timing_event_completes),
        .compatibility_delay_cycles(debug_timing_compatibility_delay_cycles),
        .trace_queue_count(debug_timing_queue_count),
        .trace_schema_version(debug_timing_schema_version),
        .trace_policy(debug_timing_policy),
        .trace_valid(debug_timing_trace_valid),
        .trace_cycle(debug_timing_trace_cycle),
        .trace_address(debug_timing_trace_address),
        .trace_status(debug_timing_trace_status),
        .trace_data(debug_timing_trace_data),
        .trace_lane_mask(debug_timing_trace_lane_mask),
        .trace_write(debug_timing_trace_write),
        .trace_owner(debug_timing_trace_owner),
        .trace_lock(debug_timing_trace_lock),
        .trace_hold(debug_timing_trace_hold),
        .trace_hlda(debug_timing_trace_hlda),
        .trace_ready(debug_timing_trace_ready),
        .trace_phase(debug_timing_trace_phase)
    );

    spk286_decoder decoder (
        .opcode(queue_consume_data), .extended_opcode(extended_opcode_active), .supported(decode_supported),
        .invalid_opcode(opcode_invalid),
        .destination(decode_destination), .source_index(decode_source_index), .entry(decode_entry)
    );

    logic [spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] next_micro_pc;
    spk286_microcode_sync_rom microcode_rom (
        .clk(clk), .address(next_micro_pc), .word(micro_word), .valid(micro_valid)
    );

    assign micro_end = micro_word == spk286_microcode_pkg::MC_END;
    assign loadall_start = operation_valid && micro_word == spk286_microcode_pkg::MC_LOADALL;
    assign operation_done = micro_end || executor_done || loadall_complete;
    assign opcode_start = decode_ready && !event_active && !event_request && !event_completed && !raw_retired &&
                          !unsupported_q && queue_consume_valid && decode_supported && !is_prefix && !length_fault;
    assign prefix_accept = decode_ready && !event_active && !event_request && !event_completed && !raw_retired &&
                           !unsupported_q && queue_consume_valid && is_prefix && !length_fault;
    assign length_fault = !event_active && !raw_retired && !event_completed && instruction_bytes == 10 &&
                          (micro_active ? executor_byte_ready : decode_ready);
    spk286_instruction_context instruction_context (
        .clk(clk), .reset(reset), .cancel(semantic_cancel), .complete(raw_retired || event_completed),
        .consume(queue_consume_valid && queue_consume_ready && !event_active), .prefix_accept(prefix_accept),
        .byte_data(queue_consume_data), .is_prefix(is_prefix), .extended_opcode(extended_opcode_active), .active(context_active),
        .segment_override(segment_override), .segment_index(override_segment),
        .lock_prefix(lock_prefix), .repeat_kind(repeat_kind), .byte_count(instruction_bytes)
    );
    assign micro_start = opcode_start || event_dispatch;
    // Clear transient services at a candidate dispatch without feeding their
    // combinational fault/request outputs back into their own start gating.
    assign service_start = event_dispatch || (decode_ready && !event_active && !raw_retired &&
                                             !event_completed && queue_consume_valid && decode_supported && !is_prefix);

    spk286_microsequencer #(
        .ADDRESS_WIDTH(spk286_microcode_pkg::MC_ADDR_WIDTH),
        .ROM_DEPTH(spk286_microcode_pkg::MC_DEPTH)
    ) microsequencer (
        .clk(clk), .reset(reset), .cancel(semantic_cancel), .enable(execution_allowed),
        .start(micro_start), .start_entry(event_dispatch ?
                                          (protected_msw[0] ? spk286_microcode_pkg::MC_ENTRY_EVENT_ENTRY_PROTECTED :
                                                               spk286_microcode_pkg::MC_ENTRY_EVENT_ENTRY) :
                                          decode_entry), .start_ready(decode_ready),
        .rom_valid(micro_valid), .rom_end(micro_end), .operation_done(operation_done), .operation_retire(operation_retire),
        .branch_request(dispatch_request || counter_branch_request),
        .branch_target(counter_branch_request ? counter_branch_target[spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] : dispatch_entry),
        .branch_target_valid(counter_branch_request ? counter_branch_target[spk286_microcode_pkg::MC_ADDR_WIDTH] : dispatch_valid),
        .operation_valid(operation_valid), .active(micro_active),
        .micro_pc(micro_pc), .micro_entry(micro_entry),
        .next_micro_pc(next_micro_pc),
        .retired(raw_retired), .fault(microcode_fault)
    );

    // These serialized protected services always select a memory operand.
    // Bypass the general register/byte mux on their response data, retaining
    // the operand service's existing admission/completion handshake.
    assign executor_operand_read_data = (protected_descriptor_access || protected_tss_access || protected_event_access) ?
                                        memory_read_data : operand_read_data;
    // These three active services unconditionally select a memory request at
    // offset zero with limit FFFF, and cannot raise ordinary access faults.
    // Remove that redundant late qualification from descriptor/event responses.
    assign executor_operand_done = (protected_descriptor_access || protected_tss_access || protected_event_access) ?
                                   unlimited_memory_done : operand_done;
    spk286_micro_executor #(
        .USE_PARALLEL_SYSTEM_LIMIT(1'b1)
    ) micro_executor (
        .parallel_system_limit_fault(parallel_system_cache_fault),
        .clk(clk), .reset(reset), .cancel(semantic_cancel), .start(service_start),
        .operation_valid(operation_valid), .operation(micro_word), .operation_done(executor_done), .operation_retire(operation_retire), .dispatch_request(dispatch_request),
        .segment_pop_opcode(opcode_q == 8'h07 || opcode_q == 8'h17 || opcode_q == 8'h1F),
        .byte_valid(queue_consume_valid && !length_fault), .byte_data(queue_consume_data), .byte_ready(executor_byte_ready),
        .decode_operand(operand_decode_enable), .decode_done(operand_decode_done), .decode_modrm_valid(operand_context_valid),
        .decode_byte_ready(operand_byte_ready), .operand_request(operand_request),
        .operand_write(operand_write), .operand_byte(operand_byte), .operand_select_rm(operand_select_rm), .operand_check(operand_check),
        .stack_request(stack_request), .stack_offset(stack_offset),
        .architectural_ip(debug_ip), .stack_pointer(register_state[64 +: 16]), .count_value(register_state[16 +: 16]),
        .push_enabled(event_active || push_enabled), .push_return_ip(!event_active && push_return_ip), .branch_taken(branch_taken), .decrement_count(decrement_count),
        .redirect_request(internal_redirect), .redirect_target(internal_target), .redirect_ready(1'b1),
        .operand_write_data(operand_write_data), .operand_done(executor_operand_done),
        .operand_gpr_write_byte(operand_gpr_write_byte), .operand_read_data(executor_operand_read_data), .operand_gpr_write_en(operand_gpr_write_en),
        .memory_read_data(memory_read_data),
        .operand_gpr_write_index(operand_gpr_write_index), .operand_gpr_write_data(operand_gpr_write_data),
        .gpr_write_byte(internal_gpr_write_byte), .destination(destination_q), .gpr_write_en(internal_gpr_write_en),
        .gpr_write_index(internal_gpr_write_index), .gpr_write_data(internal_gpr_write_data),
        .destination_read_data(register_state[source_index_q * 16 +: 16]),
        .source_index(source_index_q), .lock_prefix(lock_prefix), .target_read_data(register_state[destination_q * 16 +: 16]),
        .effective_offset(operand_offset), .address_base(register_state[48 +: 16]), .segment_limit(segment_limit), .stack_segment_limit(debug_segment_limits[32 +: 16]), .stack_segment_access(debug_segment_access[23:16]), .operand_register_direct(operand_register_direct), .operand_rm_index(operand_rm),
        .segment_expand_down(protected_msw[0] && protected_segment_is_expand_down),
        .address_override(address_override), .address_offset(address_offset),
        .direct_flags_data(direct_flags_data), .direct_flags_mask(direct_flags_mask),
        .destination_byte_data(register_state[destination_q[1:0] * 16 + (destination_q[2] ? 8 : 0) +: 8]),
        .shift_kind(operand_reg), .adjust_kind(adjust_kind), .muldiv_kind(muldiv_kind), .arithmetic_fault(arithmetic_fault),
        .io_transfer(io_transfer), .io_port(io_port), .port_immediate(!opcode_q[3]), .port_register(register_state[32 +: 16]),
        .string_byte(string_byte), .string_compare(string_compare), .repeat_kind(repeat_kind),
        .string_request(string_request), .string_destination(string_destination), .repeat_boundary(repeat_boundary), .repeat_stepped(repeat_stepped),
        .register_state(register_state), .counter_branch_request(counter_branch_request), .range_fault(range_fault), .bounds_fault(bounds_fault),
        .segment_read_value(debug_segment_selectors[decoded_segment_index*16 +: 16]),
        .segment_write(internal_segment_write), .segment_write_data(internal_segment_data), .segment_index(decoded_segment_index),
        .protected_segment_commit_en(protected_segment_commit_en), .protected_segment_commit_index(protected_segment_commit_index),
        .protected_segment_commit_selector(protected_segment_commit_selector), .protected_segment_commit_base(protected_segment_commit_base),
        .protected_segment_commit_limit(protected_segment_commit_limit), .protected_segment_commit_access(protected_segment_commit_access),
        .protected_segment_commit_class(protected_segment_commit_class), .protected_segment_commit_present(protected_segment_commit_present),
        .protected_segment_commit_protected(protected_segment_commit_protected), .protected_segment_commit_dpl(protected_segment_commit_dpl),
        .protected_segment_commit_table_indicator(protected_segment_commit_table_indicator), .protected_segment_commit_rpl(protected_segment_commit_rpl),
        .protected_segment_commit_en2(protected_segment_commit_en2), .protected_segment_commit_index2(protected_segment_commit_index2),
        .protected_segment_commit_selector2(protected_segment_commit_selector2), .protected_segment_commit_base2(protected_segment_commit_base2),
        .protected_segment_commit_limit2(protected_segment_commit_limit2), .protected_segment_commit_access2(protected_segment_commit_access2),
        .protected_segment_commit_class2(protected_segment_commit_class2), .protected_segment_commit_present2(protected_segment_commit_present2),
        .protected_segment_commit_protected2(protected_segment_commit_protected2), .protected_segment_commit_dpl2(protected_segment_commit_dpl2),
        .protected_segment_commit_table_indicator2(protected_segment_commit_table_indicator2), .protected_segment_commit_rpl2(protected_segment_commit_rpl2),
        .alu_byte(alu_byte), .reverse_operands(reverse_operands), .carry_in(debug_flags[0]), .alu_operation(alu_operation), .result_write_allowed(result_write_allowed),
        .architectural_flags(debug_flags), .if_value(opcode_q == 8'hFB),
        .event_flags(event_flags), .event_cs(event_cs), .event_ip(event_ip), .event_error_valid(event_error_valid), .event_error_code(event_error_code), .event_vector(debug_event_vector),
        .event_needs_ack(event_needs_ack), .ack_done(ack_done), .event_active(event_active), .event_software(event_software), .ack_request(ack_request),
        .software_event_request(software_request), .software_vector(software_vector),
        .halt_request(halt_request), .context_commit(context_commit),
        .vector_request(vector_request), .context_cs(context_cs), .vector_offset(vector_offset),
        .decoded_flags_mask(decoded_flags_mask), .decoded_undefined_mask(decoded_undefined_mask),
        .flags_write_en(internal_flags_write_en), .flags_write_data(internal_flags_write_data),
        .flags_write_mask(internal_flags_write_mask),
        .protected_msw(protected_msw), .protected_gdtr_limit(protected_gdtr_limit), .protected_idtr_limit(protected_idtr_limit),
        .protected_gdtr_base(protected_gdtr_base), .protected_idtr_base(protected_idtr_base),
        .protected_ldtr_selector(protected_ldtr_selector), .protected_tr_selector(protected_tr_selector),
        .protected_ldtr_base(protected_ldtr_base), .protected_ldtr_limit(protected_ldtr_limit),
        .protected_ldtr_valid(protected_ldtr_valid), .protected_ldtr_present(protected_ldtr_present),
        .protected_tr_base(protected_tr_base), .protected_tr_limit(protected_tr_limit),
        .protected_tr_valid(protected_tr_valid), .protected_tr_present(protected_tr_present),
        .protected_ss_selector(protected_segment_selectors[2*16 +: 16]),
        .protected_cpl(current_cpl),
        .protected_msw_load_en(protected_msw_load_en), .protected_msw_load_data(protected_msw_load_data), .protected_msw_load_mask(protected_msw_load_mask),
        .protected_gdtr_load_en(protected_gdtr_load_en), .protected_idtr_load_en(protected_idtr_load_en),
        .protected_gdtr_load_limit(protected_gdtr_load_limit), .protected_idtr_load_limit(protected_idtr_load_limit),
        .protected_gdtr_load_base(protected_gdtr_load_base), .protected_idtr_load_base(protected_idtr_load_base),
        .protected_ldtr_commit_en(protected_ldtr_commit_en), .protected_tr_commit_en(protected_tr_commit_en),
        .protected_ldtr_commit_selector(protected_ldtr_commit_selector), .protected_tr_commit_selector(protected_tr_commit_selector),
        .protected_ldtr_commit_base(protected_ldtr_commit_base), .protected_tr_commit_base(protected_tr_commit_base),
        .protected_ldtr_commit_limit(protected_ldtr_commit_limit), .protected_tr_commit_limit(protected_tr_commit_limit),
        .protected_ldtr_commit_access(protected_ldtr_commit_access), .protected_tr_commit_access(protected_tr_commit_access),
        .protected_ldtr_commit_class(protected_ldtr_commit_class), .protected_tr_commit_class(protected_tr_commit_class),
        .protected_ldtr_commit_present(protected_ldtr_commit_present), .protected_tr_commit_present(protected_tr_commit_present),
        .protected_ldtr_commit_valid(protected_ldtr_commit_valid), .protected_tr_commit_valid(protected_tr_commit_valid),
        .protected_descriptor_access(protected_descriptor_access), .protected_descriptor_address(protected_descriptor_address),
        .protected_gate_access(protected_gate_access),
        .protected_tss_access(protected_tss_access), .protected_tss_address(protected_tss_address),
        .protected_call_stack_access(protected_call_stack_access), .protected_call_stack_address(protected_call_stack_address),
        .protected_call_stack_limit(protected_call_stack_limit),
        .protected_call_stack_expand_down(protected_call_stack_expand_down),
        .protected_event_access(protected_event_access), .protected_event_address(protected_event_address),
        .task_switch_start(task_switch_start),
        .task_switch_nested_call(task_switch_nested_call),
        .task_switch_return_task(task_switch_return_task),
        .task_switch_target_selector(task_switch_target_selector), .task_switch_target_base(task_switch_target_base),
        .task_switch_target_limit(task_switch_target_limit), .task_switch_target_access(task_switch_target_access),
        .task_switch_target_descriptor_address(task_switch_target_descriptor_address),
        .task_service_busy(task_service_busy), .task_service_complete(task_service_complete),
        .task_service_commit_ready(task_service_commit_ready),
        .task_cache_commit(task_cache_commit), .task_cache_commit_index(task_cache_commit_index),
        .protected_task_load(protected_task_load), .task_state_loaded(task_state_loaded),
        .protected_segment_commit_valid(protected_segment_commit_valid),
        .task_fault_external(task_fault_external),
        .task_service_fault(task_service_fault), .task_service_fault_vector(task_service_fault_vector),
        .task_service_fault_error_code(task_service_fault_error_code),
        .task_loaded_ip(task_loaded_ip), .task_loaded_flags(task_loaded_flags),
        .task_loaded_gpr(task_loaded_gpr),
        .task_loaded_ldtr(task_loaded_ldtr), .task_loaded_ldtr_base(task_loaded_ldtr_base),
        .task_loaded_ldtr_limit(task_loaded_ldtr_limit), .task_loaded_ldtr_access(task_loaded_ldtr_access),
        .task_loaded_ldtr_class(task_loaded_ldtr_class), .task_loaded_ldtr_valid(task_loaded_ldtr_valid),
        .task_loaded_ldtr_present(task_loaded_ldtr_present),
        .task_loaded_tr_selector(task_loaded_tr_selector),
        .task_loaded_tr_base(task_loaded_tr_base), .task_loaded_tr_limit(task_loaded_tr_limit),
        .task_loaded_tr_access(task_loaded_tr_access), .task_cache_selectors(task_cache_selectors),
        .task_cache_bases(task_cache_bases), .task_cache_limits(task_cache_limits),
        .task_cache_access(task_cache_access), .task_cache_classes(task_cache_classes),
        .task_cache_present(task_cache_present), .task_cache_protected(task_cache_protected),
        .task_cache_dpl(task_cache_dpl), .task_cache_tables(task_cache_tables), .task_cache_rpl(task_cache_rpl),
        .task_flags_write_en(internal_task_flags_write),
        .system_fault(system_fault), .system_fault_vector(system_fault_vector), .system_fault_error_code(system_fault_error_code),
        .system_limit_fault(system_limit_fault)
    );

    spk286_flags_decode flags_decode (
        .opcode(opcode_q), .carry(debug_flags[0]), .ah(register_state[8 +: 8]),
        .candidate(direct_flags_data), .mask(direct_flags_mask)
    );

    spk286_condition condition_decode (
        .condition_code(opcode_q[3:0]), .carry(debug_flags[0]), .parity(debug_flags[2]),
        .zero(debug_flags[6]), .sign_flag(debug_flags[7]), .overflow(debug_flags[11]), .taken(condition_taken)
    );
    spk286_control_decode control_decode (
        .opcode(opcode_q), .extended_opcode(extended_opcode_active), .group_extension(operand_reg), .condition_taken(condition_taken),
        .zero(debug_flags[6]), .count(register_state[16 +: 16]), .push_enabled(push_enabled),
        .push_return_ip(push_return_ip), .branch_taken(branch_taken), .decrement_count(decrement_count),
        .string_byte(string_byte), .string_compare(string_compare), .form_supported(form_supported), .adjust_kind(adjust_kind), .muldiv_kind(muldiv_kind), .segment_index(decoded_segment_index), .dispatch_entry(dispatch_entry), .dispatch_valid(dispatch_valid)
    );

    spk286_alu_decode alu_decode (
        .opcode(opcode_q), .group_extension(operand_reg), .operation(alu_operation),
        .operand_byte(alu_byte), .reverse_operands(reverse_operands), .write_result(result_write_allowed), .flags_mask(decoded_flags_mask),
        .undefined_mask(decoded_undefined_mask)
    );

    spk286_operand_decode operand_decode (
        .clk(clk), .reset(reset), .cancel(semantic_cancel), .start(service_start), .enable(operand_decode_enable && !invalid_form),
        .rearm(dispatch_request && dispatch_valid && execution_allowed),
        .byte_valid(queue_consume_valid && !length_fault), .byte_data(queue_consume_data),
        .byte_ready(operand_byte_ready), .done(operand_decode_done), .modrm_valid(operand_context_valid),
        .bx(register_state[48 +: 16]), .bp(register_state[80 +: 16]),
        .si(register_state[96 +: 16]), .di(register_state[112 +: 16]),
        .mode(operand_mode), .reg_index(operand_reg), .rm_index(operand_rm),
        .register_direct(operand_register_direct), .displacement(operand_displacement),
        .effective_offset(operand_offset), .segment_index(operand_segment)
    );
    // Task-switch memory is a direct BIU transaction. The ordinary operand
    // service remains isolated so a TSS word can never be mistaken for an
    // instruction temporary or an effective-address access.
    assign memory_request = loadall_memory_request || task_memory_request || operand_memory_request;
    assign memory_write = loadall_memory_request ? loadall_memory_write :
                          task_memory_request ? task_memory_write : operand_memory_write;
    assign memory_byte = loadall_memory_request ? loadall_memory_byte :
                         task_memory_request ? task_memory_byte : operand_memory_byte;
    assign memory_address = loadall_memory_request ? loadall_memory_address :
                            task_memory_request ? task_memory_address : operand_memory_address;
    assign memory_write_data = loadall_memory_request ? loadall_memory_write_data :
                               task_memory_request ? task_memory_write_data : operand_memory_write_data;
    assign memory_response_ready = loadall_memory_request ? 1'b1 :
                                   task_memory_request ? 1'b1 : operand_memory_response_ready;
    assign loadall_memory_done = loadall_memory_request && memory_response_valid;
    assign task_memory_done = task_memory_request && memory_response_valid;

    spk286_operand #(
        .USE_PARALLEL_RANGE(1'b1)
    ) operand (
        .parallel_within_limit(parallel_operand_within_limit),
        .clk(clk), .reset(reset), .cancel(semantic_cancel), .request_valid(operand_request && !protected_access_fault),
        .request_byte(operand_byte), .request_write(operand_write), .request_check(operand_check), .select_rm(operand_select_rm), .write_data(operand_write_data),
        .done(operand_done), .unlimited_memory_done(unlimited_memory_done), .read_data(operand_read_data), .register_state(register_state),
        .reg_index(operand_reg), .rm_index(operand_rm), .register_direct(operand_register_direct && !protected_descriptor_access && !protected_tss_access && !protected_call_stack_access && !protected_event_access && !address_override && !stack_request && !vector_request && !io_transfer),
        .physical_address(operand_physical_address),
        .offset((protected_event_access || protected_descriptor_access || protected_tss_access || protected_call_stack_access) ? 16'd0 : service_offset), .segment_limit((protected_event_access || protected_descriptor_access || protected_tss_access || protected_call_stack_access) ? 16'hFFFF : (vector_request ? 16'hFFFF : segment_limit)),
        .segment_expand_down(protected_msw[0] && protected_segment_is_expand_down && !protected_call_stack_access && !protected_event_access && !protected_descriptor_access && !protected_tss_access),
        .gpr_write_byte(operand_gpr_write_byte), .blocked(operand_blocked), .gpr_write_en(operand_gpr_write_en),
        .gpr_write_index(operand_gpr_write_index), .gpr_write_data(operand_gpr_write_data),
        .memory_request(operand_memory_request), .memory_request_ready(memory_request_ready),
        .memory_byte(operand_memory_byte), .memory_write(operand_memory_write), .memory_address(operand_memory_address), .memory_write_data(operand_memory_write_data),
        .memory_response_valid(memory_response_valid), .memory_response_ready(operand_memory_response_ready),
        .timing_wait(operand_service_wait),
        .memory_read_data(memory_read_data)
    );

    // Decode and the executor share one byte-consumption interface. Unsupported
    // opcodes stay at its head. Redirect/control errors suppress both consumers.
    assign queue_consume_ready = !length_fault && (prefix_accept || opcode_start || executor_byte_ready);

    assign internal_ip_write_en = internal_redirect || (queue_consume_valid && queue_consume_ready);
    assign internal_ip_write_data = internal_redirect ? internal_target : debug_ip + 16'h0001;

    always_ff @(posedge clk) begin
        if (reset || semantic_cancel) begin
            destination_q <= 3'd0; source_index_q <= 3'd0;
            opcode_q <= 8'h00;
            unsupported_q <= 1'b0;
        end else if (operand_context_valid && micro_active && !event_active && !form_supported && !invalid_form) begin
            unsupported_q <= 1'b1;
        end else if (decode_ready && !event_active && !event_request && !event_completed && !raw_retired && !unsupported_q && queue_consume_valid && !is_prefix && !length_fault) begin
            opcode_q <= queue_consume_data;
            if (decode_supported) begin destination_q <= decode_destination; source_index_q <= decode_source_index; end
            else unsupported_q <= 1'b1;
        end
    end

    assign debug_cs = debug_segment_selectors[16 +: 16];
    assign debug_gpr = register_state;
    assign debug_modrm = {operand_mode, operand_reg, operand_rm};
    assign debug_displacement = operand_displacement;
    assign debug_effective_offset = operand_offset;
    assign debug_operand_segment = operand_segment;
    assign debug_cs_base = debug_segment_bases[24 +: 24];
    assign debug_protected_msw = protected_msw;
    assign debug_gdtr_limit = protected_gdtr_limit;
    assign debug_idtr_limit = protected_idtr_limit;
    assign debug_gdtr_base = protected_gdtr_base;
    assign debug_idtr_base = protected_idtr_base;
    assign debug_ldtr_selector = protected_ldtr_selector;
    assign debug_tr_selector = protected_tr_selector;
    assign debug_ldtr_limit = protected_ldtr_limit;
    assign debug_tr_limit = protected_tr_limit;
    assign debug_ldtr_base = protected_ldtr_base;
    assign debug_tr_base = protected_tr_base;
    assign unsupported_opcode = unsupported_q;
    assign debug_opcode = opcode_q;
    assign debug_prefetch_count = queue_count;
    assign debug_micro_pc = 12'(micro_pc);
    assign debug_micro_entry = 12'(micro_entry);
    assign debug_micro_instruction = micro_word;
    assign debug_micro_active = micro_active;
    assign debug_bus_state = bus_valid ? 4'h1 : 4'h0;
    // Functional trace metadata is orthogonal to the normalized bus status.
    // It identifies the protected-mode logical owner while READY holds the
    // physical request stable; it is not a historical cycle-timing encoding.
    always_comb begin
        debug_bus_transaction = 4'h0;
        if (bus_valid) begin
            if (protected_tss_access || task_memory_request) debug_bus_transaction = 4'h2;
            else if (protected_gate_access || protected_event_access) debug_bus_transaction = 4'h3;
            else if (protected_descriptor_access) debug_bus_transaction = 4'h1;
            else if (protected_call_stack_access || stack_request) debug_bus_transaction = 4'h4;
            else if (protected_msw[0] && biu_status == 4'hD) debug_bus_transaction = 4'h5;
        end
    end
    assign invalid_form = operand_context_valid && micro_active && !event_active &&
                          ((opcode_q == 8'h63 && lock_prefix) ||
                           (extended_opcode_active && opcode_q == 8'h00 && operand_reg > 3'd5) ||
                           (extended_opcode_active && opcode_q == 8'h01 && ((operand_reg <= 3 && operand_register_direct) || operand_reg == 3'd5 || operand_reg == 3'd7)) ||
                           ((opcode_q == 8'h8C && operand_reg > 3) || (opcode_q == 8'h8E && (operand_reg > 3 || operand_reg == 1))) || (opcode_q == 8'hFE && operand_reg > 1) || ((opcode_q == 8'h8D || opcode_q == 8'h62 || opcode_q == 8'hC4 || opcode_q == 8'hC5) && operand_register_direct) || ((opcode_q == 8'h8F || opcode_q == 8'hC6 || opcode_q == 8'hC7) && operand_reg != 0) ||
                           (opcode_q == 8'hFF && (operand_reg == 7 ||
                            (operand_register_direct && (operand_reg == 3 || operand_reg == 5)))));
    // Only the decoder's explicit invalid-opcode classification raises #UD.
    // A legal but unimplemented instruction remains a development diagnostic.
    assign invalid_opcode_fault = execution_allowed && decode_ready && !event_active &&
                                  !raw_retired && !event_completed && queue_consume_valid &&
                                  !is_prefix && !length_fault && opcode_invalid;
    assign demanded_code_fault = execution_allowed && !event_active && !raw_retired && !event_completed &&
                                 !queue_consume_valid && !fetch_response_valid && !fetch_bus_valid && fetch_blocked &&
                                 (micro_active ? executor_byte_ready : decode_ready);
    assign fault_request = range_fault || bounds_fault || arithmetic_fault || operand_blocked || invalid_form ||
                           invalid_opcode_fault || system_limit_fault || system_fault ||
                           protected_access_fault || protected_fetch_fault || demanded_code_fault || length_fault || loadall_fault;
    assign fault_vector = (invalid_form || invalid_opcode_fault) ? 8'd6 : loadall_fault ? loadall_fault_vector : system_fault ? system_fault_vector :
                          (protected_access_ss_fault || ((system_limit_fault || range_fault) && protected_msw[0] && service_segment == 2'd2)) ? 8'd12 : protected_access_fault ? 8'd13 :
                          protected_fetch_fault ? 8'd13 : bounds_fault ? 8'd5 : arithmetic_fault ? 8'd0 : 8'd13;
    // Error words: protected selector faults in the #TS/#NP/#SS/#GP
    // family carry one 16-bit error word.  Non-selector protected faults use
    // the architecturally defined zero word until their individual source
    // classification is extended.
    // Classify each source before the late vector-priority mux. Preserve
    // exactly the same priority, including simultaneous diagnostic faults.
    logic loadall_fault_has_error, system_fault_has_error;
    assign loadall_fault_has_error = loadall_fault_vector == 8'd8 || loadall_fault_vector == 8'd10 ||
                                    loadall_fault_vector == 8'd11 || loadall_fault_vector == 8'd12 || loadall_fault_vector == 8'd13;
    assign system_fault_has_error = system_fault_vector == 8'd8 || system_fault_vector == 8'd10 ||
                                   system_fault_vector == 8'd11 || system_fault_vector == 8'd12 || system_fault_vector == 8'd13;
    assign fault_error_valid = protected_msw[0] && !(invalid_form || invalid_opcode_fault) &&
                              (loadall_fault ? loadall_fault_has_error :
                               system_fault ? system_fault_has_error :
                               (protected_access_ss_fault ||
                                ((system_limit_fault || range_fault) && protected_msw[0] && service_segment == 2'd2) ||
                                protected_access_fault || protected_fetch_fault || (!bounds_fault && !arithmetic_fault)));
    assign fault_error_code = system_fault ? system_fault_error_code :
                              loadall_fault ? loadall_fault_error_code : 16'd0;
    assign software_taken = software_request && (opcode_q != 8'hCE || debug_flags[11]);
    assign selected_software_vector = opcode_q == 8'hCD ? software_vector : (opcode_q == 8'hCC ? 8'd3 : 8'd4);
    assign instruction_retired = (raw_retired && !event_active) || (event_completed && event_software);
    assign bus_status = !bus_valid && (halted || shutdown) ? 4'h4 : biu_status;
    assign address = bus_valid ? biu_address : (halted ? 24'd2 : 24'd0);
    assign ack_response_ready = ack_request && ack_pending_q;
    assign ack_done = ack_response_ready && ack_response_valid;
    always_ff @(posedge clk) begin
        if (reset || semantic_cancel) ack_pending_q <= 1'b0;
        else begin
            if (ack_request && ack_request_ready && !ack_pending_q) ack_pending_q <= 1'b1;
            if (ack_done) ack_pending_q <= 1'b0;
        end
    end
    spk286_events events (
        .clk(clk), .reset(reset), .cancel(restart), .enable(execute_enable && commit_allowed && !reset && !restart),
        .protected_mode(protected_msw[0]), .delivery_commit(internal_redirect),
        .intr(intr), .nmi(nmi),
        .ss_load((internal_segment_write && decoded_segment_index == 2'd2) ||
                 (protected_segment_commit_en && protected_segment_commit_index == 2'd2) ||
                 (protected_segment_commit_en2 && protected_segment_commit_index2 == 2'd2)),
        .ss_shadow(unused_ss_shadow), .instruction_start((prefix_accept || opcode_start) && !context_active), .opcode_dispatch(opcode_start), .instruction_active(micro_active || context_active),
        .repeat_boundary(repeat_boundary), .repeat_stepped(repeat_stepped),
        .retired(raw_retired), .opcode(queue_consume_data), .ip(debug_ip), .cs(debug_cs), .flags(debug_flags),
        .fault_request(fault_request), .fault_vector(fault_vector),
        .fault_new_task(task_state_loaded && task_service_fault),
        .fault_error_valid(fault_error_valid), .fault_error_code(fault_error_code),
        .software_request(software_taken), .software_vector(selected_software_vector),
        .halt_request(halt_request), .dispatch_ready(decode_ready), .ack_done(ack_done), .ack_vector(ack_vector),
        .event_active(event_active), .cancel_operation(event_cancel), .dispatch(event_dispatch), .event_request(event_request),
        .event_completed(event_completed), .event_software(event_software), .event_external(event_external), .event_vector(debug_event_vector),
        .event_ip(event_ip), .event_cs(event_cs), .event_flags(event_flags),
        .event_error_valid(event_error_valid), .event_error_code(event_error_code), .event_needs_ack(event_needs_ack),
        .halted(halted), .shutdown(shutdown), .nmi_pending(debug_nmi_pending), .nmi_blocked(debug_nmi_blocked),
        .sti_shadow(debug_sti_shadow), .instruction_ip(debug_instruction_ip), .event_kind(event_kind)
    );
    assign debug_event_kind = event_kind;
    assign debug_event_error_valid = event_error_valid;
    assign debug_event_error_code = event_error_code;
    assign debug_fault_vector = fault_vector;
    assign debug_fault_error_code = fault_error_code;
endmodule
