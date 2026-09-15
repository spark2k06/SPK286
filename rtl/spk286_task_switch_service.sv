// Serialized 80286 task-switch transaction.
//
// This is the single task-service boundary used by direct TSS transfers,
// task gates and nested-task returns.  The TSS service performs the
// architectural save/load sequence first; the incoming LDTR and segment
// caches are then validated in the new task context.  The BIU-facing memory
// interface remains one request at a time and is stable across READY waits.
`timescale 1ns/1ps

module spk286_task_switch_service (
    input  logic        clk,
    input  logic        reset,
    input  logic        cancel,
    input  logic        start,
    input  logic        nested_call,
    input  logic        jump_task,
    input  logic        return_task,
    input  logic [15:0] target_selector,
    input  logic [23:0] target_base,
    input  logic [15:0] target_limit,
    input  logic [7:0]  target_access,
    input  logic [23:0] target_descriptor_address,
    input  logic [15:0] current_selector,
    input  logic [23:0] current_base,
    input  logic [15:0] current_limit,
    input  logic [7:0]  current_access,
    input  logic [23:0] current_descriptor_address,
    input  logic [15:0] current_ip,
    input  logic [15:0] current_flags,
    input  logic [127:0] current_gpr,
    input  logic [63:0] current_segments,
    input  logic [15:0] current_ldtr,
    input  logic [15:0] gdtr_limit,
    input  logic [23:0] gdtr_base,
    input  logic        memory_done,
    input  logic [15:0] memory_read_data,
    output logic        memory_request,
    output logic        memory_write,
    output logic        memory_byte,
    output logic [23:0] memory_address,
    output logic [15:0] memory_write_data,
    output logic        busy,
    output logic        complete,
    output logic        commit_ready,
    output logic        fault,
    output logic [7:0]  fault_vector,
    output logic [15:0] fault_error_code,
    output logic        commit_valid,
    output logic [15:0] loaded_ip,
    output logic [15:0] loaded_flags,
    output logic [127:0] loaded_gpr,
    output logic [63:0] loaded_segments,
    output logic [15:0] loaded_ldtr,
    output logic [23:0] loaded_ldtr_base,
    output logic [15:0] loaded_ldtr_limit,
    output logic [7:0]  loaded_ldtr_access,
    output logic [3:0]  loaded_ldtr_class,
    output logic        loaded_ldtr_valid,
    output logic        loaded_ldtr_present,
    output logic [15:0] loaded_backlink,
    output logic [15:0] loaded_tr_selector,
    output logic [23:0] loaded_tr_base,
    output logic [15:0] loaded_tr_limit,
    output logic [7:0]  loaded_tr_access,
    output logic [63:0] cache_selectors,
    output logic [95:0] cache_bases,
    output logic [63:0] cache_limits,
    output logic [31:0] cache_access,
    output logic [15:0] cache_classes,
    output logic [3:0]  cache_present,
    output logic [3:0]  cache_protected,
    output logic [7:0]  cache_dpl,
    output logic [3:0]  cache_tables,
    output logic [7:0]  cache_rpl,
    output logic        memory_lock
);
    typedef enum logic [4:0] {
        ST_IDLE,
        ST_CHECK,
        ST_LDTR_DESC0,
        ST_LDTR_DESC1,
        ST_LDTR_DESC2,
        ST_LDTR_DESC3,
        ST_SEG_START,
        ST_SEG_ACTIVE,
        ST_TASK_START,
        ST_TASK_ACTIVE,
        ST_COMPLETE,
        ST_FAULT,
        ST_RETURN_LINK,
        ST_RETURN_DESC0,
        ST_RETURN_DESC1,
        ST_RETURN_DESC2,
        ST_RETURN_DESC3
    } state_t;

    state_t state_q;
    logic [15:0] target_selector_q, target_limit_q, current_selector_q, current_limit_q;
    logic [23:0] target_base_q, current_base_q;
    logic [7:0] target_access_q, current_access_q;
    logic [23:0] target_descriptor_address_q, current_descriptor_address_q;
    logic [15:0] current_ip_q, current_flags_q, current_ldtr_q;
    logic [127:0] current_gpr_q;
    logic [63:0] current_segments_q;
    logic nested_call_q, jump_task_q, return_task_q;
    logic [15:0] incoming_ldtr_selector_q;
    logic [15:0] incoming_ldtr_word0_q, incoming_ldtr_word1_q, incoming_ldtr_word2_q;
    logic [23:0] incoming_ldtr_descriptor_address_q;
    logic [15:0] incoming_ldtr_limit_q;
    logic [23:0] incoming_ldtr_base_q;
    logic [7:0] incoming_ldtr_access_q;
    logic [3:0] incoming_ldtr_class_q;
    logic incoming_ldtr_valid_q, incoming_ldtr_present_q;
    logic return_target_resolved_q;
    logic [15:0] return_selector_q;
    logic [15:0] return_descriptor_word0_q, return_descriptor_word1_q;
    logic [15:0] return_descriptor_word2_q;
    logic [23:0] return_descriptor_address;
    logic [15:0] return_descriptor_limit;
    logic [23:0] return_descriptor_base;
    logic [7:0] return_descriptor_access;
    logic [3:0] return_descriptor_class;
    logic return_descriptor_valid, return_descriptor_reserved_valid, return_descriptor_present;
    logic ldtr_memory_request, return_memory_request;
    logic segment_start, segment_memory_request, segment_memory_write, segment_memory_byte;
    logic [23:0] segment_memory_address;
    logic [15:0] segment_memory_write_data;
    logic segment_complete, segment_fault;
    logic [7:0] segment_fault_vector;
    logic [15:0] segment_fault_error_code;
    logic task_start, task_memory_request, task_memory_write, task_memory_byte;
    logic [23:0] task_memory_address;
    logic [15:0] task_memory_write_data;
    logic task_complete, task_fault;
    logic [7:0] task_fault_vector;
    logic [15:0] task_fault_error_code;
    logic [15:0] task_loaded_ip, task_loaded_flags, task_loaded_ldtr, task_loaded_backlink;
    logic [127:0] task_loaded_gpr;
    logic [63:0] task_loaded_segments;
    logic [15:0] task_loaded_tr_selector, task_loaded_tr_limit;
    logic [23:0] task_loaded_tr_base;
    logic [7:0] task_loaded_tr_access;
    logic [63:0] segment_cache_selectors;
    logic [95:0] segment_cache_bases;
    logic [63:0] segment_cache_limits;
    logic [31:0] segment_cache_access;
    logic [15:0] segment_cache_classes;
    logic [3:0] segment_cache_present, segment_cache_protected, segment_cache_tables;
    logic [7:0] segment_cache_dpl, segment_cache_rpl;
    logic [15:0] incoming_ldtr_limit;
    logic [23:0] incoming_ldtr_base;
    logic [7:0] incoming_ldtr_access;
    logic [3:0] incoming_ldtr_class;
    logic incoming_ldtr_valid, incoming_ldtr_reserved_valid, incoming_ldtr_present;
    logic incoming_ip_limit_fault;
    logic task_memory_lock;
    /* The composite intentionally exposes cache candidates, not the child
       service's intermediate write metadata. */
    /* verilator lint_off UNUSEDSIGNAL */
    logic segment_commit_valid_unused;
    logic task_descriptor_update_unused;
    logic [23:0] task_descriptor_update_address_unused;
    logic [7:0] task_descriptor_update_data_unused;
    /* verilator lint_on UNUSEDSIGNAL */

    assign ldtr_memory_request = state_q == ST_LDTR_DESC0 || state_q == ST_LDTR_DESC1 ||
                                 state_q == ST_LDTR_DESC2 || state_q == ST_LDTR_DESC3;
    assign return_descriptor_address = gdtr_base + {8'd0, return_selector_q[15:3], 3'b000};
    assign return_memory_request = state_q == ST_RETURN_LINK ||
                                   state_q == ST_RETURN_DESC0 || state_q == ST_RETURN_DESC1 ||
                                   state_q == ST_RETURN_DESC2 || state_q == ST_RETURN_DESC3;
    assign segment_start = state_q == ST_SEG_START;
    assign task_start = state_q == ST_TASK_START;
    // The TSS service has already loaded the architectural task context when
    // this check runs.  A bad IP is therefore a late #GP(0) in the new task.
    assign incoming_ip_limit_fault = task_loaded_ip > segment_cache_limits[31:16];

    /* The return path only needs the TSS classification, base, limit and
       presence bits; the remaining descriptor fields are intentionally
       unused at this transaction boundary. */
    /* verilator lint_off PINCONNECTEMPTY */
    spk286_descriptor return_descriptor_parser (
        .raw_descriptor({memory_read_data, return_descriptor_word2_q,
                         return_descriptor_word1_q, return_descriptor_word0_q}),
        .limit(return_descriptor_limit), .base(return_descriptor_base),
        .access_rights(return_descriptor_access), .descriptor_class(return_descriptor_class),
        .descriptor_valid(return_descriptor_valid), .reserved_form_valid(return_descriptor_reserved_valid),
        .present(return_descriptor_present), .segment(), .executable(), .conforming(),
        .expand_down(), .readable(), .writable(), .accessed(), .dpl(),
        .gate_target_selector(), .gate_offset(), .gate_parameter_count()
    );

    /* The incoming task's non-null LDTR is always a GDT selector.  Resolve
       it after the TSS load and before validating the task's LDT-qualified
       segment selectors. */
    /* verilator lint_off PINCONNECTEMPTY */
    spk286_descriptor incoming_ldtr_parser (
        .raw_descriptor({memory_read_data, incoming_ldtr_word2_q,
                         incoming_ldtr_word1_q, incoming_ldtr_word0_q}),
        .limit(incoming_ldtr_limit), .base(incoming_ldtr_base),
        .access_rights(incoming_ldtr_access), .descriptor_class(incoming_ldtr_class),
        .descriptor_valid(incoming_ldtr_valid), .reserved_form_valid(incoming_ldtr_reserved_valid),
        .present(incoming_ldtr_present), .segment(), .executable(), .conforming(),
        .expand_down(), .readable(), .writable(), .accessed(), .dpl(),
        .gate_target_selector(), .gate_offset(), .gate_parameter_count()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    /* Child phase/status outputs are represented by the composite state
       machine; intentionally do not duplicate them at this boundary. */
    /* verilator lint_off PINCONNECTEMPTY */
    spk286_task_segment_service segment_service (
        .clk(clk), .reset(reset), .cancel(cancel), .start(segment_start),
        .task_segments(task_loaded_segments), .gdtr_limit(gdtr_limit), .gdtr_base(gdtr_base),
        .ldtr_valid(incoming_ldtr_valid_q), .ldtr_present(incoming_ldtr_present_q),
        .ldtr_limit(incoming_ldtr_limit_q), .ldtr_base(incoming_ldtr_base_q), .update_accessed(1'b1),
        .memory_done(memory_done && state_q == ST_SEG_ACTIVE), .memory_read_data(memory_read_data),
        .memory_request(segment_memory_request), .memory_write(segment_memory_write),
        .memory_byte(segment_memory_byte), .memory_address(segment_memory_address),
        .memory_write_data(segment_memory_write_data), .busy(),
        .complete(segment_complete), .fault(segment_fault), .fault_vector(segment_fault_vector),
        .fault_error_code(segment_fault_error_code), .commit_valid(segment_commit_valid_unused),
        .cache_selectors(segment_cache_selectors), .cache_bases(segment_cache_bases),
        .cache_limits(segment_cache_limits), .cache_access(segment_cache_access),
        .cache_classes(segment_cache_classes), .cache_present(segment_cache_present),
        .cache_protected(segment_cache_protected), .cache_dpl(segment_cache_dpl),
        .cache_tables(segment_cache_tables), .cache_rpl(segment_cache_rpl)
    );

    spk286_tss_service task_service (
        .clk(clk), .reset(reset), .cancel(cancel), .start(task_start),
        .nested_call(nested_call_q), .jump_task(jump_task_q), .return_task(return_task_q),
        .target_selector(target_selector_q), .target_base(target_base_q), .target_limit(target_limit_q),
        .target_access(target_access_q), .target_descriptor_address(target_descriptor_address_q),
        .current_selector(current_selector_q), .current_base(current_base_q), .current_limit(current_limit_q),
        .current_access(current_access_q), .current_descriptor_address(current_descriptor_address_q),
        .current_ip(current_ip_q), .current_flags(current_flags_q), .current_gpr(current_gpr_q),
        .current_segments(current_segments_q), .current_ldtr(current_ldtr_q),
        .memory_done(memory_done && state_q == ST_TASK_ACTIVE), .memory_read_data(memory_read_data),
        .memory_request(task_memory_request), .memory_write(task_memory_write),
        .memory_byte(task_memory_byte), .memory_lock(task_memory_lock), .memory_address(task_memory_address),
        .memory_write_data(task_memory_write_data), .busy(), .complete(task_complete),
        .fault(task_fault), .fault_vector(task_fault_vector), .fault_error_code(task_fault_error_code),
        .commit_valid(), .loaded_ip(task_loaded_ip), .loaded_flags(task_loaded_flags),
        .loaded_gpr(task_loaded_gpr), .loaded_segments(task_loaded_segments),
        .loaded_ldtr(task_loaded_ldtr), .loaded_backlink(task_loaded_backlink),
        .loaded_tr_selector(task_loaded_tr_selector), .loaded_tr_base(task_loaded_tr_base),
        .loaded_tr_limit(task_loaded_tr_limit), .loaded_tr_access(task_loaded_tr_access),
        .descriptor_update(task_descriptor_update_unused),
        .descriptor_update_address(task_descriptor_update_address_unused),
        .descriptor_update_data(task_descriptor_update_data_unused)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    assign memory_request = ldtr_memory_request || return_memory_request ||
                            segment_memory_request || task_memory_request;
    assign memory_write = segment_memory_request ? segment_memory_write : task_memory_request ? task_memory_write : 1'b0;
    assign memory_byte = segment_memory_request ? segment_memory_byte : task_memory_request ? task_memory_byte : 1'b0;
    assign memory_address = (state_q == ST_LDTR_DESC0) ? incoming_ldtr_descriptor_address_q :
                            (state_q == ST_LDTR_DESC1) ? (incoming_ldtr_descriptor_address_q + 24'd2) :
                            (state_q == ST_LDTR_DESC2) ? (incoming_ldtr_descriptor_address_q + 24'd4) :
                            (state_q == ST_LDTR_DESC3) ? (incoming_ldtr_descriptor_address_q + 24'd6) :
                            (state_q == ST_RETURN_LINK) ? (current_base_q + {8'd0, spk286_tss_pkg::TSS_BACKLINK}) :
                            (state_q == ST_RETURN_DESC0) ? return_descriptor_address :
                            (state_q == ST_RETURN_DESC1) ? (return_descriptor_address + 24'd2) :
                            (state_q == ST_RETURN_DESC2) ? (return_descriptor_address + 24'd4) :
                            (state_q == ST_RETURN_DESC3) ? (return_descriptor_address + 24'd6) :
                            segment_memory_request ? segment_memory_address : task_memory_address;
    assign memory_write_data = segment_memory_request ? segment_memory_write_data : task_memory_write_data;
    assign busy = state_q != ST_IDLE && state_q != ST_COMPLETE && state_q != ST_FAULT;
    assign complete = state_q == ST_COMPLETE;
    assign commit_ready = state_q == ST_TASK_ACTIVE && task_complete;
    assign fault = state_q == ST_FAULT;
    // The child service's one-cycle commit state is consumed when the
    // composite advances to ST_COMPLETE; expose the composite commit there.
    assign commit_valid = state_q == ST_COMPLETE;
    assign loaded_ip = task_loaded_ip;
    assign loaded_flags = task_loaded_flags;
    assign loaded_gpr = task_loaded_gpr;
    assign loaded_segments = task_loaded_segments;
    assign loaded_ldtr = task_loaded_ldtr;
    assign loaded_ldtr_base = incoming_ldtr_base_q;
    assign loaded_ldtr_limit = incoming_ldtr_limit_q;
    assign loaded_ldtr_access = incoming_ldtr_access_q;
    assign loaded_ldtr_class = incoming_ldtr_class_q;
    assign loaded_ldtr_valid = incoming_ldtr_valid_q;
    assign loaded_ldtr_present = incoming_ldtr_present_q;
    assign loaded_backlink = task_loaded_backlink;
    assign loaded_tr_selector = task_loaded_tr_selector;
    assign loaded_tr_base = task_loaded_tr_base;
    assign loaded_tr_limit = task_loaded_tr_limit;
    assign loaded_tr_access = task_loaded_tr_access;
    assign cache_selectors = segment_cache_selectors;
    assign cache_bases = segment_cache_bases;
    assign cache_limits = segment_cache_limits;
    assign cache_access = segment_cache_access;
    assign cache_classes = segment_cache_classes;
    assign cache_present = segment_cache_present;
    assign cache_protected = segment_cache_protected;
    assign cache_dpl = segment_cache_dpl;
    assign cache_tables = segment_cache_tables;
    assign cache_rpl = segment_cache_rpl;
    assign memory_lock = task_memory_lock;

    logic [7:0] fault_vector_q;
    logic [15:0] fault_error_code_q;
    always_comb begin
        fault_vector = fault_vector_q;
        fault_error_code = fault_error_code_q;
    end

    always_ff @(posedge clk) begin
        if (reset || cancel) begin
            state_q <= ST_IDLE;
            target_selector_q <= 16'h0; target_base_q <= 24'h0; target_limit_q <= 16'h0;
            target_access_q <= 8'h0; target_descriptor_address_q <= 24'h0;
            current_selector_q <= 16'h0; current_base_q <= 24'h0; current_limit_q <= 16'h0;
            current_access_q <= 8'h0; current_descriptor_address_q <= 24'h0;
            current_ip_q <= 16'h0; current_flags_q <= 16'h0; current_gpr_q <= 128'h0;
            current_segments_q <= 64'h0; current_ldtr_q <= 16'h0;
            nested_call_q <= 1'b0; jump_task_q <= 1'b0; return_task_q <= 1'b0;
            incoming_ldtr_selector_q <= 16'h0000;
            incoming_ldtr_word0_q <= 16'h0000; incoming_ldtr_word1_q <= 16'h0000;
            incoming_ldtr_word2_q <= 16'h0000; incoming_ldtr_descriptor_address_q <= 24'h000000;
            incoming_ldtr_limit_q <= 16'h0000; incoming_ldtr_base_q <= 24'h000000;
            incoming_ldtr_access_q <= 8'h00; incoming_ldtr_class_q <= spk286_protected_pkg::DESC_INVALID;
            incoming_ldtr_valid_q <= 1'b0; incoming_ldtr_present_q <= 1'b0;
            return_target_resolved_q <= 1'b0; return_selector_q <= 16'h0000;
            return_descriptor_word0_q <= 16'h0000; return_descriptor_word1_q <= 16'h0000;
            return_descriptor_word2_q <= 16'h0000;
            fault_vector_q <= 8'h0; fault_error_code_q <= 16'h0;
        end else begin
            if (state_q == ST_COMPLETE || state_q == ST_FAULT) begin
                state_q <= ST_IDLE;
            end else if (state_q == ST_IDLE && start) begin
                target_selector_q <= target_selector; target_base_q <= target_base;
                target_limit_q <= target_limit; target_access_q <= target_access;
                target_descriptor_address_q <= target_descriptor_address;
                current_selector_q <= current_selector; current_base_q <= current_base;
                current_limit_q <= current_limit; current_access_q <= current_access;
                current_descriptor_address_q <= current_descriptor_address;
                current_ip_q <= current_ip; current_flags_q <= current_flags;
                current_gpr_q <= current_gpr; current_segments_q <= current_segments;
                current_ldtr_q <= current_ldtr; nested_call_q <= nested_call;
                jump_task_q <= jump_task; return_task_q <= return_task;
                return_target_resolved_q <= 1'b0;
                // Never publish a previous task's LDT cache while the new
                // descriptor is still being validated (or when it faults).
                incoming_ldtr_limit_q <= 16'h0000; incoming_ldtr_base_q <= 24'h000000;
                incoming_ldtr_access_q <= 8'h00; incoming_ldtr_class_q <= spk286_protected_pkg::DESC_INVALID;
                incoming_ldtr_valid_q <= 1'b0; incoming_ldtr_present_q <= 1'b0;
                state_q <= ST_CHECK;
            end else if (state_q == ST_CHECK) begin
                if (return_task_q && !return_target_resolved_q) begin
                    if (current_limit_q < spk286_tss_pkg::TSS_MIN_LIMIT || !current_access_q[7]) begin
                        fault_vector_q <= 8'd10;
                        fault_error_code_q <= current_selector_q;
                        state_q <= ST_FAULT;
                    end else state_q <= ST_RETURN_LINK;
                end else if (target_selector_q[15:3] == 13'd0 || target_selector_q == current_selector_q ||
                    target_limit_q < spk286_tss_pkg::TSS_MIN_LIMIT || current_limit_q < spk286_tss_pkg::TSS_MIN_LIMIT ||
                    !target_access_q[7] || !current_access_q[7] ||
                    (!return_task_q && (!target_access_q[0] || target_access_q[1])) ||
                    (return_task_q && (!target_access_q[0] || !target_access_q[1]))) begin
                    fault_vector_q <= target_access_q[7] ? 8'd10 : 8'd11;
                    fault_error_code_q <= target_selector_q;
                    state_q <= ST_FAULT;
                end else state_q <= ST_TASK_START;
            end else if (state_q == ST_RETURN_LINK && memory_done) begin
                if (memory_read_data[2] || memory_read_data[15:3] == 13'd0 ||
                    ({1'b0, memory_read_data[15:3], 3'b000} + 17'd7 > {1'b0, gdtr_limit})) begin
                    fault_vector_q <= 8'd10;
                    fault_error_code_q <= memory_read_data;
                    state_q <= ST_FAULT;
                end else begin
                    return_selector_q <= memory_read_data;
                    state_q <= ST_RETURN_DESC0;
                end
            end else if (state_q == ST_RETURN_DESC0 && memory_done) begin
                return_descriptor_word0_q <= memory_read_data;
                state_q <= ST_RETURN_DESC1;
            end else if (state_q == ST_RETURN_DESC1 && memory_done) begin
                return_descriptor_word1_q <= memory_read_data;
                state_q <= ST_RETURN_DESC2;
            end else if (state_q == ST_RETURN_DESC2 && memory_done) begin
                return_descriptor_word2_q <= memory_read_data;
                state_q <= ST_RETURN_DESC3;
            end else if (state_q == ST_RETURN_DESC3 && memory_done) begin
                if (!return_descriptor_valid || !return_descriptor_reserved_valid ||
                    !return_descriptor_present ||
                    return_descriptor_class != spk286_protected_pkg::DESC_TSS_BUSY ||
                    return_descriptor_limit < spk286_tss_pkg::TSS_MIN_LIMIT) begin
                    fault_vector_q <= return_descriptor_present ? 8'd10 : 8'd11;
                    fault_error_code_q <= return_selector_q;
                    state_q <= ST_FAULT;
                end else begin
                    target_selector_q <= return_selector_q;
                    target_base_q <= return_descriptor_base;
                    target_limit_q <= return_descriptor_limit;
                    target_access_q <= return_descriptor_access;
                    target_descriptor_address_q <= return_descriptor_address;
                    return_target_resolved_q <= 1'b1;
                    state_q <= ST_CHECK;
                end
            end else if (state_q == ST_TASK_START) begin
                state_q <= ST_TASK_ACTIVE;
            end else if (state_q == ST_TASK_ACTIVE) begin
                if (task_fault) begin
                    fault_vector_q <= task_fault_vector;
                    fault_error_code_q <= task_fault_error_code;
                    state_q <= ST_FAULT;
                end else if (task_complete) begin
                    // The child service has now performed BUSY/save/load.
                    // Continue with the incoming task's late validation.
                    incoming_ldtr_selector_q <= task_loaded_ldtr;
                    if (task_loaded_ldtr == 16'h0000) begin
                        incoming_ldtr_limit_q <= 16'h0000;
                        incoming_ldtr_base_q <= 24'h000000;
                        incoming_ldtr_access_q <= 8'h00;
                        incoming_ldtr_class_q <= spk286_protected_pkg::DESC_INVALID;
                        incoming_ldtr_valid_q <= 1'b0;
                        incoming_ldtr_present_q <= 1'b0;
                        state_q <= ST_SEG_START;
                    end else if (task_loaded_ldtr[2] || task_loaded_ldtr[15:3] == 13'd0 ||
                                 ({1'b0, task_loaded_ldtr[15:3], 3'b000} + 17'd7 > {1'b0, gdtr_limit})) begin
                        fault_vector_q <= 8'd10;
                        fault_error_code_q <= task_loaded_ldtr;
                        state_q <= ST_FAULT;
                    end else begin
                        incoming_ldtr_descriptor_address_q <= gdtr_base +
                                                            {8'd0, task_loaded_ldtr[15:3], 3'b000};
                        state_q <= ST_LDTR_DESC0;
                    end
                end
            end else if (state_q == ST_LDTR_DESC0 && memory_done) begin
                incoming_ldtr_word0_q <= memory_read_data;
                state_q <= ST_LDTR_DESC1;
            end else if (state_q == ST_LDTR_DESC1 && memory_done) begin
                incoming_ldtr_word1_q <= memory_read_data;
                state_q <= ST_LDTR_DESC2;
            end else if (state_q == ST_LDTR_DESC2 && memory_done) begin
                incoming_ldtr_word2_q <= memory_read_data;
                state_q <= ST_LDTR_DESC3;
            end else if (state_q == ST_LDTR_DESC3 && memory_done) begin
                if (!incoming_ldtr_valid || !incoming_ldtr_reserved_valid ||
                    incoming_ldtr_class != spk286_protected_pkg::DESC_LDT) begin
                    fault_vector_q <= 8'd10;
                    fault_error_code_q <= incoming_ldtr_selector_q;
                    state_q <= ST_FAULT;
                end else if (!incoming_ldtr_present) begin
                    fault_vector_q <= 8'd10;
                    fault_error_code_q <= incoming_ldtr_selector_q;
                    state_q <= ST_FAULT;
                end else begin
                    incoming_ldtr_limit_q <= incoming_ldtr_limit;
                    incoming_ldtr_base_q <= incoming_ldtr_base;
                    incoming_ldtr_access_q <= incoming_ldtr_access;
                    incoming_ldtr_class_q <= incoming_ldtr_class;
                    incoming_ldtr_valid_q <= 1'b1;
                    incoming_ldtr_present_q <= 1'b1;
                    state_q <= ST_SEG_START;
                end
            end else if (state_q == ST_SEG_START) begin
                state_q <= ST_SEG_ACTIVE;
            end else if (state_q == ST_SEG_ACTIVE) begin
                if (segment_fault) begin
                    fault_vector_q <= segment_fault_vector;
                    fault_error_code_q <= segment_fault_error_code;
                    state_q <= ST_FAULT;
                end else if (segment_complete) begin
                    if (incoming_ip_limit_fault) begin
                        fault_vector_q <= 8'd13;
                        fault_error_code_q <= 16'h0000;
                        state_q <= ST_FAULT;
                    end else state_q <= ST_COMPLETE;
                end
            end
        end
    end
endmodule
