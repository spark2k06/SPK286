// Hidden-cache construction for the four 80286 task segments.
//
// The service reads the descriptors before publishing cache candidates, but
// reports faults in the architectural SS, CS, ES, DS precedence.  The caller
// invokes this after the TSS image has been loaded, so a fault is deliberately
// a late task-state fault rather than a pre-switch rollback.
`timescale 1ns/1ps

module spk286_task_segment_service (
    input  logic        clk,
    input  logic        reset,
    input  logic        cancel,
    input  logic        start,
    input  logic [63:0] task_segments,
    input  logic [15:0] gdtr_limit,
    input  logic [23:0] gdtr_base,
    input  logic        ldtr_valid,
    input  logic        ldtr_present,
    input  logic [15:0] ldtr_limit,
    input  logic [23:0] ldtr_base,
    input  logic        update_accessed,
    input  logic        memory_done,
    input  logic [15:0] memory_read_data,
    output logic        memory_request,
    output logic        memory_write,
    output logic        memory_byte,
    output logic [23:0] memory_address,
    output logic [15:0] memory_write_data,
    output logic        busy,
    output logic        complete,
    output logic        fault,
    output logic [7:0]  fault_vector,
    output logic [15:0] fault_error_code,
    output logic        commit_valid,
    output logic [63:0] cache_selectors,
    output logic [95:0] cache_bases,
    output logic [63:0] cache_limits,
    output logic [31:0] cache_access,
    output logic [15:0] cache_classes,
    output logic [3:0]  cache_present,
    output logic [3:0]  cache_protected,
    output logic [7:0]  cache_dpl,
    output logic [3:0]  cache_tables,
    output logic [7:0]  cache_rpl
);
    localparam logic [7:0] VECTOR_INVALID_TSS = 8'd10;
    localparam logic [7:0] VECTOR_NOT_PRESENT = 8'd11;
    localparam logic [7:0] VECTOR_STACK_FAULT = 8'd12;
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_CHECK,
        ST_READ,
        ST_VALIDATE,
        ST_WRITE,
        ST_COMPLETE,
        ST_FAULT
    } state_t;

    state_t state_q;
    logic [1:0] segment_index_q, word_index_q, write_index_q;
    logic [63:0] task_segments_q;
    logic [63:0] descriptor_raw_q [0:3];
    logic [23:0] descriptor_address_q [0:3];
    logic [63:0] cache_selectors_q;
    logic [95:0] cache_bases_q;
    logic [63:0] cache_limits_q;
    logic [31:0] cache_access_q;
    logic [15:0] cache_classes_q;
    logic [3:0] cache_present_q, cache_protected_q, cache_tables_q;
    logic [7:0] cache_dpl_q, cache_rpl_q;
    logic [1:0] target_cpl_q;
    logic [3:0] precheck_fault_q;
    logic [3:0] segment_required, segment_invalid, segment_missing;
    logic selected_fault_valid;
    logic [1:0] selected_fault_index;
    logic [7:0] selected_fault_vector;

    logic [15:0] selected_selector;
    logic selected_ldt, selector_table_indicator, selector_null, selector_carry, selector_limit_valid;
    logic [15:0] selected_table_limit;
    logic [23:0] selected_table_base;
    logic [12:0] unused_selector_index;
    logic [1:0] unused_selector_rpl;
    logic [20:0] unused_descriptor_end;
    logic unused_selector_valid;
    logic [23:0] descriptor_address_calc;
    logic write_needed;
    logic target_cpl_valid;
    logic descriptor_accessed [0:3];
    logic descriptor_present [0:3];
    logic descriptor_valid [0:3];
    logic descriptor_reserved_valid [0:3];
    logic descriptor_segment [0:3];
    logic descriptor_executable [0:3];
    logic descriptor_conforming [0:3];
    logic descriptor_readable [0:3];
    logic descriptor_writable [0:3];
    logic [15:0] descriptor_limit [0:3];
    logic [23:0] descriptor_base [0:3];
    logic [7:0] descriptor_access [0:3];
    logic [3:0] descriptor_class [0:3];
    logic [1:0] descriptor_dpl [0:3];

    assign selected_selector = task_segments_q[segment_index_q * 16 +: 16];
    assign selected_ldt = selected_selector[2];
    assign selected_table_limit = selected_ldt ? ldtr_limit : gdtr_limit;
    assign selected_table_base = selected_ldt ? ldtr_base : gdtr_base;

    spk286_selector selector_service (
        .selector(selected_selector), .table_limit(selected_table_limit),
        .table_base(selected_table_base), .index(unused_selector_index),
        .table_indicator(selector_table_indicator), .rpl(unused_selector_rpl),
        .null_selector(selector_null), .descriptor_end(unused_descriptor_end),
        .descriptor_limit_valid(selector_limit_valid),
        .descriptor_selector_valid(unused_selector_valid),
        .descriptor_address(descriptor_address_calc),
        .descriptor_address_carry(selector_carry)
    );

    genvar g;
    generate
        /* The parser exports this classification for the general descriptor
           contract; this service consumes the equivalent access/type fields. */
        /* verilator lint_off PINCONNECTEMPTY */
        for (g = 0; g < 4; g = g + 1) begin : descriptor_parsers
            logic [15:0] unused_gate_selector, unused_gate_offset;
            logic [4:0] unused_gate_parameter_count;
            spk286_descriptor parser (
                .raw_descriptor(descriptor_raw_q[g]),
                .limit(descriptor_limit[g]), .base(descriptor_base[g]),
                .access_rights(descriptor_access[g]), .descriptor_class(descriptor_class[g]),
                .descriptor_valid(descriptor_valid[g]),
                .reserved_form_valid(descriptor_reserved_valid[g]),
                .present(descriptor_present[g]), .segment(descriptor_segment[g]),
                .executable(descriptor_executable[g]), .conforming(descriptor_conforming[g]),
                .expand_down(), .readable(descriptor_readable[g]),
                .writable(descriptor_writable[g]), .accessed(descriptor_accessed[g]),
                .dpl(descriptor_dpl[g]), .gate_target_selector(unused_gate_selector),
                .gate_offset(unused_gate_offset), .gate_parameter_count(unused_gate_parameter_count)
            );
        end
        /* verilator lint_on PINCONNECTEMPTY */
    endgenerate

    // ES/DS may contain a null selector.  CS and SS are mandatory and are
    // checked against the task's new CPL, which is the CS selector RPL.
    logic segment_type_valid [0:3];
    logic segment_privilege_valid [0:3];
    logic segment_present_valid [0:3];
    always_comb begin
        target_cpl_valid = descriptor_valid[1] && descriptor_reserved_valid[1] &&
                           descriptor_segment[1] &&
                           descriptor_executable[1] &&
                           ((descriptor_conforming[1] && descriptor_dpl[1] <= task_segments_q[17:16]) ||
                            (!descriptor_conforming[1] && descriptor_dpl[1] == task_segments_q[17:16]));
        target_cpl_q = task_segments_q[17:16];

        for (integer i = 0; i < 4; i = i + 1) begin
            segment_type_valid[i] = 1'b0;
            segment_privilege_valid[i] = 1'b0;
            segment_present_valid[i] = descriptor_present[i];
        end
        segment_type_valid[1] = descriptor_segment[1] && descriptor_executable[1];
        segment_privilege_valid[1] = target_cpl_valid;
        segment_type_valid[2] = descriptor_segment[2] && !descriptor_executable[2] && descriptor_writable[2];
        segment_privilege_valid[2] = descriptor_dpl[2] == target_cpl_q && task_segments_q[33:32] == target_cpl_q;
        for (integer j = 0; j < 4; j = j + 1) begin
            if (j != 1 && j != 2) begin
                segment_type_valid[j] = descriptor_segment[j] &&
                                         ((!descriptor_executable[j]) || descriptor_readable[j]);
                // A readable conforming code segment can be task-loaded into
                // ES/DS regardless of the incoming CPL or selector RPL.
                segment_privilege_valid[j] = descriptor_conforming[j] ||
                    (descriptor_dpl[j] >= target_cpl_q && descriptor_dpl[j] >= task_segments_q[j * 16 +: 2]);
            end
        end
    end

    always_comb begin
        segment_required = 4'b1111;
        segment_required[0] = task_segments_q[15:2] != 14'd0;
        segment_required[3] = task_segments_q[63:50] != 14'd0;
        for (integer k = 0; k < 4; k = k + 1) begin
            segment_invalid[k] = precheck_fault_q[k] ||
                                 (segment_required[k] &&
                                  (!descriptor_valid[k] || !descriptor_reserved_valid[k] ||
                                   !segment_type_valid[k] || !segment_privilege_valid[k]));
            segment_missing[k] = !precheck_fault_q[k] && segment_required[k] &&
                                 descriptor_valid[k] && descriptor_reserved_valid[k] &&
                                 !segment_present_valid[k];
        end

        // Intel validates SS, then CS, then ES/DS.  Do not let the physical
        // descriptor read order (ES, CS, SS, DS) change the reported fault.
        selected_fault_valid = 1'b0;
        selected_fault_index = 2'd0;
        selected_fault_vector = VECTOR_INVALID_TSS;
        if (segment_invalid[2]) begin
            selected_fault_valid = 1'b1; selected_fault_index = 2'd2; selected_fault_vector = VECTOR_INVALID_TSS;
        end else if (segment_missing[2]) begin
            selected_fault_valid = 1'b1; selected_fault_index = 2'd2; selected_fault_vector = VECTOR_STACK_FAULT;
        end else if (segment_invalid[1]) begin
            selected_fault_valid = 1'b1; selected_fault_index = 2'd1; selected_fault_vector = VECTOR_INVALID_TSS;
        end else if (segment_missing[1]) begin
            selected_fault_valid = 1'b1; selected_fault_index = 2'd1; selected_fault_vector = VECTOR_NOT_PRESENT;
        end else if (segment_invalid[0]) begin
            selected_fault_valid = 1'b1; selected_fault_index = 2'd0; selected_fault_vector = VECTOR_INVALID_TSS;
        end else if (segment_missing[0]) begin
            selected_fault_valid = 1'b1; selected_fault_index = 2'd0; selected_fault_vector = VECTOR_NOT_PRESENT;
        end else if (segment_invalid[3]) begin
            selected_fault_valid = 1'b1; selected_fault_index = 2'd3; selected_fault_vector = VECTOR_INVALID_TSS;
        end else if (segment_missing[3]) begin
            selected_fault_valid = 1'b1; selected_fault_index = 2'd3; selected_fault_vector = VECTOR_NOT_PRESENT;
        end
    end

    always_comb begin
        write_needed = 1'b0;
        if (update_accessed && write_index_q == 2'd0 && segment_required[0]) write_needed = !descriptor_accessed[0];
        if (update_accessed && write_index_q == 2'd1) write_needed = !descriptor_accessed[1];
        if (update_accessed && write_index_q == 2'd2) write_needed = !descriptor_accessed[2];
        if (update_accessed && write_index_q == 2'd3 && segment_required[3]) write_needed = !descriptor_accessed[3];
    end

    assign busy = state_q == ST_CHECK || state_q == ST_READ || state_q == ST_VALIDATE || state_q == ST_WRITE;
    assign complete = state_q == ST_COMPLETE;
    assign fault = state_q == ST_FAULT;
    assign commit_valid = state_q == ST_COMPLETE;
    assign memory_request = (state_q == ST_READ) || (state_q == ST_WRITE && write_needed);
    assign memory_write = state_q == ST_WRITE;
    assign memory_byte = state_q == ST_WRITE;
    assign memory_address = (state_q == ST_READ) ?
                            (descriptor_address_q[segment_index_q] + {21'd0, word_index_q, 1'b0}) :
                            (descriptor_address_q[write_index_q] + 24'd5);
    assign memory_write_data = {8'h00, descriptor_access[write_index_q] | 8'h01};
    assign cache_selectors = cache_selectors_q;
    assign cache_bases = cache_bases_q;
    assign cache_limits = cache_limits_q;
    assign cache_access = cache_access_q;
    assign cache_classes = cache_classes_q;
    assign cache_present = cache_present_q;
    assign cache_protected = cache_protected_q;
    assign cache_dpl = cache_dpl_q;
    assign cache_tables = cache_tables_q;
    assign cache_rpl = cache_rpl_q;

    always_comb begin
        fault_vector = selected_fault_vector;
        fault_error_code = task_segments_q[selected_fault_index * 16 +: 16];
    end

    always_ff @(posedge clk) begin
        if (reset || cancel) begin
            state_q <= ST_IDLE;
            segment_index_q <= 2'd0; word_index_q <= 2'd0; write_index_q <= 2'd0;
            task_segments_q <= 64'h0;
            cache_selectors_q <= 64'h0; cache_bases_q <= 96'h0; cache_limits_q <= 64'h0;
            cache_access_q <= 32'h0; cache_classes_q <= 16'h0;
            cache_present_q <= 4'h0; cache_protected_q <= 4'h0; cache_dpl_q <= 8'h0;
            cache_tables_q <= 4'h0; cache_rpl_q <= 8'h0;
            precheck_fault_q <= 4'h0;
            for (integer i = 0; i < 4; i = i + 1) begin
                descriptor_raw_q[i] <= 64'h0;
                descriptor_address_q[i] <= 24'h0;
            end
        end else begin
            if (state_q == ST_COMPLETE || state_q == ST_FAULT) begin
                state_q <= ST_IDLE;
            end else if (state_q == ST_IDLE && start) begin
                task_segments_q <= task_segments;
                segment_index_q <= 2'd0;
                word_index_q <= 2'd0;
                precheck_fault_q <= 4'h0;
                state_q <= ST_CHECK;
            end else if (state_q == ST_CHECK) begin
                if ((segment_index_q == 2'd0 || segment_index_q == 2'd3) && selector_null) begin
                    cache_selectors_q[segment_index_q * 16 +: 16] <= 16'h0;
                    cache_bases_q[segment_index_q * 24 +: 24] <= 24'h0;
                    cache_limits_q[segment_index_q * 16 +: 16] <= 16'h0;
                    cache_access_q[segment_index_q * 8 +: 8] <= 8'h0;
                    cache_classes_q[segment_index_q * 4 +: 4] <= 4'h0;
                    cache_present_q[segment_index_q] <= 1'b0;
                    cache_protected_q[segment_index_q] <= 1'b1;
                    cache_dpl_q[segment_index_q * 2 +: 2] <= 2'd0;
                    cache_tables_q[segment_index_q] <= selector_table_indicator;
                    cache_rpl_q[segment_index_q * 2 +: 2] <= selected_selector[1:0];
                    if (segment_index_q == 2'd3) state_q <= ST_VALIDATE;
                    else begin segment_index_q <= segment_index_q + 2'd1; word_index_q <= 2'd0; end
                end else if (selector_null || selector_carry || !selector_limit_valid ||
                             (selected_ldt && (!ldtr_valid || !ldtr_present))) begin
                    precheck_fault_q[segment_index_q] <= 1'b1;
                    if (segment_index_q == 2'd3) begin
                        segment_index_q <= 2'd0;
                        state_q <= ST_VALIDATE;
                    end else begin
                        segment_index_q <= segment_index_q + 2'd1;
                        word_index_q <= 2'd0;
                    end
                end else begin
                    descriptor_address_q[segment_index_q] <= descriptor_address_calc;
                    word_index_q <= 2'd0;
                    state_q <= ST_READ;
                end
            end else if (state_q == ST_READ && memory_done) begin
                case (word_index_q)
                    2'd0: begin descriptor_raw_q[segment_index_q][15:0] <= memory_read_data; word_index_q <= 2'd1; end
                    2'd1: begin descriptor_raw_q[segment_index_q][31:16] <= memory_read_data; word_index_q <= 2'd2; end
                    2'd2: begin descriptor_raw_q[segment_index_q][47:32] <= memory_read_data; word_index_q <= 2'd3; end
                    default: begin
                        descriptor_raw_q[segment_index_q][63:48] <= memory_read_data;
                        if (segment_index_q == 2'd3) begin
                            segment_index_q <= 2'd0;
                            state_q <= ST_VALIDATE;
                        end else begin
                            segment_index_q <= segment_index_q + 2'd1;
                            word_index_q <= 2'd0;
                            state_q <= ST_CHECK;
                        end
                    end
                endcase
            end else if (state_q == ST_VALIDATE) begin
                if (selected_fault_valid) begin
                    state_q <= ST_FAULT;
                end else begin
                    for (integer j = 0; j < 4; j = j + 1) begin
                        if (segment_required[j]) begin
                            cache_selectors_q[j * 16 +: 16] <= task_segments_q[j * 16 +: 16];
                            cache_bases_q[j * 24 +: 24] <= descriptor_base[j];
                            cache_limits_q[j * 16 +: 16] <= descriptor_limit[j];
                            cache_access_q[j * 8 +: 8] <= descriptor_access[j] | 8'h01;
                            cache_classes_q[j * 4 +: 4] <= descriptor_class[j];
                            cache_present_q[j] <= descriptor_present[j];
                            cache_protected_q[j] <= 1'b1;
                            cache_dpl_q[j * 2 +: 2] <= descriptor_dpl[j];
                            cache_tables_q[j] <= task_segments_q[j * 16 + 2];
                            cache_rpl_q[j * 2 +: 2] <= task_segments_q[j * 16 +: 2];
                        end
                    end
                    write_index_q <= 2'd0;
                    state_q <= ST_WRITE;
                end
            end else if (state_q == ST_WRITE) begin
                if (!write_needed || memory_done) begin
                    if (write_index_q == 2'd3) state_q <= ST_COMPLETE;
                    else write_index_q <= write_index_q + 2'd1;
                end
            end
        end
    end
endmodule
