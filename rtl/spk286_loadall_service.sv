// Serialized 80286 LOADALL image acquisition.
//
// LOADALL is an undocumented but guaranteed 80286 instruction.  The image is
// read as 51 little-endian words from physical 000800h.  No architectural
// state is published until the complete image has been acquired and the
// protected-mode rules that can be checked locally have passed.
`timescale 1ns/1ps

module spk286_loadall_service (
    input  logic        clk,
    input  logic        reset,
    input  logic        cancel,
    input  logic        start,
    input  logic        current_protected,
    input  logic [1:0]  current_cpl,
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
    output logic [15:0] loaded_msw,
    output logic [15:0] loaded_ip,
    output logic [15:0] loaded_flags,
    output logic [127:0] loaded_gpr,
    output logic [15:0] loaded_gdtr_limit,
    output logic [23:0] loaded_gdtr_base,
    output logic [15:0] loaded_idtr_limit,
    output logic [23:0] loaded_idtr_base,
    output logic [15:0] loaded_ldtr_selector,
    output logic [23:0] loaded_ldtr_base,
    output logic [15:0] loaded_ldtr_limit,
    output logic [7:0]  loaded_ldtr_access,
    output logic [3:0]  loaded_ldtr_class,
    output logic        loaded_ldtr_valid,
    output logic        loaded_ldtr_present,
    output logic [15:0] loaded_tr_selector,
    output logic [23:0] loaded_tr_base,
    output logic [15:0] loaded_tr_limit,
    output logic [7:0]  loaded_tr_access,
    output logic [3:0]  loaded_tr_class,
    output logic        loaded_tr_valid,
    output logic        loaded_tr_present,
    output logic [63:0] cache_selectors,
    output logic [95:0] cache_bases,
    output logic [63:0] cache_limits,
    output logic [31:0] cache_access,
    output logic [15:0] cache_classes,
    output logic [3:0]  cache_valid,
    output logic [3:0]  cache_present,
    output logic [3:0]  cache_protected,
    output logic [7:0]  cache_dpl,
    output logic [3:0]  cache_tables,
    output logic [7:0]  cache_rpl
);
    localparam logic [23:0] LOADALL_IMAGE_BASE = 24'h000800;
    localparam logic [5:0]  LOADALL_LAST_WORD = 6'd50;
    localparam logic [7:0]  LOADALL_VECTOR = 8'd13;

    localparam logic [3:0] DESC_INVALID = 4'd0;
    localparam logic [3:0] DESC_CODE = 4'd1;
    localparam logic [3:0] DESC_DATA = 4'd2;
    localparam logic [3:0] DESC_EXPAND_DOWN = 4'd3;
    localparam logic [3:0] DESC_TSS_AVAIL = 4'd4;
    localparam logic [3:0] DESC_LDT = 4'd10;

    typedef enum logic [1:0] {ST_IDLE, ST_READ, ST_COMPLETE, ST_FAULT} state_t;
    state_t state_q;
    logic [5:0] word_index_q;
    logic current_protected_q;
    logic [15:0] image_q [0:50];

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [23:0] cache_base(input logic [15:0] low,
                                                input logic [15:0] high_access);
        cache_base = {high_access[7:0], low};
    endfunction

    function automatic logic [7:0] cache_access_value(input logic [15:0] high_access);
        cache_access_value = high_access[15:8];
    endfunction

    function automatic logic [3:0] segment_class(input logic [7:0] access);
        if (!access[7]) segment_class = DESC_INVALID;
        else if (access[3]) segment_class = DESC_CODE;
        else if (access[2]) segment_class = DESC_EXPAND_DOWN;
        else segment_class = DESC_DATA;
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    assign memory_request = state_q == ST_READ;
    assign memory_write = 1'b0;
    assign memory_byte = 1'b0;
    assign memory_address = LOADALL_IMAGE_BASE + {17'd0, word_index_q, 1'b0};
    assign memory_write_data = 16'h0000;
    assign busy = state_q == ST_READ;
    assign complete = state_q == ST_COMPLETE;
    assign fault = state_q == ST_FAULT;
    assign fault_vector = LOADALL_VECTOR;
    assign fault_error_code = 16'h0000;
    assign commit_valid = complete;

    // Image layout, in 16-bit words, follows the Intel LOADALL note:
    // 3 MSW, 11 TR, 12 FLAGS, 13 IP, 14 LDT, 15 DS, 16 SS, 17 CS,
    // 18 ES, 19..26 AX..DI, then six-byte ES/CS/SS/DS/GDTR/LDT/IDTR/TSS
    // cache records.  The high byte of each cache's middle word is access.
    always_comb begin
        loaded_msw = image_q[3];
        loaded_flags = image_q[12];
        loaded_ip = image_q[13];
        loaded_ldtr_selector = image_q[14];
        loaded_tr_selector = image_q[11];
        loaded_gpr = '0;
        loaded_gpr[0*16 +: 16] = image_q[26]; // AX
        loaded_gpr[1*16 +: 16] = image_q[25]; // CX
        loaded_gpr[2*16 +: 16] = image_q[24]; // DX
        loaded_gpr[3*16 +: 16] = image_q[23]; // BX
        loaded_gpr[4*16 +: 16] = image_q[22]; // SP
        loaded_gpr[5*16 +: 16] = image_q[21]; // BP
        loaded_gpr[6*16 +: 16] = image_q[20]; // SI
        loaded_gpr[7*16 +: 16] = image_q[19]; // DI

        loaded_gdtr_base = cache_base(image_q[39], image_q[40]);
        loaded_gdtr_limit = image_q[41];
        loaded_idtr_base = cache_base(image_q[45], image_q[46]);
        loaded_idtr_limit = image_q[47];

        loaded_ldtr_base = cache_base(image_q[42], image_q[43]);
        loaded_ldtr_limit = image_q[44];
        loaded_ldtr_access = cache_access_value(image_q[43]);
        loaded_ldtr_class = DESC_LDT;
        loaded_ldtr_valid = loaded_ldtr_access[7];
        loaded_ldtr_present = loaded_ldtr_access[7];

        loaded_tr_base = cache_base(image_q[48], image_q[49]);
        loaded_tr_limit = image_q[50];
        loaded_tr_access = cache_access_value(image_q[49]);
        loaded_tr_class = DESC_TSS_AVAIL;
        loaded_tr_valid = loaded_tr_access[7];
        loaded_tr_present = loaded_tr_access[7];

        cache_selectors = '0;
        cache_selectors[0*16 +: 16] = image_q[18]; // ES
        cache_selectors[1*16 +: 16] = image_q[17]; // CS
        cache_selectors[2*16 +: 16] = image_q[16]; // SS
        cache_selectors[3*16 +: 16] = image_q[15]; // DS

        cache_bases = '0;
        cache_bases[0*24 +: 24] = cache_base(image_q[27], image_q[28]);
        cache_bases[1*24 +: 24] = cache_base(image_q[30], image_q[31]);
        cache_bases[2*24 +: 24] = cache_base(image_q[33], image_q[34]);
        cache_bases[3*24 +: 24] = cache_base(image_q[36], image_q[37]);
        cache_limits = '0;
        cache_limits[0*16 +: 16] = image_q[29];
        cache_limits[1*16 +: 16] = image_q[32];
        cache_limits[2*16 +: 16] = image_q[35];
        cache_limits[3*16 +: 16] = image_q[38];
        cache_access = '0;
        cache_access[0*8 +: 8] = cache_access_value(image_q[28]);
        cache_access[1*8 +: 8] = cache_access_value(image_q[31]);
        cache_access[2*8 +: 8] = cache_access_value(image_q[34]);
        cache_access[3*8 +: 8] = cache_access_value(image_q[37]);
        cache_classes = '0;
        cache_classes[0*4 +: 4] = segment_class(cache_access[0*8 +: 8]);
        cache_classes[1*4 +: 4] = segment_class(cache_access[1*8 +: 8]);
        cache_classes[2*4 +: 4] = segment_class(cache_access[2*8 +: 8]);
        cache_classes[3*4 +: 4] = segment_class(cache_access[3*8 +: 8]);
        cache_valid = {4{1'b0}};
        cache_present = {4{1'b0}};
        cache_protected = {4{loaded_msw[0]}};
        cache_dpl = '0;
        cache_tables = '0;
        cache_rpl = '0;
        for (integer i = 0; i < 4; i = i + 1) begin
            cache_valid[i] = cache_access[i*8 + 7];
            cache_present[i] = cache_access[i*8 + 7];
            cache_dpl[i*2 +: 2] = cache_access[i*8 + 5 +: 2];
            cache_tables[i] = cache_selectors[i*16 + 2];
            cache_rpl[i*2 +: 2] = cache_selectors[i*16 +: 2];
        end
    end

    always_ff @(posedge clk) begin
        if (reset || cancel) begin
            state_q <= ST_IDLE;
            word_index_q <= 6'd0;
            current_protected_q <= 1'b0;
            for (integer i = 0; i <= 50; i = i + 1) image_q[i] <= 16'h0000;
        end else begin
            case (state_q)
                ST_IDLE: begin
                    if (start) begin
                        current_protected_q <= current_protected;
                        if (current_protected && current_cpl != 2'd0) state_q <= ST_FAULT;
                        else begin
                            word_index_q <= 6'd0;
                            state_q <= ST_READ;
                        end
                    end
                end
                ST_READ: begin
                    if (memory_done) begin
                        image_q[word_index_q] <= memory_read_data;
                        // An 80286 cannot leave protected mode through
                        // LOADALL.  Reject the image before publishing any
                        // hidden state, while still leaving the memory
                        // protocol deterministic.
                        if (word_index_q == 6'd3 && current_protected_q && !memory_read_data[0])
                            state_q <= ST_FAULT;
                        else if (word_index_q == LOADALL_LAST_WORD)
                            state_q <= ST_COMPLETE;
                        else word_index_q <= word_index_q + 6'd1;
                    end
                end
                ST_COMPLETE: state_q <= ST_IDLE;
                ST_FAULT: state_q <= ST_IDLE;
                default: state_q <= ST_IDLE;
            endcase
        end
    end
endmodule
