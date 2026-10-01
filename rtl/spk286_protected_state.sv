// PM0 architectural state foundation.
//
// This block is the single architectural protected-state commit owner.
// Descriptor and segment services are still added incrementally by phase.
`timescale 1ns/1ps

module spk286_protected_state (
    input  logic        clk,
    input  logic        reset,

    input  logic        msw_load_en,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [15:0] msw_load_data,
    input  logic [15:0] msw_load_mask,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [15:0] msw,

    input  logic        gdtr_load_en,
    input  logic [15:0] gdtr_load_limit,
    input  logic [23:0] gdtr_load_base,
    output logic [15:0] gdtr_limit,
    output logic [23:0] gdtr_base,
    input  logic        idtr_load_en,
    input  logic [15:0] idtr_load_limit,
    input  logic [23:0] idtr_load_base,
    output logic [15:0] idtr_limit,
    output logic [23:0] idtr_base,

    input  logic        ldtr_commit_en,
    input  logic        ldtr_commit_valid,
    input  logic [15:0] ldtr_commit_selector,
    input  logic [23:0] ldtr_commit_base,
    input  logic [15:0] ldtr_commit_limit,
    input  logic [7:0]  ldtr_commit_access,
    input  logic [3:0]  ldtr_commit_class,
    input  logic        ldtr_commit_present,
    output logic [15:0] ldtr_selector,
    output logic [23:0] ldtr_base,
    output logic [15:0] ldtr_limit,
    output logic [7:0]  ldtr_access,
    output logic [3:0]  ldtr_class,
    output logic        ldtr_valid,
    output logic        ldtr_present,

    input  logic        tr_commit_en,
    input  logic        tr_commit_valid,
    input  logic [15:0] tr_commit_selector,
    input  logic [23:0] tr_commit_base,
    input  logic [15:0] tr_commit_limit,
    input  logic [7:0]  tr_commit_access,
    input  logic [3:0]  tr_commit_class,
    input  logic        tr_commit_present,
    output logic [15:0] tr_selector,
    output logic [23:0] tr_base,
    output logic [15:0] tr_limit,
    output logic [7:0]  tr_access,
    output logic [3:0]  tr_class,
    output logic        tr_valid,
    output logic        tr_present,

    input  logic        segment_commit_en,
    input  logic        segment_commit_valid,
    input  logic [1:0]  segment_commit_index,
    input  logic [15:0] segment_commit_selector,
    input  logic [23:0] segment_commit_base,
    input  logic [15:0] segment_commit_limit,
    input  logic [7:0]  segment_commit_access,
    input  logic [3:0]  segment_commit_class,
    input  logic        segment_commit_present,
    input  logic        segment_commit_protected,
    input  logic [1:0]  segment_commit_dpl,
    input  logic        segment_commit_table_indicator,
    input  logic [1:0]  segment_commit_rpl,
    input  logic        segment_commit_en2,
    input  logic        segment_commit_valid2,
    input  logic [1:0]  segment_commit_index2,
    input  logic [15:0] segment_commit_selector2,
    input  logic [23:0] segment_commit_base2,
    input  logic [15:0] segment_commit_limit2,
    input  logic [7:0]  segment_commit_access2,
    input  logic [3:0]  segment_commit_class2,
    input  logic        segment_commit_present2,
    input  logic        segment_commit_protected2,
    input  logic [1:0]  segment_commit_dpl2,
    input  logic        segment_commit_table_indicator2,
    input  logic [1:0]  segment_commit_rpl2,
    input  logic        outer_return_commit,
    input  logic        task_load_en,
    input  logic [63:0] task_load_segments,
    input  logic [1:0]  outer_return_cpl,
    input  logic        loadall_commit_en,
    input  logic [15:0] loadall_msw,
    input  logic [15:0] loadall_gdtr_limit, loadall_idtr_limit,
    input  logic [23:0] loadall_gdtr_base, loadall_idtr_base,
    input  logic [15:0] loadall_ldtr_selector, loadall_tr_selector,
    input  logic [23:0] loadall_ldtr_base, loadall_tr_base,
    input  logic [15:0] loadall_ldtr_limit, loadall_tr_limit,
    input  logic [7:0]  loadall_ldtr_access, loadall_tr_access,
    input  logic [3:0]  loadall_ldtr_class, loadall_tr_class,
    input  logic        loadall_ldtr_valid, loadall_ldtr_present,
    input  logic        loadall_tr_valid, loadall_tr_present,
    input  logic [63:0] loadall_segment_selectors, loadall_segment_limits,
    input  logic [95:0] loadall_segment_bases,
    input  logic [31:0] loadall_segment_access,
    input  logic [15:0] loadall_segment_classes,
    input  logic [3:0]  loadall_segment_valid, loadall_segment_present,
    input  logic [3:0]  loadall_segment_protected, loadall_segment_tables,
    input  logic [7:0]  loadall_segment_dpl, loadall_segment_rpl,
    output logic [63:0] segment_selector_state,
    output logic [95:0] segment_base_state,
    output logic [63:0] segment_limit_state,
    output logic [31:0] segment_access_state,
    output logic [15:0] segment_class_state,
    output logic [3:0]  segment_valid_state,
    output logic [3:0]  segment_present_state,
    output logic [3:0]  segment_protected_state,
    output logic [7:0]  segment_dpl_state,
    output logic [3:0]  segment_table_state,
    output logic [7:0]  segment_rpl_state
);
    localparam logic [3:0] DESC_INVALID = 4'd0;
    localparam logic [7:0] REAL_MODE_ACCESS = 8'h93;
    localparam logic [15:0] MSW_RESET_VALUE = 16'hFFF0;

    logic [15:0] msw_q;
    logic [15:0] gdtr_limit_q, idtr_limit_q;
    logic [23:0] gdtr_base_q, idtr_base_q;
    logic [15:0] ldtr_selector_q, tr_selector_q;
    logic [23:0] ldtr_base_q, tr_base_q;
    logic [15:0] ldtr_limit_q, tr_limit_q;
    logic [7:0] ldtr_access_q, tr_access_q;
    logic [3:0] ldtr_class_q, tr_class_q;
    logic ldtr_valid_q, ldtr_present_q, tr_valid_q, tr_present_q;

    logic [63:0] segment_selector_q, segment_limit_q;
    logic [95:0] segment_base_q;
    logic [31:0] segment_access_q;
    logic [15:0] segment_class_q;
    logic [3:0] segment_valid_q, segment_present_q, segment_protected_q;
    logic [7:0] segment_dpl_q, segment_rpl_q;
    logic [3:0] segment_table_q;
    logic [3:0] outer_return_clear;

    // The new privilege level is effective at the same edge as CS/SS commit.
    // Inspect the cached DS/ES attributes; do not replace the descriptor cache
    // with a later memory image just because the GDT/LDT entry was edited.
    always_comb begin
        outer_return_clear = 4'b0000;
        for (integer i = 0; i < 4; i = i + 1) begin : check_outer_data
            logic [15:0] selector;
            logic [4:1] access;
            logic [1:0] dpl;
            logic table_ok, type_ok, privilege_ok;
            selector = segment_selector_q[i * 16 +: 16];
            access = segment_access_q[i * 8 + 1 +: 4];
            dpl = segment_dpl_q[i * 2 +: 2];
            table_ok = selector[2] ?
                (ldtr_valid_q && ldtr_present_q &&
                 ({1'b0, selector[15:3], 3'b000} + 17'd7 <= {1'b0, ldtr_limit_q})) :
                ({1'b0, selector[15:3], 3'b000} + 17'd7 <= {1'b0, gdtr_limit_q});
            type_ok = access[4] && (!access[3] || access[1]);
            privilege_ok = (access[3] && access[2]) ||
                           (dpl >= outer_return_cpl && dpl >= selector[1:0]);
            if (i == 0 || i == 3)
                outer_return_clear[i] = selector[15:2] != 14'd0 &&
                                        (!segment_valid_q[i] || !segment_present_q[i] ||
                                         !table_ok || !type_ok || !privilege_ok);
        end
    end

    assign msw = msw_q;
    assign gdtr_limit = gdtr_limit_q;
    assign gdtr_base = gdtr_base_q;
    assign idtr_limit = idtr_limit_q;
    assign idtr_base = idtr_base_q;
    assign ldtr_selector = ldtr_selector_q;
    assign ldtr_base = ldtr_base_q;
    assign ldtr_limit = ldtr_limit_q;
    assign ldtr_access = ldtr_access_q;
    assign ldtr_class = ldtr_class_q;
    assign ldtr_valid = ldtr_valid_q;
    assign ldtr_present = ldtr_present_q;
    assign tr_selector = tr_selector_q;
    assign tr_base = tr_base_q;
    assign tr_limit = tr_limit_q;
    assign tr_access = tr_access_q;
    assign tr_class = tr_class_q;
    assign tr_valid = tr_valid_q;
    assign tr_present = tr_present_q;
    assign segment_selector_state = segment_selector_q;
    assign segment_base_state = segment_base_q;
    assign segment_limit_state = segment_limit_q;
    assign segment_access_state = segment_access_q;
    assign segment_class_state = segment_class_q;
    assign segment_valid_state = segment_valid_q;
    assign segment_present_state = segment_present_q;
    assign segment_protected_state = segment_protected_q;
    assign segment_dpl_state = segment_dpl_q;
    assign segment_table_state = segment_table_q;
    assign segment_rpl_state = segment_rpl_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            msw_q <= MSW_RESET_VALUE;
            gdtr_limit_q <= 16'h0000;
            gdtr_base_q <= 24'h000000;
            idtr_limit_q <= 16'h03FF;
            idtr_base_q <= 24'h000000;

            ldtr_selector_q <= 16'h0000;
            ldtr_base_q <= 24'h000000;
            ldtr_limit_q <= 16'h0000;
            ldtr_access_q <= 8'h00;
            ldtr_class_q <= DESC_INVALID;
            ldtr_valid_q <= 1'b0;
            ldtr_present_q <= 1'b0;
            tr_selector_q <= 16'h0000;
            tr_base_q <= 24'h000000;
            tr_limit_q <= 16'h0000;
            tr_access_q <= 8'h00;
            tr_class_q <= DESC_INVALID;
            tr_valid_q <= 1'b0;
            tr_present_q <= 1'b0;

            // Low slices are ES, CS, SS, DS, matching spk286_segments.
            segment_selector_q <= {16'h0000, 16'h0000, 16'hF000, 16'h0000};
            segment_base_q <= {24'h000000, 24'h000000, 24'hFF0000, 24'h000000};
            segment_limit_q <= {4{16'hFFFF}};
            segment_access_q <= {4{REAL_MODE_ACCESS}};
            segment_class_q <= 16'h0000;
            segment_valid_q <= 4'b1111;
            segment_present_q <= 4'b1111;
            segment_protected_q <= 4'b0000;
            segment_dpl_q <= 8'h00;
            segment_table_q <= 4'b0000;
            segment_rpl_q <= 8'h00;
        end else if (loadall_commit_en) begin
            msw_q <= loadall_msw;
            gdtr_limit_q <= loadall_gdtr_limit;
            gdtr_base_q <= loadall_gdtr_base;
            idtr_limit_q <= loadall_idtr_limit;
            idtr_base_q <= loadall_idtr_base;

            ldtr_selector_q <= loadall_ldtr_selector;
            ldtr_base_q <= loadall_ldtr_base;
            ldtr_limit_q <= loadall_ldtr_limit;
            ldtr_access_q <= loadall_ldtr_access;
            ldtr_class_q <= loadall_ldtr_class;
            ldtr_valid_q <= loadall_ldtr_valid;
            ldtr_present_q <= loadall_ldtr_valid && loadall_ldtr_present;
            tr_selector_q <= loadall_tr_selector;
            tr_base_q <= loadall_tr_base;
            tr_limit_q <= loadall_tr_limit;
            tr_access_q <= loadall_tr_access;
            tr_class_q <= loadall_tr_class;
            tr_valid_q <= loadall_tr_valid;
            tr_present_q <= loadall_tr_valid && loadall_tr_present;

            segment_selector_q <= loadall_segment_selectors;
            segment_base_q <= loadall_segment_bases;
            segment_limit_q <= loadall_segment_limits;
            segment_access_q <= loadall_segment_access;
            segment_class_q <= loadall_segment_classes;
            segment_valid_q <= loadall_segment_valid;
            segment_present_q <= loadall_segment_present;
            segment_protected_q <= loadall_segment_protected;
            segment_dpl_q <= loadall_segment_dpl;
            segment_table_q <= loadall_segment_tables;
            segment_rpl_q <= loadall_segment_rpl;
        end else begin
            // LMSW-compatible state update: only bits 0..3 are writable and
            // PE is one-way until RESET on the 80286.
            if (msw_load_en) begin
                msw_q[3:1] <= (msw_q[3:1] & ~msw_load_mask[3:1]) |
                              (msw_load_data[3:1] & msw_load_mask[3:1]);
                if (msw_load_mask[0] && msw_load_data[0]) msw_q[0] <= 1'b1;
            end
            if (gdtr_load_en) begin
                gdtr_limit_q <= gdtr_load_limit;
                gdtr_base_q <= gdtr_load_base;
            end
            if (idtr_load_en) begin
                idtr_limit_q <= idtr_load_limit;
                idtr_base_q <= idtr_load_base;
            end
            if (ldtr_commit_en) begin
                ldtr_selector_q <= ldtr_commit_selector;
                ldtr_base_q <= ldtr_commit_base;
                ldtr_limit_q <= ldtr_commit_limit;
                ldtr_access_q <= ldtr_commit_access;
                ldtr_class_q <= ldtr_commit_class;
                ldtr_valid_q <= ldtr_commit_valid;
                ldtr_present_q <= ldtr_commit_valid && ldtr_commit_present;
            end
            if (tr_commit_en) begin
                tr_selector_q <= tr_commit_selector;
                tr_base_q <= tr_commit_base;
                tr_limit_q <= tr_commit_limit;
                tr_access_q <= tr_commit_access;
                tr_class_q <= tr_commit_class;
                tr_valid_q <= tr_commit_valid;
                tr_present_q <= tr_commit_valid && tr_commit_present;
            end
            if (segment_commit_en) begin
                segment_selector_q[segment_commit_index * 16 +: 16] <= segment_commit_selector;
                segment_base_q[segment_commit_index * 24 +: 24] <= segment_commit_base;
                segment_limit_q[segment_commit_index * 16 +: 16] <= segment_commit_limit;
                segment_access_q[segment_commit_index * 8 +: 8] <= segment_commit_access;
                segment_class_q[segment_commit_index * 4 +: 4] <= segment_commit_class;
                segment_valid_q[segment_commit_index] <= segment_commit_valid;
                segment_present_q[segment_commit_index] <= segment_commit_present;
                segment_protected_q[segment_commit_index] <= segment_commit_protected;
                segment_dpl_q[segment_commit_index * 2 +: 2] <= segment_commit_dpl;
                segment_table_q[segment_commit_index] <= segment_commit_table_indicator;
                segment_rpl_q[segment_commit_index * 2 +: 2] <= segment_commit_rpl;
            end
            if (segment_commit_en2) begin
                segment_selector_q[segment_commit_index2 * 16 +: 16] <= segment_commit_selector2;
                segment_base_q[segment_commit_index2 * 24 +: 24] <= segment_commit_base2;
                segment_limit_q[segment_commit_index2 * 16 +: 16] <= segment_commit_limit2;
                segment_access_q[segment_commit_index2 * 8 +: 8] <= segment_commit_access2;
                segment_class_q[segment_commit_index2 * 4 +: 4] <= segment_commit_class2;
                segment_valid_q[segment_commit_index2] <= segment_commit_valid2;
                segment_present_q[segment_commit_index2] <= segment_commit_present2;
                segment_protected_q[segment_commit_index2] <= segment_commit_protected2;
                segment_dpl_q[segment_commit_index2 * 2 +: 2] <= segment_commit_dpl2;
                segment_table_q[segment_commit_index2] <= segment_commit_table_indicator2;
                segment_rpl_q[segment_commit_index2 * 2 +: 2] <= segment_commit_rpl2;
            end
            if (task_load_en) begin
                // Visible selectors belong to the incoming task immediately;
                // none of their outgoing hidden caches remains usable.
                segment_selector_q <= task_load_segments;
                segment_base_q <= 0; segment_limit_q <= 0; segment_access_q <= 0;
                segment_class_q <= 0; segment_valid_q <= 0; segment_present_q <= 0;
                segment_protected_q <= 4'hF;
                for (integer i=0;i<4;i++) begin
                    segment_rpl_q[i*2 +: 2] <= task_load_segments[i*16 +: 2];
                    segment_table_q[i] <= task_load_segments[i*16+2];
                    segment_dpl_q[i*2 +: 2] <= 0;
                end
            end
            if (outer_return_commit) begin
                for (integer i = 0; i < 4; i = i + 1) begin
                    if (outer_return_clear[i]) begin
                        segment_selector_q[i * 16 +: 16] <= 16'd0;
                        segment_base_q[i * 24 +: 24] <= 24'd0;
                        segment_limit_q[i * 16 +: 16] <= 16'd0;
                        segment_access_q[i * 8 +: 8] <= 8'd0;
                        segment_class_q[i * 4 +: 4] <= DESC_INVALID;
                        segment_valid_q[i] <= 1'b0;
                        segment_present_q[i] <= 1'b0;
                        segment_protected_q[i] <= 1'b1;
                        segment_dpl_q[i * 2 +: 2] <= 2'd0;
                        segment_table_q[i] <= 1'b0;
                        segment_rpl_q[i * 2 +: 2] <= 2'd0;
                    end
                end
            end
        end
    end
endmodule
