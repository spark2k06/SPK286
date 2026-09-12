// Standalone CPU: decoder -> generated microcode -> functional datapath service.
// Architectural state, prefetch storage and physical fetch retain separate owners.
`timescale 1ns/1ps

module spk286 (
    input  logic         clk,
    input  logic         reset,
    input  logic         ready,
    input  logic [15:0]  data_in,
    input  logic         execute_enable,
    input  logic         intr, nmi, hold_request,
    output logic         halted, shutdown, event_completed,
    output logic [7:0]   debug_event_vector,
    output logic [2:0]   debug_event_kind,
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
    output logic [3:0]   debug_bus_state
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
    logic micro_active, micro_valid, micro_end, operation_valid, operation_done;
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
    logic [15:0] operand_write_data, operand_read_data;
    logic operand_gpr_write_en, operand_gpr_write_byte;
    logic [2:0] operand_gpr_write_index;
    logic [15:0] operand_gpr_write_data;
    logic memory_request, memory_request_ready, memory_write, memory_byte;
    logic [23:0] memory_address;
    logic [15:0] memory_write_data, memory_read_data;
    logic memory_response_valid, memory_response_ready;
    logic [2:0] alu_operation;
    logic result_write_allowed, internal_flags_write_en, alu_byte;
    logic [15:0] decoded_flags_mask, decoded_undefined_mask;
    logic [15:0] internal_flags_write_data, internal_flags_write_mask;
    logic event_active, event_cancel, event_dispatch, event_request, event_software, event_needs_ack;
    logic [15:0] event_ip, event_cs, event_flags;
    logic event_error_valid;
    logic [15:0] event_error_code;
    logic opcode_start, service_start, raw_retired, context_commit, vector_request, halt_request;
    logic software_request, software_taken, fault_request, invalid_form, demanded_code_fault;
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
    logic protected_descriptor_access;
    logic [23:0] protected_descriptor_address;
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
    logic [7:0] protected_segment_dpl, protected_segment_rpl;
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
    logic protected_access_fault, protected_access_ss_fault, protected_fetch_fault;
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
    assign stream_restart = restart || internal_redirect || event_cancel;
    assign stream_ip = restart ? ip_write_data : (internal_redirect ? internal_target : debug_ip);
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
    assign protected_access_fault = operand_request && operand_select_rm && !operand_register_direct &&
                                   !protected_descriptor_access && !protected_tss_access && !protected_event_access &&
                                   !io_transfer && !vector_request &&
                                    (protected_call_stack_access ?
                                    (service_segment != 2'd2 ||
                                     (protected_call_stack_expand_down ?
                                      ({1'b0, service_offset} <= {1'b0, protected_call_stack_limit} ||
                                       ({1'b0, service_offset} + (operand_byte ? 17'd0 : 17'd1) > 17'h0FFFF)) :
                                      ({1'b0, service_offset} + (operand_byte ? 17'd0 : 17'd1) > {1'b0, protected_call_stack_limit}))) :
                                    (protected_segment_is_loaded &&
                                     (!protected_segment_is_valid || !protected_segment_is_present ||
                                      (protected_segment_is_code ? (!protected_segment_is_readable || operand_write) :
                                       (stack_request ? (!protected_segment_is_writable || service_segment != 2'd2) :
                                        (operand_write && !protected_segment_is_writable))) ||
                                      (protected_segment_is_expand_down ?
                                       ({1'b0, service_offset} <= {1'b0, selected_segment_limit} ||
                                        ({1'b0, service_offset} + (operand_byte ? 17'd0 : 17'd1) > 17'h0FFFF)) :
                                       ({1'b0, service_offset} + (operand_byte ? 17'd0 : 17'd1) > {1'b0, selected_segment_limit})))));
    assign protected_access_ss_fault = protected_access_fault && service_segment == 2'd2;
    assign protected_fetch_fault = protected_msw[0] && protected_segment_protected[2'd1] &&
                                   (!protected_segment_valid[2'd1] || !protected_segment_present[2'd1] ||
                                    !protected_segment_access[1*8 + 3]);

    // The Phase 1 state ports remain the setup/debug path. Once execution is
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

    // Keep two bytes of bus capacity available. This lets the current fetch
    // service preserve both bytes of every word response without a second
    // response staging slot in the instruction queue.
    assign fetch_request_internal = execute_enable && !event_active && !halted && !shutdown && !unsupported_q && !microcode_fault && !operand_blocked &&
                                    !protected_fetch_fault && (queue_count <= 4'd4);
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
        .segment_commit_en(segment_state_commit_en), .segment_commit_index(segment_state_commit_index),
        .segment_commit_selector(segment_state_commit_selector), .segment_commit_base(segment_state_commit_base),
        .segment_commit_limit(segment_state_commit_limit), .segment_commit_access(segment_state_commit_access),
        .segment_commit_class(segment_state_commit_class), .segment_commit_present(segment_state_commit_present),
        .segment_commit_protected(segment_state_commit_protected), .segment_commit_dpl(segment_state_commit_dpl),
        .segment_commit_table_indicator(segment_state_commit_table_indicator), .segment_commit_rpl(segment_state_commit_rpl),
        .segment_commit_en2(protected_segment_commit_en2), .segment_commit_index2(protected_segment_commit_index2),
        .segment_commit_selector2(protected_segment_commit_selector2), .segment_commit_base2(protected_segment_commit_base2),
        .segment_commit_limit2(protected_segment_commit_limit2), .segment_commit_access2(protected_segment_commit_access2),
        .segment_commit_class2(protected_segment_commit_class2), .segment_commit_present2(protected_segment_commit_present2),
        .segment_commit_protected2(protected_segment_commit_protected2), .segment_commit_dpl2(protected_segment_commit_dpl2),
        .segment_commit_table_indicator2(protected_segment_commit_table_indicator2), .segment_commit_rpl2(protected_segment_commit_rpl2),
        .segment_selector_state(protected_segment_selectors), .segment_base_state(protected_segment_bases), .segment_limit_state(protected_segment_limits),
        .segment_access_state(protected_segment_access), .segment_class_state(protected_segment_classes), .segment_valid_state(protected_segment_valid),
        .segment_present_state(protected_segment_present), .segment_protected_state(protected_segment_protected), .segment_dpl_state(protected_segment_dpl),
        .segment_table_state(protected_segment_tables), .segment_rpl_state(protected_segment_rpl)
    );

    spk286_segments segments (
        .clk(clk), .reset(reset),
        .load_en((segment_load_en || context_commit || internal_segment_write) && commit_allowed && !protected_msw[0]),
        .load_index(context_commit ? 2'd1 : internal_segment_write ? decoded_segment_index : segment_load_index), .load_selector(context_commit ? context_cs : internal_segment_write ? internal_segment_data : segment_load_selector),
        .read_index(execute_enable ? service_segment : segment_read_index),
        .offset(execute_enable ? service_offset : segment_offset),
        .selector(real_segment_selector), .base(real_segment_base), .limit(real_segment_limit),
        .access_rights(real_segment_access), .physical_address(real_segment_address),
        .selector_state(real_segment_selectors), .base_state(real_segment_bases),
        .limit_state(real_segment_limits), .access_state(real_segment_access_state)
    );

    spk286_fetch fetch (
        .clk(clk), .reset(reset), .ready(fetch_bus_ready), .data_in(data_in),
        .code_base(debug_segment_bases[24 +: 24]),
        .code_limit(debug_segment_limits[16 +: 16]),
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
        .hold_request(hold_request), .lock_request(lock_prefix || implicit_lock), .hlda(hlda), .bus_lock(bus_lock),
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

    spk286_decoder decoder (
        .opcode(queue_consume_data), .extended_opcode(extended_opcode_active), .supported(decode_supported),
        .destination(decode_destination), .source_index(decode_source_index), .entry(decode_entry)
    );

    spk286_microcode_rom microcode_rom (
        .address(micro_pc), .word(micro_word), .valid(micro_valid)
    );

    assign micro_end = micro_word == spk286_microcode_pkg::MC_END;
    assign operation_done = micro_end || executor_done;
    assign opcode_start = decode_ready && !event_active && !event_request && !event_completed && !raw_retired &&
                          !unsupported_q && queue_consume_valid && decode_supported && !is_prefix && !length_fault;
    assign prefix_accept = decode_ready && !event_active && !event_request && !event_completed && !raw_retired &&
                           !unsupported_q && queue_consume_valid && is_prefix && !length_fault;
    assign length_fault = !event_active && instruction_bytes == 10 &&
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
        .rom_valid(micro_valid), .rom_end(micro_end), .operation_done(operation_done),
        .branch_request(dispatch_request || counter_branch_request),
        .branch_target(counter_branch_request ? counter_branch_target[spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] : dispatch_entry),
        .branch_target_valid(counter_branch_request ? counter_branch_target[spk286_microcode_pkg::MC_ADDR_WIDTH] : dispatch_valid),
        .operation_valid(operation_valid), .active(micro_active),
        .micro_pc(micro_pc), .micro_entry(micro_entry),
        .retired(raw_retired), .fault(microcode_fault)
    );

    spk286_micro_executor micro_executor (
        .clk(clk), .reset(reset), .cancel(semantic_cancel), .start(service_start),
        .operation_valid(operation_valid), .operation(micro_word), .operation_done(executor_done), .dispatch_request(dispatch_request),
        .byte_valid(queue_consume_valid && !length_fault), .byte_data(queue_consume_data), .byte_ready(executor_byte_ready),
        .decode_operand(operand_decode_enable), .decode_done(operand_decode_done),
        .decode_byte_ready(operand_byte_ready), .operand_request(operand_request),
        .operand_write(operand_write), .operand_byte(operand_byte), .operand_select_rm(operand_select_rm), .operand_check(operand_check),
        .stack_request(stack_request), .stack_offset(stack_offset),
        .architectural_ip(debug_ip), .stack_pointer(register_state[64 +: 16]), .count_value(register_state[16 +: 16]),
        .push_enabled(event_active || push_enabled), .push_return_ip(!event_active && push_return_ip), .branch_taken(branch_taken), .decrement_count(decrement_count),
        .redirect_request(internal_redirect), .redirect_target(internal_target), .redirect_ready(1'b1),
        .operand_write_data(operand_write_data), .operand_done(operand_done),
        .operand_gpr_write_byte(operand_gpr_write_byte), .operand_read_data(operand_read_data), .operand_gpr_write_en(operand_gpr_write_en),
        .operand_gpr_write_index(operand_gpr_write_index), .operand_gpr_write_data(operand_gpr_write_data),
        .gpr_write_byte(internal_gpr_write_byte), .destination(destination_q), .gpr_write_en(internal_gpr_write_en),
        .gpr_write_index(internal_gpr_write_index), .gpr_write_data(internal_gpr_write_data),
        .destination_read_data(register_state[source_index_q * 16 +: 16]),
        .source_index(source_index_q), .lock_prefix(lock_prefix), .target_read_data(register_state[destination_q * 16 +: 16]),
        .effective_offset(operand_offset), .address_base(register_state[48 +: 16]), .segment_limit(segment_limit), .stack_segment_limit(debug_segment_limits[32 +: 16]), .stack_segment_access(debug_segment_access[23:16]), .operand_register_direct(operand_register_direct),
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
        .protected_cpl(debug_cs[1:0]),
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
        .protected_tss_access(protected_tss_access), .protected_tss_address(protected_tss_address),
        .protected_call_stack_access(protected_call_stack_access), .protected_call_stack_address(protected_call_stack_address),
        .protected_call_stack_limit(protected_call_stack_limit),
        .protected_call_stack_expand_down(protected_call_stack_expand_down),
        .protected_event_access(protected_event_access), .protected_event_address(protected_event_address),
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
    spk286_operand operand (
        .clk(clk), .reset(reset), .cancel(semantic_cancel), .request_valid(operand_request && !protected_access_fault),
        .request_byte(operand_byte), .request_write(operand_write), .request_check(operand_check), .select_rm(operand_select_rm), .write_data(operand_write_data),
        .done(operand_done), .read_data(operand_read_data), .register_state(register_state),
        .reg_index(operand_reg), .rm_index(operand_rm), .register_direct(operand_register_direct && !protected_descriptor_access && !protected_tss_access && !protected_call_stack_access && !protected_event_access && !address_override && !stack_request && !vector_request && !io_transfer),
        .physical_address(operand_physical_address),
        .offset((protected_event_access || protected_descriptor_access || protected_tss_access || protected_call_stack_access) ? 16'd0 : service_offset), .segment_limit((protected_event_access || protected_descriptor_access || protected_tss_access || protected_call_stack_access) ? 16'hFFFF : (vector_request ? 16'hFFFF : segment_limit)),
        .segment_expand_down(protected_msw[0] && protected_segment_is_expand_down && !protected_call_stack_access && !protected_event_access && !protected_descriptor_access && !protected_tss_access),
        .gpr_write_byte(operand_gpr_write_byte), .blocked(operand_blocked), .gpr_write_en(operand_gpr_write_en),
        .gpr_write_index(operand_gpr_write_index), .gpr_write_data(operand_gpr_write_data),
        .memory_request(memory_request), .memory_request_ready(memory_request_ready),
        .memory_byte(memory_byte), .memory_write(memory_write), .memory_address(memory_address), .memory_write_data(memory_write_data),
        .memory_response_valid(memory_response_valid), .memory_response_ready(memory_response_ready),
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
    assign invalid_form = operand_context_valid && micro_active && !event_active &&
                          ((opcode_q == 8'h63 && lock_prefix) ||
                           (extended_opcode_active && opcode_q == 8'h00 && operand_reg > 3'd5) ||
                           (extended_opcode_active && opcode_q == 8'h01 && ((operand_reg <= 3 && operand_register_direct) || operand_reg == 3'd5 || operand_reg == 3'd7)) ||
                           ((opcode_q == 8'h8C && operand_reg > 3) || (opcode_q == 8'h8E && (operand_reg > 3 || operand_reg == 1))) || (opcode_q == 8'hFE && operand_reg > 1) || ((opcode_q == 8'h8D || opcode_q == 8'h62 || opcode_q == 8'hC4 || opcode_q == 8'hC5) && operand_register_direct) || ((opcode_q == 8'h8F || opcode_q == 8'hC6 || opcode_q == 8'hC7) && operand_reg != 0) ||
                           (opcode_q == 8'hFF && (operand_reg == 7 ||
                            (operand_register_direct && (operand_reg == 3 || operand_reg == 5)))));
    assign demanded_code_fault = execution_allowed && !event_active && !raw_retired && !event_completed &&
                                 !queue_consume_valid && !fetch_response_valid && !fetch_bus_valid && fetch_blocked &&
                                 (micro_active ? executor_byte_ready : decode_ready);
    assign fault_request = range_fault || bounds_fault || arithmetic_fault || operand_blocked || invalid_form || system_limit_fault || system_fault ||
                           protected_access_fault || protected_fetch_fault || demanded_code_fault || length_fault;
    assign fault_vector = invalid_form ? 8'd6 : system_fault ? system_fault_vector :
                          protected_access_ss_fault ? 8'd12 : protected_access_fault ? 8'd13 :
                          protected_fetch_fault ? 8'd13 : bounds_fault ? 8'd5 : arithmetic_fault ? 8'd0 : 8'd13;
    // PM3c frame contract: protected selector faults in the #TS/#NP/#SS/#GP
    // family carry one 16-bit error word.  Non-selector protected faults use
    // the architecturally defined zero word until their individual source
    // classification is extended.
    assign fault_error_valid = protected_msw[0] &&
                                (fault_vector == 8'd10 || fault_vector == 8'd11 ||
                                 fault_vector == 8'd12 || fault_vector == 8'd13);
    assign fault_error_code = system_fault ? system_fault_error_code : 16'd0;
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
        .intr(intr), .nmi(nmi), .ss_load(((internal_segment_write || protected_segment_commit_en) && decoded_segment_index == 2'd2) || protected_segment_commit_en2), .ss_shadow(unused_ss_shadow), .instruction_start((prefix_accept || opcode_start) && !context_active), .opcode_dispatch(opcode_start), .instruction_active(micro_active || context_active),
        .repeat_boundary(repeat_boundary), .repeat_stepped(repeat_stepped),
        .retired(raw_retired), .opcode(queue_consume_data), .ip(debug_ip), .cs(debug_cs), .flags(debug_flags),
        .fault_request(fault_request), .fault_vector(fault_vector),
        .fault_error_valid(fault_error_valid), .fault_error_code(fault_error_code),
        .software_request(software_taken), .software_vector(selected_software_vector),
        .halt_request(halt_request), .dispatch_ready(decode_ready), .ack_done(ack_done), .ack_vector(ack_vector),
        .event_active(event_active), .cancel_operation(event_cancel), .dispatch(event_dispatch), .event_request(event_request),
        .event_completed(event_completed), .event_software(event_software), .event_vector(debug_event_vector),
        .event_ip(event_ip), .event_cs(event_cs), .event_flags(event_flags),
        .event_error_valid(event_error_valid), .event_error_code(event_error_code), .event_needs_ack(event_needs_ack),
        .halted(halted), .shutdown(shutdown), .nmi_pending(debug_nmi_pending), .nmi_blocked(debug_nmi_blocked),
        .sti_shadow(debug_sti_shadow), .instruction_ip(debug_instruction_ip), .event_kind(debug_event_kind)
    );
endmodule
