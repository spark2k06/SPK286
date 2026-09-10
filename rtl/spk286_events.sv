// Event arbitration and saved context only. Functional entry lives in microcode.
`timescale 1ns/1ps
module spk286_events (
    input logic clk, reset, cancel, enable,
    input logic intr, nmi, ss_load,
    input logic repeat_boundary, repeat_stepped,
    input logic instruction_start, opcode_dispatch, instruction_active, retired,
    input logic [7:0] opcode,
    input logic [15:0] ip, cs, flags,
    input logic fault_request,
    input logic [7:0] fault_vector,
    input logic software_request,
    input logic [7:0] software_vector,
    input logic halt_request, dispatch_ready,
    input logic ack_done,
    input logic [7:0] ack_vector,
    output logic event_active, cancel_operation, dispatch, event_request,
    output logic event_completed, event_software,
    output logic [7:0] event_vector,
    output logic [15:0] event_ip, event_cs, event_flags,
    output logic event_needs_ack,
    output logic halted, shutdown,
    output logic nmi_pending, nmi_blocked, sti_shadow, ss_shadow,
    output logic [15:0] instruction_ip,
    output logic [2:0] event_kind
);
    logic repeat_ss_inhibit_q, repeat_sti_inhibit_q;
    logic nmi_previous_q, trap_sample_q, trap_pending_q, dispatch_pending_q;
    logic [15:0] instruction_cs_q;
    logic nmi_edge, boundary, trap_due, accept, entry_failure;
    logic [2:0] selected_kind;
    logic [7:0] selected_vector;
    localparam logic [2:0] KIND_FAULT=3'd1, KIND_TRAP=3'd2,
                           KIND_NMI=3'd3, KIND_INTR=3'd4, KIND_SOFTWARE=3'd5;
    assign nmi_edge = nmi && !nmi_previous_q;
    assign boundary = (!instruction_active || repeat_boundary) && !event_active && !cancel_operation;
    assign trap_due = (repeat_stepped && trap_sample_q) || trap_pending_q || (retired && trap_sample_q && !event_active);
    assign dispatch = dispatch_pending_q && dispatch_ready && enable;
    assign entry_failure = enable && event_active && fault_request && !cancel_operation;
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
                else if ((nmi_pending || nmi_edge) && !nmi_blocked && !ss_shadow && !(repeat_boundary && repeat_ss_inhibit_q)) begin selected_kind = KIND_NMI; selected_vector = 8'd2; end
                else if (intr && flags[9] && !sti_shadow && !ss_shadow && !(repeat_boundary && (repeat_ss_inhibit_q || repeat_sti_inhibit_q)) && !shutdown) begin selected_kind = KIND_INTR; end
                // An unavailable next opcode is not a fault of the instruction
                // that just completed. Its owed trap/external boundary comes first.
                else if (fault_request && !shutdown) begin selected_kind = KIND_FAULT; selected_vector = fault_vector; end
            end
        end
    end
    assign accept = selected_kind != 0;
    assign event_request = accept;
    always_ff @(posedge clk) begin
        if (reset || cancel) begin
            repeat_ss_inhibit_q <= 1'b0; repeat_sti_inhibit_q <= 1'b0;
            event_active <= 1'b0; cancel_operation <= 1'b0; dispatch_pending_q <= 1'b0;
            event_completed <= 1'b0; event_software <= 1'b0; event_kind <= 3'd0;
            event_vector <= 8'd0; event_ip <= 16'd0; event_cs <= 16'd0; event_flags <= 16'd0;
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
                // Candidate policy: release at IRET start. The failed-IRET
                // distinction still requires 286 evidence; the release gate
                // records it in docs/phase6_evidence.json. Boundaries remain safe.
                if (opcode == 8'hCF) nmi_blocked <= 1'b0;
                if (opcode == 8'hFB && !flags[9]) sti_shadow <= 1'b1;
                else sti_shadow <= 1'b0;
            end
            if (retired && !event_active && trap_sample_q && !ss_shadow) trap_pending_q <= 1'b1;
            if (halt_request) halted <= 1'b1;
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
            end
            if (accept) begin
                event_active <= 1'b1; cancel_operation <= 1'b1; dispatch_pending_q <= 1'b0;
                event_kind <= selected_kind; event_vector <= selected_vector;
                event_software <= selected_kind == KIND_SOFTWARE;
                event_needs_ack <= selected_kind == KIND_INTR;
                event_ip <= (repeat_boundary || (selected_kind == KIND_FAULT && instruction_active)) ? instruction_ip : ip;
                event_cs <= (repeat_boundary || (selected_kind == KIND_FAULT && instruction_active)) ? instruction_cs_q : cs;
                event_flags <= flags;
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
                shutdown <= 1'b1; halted <= 1'b0; event_active <= 1'b0;
                cancel_operation <= 1'b1; dispatch_pending_q <= 1'b0;
                event_needs_ack <= 1'b0;
            end
        end
    end
endmodule
