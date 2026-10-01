`timescale 1ns/1ps

module spk286_protected_foundation_tb;
    import spk286_protected_pkg::*;

    logic [15:0] selector, table_limit;
    logic [23:0] table_base;
    wire [12:0] selector_index;
    wire selector_ti;
    wire [1:0] selector_rpl;
    wire selector_null, selector_limit_valid, selector_valid, selector_carry;
    wire [20:0] selector_end;
    wire [23:0] selector_address;

    spk286_selector selector_dut (
        .selector(selector), .table_limit(table_limit), .table_base(table_base),
        .index(selector_index), .table_indicator(selector_ti), .rpl(selector_rpl),
        .null_selector(selector_null), .descriptor_end(selector_end),
        .descriptor_limit_valid(selector_limit_valid),
        .descriptor_selector_valid(selector_valid),
        .descriptor_address(selector_address),
        .descriptor_address_carry(selector_carry)
    );

    logic [63:0] raw_descriptor;
    wire [15:0] descriptor_limit, gate_selector, gate_offset;
    wire [23:0] descriptor_base;
    wire [7:0] descriptor_access;
    wire [3:0] descriptor_class;
    wire descriptor_valid, reserved_valid, descriptor_present, descriptor_segment;
    wire descriptor_executable, descriptor_conforming, descriptor_expand_down;
    wire descriptor_readable, descriptor_writable, descriptor_accessed;
    wire [1:0] descriptor_dpl;
    wire [4:0] gate_parameter_count;

    spk286_descriptor descriptor_dut (
        .raw_descriptor(raw_descriptor), .limit(descriptor_limit), .base(descriptor_base),
        .access_rights(descriptor_access), .descriptor_class(descriptor_class),
        .descriptor_valid(descriptor_valid), .reserved_form_valid(reserved_valid),
        .present(descriptor_present), .segment(descriptor_segment),
        .executable(descriptor_executable), .conforming(descriptor_conforming),
        .expand_down(descriptor_expand_down), .readable(descriptor_readable),
        .writable(descriptor_writable), .accessed(descriptor_accessed), .dpl(descriptor_dpl),
        .gate_target_selector(gate_selector), .gate_offset(gate_offset),
        .gate_parameter_count(gate_parameter_count)
    );

    logic clk = 1'b0, reset = 1'b1;
    logic msw_load_en = 1'b0;
    logic [15:0] msw_load_data = 16'h0000, msw_load_mask = 16'h0000;
    wire [15:0] msw;
    logic gdtr_load_en = 1'b0;
    logic [15:0] gdtr_load_limit = 16'h0000;
    logic [23:0] gdtr_load_base = 24'h000000;
    wire [15:0] gdtr_limit;
    wire [23:0] gdtr_base;
    logic idtr_load_en = 1'b0;
    logic [15:0] idtr_load_limit = 16'h0000;
    logic [23:0] idtr_load_base = 24'h000000;
    wire [15:0] idtr_limit;
    wire [23:0] idtr_base;

    logic ldtr_commit_en = 1'b0;
    logic [15:0] ldtr_commit_selector = 16'h0000;
    logic [23:0] ldtr_commit_base = 24'h000000;
    logic [15:0] ldtr_commit_limit = 16'h0000;
    logic [7:0] ldtr_commit_access = 8'h00;
    logic [3:0] ldtr_commit_class = DESC_INVALID;
    logic ldtr_commit_present = 1'b0;
    wire [15:0] ldtr_selector;
    wire [23:0] ldtr_base;
    wire [15:0] ldtr_limit;
    wire [7:0] ldtr_access;
    wire [3:0] ldtr_class;
    wire ldtr_valid, ldtr_present;

    logic tr_commit_en = 1'b0;
    logic [15:0] tr_commit_selector = 16'h0000;
    logic [23:0] tr_commit_base = 24'h000000;
    logic [15:0] tr_commit_limit = 16'h0000;
    logic [7:0] tr_commit_access = 8'h00;
    logic [3:0] tr_commit_class = DESC_INVALID;
    logic tr_commit_present = 1'b0;
    wire [15:0] tr_selector;
    wire [23:0] tr_base;
    wire [15:0] tr_limit;
    wire [7:0] tr_access;
    wire [3:0] tr_class;
    wire tr_valid, tr_present;

    logic segment_commit_en = 1'b0;
    logic [1:0] segment_commit_index = 2'd0;
    logic [15:0] segment_commit_selector = 16'h0000;
    logic [23:0] segment_commit_base = 24'h000000;
    logic [15:0] segment_commit_limit = 16'h0000;
    logic [7:0] segment_commit_access = 8'h00;
    logic [3:0] segment_commit_class = DESC_INVALID;
    logic segment_commit_present = 1'b0, segment_commit_protected = 1'b0;
    logic [1:0] segment_commit_dpl = 2'd0;
    logic segment_commit_table_indicator = 1'b0;
    logic [1:0] segment_commit_rpl = 2'd0;
    logic segment_commit_en2 = 1'b0;
    logic [1:0] segment_commit_index2 = 2'd0;
    logic [15:0] segment_commit_selector2 = 16'h0000;
    logic [23:0] segment_commit_base2 = 24'h000000;
    logic [15:0] segment_commit_limit2 = 16'h0000;
    logic [7:0] segment_commit_access2 = 8'h00;
    logic [3:0] segment_commit_class2 = DESC_INVALID;
    logic segment_commit_present2 = 1'b0, segment_commit_protected2 = 1'b0;
    logic [1:0] segment_commit_dpl2 = 2'd0;
    logic segment_commit_table_indicator2 = 1'b0;
    logic [1:0] segment_commit_rpl2 = 2'd0;
    logic loadall_commit_en = 1'b0;
    logic [15:0] loadall_msw = 16'h0, loadall_gdtr_limit = 16'h0, loadall_idtr_limit = 16'h0;
    logic [23:0] loadall_gdtr_base = 24'h0, loadall_idtr_base = 24'h0;
    logic [15:0] loadall_ldtr_selector = 16'h0, loadall_tr_selector = 16'h0;
    logic [23:0] loadall_ldtr_base = 24'h0, loadall_tr_base = 24'h0;
    logic [15:0] loadall_ldtr_limit = 16'h0, loadall_tr_limit = 16'h0;
    logic [7:0] loadall_ldtr_access = 8'h0, loadall_tr_access = 8'h0;
    logic [3:0] loadall_ldtr_class = DESC_INVALID, loadall_tr_class = DESC_INVALID;
    logic loadall_ldtr_valid = 1'b0, loadall_ldtr_present = 1'b0;
    logic loadall_tr_valid = 1'b0, loadall_tr_present = 1'b0;
    logic [63:0] loadall_segment_selectors = 64'h0, loadall_segment_limits = 64'h0;
    logic [95:0] loadall_segment_bases = 96'h0;
    logic [31:0] loadall_segment_access = 32'h0;
    logic [15:0] loadall_segment_classes = 16'h0;
    logic [3:0] loadall_segment_valid = 4'h0, loadall_segment_present = 4'h0;
    logic [3:0] loadall_segment_protected = 4'h0, loadall_segment_tables = 4'h0;
    logic [7:0] loadall_segment_dpl = 8'h0, loadall_segment_rpl = 8'h0;
    wire [63:0] segment_selector_state;
    wire [95:0] segment_base_state;
    wire [63:0] segment_limit_state;
    wire [31:0] segment_access_state;
    wire [15:0] segment_class_state;
    wire [3:0] segment_valid_state, segment_present_state, segment_protected_state;
    wire [7:0] segment_dpl_state, segment_rpl_state;
    wire [3:0] segment_table_state;

    spk286_protected_state state_dut (
        .clk(clk), .reset(reset), .msw_load_en(msw_load_en),
        .msw_load_data(msw_load_data), .msw_load_mask(msw_load_mask), .msw(msw),
        .gdtr_load_en(gdtr_load_en), .gdtr_load_limit(gdtr_load_limit),
        .gdtr_load_base(gdtr_load_base), .gdtr_limit(gdtr_limit), .gdtr_base(gdtr_base),
        .idtr_load_en(idtr_load_en), .idtr_load_limit(idtr_load_limit),
        .idtr_load_base(idtr_load_base), .idtr_limit(idtr_limit), .idtr_base(idtr_base),
        .ldtr_commit_en(ldtr_commit_en), .ldtr_commit_valid(1'b1), .ldtr_commit_selector(ldtr_commit_selector),
        .ldtr_commit_base(ldtr_commit_base), .ldtr_commit_limit(ldtr_commit_limit),
        .ldtr_commit_access(ldtr_commit_access), .ldtr_commit_class(ldtr_commit_class),
        .ldtr_commit_present(ldtr_commit_present), .ldtr_selector(ldtr_selector),
        .ldtr_base(ldtr_base), .ldtr_limit(ldtr_limit), .ldtr_access(ldtr_access),
        .ldtr_class(ldtr_class), .ldtr_valid(ldtr_valid), .ldtr_present(ldtr_present),
        .tr_commit_en(tr_commit_en), .tr_commit_valid(1'b1), .tr_commit_selector(tr_commit_selector),
        .tr_commit_base(tr_commit_base), .tr_commit_limit(tr_commit_limit),
        .tr_commit_access(tr_commit_access), .tr_commit_class(tr_commit_class),
        .tr_commit_present(tr_commit_present), .tr_selector(tr_selector),
        .tr_base(tr_base), .tr_limit(tr_limit), .tr_access(tr_access),
        .tr_class(tr_class), .tr_valid(tr_valid), .tr_present(tr_present),
        .segment_commit_en(segment_commit_en), .segment_commit_valid(1'b1), .segment_commit_index(segment_commit_index),
        .segment_commit_selector(segment_commit_selector), .segment_commit_base(segment_commit_base),
        .segment_commit_limit(segment_commit_limit), .segment_commit_access(segment_commit_access),
        .segment_commit_class(segment_commit_class), .segment_commit_present(segment_commit_present),
        .segment_commit_protected(segment_commit_protected), .segment_commit_dpl(segment_commit_dpl),
        .segment_commit_table_indicator(segment_commit_table_indicator), .segment_commit_rpl(segment_commit_rpl),
        .segment_commit_en2(segment_commit_en2), .segment_commit_valid2(1'b1), .segment_commit_index2(segment_commit_index2),
        .segment_commit_selector2(segment_commit_selector2), .segment_commit_base2(segment_commit_base2),
        .segment_commit_limit2(segment_commit_limit2), .segment_commit_access2(segment_commit_access2),
        .segment_commit_class2(segment_commit_class2), .segment_commit_present2(segment_commit_present2),
        .segment_commit_protected2(segment_commit_protected2), .segment_commit_dpl2(segment_commit_dpl2),
        .segment_commit_table_indicator2(segment_commit_table_indicator2), .segment_commit_rpl2(segment_commit_rpl2),
        .outer_return_commit(1'b0), .outer_return_cpl(2'd0),
        .task_load_en(1'b0), .task_load_segments(64'd0),
        .loadall_commit_en(loadall_commit_en), .loadall_msw(loadall_msw),
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
        .segment_selector_state(segment_selector_state), .segment_base_state(segment_base_state),
        .segment_limit_state(segment_limit_state), .segment_access_state(segment_access_state),
        .segment_class_state(segment_class_state), .segment_valid_state(segment_valid_state),
        .segment_present_state(segment_present_state), .segment_protected_state(segment_protected_state),
        .segment_dpl_state(segment_dpl_state), .segment_table_state(segment_table_state),
        .segment_rpl_state(segment_rpl_state)
    );

    integer checks = 0;
    task automatic tick;
        #5; clk = 1'b1; #5; clk = 1'b0; #1;
    endtask
    task automatic check_expect(input logic condition, input string message);
        if (!condition) $fatal(1, "%s", message);
        checks = checks + 1;
    endtask

    initial begin
        // Selector fields and exact complete-descriptor boundaries.
        selector = 16'h0008; table_limit = 16'h000F; table_base = 24'h010000; #1;
        check_expect(selector_index == 13'd1 && !selector_ti && selector_rpl == 0 && !selector_null,
               "GDT selector decomposition");
        check_expect(selector_end == 21'd15 && selector_limit_valid && selector_valid,
               "exact one-descriptor table boundary");
        check_expect(selector_address == 24'h010008 && !selector_carry, "descriptor address");
        table_limit = 16'h000E; #1;
        check_expect(!selector_limit_valid && !selector_valid, "one-byte descriptor overflow");
        selector = 16'hFFF8; table_limit = 16'hFFFF; table_base = 24'h000000; #1;
        check_expect(selector_index == 13'h1FFF && selector_end == 21'h0FFFF && selector_limit_valid,
               "last representable descriptor");
        // Intel 80286 B-2/B-3 Information Sheet (1984-11-21), p. 4:
        // null means index AND TI are zero; RPL does not affect nullness.
        // Sweep every selector with a full table, independently of RTL slicing.
        for (integer value = 0; value < 65536; value = value + 1) begin
            selector = 16'(value); #1;
            check_expect(selector_null == (value < 4) && selector_valid == (value >= 4),
                   $sformatf("null classification for selector %04h", selector));
        end
        for (integer rpl = 0; rpl < 4; rpl = rpl + 1) begin
            selector = 16'h0004 | 16'(rpl); table_limit = 16'h0007; #1;
            check_expect(!selector_null && selector_ti && selector_index == 0 &&
                   selector_rpl == 2'(rpl) && selector_valid && selector_end == 7 &&
                   selector_address == table_base,
                   "LDT entry zero is usable at the exact eight-byte boundary");
            table_limit = 16'h0006; #1;
            check_expect(!selector_null && !selector_limit_valid && !selector_valid,
                   "LDT entry zero still requires a complete descriptor");
            selector = 16'(rpl); table_limit = 16'h0007; #1;
            check_expect(selector_null && !selector_ti && selector_limit_valid && !selector_valid,
                   "GDT entry zero remains null for every RPL");
        end
        selector = 16'h0008; table_limit = 16'h000F; table_base = 24'hFFFFF8; #1;
        check_expect(selector_address == 24'h000000 && selector_carry, "24-bit base carry is visible");

        // Segment, expand-down and system descriptor classes.
        raw_descriptor = {16'h0000, 8'h9A, 8'h56, 16'h3412, 16'hABCD}; #1;
        check_expect(descriptor_valid && reserved_valid && descriptor_class == DESC_CODE && descriptor_present,
               "readable code descriptor");
        check_expect(descriptor_base == 24'h563412 && descriptor_limit == 16'hABCD &&
               descriptor_readable && !descriptor_conforming && descriptor_dpl == 0,
               "code fields");
        raw_descriptor = {16'h0000, 8'h96, 8'h12, 16'h0000, 16'hFFFF}; #1;
        check_expect(descriptor_valid && descriptor_class == DESC_EXPAND_DOWN && descriptor_expand_down && descriptor_writable,
               "expand-down data descriptor");
        raw_descriptor = {16'h0000, 8'h84, 8'h03, 16'h1234, 16'h5678}; #1;
        check_expect(descriptor_valid && descriptor_class == DESC_CALL_GATE && gate_offset == 16'h5678 &&
               gate_selector == 16'h1234 && gate_parameter_count == 5'd3,
               "286 call gate fields");
        raw_descriptor = {16'h0000, 8'h81, 8'h01, 16'h2222, 16'h1111}; #1;
        check_expect(descriptor_valid && descriptor_class == DESC_TSS_AVAIL && descriptor_base == 24'h012222,
               "available 286 TSS descriptor");
        raw_descriptor = {16'h0001, 8'h9A, 8'h00, 16'h0000, 16'h0000}; #1;
        check_expect(descriptor_valid && reserved_valid && descriptor_class == DESC_CODE,
               "286 code descriptor ignores the upper word (Intel 386 PRM 13.3.2)");
        raw_descriptor = {16'h0010, 8'h7B, 8'h1F, 16'h8290, 16'h042F}; #1;
        check_expect(descriptor_valid && reserved_valid && !descriptor_present && descriptor_class == DESC_CODE,
               "Windows absent code descriptor remains typed with nonzero upper word");
        raw_descriptor = {16'hA5FF, 8'hF3, 8'h12, 16'h3456, 16'hFEDC}; #1;
        check_expect(descriptor_valid && reserved_valid && descriptor_class == DESC_DATA &&
                     descriptor_base == 24'h123456 && descriptor_limit == 16'hFEDC,
               "286 data descriptor upper word does not extend base or limit");
        raw_descriptor = {16'h0000, 8'h88, 8'h00, 16'h0000, 16'h0000}; #1;
        check_expect(!descriptor_valid && descriptor_class == DESC_INVALID, "reserved system type rejected");
        raw_descriptor = {16'h0000, 8'h1A, 8'h00, 16'h0000, 16'h0000}; #1;
        check_expect(descriptor_valid && !descriptor_present && descriptor_class == DESC_CODE,
               "not-present descriptor remains typed");

        // State reset and atomic candidate commits.
        tick();
        check_expect(msw == 16'hFFF0 && gdtr_base == 0 && gdtr_limit == 0,
               "reset MSW/GDTR state");
        check_expect(idtr_base == 0 && idtr_limit == 16'h03FF && !ldtr_valid && !tr_valid,
               "reset IDTR/LDTR/TR state");
        check_expect(segment_selector_state[16 +: 16] == 16'hF000 &&
               segment_base_state[24 +: 24] == 24'hFF0000 && segment_valid_state == 4'b1111,
               "reset hidden segment representation");

        reset = 1'b0;
        msw_load_en = 1'b1; msw_load_data = 16'h0001; msw_load_mask = 16'h000F; tick();
        msw_load_data = 16'h0000; tick(); msw_load_en = 1'b0;
        check_expect(msw[0] && msw[15:4] == 12'hFFF, "PE is one-way through LMSW state");
        gdtr_load_en = 1'b1; gdtr_load_base = 24'h123456; gdtr_load_limit = 16'h004F;
        idtr_load_en = 1'b1; idtr_load_base = 24'hFEDCBA; idtr_load_limit = 16'h007F; tick();
        gdtr_load_en = 1'b0; idtr_load_en = 1'b0;
        check_expect(gdtr_base == 24'h123456 && gdtr_limit == 16'h004F &&
               idtr_base == 24'hFEDCBA && idtr_limit == 16'h007F, "table register commit");

        ldtr_commit_en = 1'b1; ldtr_commit_selector = 16'h0017; ldtr_commit_base = 24'h020000;
        ldtr_commit_limit = 16'h00FF; ldtr_commit_access = 8'h82; ldtr_commit_class = DESC_LDT;
        ldtr_commit_present = 1'b1;
        tr_commit_en = 1'b1; tr_commit_selector = 16'h0020; tr_commit_base = 24'h030000;
        tr_commit_limit = 16'h0067; tr_commit_access = 8'h81; tr_commit_class = DESC_TSS_AVAIL;
        tr_commit_present = 1'b1; tick();
        ldtr_commit_en = 1'b0; tr_commit_en = 1'b0;
        check_expect(ldtr_valid && ldtr_present && ldtr_selector == 16'h0017 && ldtr_class == DESC_LDT &&
               ldtr_base == 24'h020000, "atomic LDTR cache commit");
        check_expect(tr_valid && tr_present && tr_selector == 16'h0020 && tr_class == DESC_TSS_AVAIL &&
               tr_base == 24'h030000, "atomic TR cache commit");

        segment_commit_en = 1'b1; segment_commit_index = 2'd3;
        segment_commit_selector = 16'h003B; segment_commit_base = 24'h654321;
        segment_commit_limit = 16'h7FFF; segment_commit_access = 8'hFA;
        segment_commit_class = DESC_CODE; segment_commit_present = 1'b1;
        segment_commit_protected = 1'b1; segment_commit_dpl = 2'd3;
        segment_commit_table_indicator = 1'b1; segment_commit_rpl = 2'd3; tick();
        segment_commit_en = 1'b0;
        check_expect(segment_selector_state[48 +: 16] == 16'h003B &&
               segment_base_state[72 +: 24] == 24'h654321 &&
               segment_limit_state[48 +: 16] == 16'h7FFF &&
               segment_access_state[24 +: 8] == 8'hFA, "segment cache fields commit together");
        check_expect(segment_class_state[12 +: 4] == DESC_CODE && segment_valid_state[3] &&
               segment_present_state[3] && segment_protected_state[3] &&
               segment_dpl_state[6 +: 2] == 2'd3 && segment_table_state[3] &&
               segment_rpl_state[6 +: 2] == 2'd3, "segment privilege metadata commit");

        $display("PROTECTED_FOUNDATION PASS: %0d checks", checks);
        $finish;
    end
endmodule
