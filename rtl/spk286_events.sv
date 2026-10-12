// SPDX-License-Identifier: MIT
// Event arbitration, delivery-failure classification and saved context.
// Functional entry lives in microcode.
`timescale 1ns/1ps
module spk286_events (
    input logic clk, reset, cancel, enable,
    input logic protected_mode, delivery_commit,
    input logic intr, nmi, ss_load,
    input logic repeat_boundary, repeat_stepped,
    input logic instruction_start, opcode_dispatch, instruction_active, retired,
    input logic [7:0] opcode,
    input logic [15:0] ip, cs, flags,
    input logic fault_request, fault_new_task,
    input logic [7:0] fault_vector,
    input logic fault_error_valid,
    input logic [15:0] fault_error_code,
    input logic software_request,
    input logic [7:0] software_vector,
    input logic halt_request, dispatch_ready,
    input logic ack_done,
    input logic [7:0] ack_vector,
    output logic event_active, cancel_operation, dispatch, event_request,
    output logic event_completed, event_software, event_external,
    output logic [7:0] event_vector,
    output logic [15:0] event_ip, event_cs, event_flags,
    output logic event_error_valid,
    output logic [15:0] event_error_code,
    output logic event_needs_ack,
    output logic halted, shutdown,
    output logic nmi_pending, nmi_blocked, sti_shadow, ss_shadow,
    output logic [15:0] instruction_ip,
    output logic [2:0] event_kind
);
    logic repeat_ss_inhibit_q, repeat_sti_inhibit_q;
    logic nmi_previous_q, trap_sample_q, trap_pending_q, dispatch_pending_q;
    logic delivery_context_live_q, shutdown_nmi_q, shutdown_reset_only_q;
    logic [15:0] instruction_cs_q;
    logic nmi_edge, boundary, trap_due, accept, entry_failure, entry_double_fault, entry_shutdown;
    logic [2:0] selected_kind;
    logic [7:0] selected_vector;
    localparam logic [2:0] KIND_FAULT=3'd1, KIND_TRAP=3'd2,
                           KIND_NMI=3'd3, KIND_INTR=3'd4, KIND_SOFTWARE=3'd5;
    assign nmi_edge = nmi && !nmi_previous_q;
    assign boundary = (!instruction_active || repeat_boundary) && !event_active && !cancel_operation;
    assign trap_due = (repeat_stepped && trap_sample_q) || trap_pending_q || (retired && trap_sample_q && !event_active);
    assign dispatch = dispatch_pending_q && dispatch_ready && enable;
    assign entry_failure = enable && event_active && fault_request && !cancel_operation;
    // Intel 286 PRM 9.6.2 / B-8: classify the first actual exception.
    // A software INT to the same vector is a different origin. #9 is benign
    // on the 286; do not import the 386 contributory/page-fault table.
    assign entry_double_fault = event_kind == KIND_FAULT &&
                                (event_vector == 8'd0 || event_vector == 8'd10 ||
                                 event_vector == 8'd11 || event_vector == 8'd12 || event_vector == 8'd13);
    assign entry_shutdown = shutdown_nmi_q ||
                            (event_kind == KIND_FAULT && event_vector == 8'd8);
    always_comb begin
        selected_kind = 3'd0;
        selected_vector = 8'd0;
        if (enable && !event_active && !cancel_operation) begin
            if (fault_request && instruction_active && !shutdown) begin
                selected_kind = KIND_FAULT; selected_vector = fault_vector;
            end else if (software_request && !shutdown) begin
                selected_kind = KIND_SOFTWARE; selected_vector = software_vector;
            end else if (boundary) begin
                if (trap_due && !ss_shadow && !(repeat_boundary && repeat_ss_inhibit_q) && !shutdown) begin selected_kind = KIND_TRAP; selected_vector = 8'd1; end
                else if ((nmi_pending || nmi_edge) && !nmi_blocked && !shutdown_reset_only_q && !ss_shadow && !(repeat_boundary && repeat_ss_inhibit_q)) begin selected_kind = KIND_NMI; selected_vector = 8'd2; end
                else if (intr && flags[9] && !sti_shadow && !ss_shadow && !(repeat_boundary && (repeat_ss_inhibit_q || repeat_sti_inhibit_q)) && !shutdown) begin selected_kind = KIND_INTR; end
                // An unavailable next opcode is not a fault of the instruction
                // that just completed. Its owed trap/external boundary comes first.
                else if (fault_request && !shutdown) begin selected_kind = KIND_FAULT; selected_vector = fault_vector; end
            end
        end
    end
    assign accept = selected_kind != 0;
    assign event_request = accept || (entry_failure && !entry_shutdown);
    always_ff @(posedge clk) begin
        if (reset || cancel) begin
            repeat_ss_inhibit_q <= 1'b0; repeat_sti_inhibit_q <= 1'b0;
            event_active <= 1'b0; cancel_operation <= 1'b0; dispatch_pending_q <= 1'b0;
            event_completed <= 1'b0; event_software <= 1'b0; event_kind <= 3'd0;
            event_external <= 1'b0; delivery_context_live_q <= 1'b0;
            shutdown_nmi_q <= 1'b0; shutdown_reset_only_q <= 1'b0;
            event_vector <= 8'd0; event_ip <= 16'd0; event_cs <= 16'd0; event_flags <= 16'd0;
            event_error_valid <= 1'b0; event_error_code <= 16'd0;
            event_needs_ack <= 1'b0;
            nmi_previous_q <= 1'b0; nmi_pending <= 1'b0; nmi_blocked <= 1'b0;
            sti_shadow <= 1'b0; ss_shadow <= 1'b0; halted <= 1'b0; shutdown <= 1'b0;
            trap_sample_q <= 1'b0; trap_pending_q <= 1'b0;
            instruction_ip <= 16'd0; instruction_cs_q <= 16'd0;
        end else begin
            event_completed <= 1'b0;
            nmi_previous_q <= nmi;
            if (nmi_edge) nmi_pending <= 1'b1;
            if (instruction_start) begin
                instruction_ip <= ip; instruction_cs_q <= cs;
                trap_sample_q <= flags[8];
            end
            // A successful SS cache commit protects the following instruction.
            // Its prefixes retain the shadow; its opcode starts the protected body.
            if (ss_load) ss_shadow <= 1'b1;
            if (opcode_dispatch) begin
                repeat_ss_inhibit_q <= ss_shadow; repeat_sti_inhibit_q <= sti_shadow;
                ss_shadow <= 1'b0;
                // NMI blocking is released at IRET start. Whether a faulting
                // IRET also releases it is unconfirmed on 80286 hardware;
                // instruction boundaries remain safe either way.
                if (opcode == 8'hCF) nmi_blocked <= 1'b0;
                if (opcode == 8'hFB && !flags[9]) sti_shadow <= 1'b1;
                else sti_shadow <= 1'b0;
            end
            if (retired && !event_active && trap_sample_q && !ss_shadow) trap_pending_q <= 1'b1;
            if (halt_request) halted <= 1'b1;
            // A task/entry handoff makes any subsequent delivery fault belong
            // to the newly committed live context. Completed writes stay live.
            if (enable && event_active && delivery_commit) delivery_context_live_q <= 1'b1;
            if (cancel_operation) begin
                cancel_operation <= 1'b0;
                dispatch_pending_q <= event_active;
            end
            if (dispatch) dispatch_pending_q <= 1'b0;
            if (ack_done && event_active) begin
                event_vector <= ack_vector; event_needs_ack <= 1'b0;
            end
            if (retired && event_active) begin
                event_active <= 1'b0; event_completed <= 1'b1;
                trap_sample_q <= 1'b0;
                shutdown_nmi_q <= 1'b0; delivery_context_live_q <= 1'b0;
            end
            if (accept) begin
                event_active <= 1'b1; cancel_operation <= 1'b1; dispatch_pending_q <= 1'b0;
                event_kind <= selected_kind; event_vector <= selected_vector;
                event_software <= selected_kind == KIND_SOFTWARE;
                event_external <= selected_kind == KIND_TRAP || selected_kind == KIND_NMI || selected_kind == KIND_INTR ||
                                  (selected_kind == KIND_FAULT && (selected_vector == 8'd7 || selected_vector == 8'd9));
                delivery_context_live_q <= 1'b0;
                shutdown_nmi_q <= shutdown && selected_kind == KIND_NMI;
                event_needs_ack <= selected_kind == KIND_INTR;
                event_ip <= (repeat_boundary || (selected_kind == KIND_FAULT && instruction_active && !fault_new_task)) ? instruction_ip : ip;
                event_cs <= (repeat_boundary || (selected_kind == KIND_FAULT && instruction_active && !fault_new_task)) ? instruction_cs_q : cs;
                event_flags <= flags;
                event_error_valid <= selected_kind == KIND_FAULT && fault_error_valid;
                event_error_code <= (selected_kind == KIND_FAULT && fault_error_valid) ? fault_error_code : 16'd0;
                trap_pending_q <= 1'b0; trap_sample_q <= 1'b0; sti_shadow <= 1'b0; ss_shadow <= 1'b0;
                halted <= 1'b0; shutdown <= 1'b0;
                if (selected_kind == KIND_NMI) begin
                    // If an older edge is being accepted, a simultaneous new
                    // edge occupies the now-free single pending slot.
                    nmi_pending <= nmi_pending && nmi_edge;
                    nmi_blocked <= 1'b1;
                end
            end
            if (entry_failure) begin
                event_completed <= 1'b0;
                cancel_operation <= 1'b1; dispatch_pending_q <= 1'b0;
                event_needs_ack <= 1'b0;
                event_software <= 1'b0; halted <= 1'b0;
                if (entry_shutdown) begin
                    shutdown <= 1'b1; event_active <= 1'b0;
                    // There is no next instruction while shut down. An SS
                    // cache handoff during the failed entry must not strand
                    // the architectural NMI exit behind an instruction shadow.
                    ss_shadow <= 1'b0; sti_shadow <= 1'b0;
                    repeat_ss_inhibit_q <= 1'b0; repeat_sti_inhibit_q <= 1'b0;
                    shutdown_reset_only_q <= shutdown_nmi_q;
                    // A failed chain must not prevent the one architectural
                    // NMI exit. Failure of that recovery NMI instead locks it.
                    nmi_blocked <= shutdown_nmi_q;
                end else begin
                    event_active <= 1'b1;
                    event_kind <= KIND_FAULT;
                    event_vector <= entry_double_fault ? 8'd8 : fault_vector;
                    event_error_valid <= entry_double_fault ? protected_mode : fault_error_valid;
                    event_error_code <= entry_double_fault ? 16'd0 : (fault_error_valid ? fault_error_code : 16'd0);
                    if (delivery_context_live_q) begin
                        event_ip <= ip; event_cs <= cs; event_flags <= flags;
                    end else if (event_software) begin
                        event_ip <= instruction_ip; event_cs <= instruction_cs_q;
                    end
                    // Keep the original EXT provenance, even after changing
                    // the kind/vector to an instruction-like protection fault.
                    delivery_context_live_q <= 1'b0;
                end
            end
        end
    end
endmodule
