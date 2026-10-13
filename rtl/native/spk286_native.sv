// SPDX-License-Identifier: MIT
// 80286 pin adapter (docs/NATIVE_BUS.md, stage 1). Runs every normalized
// SPK286 transaction as a native bus cycle: address-setup Ti, Ts, then Tc
// until READY#. A processor clock is two CLK periods; every pin output is
// registered and changes only where a processor clock begins.
// Three-state pins are split into value and enable for the board top level.
`timescale 1ns/1ps

module spk286_native (
    input  logic        clk,            // CLK, twice the processor clock
    input  logic        reset,          // RESET, active high
    input  logic [1:0]  timing_policy,  // strap, sampled by the core at reset
    output logic [23:0] a,
    output logic        bhe_n, s1_n, s0_n, m_io, cod_inta_n,
    output logic        bus_oe,         // drives a, bhe_n, s1_n, s0_n, m_io, cod_inta_n
    input  logic [15:0] d_in,
    output logic [15:0] d_out,
    output logic        d_oe,
    output logic        lock_n,
    input  logic        ready_n,
    input  logic        hold,
    output logic        hlda,
    input  logic        intr, nmi,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic        pereq, busy_n, error_n,  // no processor extension interface
    /* verilator lint_on UNUSEDSIGNAL */
    output logic        peack_n,
    output logic        halted, shutdown
);
    localparam logic [2:0] T_IDLE    = 3'd0;  // Ti, bus driven passive
    localparam logic [2:0] T_ADDR    = 3'd1;  // address-setup Ti
    localparam logic [2:0] T_STATUS  = 3'd2;  // Ts
    localparam logic [2:0] T_COMMAND = 3'd3;  // Tc, repeated until READY#
    localparam logic [2:0] T_FLOAT   = 3'd4;  // bus floated, HLDA not yet high
    localparam logic [2:0] T_HOLD    = 3'd5;  // Th
    localparam logic [2:0] T_RELEASE = 3'd6;  // HLDA low, bus still floated

    logic reset_q, hold_q, intr_q, nmi_q;
    logic phase2_q;
    logic [2:0] state_q;
    logic [1:0] status_q;  // S1#, S0# for the next Ts
    logic write_q, halt_cycle_q, notify_q;
    logic [1:0] announced_q;
    logic [15:0] core_data_q;

    logic [23:0] core_address;
    logic [15:0] core_data_out;
    logic [3:0] core_status;
    logic core_bus_valid, core_bus_write, core_bhe_n, core_lock, core_hlda;

    assign peack_n = 1'b1;

    // RESET, HOLD, INTR and NMI are registered once. READY# and D15-D0 are
    // sampled only at the end of Tc, by the state and data registers below.
    always_ff @(posedge clk) begin
        reset_q <= reset;
        hold_q <= hold;
        intr_q <= intr;
        nmi_q <= nmi;
    end

    always_ff @(posedge clk) begin
        if (reset_q) begin
            // The first edge after RESET falls starts phase 1.
            phase2_q <= 1'b0;
            state_q <= T_IDLE;
            status_q <= 2'b11;
            write_q <= 1'b0;
            halt_cycle_q <= 1'b0;
            notify_q <= 1'b0;
            announced_q <= 2'b00;
            core_data_q <= 16'h0000;
            a <= 24'hFFFFFF;
            {cod_inta_n, m_io, s1_n, s0_n} <= 4'hF;
            bhe_n <= 1'b1;
            bus_oe <= 1'b1;
            d_out <= 16'h0000;
            d_oe <= 1'b0;
            lock_n <= 1'b1;
            hlda <= 1'b0;
        end else begin
            phase2_q <= !phase2_q;
            notify_q <= 1'b0;
            if (!halted && !shutdown) announced_q <= 2'b00;
            if (phase2_q) begin
                lock_n <= !core_lock;
                case (state_q)
                    T_IDLE: begin
                        // The core never offers a transaction while it grants HOLD.
                        if (core_bus_valid) begin
                            a <= core_address;
                            bhe_n <= core_bhe_n;
                            {cod_inta_n, m_io} <= core_status[3:2];
                            status_q <= core_status[1:0];
                            write_q <= core_bus_write;
                            d_out <= core_data_out;
                            halt_cycle_q <= 1'b0;
                            state_q <= T_ADDR;
                        end else if (core_hlda) begin
                            bus_oe <= 1'b0;
                            state_q <= T_FLOAT;
                        end else if ((halted || shutdown) && announced_q != {halted, shutdown}) begin
                            // The core reports halt/shutdown as a level; the pins
                            // show it once as a status-4 cycle, A1 set for halt.
                            a <= halted ? 24'h000002 : 24'h000000;
                            bhe_n <= 1'b1;
                            {cod_inta_n, m_io} <= 2'b01;
                            status_q <= 2'b00;
                            write_q <= 1'b0;
                            halt_cycle_q <= 1'b1;
                            announced_q <= {halted, shutdown};
                            state_q <= T_ADDR;
                        end
                    end
                    T_ADDR: begin
                        {s1_n, s0_n} <= status_q;
                        state_q <= T_STATUS;
                    end
                    T_STATUS: begin
                        {s1_n, s0_n} <= 2'b11;
                        d_oe <= write_q;
                        state_q <= T_COMMAND;
                    end
                    T_COMMAND: begin
                        if (!ready_n) begin
                            d_oe <= 1'b0;
                            core_data_q <= d_in;
                            notify_q <= !halt_cycle_q;
                            state_q <= T_IDLE;
                        end
                    end
                    T_FLOAT: begin
                        if (core_hlda) begin
                            hlda <= 1'b1;
                            state_q <= T_HOLD;
                        end else state_q <= T_RELEASE;
                    end
                    T_HOLD: begin
                        if (!core_hlda) begin
                            hlda <= 1'b0;
                            state_q <= T_RELEASE;
                        end
                    end
                    T_RELEASE: begin
                        bus_oe <= 1'b1;
                        state_q <= T_IDLE;
                    end
                    default: state_q <= T_IDLE;
                endcase
            end
        end
    end

    // The core sees READY for one CLK, in phase 1 of the Ti after the cycle.
    // It keeps the offered transaction unchanged until then.
    /* verilator lint_off PINCONNECTEMPTY */
    spk286 cpu (
        .clk(clk), .reset(reset_q), .ready(notify_q), .data_in(core_data_q),
        .execute_enable(1'b1), .timing_policy_request(timing_policy),
        .intr(intr_q), .nmi(nmi_q), .hold_request(hold_q),
        .halted(halted), .shutdown(shutdown), .event_completed(),
        .debug_event_vector(), .debug_event_kind(), .debug_event_error_valid(),
        .debug_event_error_code(), .debug_fault_vector(), .debug_fault_error_code(),
        .debug_instruction_ip(), .debug_nmi_pending(), .debug_nmi_blocked(),
        .debug_sti_shadow(),
        .gpr_read_a_index(3'd0), .gpr_read_b_index(3'd0),
        .gpr_read_a_byte(1'b0), .gpr_read_b_byte(1'b0),
        .gpr_read_a_data(), .gpr_read_b_data(),
        .gpr_write_en(1'b0), .gpr_write_byte(1'b0), .gpr_write_index(3'd0),
        .gpr_write_data(16'h0000), .ip_write_en(1'b0), .ip_write_data(16'h0000),
        .flags_write_en(1'b0), .flags_write_data(16'h0000), .flags_write_mask(16'h0000),
        .segment_load_en(1'b0), .segment_load_index(2'd0), .segment_load_selector(16'h0000),
        .segment_read_index(2'd0), .segment_offset(16'h0000),
        .segment_selector(), .segment_base(), .segment_limit(), .segment_access(),
        .segment_address(), .redirect(1'b0), .control_error(), .unsupported_opcode(),
        .debug_opcode(), .instruction_retired(), .microcode_fault(), .operand_blocked(),
        .debug_modrm(), .debug_displacement(), .debug_effective_offset(),
        .debug_operand_segment(),
        .fetch_request(1'b0), .fetch_request_ready(), .fetch_ready(1'b0), .fetch_valid(),
        .fetch_data(), .fetch_ip(), .fetch_count(), .fetch_blocked(),
        .address(core_address), .data_out(core_data_out), .data_oe(),
        .bus_valid(core_bus_valid), .bus_write(core_bus_write), .bus_bhe_n(core_bhe_n),
        .bus_status(core_status), .bus_lock(core_lock), .hlda(core_hlda),
        .debug_cs(), .debug_cs_base(), .debug_ip(), .debug_flags(), .debug_gpr(),
        .debug_segment_selectors(), .debug_segment_bases(), .debug_segment_limits(),
        .debug_segment_access(), .debug_protected_msw(),
        .debug_gdtr_limit(), .debug_idtr_limit(), .debug_gdtr_base(), .debug_idtr_base(),
        .debug_ldtr_selector(), .debug_tr_selector(), .debug_ldtr_limit(), .debug_tr_limit(),
        .debug_ldtr_base(), .debug_tr_base(), .debug_fetch_cursor(), .debug_micro_pc(),
        .debug_micro_entry(), .debug_micro_instruction(), .debug_micro_active(),
        .debug_prefetch_count(), .debug_bus_state(), .debug_bus_transaction(),
        .debug_timing_cycle_count(), .debug_timing_biu_busy_cycles(),
        .debug_timing_accepted_transfers(), .debug_timing_ready_wait_cycles(),
        .debug_timing_prefetch_requests(), .debug_timing_prefetch_responses(),
        .debug_timing_queue_consumes(), .debug_timing_queue_empty_cycles(),
        .debug_timing_redirects(), .debug_timing_cancels(),
        .debug_timing_operand_wait_cycles(), .debug_timing_event_requests(),
        .debug_timing_event_completes(), .debug_timing_compatibility_delay_cycles(),
        .debug_timing_queue_count(), .debug_timing_schema_version(),
        .debug_timing_policy(), .debug_timing_policy_error(), .debug_timing_policy_locked(),
        .debug_timing_trace_valid(), .debug_timing_trace_cycle(),
        .debug_timing_trace_address(), .debug_timing_trace_status(),
        .debug_timing_trace_data(), .debug_timing_trace_lane_mask(),
        .debug_timing_trace_write(), .debug_timing_trace_owner(),
        .debug_timing_trace_lock(), .debug_timing_trace_hold(),
        .debug_timing_trace_hlda(), .debug_timing_trace_ready(),
        .debug_timing_trace_phase()
    );
    /* verilator lint_on PINCONNECTEMPTY */
endmodule
