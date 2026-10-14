// SPDX-License-Identifier: MIT
// Testbench connections to the normal execution/state boundary.
logic clk = 1'b0, reset = 1'b1, ready = 1'b0, execute_enable = 1'b0;
logic [1:0] timing_policy_request = 2'd0;
logic intr = 1'b0, nmi = 1'b0, hold_request = 1'b0;
wire halted, shutdown, event_completed;
wire [7:0] debug_event_vector;
wire [2:0] debug_event_kind;
wire debug_event_error_valid;
wire [15:0] debug_event_error_code;
wire [7:0] debug_fault_vector;
wire [15:0] debug_fault_error_code;
wire [15:0] debug_instruction_ip;
wire debug_nmi_pending, debug_nmi_blocked, debug_sti_shadow;
logic [15:0] data_in = 16'h0000;
logic [2:0] gpr_read_a_index = 3'd0, gpr_read_b_index = 3'd0, gpr_write_index = 3'd0;
logic gpr_read_a_byte = 1'b0, gpr_read_b_byte = 1'b0;
logic gpr_write_en = 1'b0, gpr_write_byte = 1'b0;
logic [15:0] gpr_write_data = 16'h0000;
wire [15:0] gpr_read_a_data, gpr_read_b_data;
logic ip_write_en = 1'b0, flags_write_en = 1'b0;
logic [15:0] ip_write_data = 16'h0000;
logic [15:0] flags_write_data = 16'h0000, flags_write_mask = 16'h0000;
logic segment_load_en = 1'b0;
logic [1:0] segment_load_index = 2'd0, segment_read_index = 2'd0;
logic [15:0] segment_load_selector = 16'h0000, segment_offset = 16'h0000;
wire [15:0] segment_selector, segment_limit;
wire [23:0] segment_base, segment_address;
wire [7:0] segment_access;
logic redirect = 1'b0, fetch_request = 1'b0, fetch_ready = 1'b0;
wire control_error, unsupported_opcode, instruction_retired;
wire fetch_request_ready, fetch_valid, fetch_blocked;
wire [7:0] debug_opcode;
wire [15:0] fetch_data, fetch_ip;
wire [1:0] fetch_count;
wire [23:0] address;
wire [15:0] data_out;
wire data_oe, bus_valid, bus_write, bus_bhe_n, bus_lock, hlda;
wire [3:0] bus_status;
wire [7:0] debug_biu_detail;
wire [15:0] debug_cs, debug_ip, debug_flags;
wire [23:0] debug_cs_base;
wire [11:0] debug_micro_pc;
wire [11:0] debug_micro_entry;
wire [spk286_microcode_pkg::MC_WORD_WIDTH-1:0] debug_micro_instruction;
wire debug_micro_active, microcode_fault;
wire operand_blocked;
wire [7:0] debug_modrm;
wire [15:0] debug_displacement, debug_effective_offset;
wire [1:0] debug_operand_segment;
wire [3:0] debug_bus_state;
wire [3:0] debug_prefetch_count;
wire [127:0] debug_gpr;
wire [63:0] debug_segment_selectors, debug_segment_limits;
wire [95:0] debug_segment_bases;
wire [31:0] debug_segment_access;
wire [15:0] debug_protected_msw;
wire [15:0] debug_gdtr_limit, debug_idtr_limit;
wire [23:0] debug_gdtr_base, debug_idtr_base;
wire [15:0] debug_ldtr_selector, debug_tr_selector;
wire [15:0] debug_ldtr_limit, debug_tr_limit;
wire [23:0] debug_ldtr_base, debug_tr_base;
wire [16:0] debug_fetch_cursor;
wire [3:0] debug_bus_transaction;
wire [63:0] debug_timing_cycle_count;
wire [63:0] debug_timing_biu_busy_cycles;
wire [63:0] debug_timing_accepted_transfers;
wire [63:0] debug_timing_ready_wait_cycles;
wire [63:0] debug_timing_prefetch_requests;
wire [63:0] debug_timing_prefetch_responses;
wire [63:0] debug_timing_queue_consumes;
wire [63:0] debug_timing_queue_empty_cycles;
wire [63:0] debug_timing_redirects;
wire [63:0] debug_timing_cancels;
wire [63:0] debug_timing_operand_wait_cycles;
wire [63:0] debug_timing_event_requests;
wire [63:0] debug_timing_event_completes;
wire [63:0] debug_timing_compatibility_delay_cycles;
wire [3:0] debug_timing_queue_count;
wire [7:0] debug_timing_schema_version;
wire [1:0] debug_timing_policy;
wire debug_timing_policy_error, debug_timing_policy_locked;
wire debug_timing_trace_valid;
wire [63:0] debug_timing_trace_cycle;
wire [23:0] debug_timing_trace_address;
wire [3:0] debug_timing_trace_status;
wire [15:0] debug_timing_trace_data;
wire [1:0] debug_timing_trace_lane_mask;
wire debug_timing_trace_write;
wire [1:0] debug_timing_trace_owner;
wire debug_timing_trace_lock, debug_timing_trace_hold;
wire debug_timing_trace_hlda, debug_timing_trace_ready;
wire [2:0] debug_timing_trace_phase;
// The executor's operation gate does not repeat service_start: an instruction
// or event may start only while the microsequencer is idle, and operations
// are valid only while it is active. Every bench on this boundary checks it.
always @(posedge clk)
    if (!reset && dut.service_start && dut.micro_active)
        $fatal(1, "service_start while the microsequencer is active");
// Operand completion does not repeat the access fault: a memory transfer was
// fault-free when issued, and nothing that decides the fault may change
// before it completes.
always @(posedge clk)
    if (!reset && dut.operand.pending_q && dut.protected_access_fault)
        $fatal(1, "access fault raised while an operand transfer is pending");
