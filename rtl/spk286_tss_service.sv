// Fixed-80286 TSS image service.
//
// This block owns only TSS image movement and descriptor busy-byte updates.
// Descriptor classification, selector validation and hidden segment-cache
// construction remain architectural consumers of its loaded candidates.
// The service never advances a phase without an accepted memory response.
`timescale 1ns/1ps

module spk286_tss_service (
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
    input  logic        memory_done,
    input  logic [15:0] memory_read_data,
    output logic        memory_request,
    output logic        memory_write,
    output logic        memory_byte,
    output logic        memory_lock,
    output logic [23:0] memory_address,
    output logic [15:0] memory_write_data,
    output logic        busy,
    output logic        complete,
    output logic        fault,
    output logic [7:0]  fault_vector,
    output logic [15:0] fault_error_code,
    output logic        commit_valid,
    output logic [15:0] loaded_ip,
    output logic [15:0] loaded_flags,
    output logic [127:0] loaded_gpr,
    output logic [63:0] loaded_segments,
    output logic [15:0] loaded_ldtr,
    output logic [15:0] loaded_backlink,
    output logic [15:0] loaded_tr_selector,
    output logic [23:0] loaded_tr_base,
    output logic [15:0] loaded_tr_limit,
    output logic [7:0]  loaded_tr_access,
    output logic        descriptor_update,
    output logic [23:0] descriptor_update_address,
    output logic [7:0]  descriptor_update_data
);
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_SAVE,
        ST_LINK,
        ST_NEW_BUSY,
        ST_OLD_FREE,
        ST_LOAD,
        ST_COMMIT,
        ST_FAULT
    } state_t;

    state_t state_q;
    logic [4:0] index_q;
    logic [15:0] load_words_q [0:14];
    logic [15:0] load_offset;
    logic [15:0] current_selector_q;
    logic [23:0] target_base_q;
    logic [15:0] target_selector_q, target_limit_q;
    logic [7:0] target_access_q;
    logic [23:0] target_descriptor_address_q, current_descriptor_address_q;
    logic nested_call_q, jump_task_q, return_task_q;
    logic [15:0] loaded_backlink_q;

    function automatic logic [15:0] save_offset(input logic [4:0] index);
        case (index)
            5'd0: save_offset = spk286_tss_pkg::TSS_IP;
            5'd1: save_offset = spk286_tss_pkg::TSS_FLAGS;
            5'd2: save_offset = spk286_tss_pkg::TSS_AX;
            5'd3: save_offset = spk286_tss_pkg::TSS_CX;
            5'd4: save_offset = spk286_tss_pkg::TSS_DX;
            5'd5: save_offset = spk286_tss_pkg::TSS_BX;
            5'd6: save_offset = spk286_tss_pkg::TSS_SP;
            5'd7: save_offset = spk286_tss_pkg::TSS_BP;
            5'd8: save_offset = spk286_tss_pkg::TSS_SI;
            5'd9: save_offset = spk286_tss_pkg::TSS_DI;
            5'd10: save_offset = spk286_tss_pkg::TSS_ES;
            5'd11: save_offset = spk286_tss_pkg::TSS_CS;
            5'd12: save_offset = spk286_tss_pkg::TSS_SS;
            5'd13: save_offset = spk286_tss_pkg::TSS_DS;
            default: save_offset = spk286_tss_pkg::TSS_LDT;
        endcase
    endfunction

    function automatic logic [15:0] save_data(input logic [4:0] index);
        case (index)
            5'd0: save_data = current_ip;
            5'd1: save_data = current_flags;
            5'd2: save_data = current_gpr[0 +: 16];
            5'd3: save_data = current_gpr[16 +: 16];
            5'd4: save_data = current_gpr[32 +: 16];
            5'd5: save_data = current_gpr[48 +: 16];
            5'd6: save_data = current_gpr[64 +: 16];
            5'd7: save_data = current_gpr[80 +: 16];
            5'd8: save_data = current_gpr[96 +: 16];
            5'd9: save_data = current_gpr[112 +: 16];
            5'd10: save_data = current_segments[0 +: 16];
            5'd11: save_data = current_segments[16 +: 16];
            5'd12: save_data = current_segments[32 +: 16];
            5'd13: save_data = current_segments[48 +: 16];
            default: save_data = current_ldtr;
        endcase
    endfunction

    assign busy = state_q != ST_IDLE && state_q != ST_COMMIT && state_q != ST_FAULT;
    assign complete = state_q == ST_COMMIT;
    assign commit_valid = state_q == ST_COMMIT;
    assign fault = state_q == ST_FAULT;
    assign memory_request = (state_q == ST_SAVE) || (state_q == ST_LINK) ||
                            (state_q == ST_NEW_BUSY) || (state_q == ST_OLD_FREE) ||
                            (state_q == ST_LOAD);
    assign memory_write = state_q != ST_LOAD;
    assign memory_byte = (state_q == ST_NEW_BUSY) || (state_q == ST_OLD_FREE);
    // The descriptor test and BUSY set are one locked external transaction.
    // The composite controller does not start a task service until the target
    // descriptor has been classified, so this lock covers the actual update
    // that makes the target task visible to another bus master.
    assign memory_lock = state_q == ST_NEW_BUSY;
    always @* begin
        memory_address = 24'h000000;
        memory_write_data = 16'h0000;
        if (state_q == ST_SAVE) begin
            memory_address = current_base + {8'd0, save_offset(index_q)};
            memory_write_data = save_data(index_q);
        end else if (state_q == ST_LINK) begin
            memory_address = target_base_q + {8'd0, spk286_tss_pkg::TSS_BACKLINK};
            memory_write_data = current_selector_q;
        end else if (state_q == ST_NEW_BUSY) begin
            memory_address = target_descriptor_address_q + 24'd5;
            memory_write_data = {8'h00, target_access_q | 8'h02};
        end else if (state_q == ST_OLD_FREE) begin
            memory_address = current_descriptor_address_q + 24'd5;
            memory_write_data = {8'h00, current_access & ~8'h02};
        end else if (state_q == ST_LOAD) begin
            memory_address = target_base_q + {8'd0, load_offset};
        end
    end

    assign descriptor_update = (state_q == ST_NEW_BUSY) || (state_q == ST_OLD_FREE);
    assign descriptor_update_address = memory_address;
    assign descriptor_update_data = memory_write_data[7:0];
    assign loaded_backlink = loaded_backlink_q;
    assign loaded_tr_selector = target_selector_q;
    assign loaded_tr_base = target_base_q;
    assign loaded_tr_limit = target_limit_q;
    assign loaded_tr_access = target_access_q | 8'h02;

    always_comb begin
        load_offset = 16'(spk286_tss_pkg::TSS_IP + {11'd0, index_q, 1'b0});
        loaded_ip = load_words_q[0];
        // Supersoft's two-task loop relies on the incoming TSS image's NT
        // surviving a JMP task transfer so the later IRET performs a nested
        // task return.  CALL/INT still force NT as required for nesting;
        // JMP now preserves the target image instead of unconditionally
        // clearing it.
        loaded_flags = nested_call_q ? (load_words_q[1] | 16'h4000) :
                       load_words_q[1];
        loaded_gpr = {load_words_q[9], load_words_q[8], load_words_q[7], load_words_q[6],
                      load_words_q[5], load_words_q[4], load_words_q[3], load_words_q[2]};
        loaded_segments = {load_words_q[13], load_words_q[12], load_words_q[11], load_words_q[10]};
        loaded_ldtr = load_words_q[14];
    end

    always_ff @(posedge clk) begin
        if (reset || cancel) begin
            state_q <= ST_IDLE;
            index_q <= 5'd0;
            current_selector_q <= 16'h0000;
            target_base_q <= 24'h000000;
            target_selector_q <= 16'h0000;
            target_limit_q <= 16'h0000;
            target_access_q <= 8'h00;
            target_descriptor_address_q <= 24'h000000;
            current_descriptor_address_q <= 24'h000000;
            nested_call_q <= 1'b0;
            jump_task_q <= 1'b0;
            return_task_q <= 1'b0;
            loaded_backlink_q <= 16'h0000;
            fault_vector <= 8'h00;
            fault_error_code <= 16'h0000;
            for (integer i = 0; i < 15; i = i + 1) load_words_q[i] <= 16'h0000;
        end else begin
            if (state_q == ST_COMMIT) state_q <= ST_IDLE;
            else if (state_q == ST_FAULT) state_q <= ST_IDLE;
            else if (state_q == ST_IDLE && start) begin
                current_selector_q <= current_selector;
                target_base_q <= target_base;
                target_selector_q <= target_selector;
                target_limit_q <= target_limit;
                target_access_q <= target_access;
                target_descriptor_address_q <= target_descriptor_address;
                current_descriptor_address_q <= current_descriptor_address;
                nested_call_q <= nested_call;
                jump_task_q <= jump_task;
                return_task_q <= return_task;
                loaded_backlink_q <= current_selector;
                if (target_selector[15:3] == 0 || target_selector == current_selector ||
                    target_limit < spk286_tss_pkg::TSS_MIN_LIMIT ||
                    current_limit < spk286_tss_pkg::TSS_MIN_LIMIT ||
                    (!return_task && !(target_access[0] && !target_access[1])) ||
                    (return_task && !(target_access[0] && target_access[1]))) begin
                    fault_vector <= 8'd10;
                    fault_error_code <= target_selector;
                    state_q <= ST_FAULT;
                end else if (!target_access[7]) begin
                    fault_vector <= 8'd11;
                    fault_error_code <= target_selector;
                    state_q <= ST_FAULT;
                end else if (return_task) begin
                    index_q <= 5'd0;
                    state_q <= ST_SAVE;
                end else begin
                    index_q <= 5'd0;
                    state_q <= ST_NEW_BUSY;
                end
            end else if (memory_request && memory_done) begin
                case (state_q)
                    ST_SAVE: begin
                        if (index_q == 5'd14) begin
                            index_q <= 5'd0;
                            state_q <= nested_call_q ? ST_LINK : ((jump_task_q || return_task_q) ? ST_OLD_FREE : ST_LOAD);
                        end else index_q <= index_q + 5'd1;
                    end
                    ST_LINK: state_q <= ST_LOAD;
                    ST_NEW_BUSY: begin
                        index_q <= 5'd0;
                        state_q <= ST_SAVE;
                    end
                    ST_OLD_FREE: begin
                        index_q <= 5'd0;
                        state_q <= ST_LOAD;
                    end
                    ST_LOAD: begin
                        load_words_q[index_q[3:0]] <= memory_read_data;
                        if (index_q == 5'd14) state_q <= ST_COMMIT;
                        else index_q <= index_q + 5'd1;
                    end
                    default: state_q <= ST_FAULT;
                endcase
            end
        end
    end
endmodule
