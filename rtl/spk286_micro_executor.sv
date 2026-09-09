// Functional micro-operation service. Physical fetch/READY belongs to the BIU.
`timescale 1ns/1ps

module spk286_micro_executor (
    input  logic clk,
    input  logic reset,
    input  logic cancel,
    input  logic start,
    input  logic operation_valid,
    input  logic [spk286_microcode_pkg::MC_WORD_WIDTH-1:0] operation,
    output logic operation_done, dispatch_request,
    input  logic byte_valid,
    input  logic [7:0] byte_data,
    output logic byte_ready,
    input  logic [2:0] destination, source_index,
    input logic [15:0] target_read_data, effective_offset, address_base,
    output logic address_override,
    output logic [15:0] address_offset,
    output logic decode_operand,
    input  logic decode_done,
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
    input  logic [15:0] operand_read_data,
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
    input logic [7:0] event_vector,
    input logic event_needs_ack, ack_done,
    output logic ack_request, software_event_request, halt_request,
    output logic [7:0] software_vector,
    output logic context_commit, vector_request,
    output logic [15:0] context_cs,
    output logic [15:0] vector_offset,
    input logic [2:0] alu_operation,
    input logic alu_byte, reverse_operands,
    input logic [2:0] shift_kind, adjust_kind,
    output logic arithmetic_fault,
    input logic [127:0] register_state,
    output logic counter_branch_request, range_fault, bounds_fault,
    input logic [15:0] segment_read_value,
    output logic segment_write,
    output logic [15:0] segment_write_data,
    input logic result_write_allowed,
    input logic [15:0] decoded_flags_mask, decoded_undefined_mask,
    output logic flags_write_en,
    output logic [15:0] flags_write_data, flags_write_mask
);
    logic check_push2,check_pop2,add_allocation_sp;
    assign check_push2=allowed && operation==spk286_microcode_pkg::MC_CHECK_PUSH2;
    assign check_pop2=allowed && operation==spk286_microcode_pkg::MC_CHECK_POP2;
    assign add_allocation_sp=allowed && operation==spk286_microcode_pkg::MC_ADD_ALLOCATION_SP && allocation_valid_q;
    logic [15:0] auxiliary_q, allocation_q, frame_address_q;
    logic auxiliary_valid_q, allocation_valid_q, frame_address_valid_q, counter_valid_q;
    logic [4:0] counter_q;
    logic frame_read_gpr, frame_write_gpr, save_auxiliary, restore_auxiliary;
    logic save_allocation, load_counter, decrement_counter, counter_branch;
    logic check_push8, check_pop8, begin_stack_cursor, read_stack_cursor, check_stack_word, check_rm32, check_bounds;
    logic set_frame_address, read_frame_address, decrement_frame_address, allocate_stack, set_ea_plus2;
    logic push8_invalid, pop8_invalid, stack_cursor_valid_q, stack_arch_write;
    logic [15:0] stack_cursor_q;
    assign stack_arch_write = stack_write_sp && !stack_cursor_valid_q;
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
    assign counter_branch_request = counter_branch && ((operation == spk286_microcode_pkg::MC_BRANCH_ZERO) == (counter_q == 0));
    assign check_push8 = allowed && operation == spk286_microcode_pkg::MC_CHECK_PUSH8;
    assign check_pop8 = allowed && operation == spk286_microcode_pkg::MC_CHECK_POP8;
    assign begin_stack_cursor = allowed && operation == spk286_microcode_pkg::MC_BEGIN_STACK_CURSOR;
    assign read_stack_cursor = allowed && operation == spk286_microcode_pkg::MC_READ_STACK_CURSOR_TMP0 && stack_cursor_valid_q;
    assign check_stack_word = allowed && operation == spk286_microcode_pkg::MC_CHECK_STACK_TMP0 && temporary_valid_q[0];
    assign check_rm32 = allowed && operation == spk286_microcode_pkg::MC_CHECK_RM32;
    assign check_bounds = allowed && operation == spk286_microcode_pkg::MC_CHECK_BOUNDS && auxiliary_valid_q && &temporary_valid_q[1:0];
    assign range_fault = (check_push2 && stack_pointer[0] && stack_pointer<16'd4) ||
                         (check_pop2 && stack_pointer[0] && stack_pointer>=16'hFFFD) || (check_push8 && push8_invalid) || (check_pop8 && pop8_invalid) ||
                         (check_stack_word && tmp0_q == 16'hFFFF) ||
                         (check_rm32 && effective_offset[0] && effective_offset > 16'hFFFC);
    assign bounds_fault = check_bounds && ($signed(tmp1_q) < $signed(auxiliary_q) || $signed(tmp1_q) > $signed(tmp0_q));
    assign set_frame_address = allowed && operation == spk286_microcode_pkg::MC_SET_STACK_ADDRESS_TMP0 && temporary_valid_q[0];
    assign read_frame_address = allowed && operation == spk286_microcode_pkg::MC_READ_STACK_ADDRESS_TMP0 && frame_address_valid_q;
    assign decrement_frame_address = allowed && operation == spk286_microcode_pkg::MC_DECREMENT_STACK_ADDRESS && frame_address_valid_q;
    assign allocate_stack = allowed && operation == spk286_microcode_pkg::MC_ALLOCATE_STACK && allocation_valid_q && stack_cursor_valid_q;
    assign set_ea_plus2 = allowed && operation == spk286_microcode_pkg::MC_SET_EA_PLUS2;
    assign stack_offset = read_frame_address ? frame_address_q : stack_native_offset;

    logic adjust_request, adjust_complete, adjust_valid, adjust_write, adjust_fault;
    logic unused_adjust_ready, arithmetic_fault_q, check_arithmetic;
    logic [15:0] adjust_result, adjust_flags, adjust_mask;
    assign adjust_request = allowed && operation == spk286_microcode_pkg::MC_ADJUST && &temporary_valid_q[1:0] && !flags_valid_q;
    assign adjust_complete = adjust_request && adjust_valid;
    assign check_arithmetic = allowed && operation == spk286_microcode_pkg::MC_CHECK_ARITHMETIC;
    assign arithmetic_fault = check_arithmetic && arithmetic_fault_q;
    logic read_segment;
    assign read_segment = allowed && operation == spk286_microcode_pkg::MC_READ_SEG16_TMP0;
    assign segment_write = allowed && operation == spk286_microcode_pkg::MC_WRITE_SEG16_TMP0 && temporary_valid_q[0];
    assign segment_write_data = tmp0_q;
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
    logic [15:0] tmp0_q, tmp1_q, tmp2_q, flags_q, flags_mask_q;
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
    logic push_operation, pop_operation, push_transfer, read_ip, target_relative, target_absolute;
    logic redirect_operation, adjust_stack, count_operation, stack_write_sp, check_operand;
    logic target_valid_q;
    logic [15:0] target_q, stack_next_sp;
    logic fetch_byte, fetch_byte_tmp1, read_flags, restore_flags, set_if, clear_if_tf;
    logic direct_flags, sign_extend_byte, sign_fill_word, constant_one;
    assign direct_flags = allowed && operation == spk286_microcode_pkg::MC_FLAGS_DECODED;
    assign sign_extend_byte = allowed && operation == spk286_microcode_pkg::MC_SIGN_EXTEND8 && temporary_valid_q[0];
    assign sign_fill_word = allowed && operation == spk286_microcode_pkg::MC_SIGN_FILL16 && temporary_valid_q[0];
    assign constant_one = allowed && operation == spk286_microcode_pkg::MC_CONST_ONE_TMP1;
    logic read_event_flags, read_event_cs, read_event_ip, vector_ip, vector_cs;
    logic commit_context, ack_operation, request_event, halt_operation, iret_commit;
    spk286_stack stack_service (
        .request(push_transfer || pop_operation), .push(push_transfer), .adjust(adjust_stack), .operand_done(operand_done),
        .sp(stack_cursor_valid_q ? stack_cursor_q : stack_pointer), .adjustment(tmp1_q), .offset(stack_native_offset), .next_sp(stack_next_sp), .write_sp(stack_write_sp)
    );
    assign push_operation = allowed && operation == spk286_microcode_pkg::MC_PUSH16 && temporary_valid_q[0];
    assign push_transfer = push_operation && push_enabled;
    assign pop_operation = allowed && (operation == spk286_microcode_pkg::MC_POP16 ||
                                      operation == spk286_microcode_pkg::MC_POP16_TMP1 ||
                                      operation == spk286_microcode_pkg::MC_POP16_TMP2);
    assign stack_request = push_transfer || pop_operation || read_frame_address;
    assign read_ip = allowed && operation == spk286_microcode_pkg::MC_READ_IP16;
    assign target_relative = allowed && operation == spk286_microcode_pkg::MC_TARGET_REL16 && temporary_valid_q[1];
    assign target_absolute = allowed && operation == spk286_microcode_pkg::MC_TARGET_ABS16 && temporary_valid_q[0];
    assign redirect_operation = allowed && operation == spk286_microcode_pkg::MC_REDIRECT && target_valid_q;
    assign redirect_request = (redirect_operation && branch_taken) || context_commit;
    assign redirect_target = context_commit ? tmp0_q : target_q;
    assign adjust_stack = allowed && operation == spk286_microcode_pkg::MC_ADJUST_SP16 && temporary_valid_q[1];
    assign count_operation = allowed && operation == spk286_microcode_pkg::MC_COUNT;
    assign check_operand = allowed && operation == spk286_microcode_pkg::MC_CHECK_RM16;
    assign operand_check = check_operand;

    assign fetch_byte = allowed && operation == spk286_microcode_pkg::MC_FETCH_IMM8;
    assign fetch_byte_tmp1 = allowed && operation == spk286_microcode_pkg::MC_FETCH_IMM8_TMP1;
    assign read_flags = allowed && operation == spk286_microcode_pkg::MC_READ_FLAGS;
    assign restore_flags = allowed && operation == spk286_microcode_pkg::MC_RESTORE_FLAGS && temporary_valid_q[0];
    assign set_if = allowed && operation == spk286_microcode_pkg::MC_SET_IF;
    assign clear_if_tf = allowed && operation == spk286_microcode_pkg::MC_CLEAR_IF_TF;
    assign read_event_flags = allowed && operation == spk286_microcode_pkg::MC_EVENT_FLAGS;
    assign read_event_cs = allowed && operation == spk286_microcode_pkg::MC_EVENT_CS;
    assign read_event_ip = allowed && operation == spk286_microcode_pkg::MC_EVENT_IP;
    assign vector_ip = allowed && operation == spk286_microcode_pkg::MC_VECTOR_IP;
    assign vector_cs = allowed && operation == spk286_microcode_pkg::MC_VECTOR_CS;
    assign vector_request = vector_ip || vector_cs;
    assign vector_offset = {6'b000000, event_vector, 2'b00} + (vector_cs ? 16'd2 : 16'd0);
    assign commit_context = allowed && operation == spk286_microcode_pkg::MC_CONTEXT_COMMIT && &temporary_valid_q[1:0];
    assign iret_commit = allowed && operation == spk286_microcode_pkg::MC_IRET_COMMIT && &temporary_valid_q;
    assign context_commit = (commit_context || iret_commit) && redirect_ready;
    assign context_cs = tmp1_q;
    assign ack_operation = allowed && operation == spk286_microcode_pkg::MC_EVENT_ACK;
    assign ack_request = ack_operation && event_needs_ack;
    assign request_event = allowed && operation == spk286_microcode_pkg::MC_REQUEST_EVENT;
    assign software_event_request = request_event;
    assign software_vector = tmp0_q[7:0];
    assign halt_operation = allowed && operation == spk286_microcode_pkg::MC_HALT;
    assign halt_request = halt_operation;


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

    spk286_alu alu (.operation(alu_operation), .operand_a(reverse_operands ? tmp1_q : tmp0_q), .operand_b(reverse_operands ? tmp0_q : tmp1_q),
                   .carry_in(carry_in), .operand_byte(alu_byte), .result(alu_result), .candidate_flags(alu_flags));
    assign allowed = operation_valid && !reset && !cancel && !start;
    assign fetch_tmp1 = operation == spk286_microcode_pkg::MC_FETCH_IMM16_TMP1;
    assign fetch_word = allowed && (operation == spk286_microcode_pkg::MC_FETCH_IMM16 || fetch_tmp1);
    assign fetch_signed_byte = allowed && (operation == spk286_microcode_pkg::MC_FETCH_IMM8S_TMP1 || operation == spk286_microcode_pkg::MC_FETCH_IMM8S_TMP0);
    assign move_word = allowed && (operation == spk286_microcode_pkg::MC_MOVE || operation == spk286_microcode_pkg::MC_MOVE8) && temporary_valid_q[0];
    assign read_destination = allowed && (operation == spk286_microcode_pkg::MC_READ_DST16 || operation == spk286_microcode_pkg::MC_READ_DST8);
    assign decode_operand = allowed && operation == spk286_microcode_pkg::MC_DECODE_MODRM;
    assign read_tmp1 = operation == spk286_microcode_pkg::MC_READ_REG16_TMP1 || operation == spk286_microcode_pkg::MC_READ_RM16_TMP1 || operation == spk286_microcode_pkg::MC_READ_REG8_TMP1 || operation == spk286_microcode_pkg::MC_READ_RM8_TMP1;
    assign result_operation = operation == spk286_microcode_pkg::MC_WRITE_RESULT_REG8 || operation == spk286_microcode_pkg::MC_WRITE_RESULT_RM8 || operation == spk286_microcode_pkg::MC_WRITE_RESULT_REG16 || operation == spk286_microcode_pkg::MC_WRITE_RESULT_RM16 ||
                              (operation == spk286_microcode_pkg::MC_WRITE_RESULT_DST || operation == spk286_microcode_pkg::MC_WRITE_RESULT_DST8);
    assign commit_result = allowed && result_operation && temporary_valid_q[2] && !result_disposed_q;
    assign discard_result = commit_result && !allow_result_write;
    assign result_to_dst = commit_result && allow_result_write && (operation == spk286_microcode_pkg::MC_WRITE_RESULT_DST || operation == spk286_microcode_pkg::MC_WRITE_RESULT_DST8);
    assign operand_request = vector_request || stack_request || check_operand || (allowed &&
                             (write_reg_tmp1 || operation == spk286_microcode_pkg::MC_READ_REG16 || operation == spk286_microcode_pkg::MC_READ_RM16 || operation == spk286_microcode_pkg::MC_READ_REG8 || operation == spk286_microcode_pkg::MC_READ_RM8 || read_tmp1 ||
                              ((operation == spk286_microcode_pkg::MC_WRITE_REG16 || operation == spk286_microcode_pkg::MC_WRITE_RM16 || operation == spk286_microcode_pkg::MC_WRITE_REG8 || operation == spk286_microcode_pkg::MC_WRITE_RM8) && temporary_valid_q[0]) ||
                              (commit_result && allow_result_write && operation != spk286_microcode_pkg::MC_WRITE_RESULT_DST && operation != spk286_microcode_pkg::MC_WRITE_RESULT_DST8)));
    assign operand_write = write_reg_tmp1 || push_transfer || operation == spk286_microcode_pkg::MC_WRITE_REG16 || operation == spk286_microcode_pkg::MC_WRITE_RM16 || operation == spk286_microcode_pkg::MC_WRITE_REG8 || operation == spk286_microcode_pkg::MC_WRITE_RM8 || result_operation;
    assign operand_select_rm = vector_request || stack_request || check_operand || operation == spk286_microcode_pkg::MC_READ_RM16 || operation == spk286_microcode_pkg::MC_READ_RM16_TMP1 ||
                               operation == spk286_microcode_pkg::MC_WRITE_RM16 || operation == spk286_microcode_pkg::MC_WRITE_RESULT_RM16 ||
                               operation == spk286_microcode_pkg::MC_READ_RM8 || operation == spk286_microcode_pkg::MC_READ_RM8_TMP1 || operation == spk286_microcode_pkg::MC_WRITE_RM8 || operation == spk286_microcode_pkg::MC_WRITE_RESULT_RM8;
    assign operand_byte = operation == spk286_microcode_pkg::MC_WRITE_REG8_TMP1 || operation == spk286_microcode_pkg::MC_READ_REG8 || operation == spk286_microcode_pkg::MC_READ_RM8 ||
                          operation == spk286_microcode_pkg::MC_READ_REG8_TMP1 || operation == spk286_microcode_pkg::MC_READ_RM8_TMP1 ||
                          operation == spk286_microcode_pkg::MC_WRITE_REG8 || operation == spk286_microcode_pkg::MC_WRITE_RM8 ||
                          operation == spk286_microcode_pkg::MC_WRITE_RESULT_REG8 || operation == spk286_microcode_pkg::MC_WRITE_RESULT_RM8;
    assign operand_write_data = push_transfer && push_return_ip ? architectural_ip : (write_reg_tmp1 ? tmp1_q : (result_operation ? tmp2_q : tmp0_q));
    assign read_operand = operand_request && !operand_write && !operand_check;
    assign compute_alu = allowed && operation == spk286_microcode_pkg::MC_ALU && temporary_valid_q[0] && temporary_valid_q[1] && !flags_valid_q;
    assign commit_flags = allowed && operation == spk286_microcode_pkg::MC_COMMIT_FLAGS && flags_valid_q && result_disposed_q;
    assign byte_ready = fetch_word || fetch_signed_byte || fetch_byte || fetch_byte_tmp1 || decode_byte_ready;
    assign operation_done = add_allocation_sp || ((check_push2 || check_pop2) && !range_fault) || frame_read_gpr || frame_write_gpr || save_auxiliary || restore_auxiliary || save_allocation || load_counter ||
                            decrement_counter || counter_branch || begin_stack_cursor || read_stack_cursor || set_frame_address || decrement_frame_address || allocate_stack || set_ea_plus2 ||
                            ((check_push8 || check_pop8 || check_stack_word || check_rm32) && !range_fault) || (check_bounds && !bounds_fault) || read_segment || segment_write || adjust_complete || (check_arithmetic && !arithmetic_fault_q) || dispatch_request || constant_zero || constant_ones || read_ea || read_target || move_source || set_address || add_base || shift_complete || count_low || direct_flags || sign_extend_byte || sign_fill_word || constant_one || read_flags || restore_flags || set_if || clear_if_tf || read_event_flags || read_event_cs || read_event_ip ||
                            context_commit || request_event || halt_operation || (ack_operation && (!event_needs_ack || ack_done)) || ((fetch_byte || fetch_byte_tmp1) && byte_valid) ||
                            read_ip || target_relative || target_absolute || adjust_stack || count_operation ||
                            (push_operation && !push_enabled) || (redirect_operation && (!branch_taken || redirect_ready)) || move_word || read_destination || compute_alu || commit_flags || discard_result || result_to_dst ||
                            (fetch_word && byte_valid && high_byte_q) || (fetch_signed_byte && byte_valid) ||
                            (decode_operand && decode_done) || (operand_request && operand_done);
    assign gpr_write_en = add_allocation_sp || frame_write_gpr || allocate_stack || move_source || stack_arch_write || (count_operation && decrement_count) || move_word || result_to_dst || operand_gpr_write_en;
    assign gpr_write_byte = !add_allocation_sp && !frame_write_gpr && !allocate_stack && !stack_arch_write && !count_operation && ((move_word && operation == spk286_microcode_pkg::MC_MOVE8) ||
                            (result_to_dst && operation == spk286_microcode_pkg::MC_WRITE_RESULT_DST8) || operand_gpr_write_byte);
    assign gpr_write_index = add_allocation_sp ? 3'd4 : frame_write_gpr ? frame_write_index : allocate_stack ? 3'd4 : move_source ? source_index : stack_arch_write ? 3'd4 : (count_operation ? 3'd1 : (move_word || result_to_dst ? destination : operand_gpr_write_index));
    assign gpr_write_data = add_allocation_sp ? stack_pointer+allocation_q : frame_write_gpr ? tmp0_q : allocate_stack ? stack_cursor_q - allocation_q : move_source ? tmp1_q : stack_arch_write ? stack_next_sp : (count_operation ? count_value - 16'd1 : (result_to_dst ? tmp2_q : (move_word ? tmp0_q : operand_gpr_write_data)));
    assign flags_write_en = direct_flags || commit_flags || restore_flags || set_if || clear_if_tf || iret_commit;
    assign flags_write_data = direct_flags ? direct_flags_data : restore_flags ? tmp0_q : (iret_commit ? tmp2_q : (set_if ? {6'd0, if_value, 9'd0} : (clear_if_tf ? 16'd0 : flags_q)));
    assign flags_write_mask = direct_flags ? direct_flags_mask : restore_flags || iret_commit ? 16'h0FD5 : (set_if ? 16'h0200 : (clear_if_tf ? 16'h0300 : flags_mask_q));

    always_ff @(posedge clk) begin
        if (reset || cancel || start) begin
            stack_cursor_q <= 16'd0; stack_cursor_valid_q <= 1'b0;
            auxiliary_q <= 16'd0; allocation_q <= 16'd0; frame_address_q <= 16'd0; counter_q <= 5'd0;
            auxiliary_valid_q <= 1'b0; allocation_valid_q <= 1'b0; frame_address_valid_q <= 1'b0; counter_valid_q <= 1'b0;
            arithmetic_fault_q <= 1'b0;
            address_override <= 1'b0; address_offset <= 16'd0;
            target_q <= 16'h0000; target_valid_q <= 1'b0;
            tmp0_q <= 16'h0000; tmp1_q <= 16'h0000; tmp2_q <= 16'h0000;
            flags_q <= 16'h0000; flags_mask_q <= 16'h0000;
            high_byte_q <= 1'b0; temporary_valid_q <= 3'b000;
            flags_valid_q <= 1'b0; result_disposed_q <= 1'b0; result_suppress_q <= 1'b0;
        end else begin
            if (begin_stack_cursor) begin stack_cursor_q <= stack_pointer; stack_cursor_valid_q <= 1'b1; end
            if (stack_write_sp && stack_cursor_valid_q) stack_cursor_q <= stack_next_sp;
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
                if (operation == spk286_microcode_pkg::MC_POP16_TMP2) begin tmp2_q <= operand_read_data; temporary_valid_q[2] <= 1'b1; end
                else if (read_tmp1 || vector_cs || operation == spk286_microcode_pkg::MC_POP16_TMP1) begin tmp1_q <= operand_read_data; temporary_valid_q[1] <= 1'b1; end
                else begin tmp0_q <= operand_read_data; temporary_valid_q[0] <= 1'b1; end
            end
            if (fetch_byte_tmp1 && byte_valid) begin tmp1_q <= {8'd0, byte_data}; temporary_valid_q[1] <= 1'b1; end
            if (fetch_byte && byte_valid) begin tmp0_q <= {8'd0, byte_data}; temporary_valid_q[0] <= 1'b1; end
            if (read_flags || read_event_flags || read_event_cs || read_event_ip) begin
                tmp0_q <= read_flags ? architectural_flags : (read_event_flags ? event_flags : (read_event_cs ? event_cs : event_ip));
                temporary_valid_q[0] <= 1'b1;
            end
            if (read_ip) begin tmp0_q <= architectural_ip; temporary_valid_q[0] <= 1'b1; end
            if (target_relative || target_absolute) begin
                target_q <= target_relative ? architectural_ip + tmp1_q : tmp0_q;
                target_valid_q <= 1'b1;
            end
            if (redirect_operation && operation_done) target_valid_q <= 1'b0;
            if (read_destination) begin tmp0_q <= operation == spk286_microcode_pkg::MC_READ_DST8 ? {8'd0, destination_byte_data} : destination_read_data; temporary_valid_q[0] <= 1'b1; end
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
        end
    end
endmodule
