// Transactional 80286 TSS descriptor resolver.
//
// This service owns selector/table lookup and descriptor classification for a
// task-switch target.  It never changes architectural state and never
// advances a read phase without an accepted memory response.  The task image
// movement service consumes the committed descriptor candidate separately.
`timescale 1ns/1ps

module spk286_tss_descriptor_service (
    input  logic        clk,
    input  logic        reset,
    input  logic        cancel,
    input  logic        start,
    input  logic        return_task,
    input  logic [15:0] selector,
    input  logic [1:0]  current_cpl,
    input  logic        enforce_dpl,
    input  logic [15:0] gdtr_limit,
    input  logic [23:0] gdtr_base,
    input  logic        ldtr_selector_valid,
    input  logic        ldtr_present,
    input  logic [15:0] ldtr_limit,
    input  logic [23:0] ldtr_base,
    input  logic        memory_done,
    input  logic [15:0] memory_read_data,
    output logic        memory_request,
    output logic [23:0] memory_address,
    output logic        busy,
    output logic        complete,
    output logic        fault,
    output logic [7:0]  fault_vector,
    output logic [15:0] fault_error_code,
    output logic        candidate_valid,
    output logic [15:0] candidate_selector,
    output logic [23:0] candidate_base,
    output logic [15:0] candidate_limit,
    output logic [7:0]  candidate_access,
    output logic [23:0] candidate_descriptor_address
);
    localparam logic [7:0] VECTOR_INVALID_TSS = 8'd10;
    localparam logic [7:0] VECTOR_NOT_PRESENT = 8'd11;
    localparam logic [3:0] DESC_TSS_AVAIL = 4'd4;
    localparam logic [3:0] DESC_TSS_BUSY  = 4'd5;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_CHECK,
        ST_READ,
        ST_COMPLETE,
        ST_FAULT
    } state_t;

    state_t state_q;
    logic [1:0] word_index_q;
    logic [15:0] selector_q;
    logic return_task_q, enforce_dpl_q;
    logic [23:0] descriptor_address_q;
    logic [23:0] descriptor_address_calc;
    logic [63:0] descriptor_raw_q;
    logic [63:0] descriptor_raw_candidate;
    logic [15:0] selected_limit;
    logic [23:0] selected_base;
    logic selected_ldt, selector_null, selector_carry, selector_limit_valid;
    logic selector_table_indicator;
    logic [12:0] unused_index;
    logic [1:0] unused_rpl;
    logic [20:0] unused_descriptor_end;
    logic unused_selector_valid;
    logic [15:0] parsed_limit;
    logic [23:0] parsed_base;
    logic [7:0] parsed_access;
    logic [3:0] parsed_class;
    logic parsed_valid, parsed_reserved_valid, parsed_present;
    logic parsed_segment, unused_executable, unused_conforming;
    logic unused_expand_down, unused_readable, unused_writable, unused_accessed;
    logic [1:0] parsed_dpl;
    logic [15:0] unused_gate_selector, unused_gate_offset;
    logic [4:0] unused_gate_parameter_count;

    assign selected_ldt = selector_q[2];
    assign selected_limit = selected_ldt ? ldtr_limit : gdtr_limit;
    assign selected_base = selected_ldt ? ldtr_base : gdtr_base;

    spk286_selector selector_service (
        .selector(selector_q),
        .table_limit(selected_limit),
        .table_base(selected_base),
        .index(unused_index),
        .table_indicator(selector_table_indicator),
        .rpl(unused_rpl),
        .null_selector(selector_null),
        .descriptor_end(unused_descriptor_end),
        .descriptor_limit_valid(selector_limit_valid),
        .descriptor_selector_valid(unused_selector_valid),
        .descriptor_address(descriptor_address_calc),
        .descriptor_address_carry(selector_carry)
    );

    spk286_descriptor descriptor_service (
        .raw_descriptor(descriptor_raw_candidate),
        .limit(parsed_limit),
        .base(parsed_base),
        .access_rights(parsed_access),
        .descriptor_class(parsed_class),
        .descriptor_valid(parsed_valid),
        .reserved_form_valid(parsed_reserved_valid),
        .present(parsed_present),
        .segment(parsed_segment),
        .executable(unused_executable),
        .conforming(unused_conforming),
        .expand_down(unused_expand_down),
        .readable(unused_readable),
        .writable(unused_writable),
        .accessed(unused_accessed),
        .dpl(parsed_dpl),
        .gate_target_selector(unused_gate_selector),
        .gate_offset(unused_gate_offset),
        .gate_parameter_count(unused_gate_parameter_count)
    );

    // The final word is assembled combinationally so the parser sees the
    // completed descriptor in the same cycle as the fourth response.
    always_comb begin
        descriptor_raw_candidate = descriptor_raw_q;
        case (word_index_q)
            2'd0: descriptor_raw_candidate[15:0] = memory_read_data;
            2'd1: descriptor_raw_candidate[31:16] = memory_read_data;
            2'd2: descriptor_raw_candidate[47:32] = memory_read_data;
            default: descriptor_raw_candidate[63:48] = memory_read_data;
        endcase
    end

    logic descriptor_shape_valid;
    logic descriptor_type_valid;
    logic descriptor_privilege_valid;
    logic descriptor_limit_valid;
    logic descriptor_fault_is_np;

    assign descriptor_shape_valid = parsed_valid && parsed_reserved_valid && !parsed_segment;
    assign descriptor_type_valid = return_task_q ? (parsed_class == DESC_TSS_BUSY) :
                                                    (parsed_class == DESC_TSS_AVAIL);
    assign descriptor_privilege_valid = !enforce_dpl_q ||
                                       (parsed_dpl >= current_cpl && parsed_dpl >= selector_q[1:0]);
    assign descriptor_limit_valid = parsed_limit >= 16'h002B;
    assign descriptor_fault_is_np = descriptor_shape_valid && descriptor_type_valid && !parsed_present;

    assign busy = state_q == ST_CHECK || state_q == ST_READ;
    assign complete = state_q == ST_COMPLETE;
    assign fault = state_q == ST_FAULT;
    assign candidate_valid = state_q == ST_COMPLETE;
    assign memory_request = state_q == ST_READ;
    assign memory_address = descriptor_address_q + {21'd0, word_index_q, 1'b0};
    assign candidate_selector = selector_q;
    assign candidate_base = parsed_base;
    assign candidate_limit = parsed_limit;
    assign candidate_access = parsed_access;
    assign candidate_descriptor_address = descriptor_address_q;

    always_comb begin
        fault_vector = VECTOR_INVALID_TSS;
        fault_error_code = selector_q;
        if (descriptor_fault_is_np) fault_vector = VECTOR_NOT_PRESENT;
    end

    always_ff @(posedge clk) begin
        if (reset || cancel) begin
            state_q <= ST_IDLE;
            word_index_q <= 2'd0;
            selector_q <= 16'h0000;
            return_task_q <= 1'b0;
            enforce_dpl_q <= 1'b0;
            descriptor_address_q <= 24'h000000;
            descriptor_raw_q <= 64'h0;
        end else begin
            if (state_q == ST_COMPLETE || state_q == ST_FAULT) begin
                state_q <= ST_IDLE;
            end else if (state_q == ST_IDLE && start) begin
                selector_q <= selector;
                return_task_q <= return_task;
                enforce_dpl_q <= enforce_dpl;
                word_index_q <= 2'd0;
                state_q <= ST_CHECK;
            end else if (state_q == ST_CHECK) begin
                descriptor_address_q <= descriptor_address_calc;
                if (selector_null || selector_carry || !selector_limit_valid ||
                    (selected_ldt && (!ldtr_selector_valid || !ldtr_present))) begin
                    state_q <= ST_FAULT;
                end else begin
                    state_q <= ST_READ;
                end
            end else if (state_q == ST_READ && memory_done) begin
                case (word_index_q)
                    2'd0: begin
                        descriptor_raw_q[15:0] <= memory_read_data;
                        word_index_q <= 2'd1;
                    end
                    2'd1: begin
                        descriptor_raw_q[31:16] <= memory_read_data;
                        word_index_q <= 2'd2;
                    end
                    2'd2: begin
                        descriptor_raw_q[47:32] <= memory_read_data;
                        word_index_q <= 2'd3;
                    end
                    default: begin
                        descriptor_raw_q[63:48] <= memory_read_data;
                        if (!descriptor_shape_valid || !descriptor_type_valid ||
                            !descriptor_privilege_valid || !descriptor_limit_valid) begin
                            state_q <= ST_FAULT;
                        end else begin
                            state_q <= ST_COMPLETE;
                        end
                    end
                endcase
            end
        end
    end
endmodule
