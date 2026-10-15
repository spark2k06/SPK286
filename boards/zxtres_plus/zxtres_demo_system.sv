// SPDX-License-Identifier: MIT
// SPK286 bring-up system for the ZXTRES+: the SPK286 core on block RAM, an
// 80x25 text screen on VGA and a few I/O ports. There is no chipset,
// interrupt controller or external memory; it only shows that the CPU runs
// x86 code on the board.
//
// Memory (24-bit physical addresses):
//   000000-00FFFF  RAM, 64 KiB
//   0B8000-0B8FFF  text screen, 80x25 character/attribute words
//   0F0000-0FFFFF  ROM, 64 KiB, mirrored at FF0000-FFFFFF for the reset fetch
//   100000-10FFFF  RAM above 1 MiB, 64 KiB, for the protected-mode test
// Other addresses read FFFFh and ignore writes.
//
// I/O ports (16-bit registers at even addresses):
//   80h  W  POST code, shown on the hardware status line
//   E0h  R  cycle counter bits 15:0; a read latches bits 31:16 for E2h
//   E2h  R  cycle counter bits 31:16 latched by the last E0h read
//   E4h  R  CPU clock in kHz
//   E6h  R  VGA frame counter
//   E8h  W  LED register (bit 0 drives led[1])
//   EAh  R  demo hardware version
//   ECh  RW scratch register for the I/O instruction test
`timescale 1ns/1ps
module zxtres_demo_system #(
    parameter string ROM_FILE  = "demo_rom.mem",
    parameter string TEXT_FILE = "demo_text.mem",
    parameter string FONT_FILE = "font8x8.mem",
    parameter int unsigned CPU_KHZ = 40000
) (
    input  logic       clk_cpu,
    input  logic       reset_cpu,      // synchronous to clk_cpu
    input  logic       clk_pix,        // 25 MHz VGA dot clock
    input  logic       reset_pix,      // synchronous to clk_pix
    output logic [5:0] vga_r,
    output logic [5:0] vga_g,
    output logic [5:0] vga_b,
    output logic       vga_hs,
    output logic       vga_vs,
    output logic       led_user,
    output logic [7:0] post_code,
    output logic       cpu_halted,
    output logic       cpu_shutdown,
    output logic       cpu_fault
);
    localparam logic [15:0] HW_VERSION = 16'h0001;

    // ------------------------------------------------------------------
    // CPU: the SPK286 core with its normalized bus (address, bus_valid,
    // bus_status, READY), in the baseline dependency-driven timing policy.
    logic [23:0] address;
    logic [15:0] data_out, data_in;
    logic        data_oe, bus_valid, bus_write, bus_bhe_n, bus_lock, hlda;
    logic [3:0]  bus_status;
    logic        ready;
    logic        control_error, unsupported_opcode, microcode_fault;
    logic [15:0] debug_cs, debug_ip;

    /* verilator lint_off PINCONNECTEMPTY */
    spk286 u_cpu (
        .clk(clk_cpu), .reset(reset_cpu), .ready(ready), .data_in(data_in),
        .execute_enable(1'b1), .timing_policy_request(2'd0),
        .intr(1'b0), .nmi(1'b0), .hold_request(1'b0),
        .halted(cpu_halted), .shutdown(cpu_shutdown), .event_completed(),
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
        .segment_address(), .redirect(1'b0), .control_error(control_error),
        .unsupported_opcode(unsupported_opcode), .debug_opcode(), .instruction_retired(),
        .microcode_fault(microcode_fault), .operand_blocked(),
        .debug_modrm(), .debug_displacement(), .debug_effective_offset(),
        .debug_operand_segment(),
        .fetch_request(1'b0), .fetch_request_ready(), .fetch_ready(1'b0), .fetch_valid(),
        .fetch_data(), .fetch_ip(), .fetch_count(), .fetch_blocked(),
        .address(address), .data_out(data_out), .data_oe(data_oe),
        .bus_valid(bus_valid), .bus_write(bus_write), .bus_bhe_n(bus_bhe_n),
        .bus_status(bus_status), .bus_lock(bus_lock), .hlda(hlda),
        .debug_cs(debug_cs), .debug_cs_base(), .debug_ip(debug_ip), .debug_flags(),
        .debug_gpr(), .debug_segment_selectors(), .debug_segment_bases(),
        .debug_segment_limits(), .debug_segment_access(), .debug_protected_msw(),
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

    // ------------------------------------------------------------------
    // Bus responder. Every READY-qualified cycle (memory, I/O, INTA) takes
    // two clocks: the block RAMs register their output in the first and
    // READY is given in the second. Halt/shutdown cycles get no READY.
    wire is_memory = (bus_status == 4'h5) || (bus_status == 4'h6) || (bus_status == 4'hD);
    wire is_io     = (bus_status == 4'h9) || (bus_status == 4'hA);
    wire is_inta   = (bus_status == 4'h0);
    logic ack_q;
    wire start = bus_valid && !ack_q && (is_memory || is_io || is_inta);
    wire write_lo = start && bus_write && !address[0];
    wire write_hi = start && bus_write && !bus_bhe_n;

    wire sel_ram0 = is_memory && (address[23:16] == 8'h00);
    wire sel_ram1 = is_memory && (address[23:16] == 8'h10);
    wire sel_text = is_memory && (address[23:12] == 12'h0B8);
    wire sel_rom  = is_memory && ((address[23:16] == 8'h0F) || (address[23:16] == 8'hFF));

    always_ff @(posedge clk_cpu) begin
        if (reset_cpu) ack_q <= 1'b0;
        else           ack_q <= start;
    end
    assign ready = ack_q;

    // Memories: 16-bit words with a write enable per byte lane.
    logic [15:0] ram0 [0:32767];
    logic [15:0] ram1 [0:32767];
    logic [15:0] rom  [0:32767];
    logic [15:0] ram0_q, ram1_q, rom_q, text_q;
    initial $readmemh(ROM_FILE, rom);

    always_ff @(posedge clk_cpu) begin
        if (sel_ram0 && write_lo) ram0[address[15:1]][7:0]  <= data_out[7:0];
        if (sel_ram0 && write_hi) ram0[address[15:1]][15:8] <= data_out[15:8];
        ram0_q <= ram0[address[15:1]];
    end
    always_ff @(posedge clk_cpu) begin
        if (sel_ram1 && write_lo) ram1[address[15:1]][7:0]  <= data_out[7:0];
        if (sel_ram1 && write_hi) ram1[address[15:1]][15:8] <= data_out[15:8];
        ram1_q <= ram1[address[15:1]];
    end
    always_ff @(posedge clk_cpu) rom_q <= rom[address[15:1]];

    // Text screen: CPU port here, video port in zxtres_text_vga.
    logic [15:0] text [0:2047];
    logic [10:0] video_text_address;
    logic [15:0] video_text_q;
    initial $readmemh(TEXT_FILE, text);
    always_ff @(posedge clk_cpu) begin
        if (sel_text && write_lo) text[address[11:1]][7:0]  <= data_out[7:0];
        if (sel_text && write_hi) text[address[11:1]][15:8] <= data_out[15:8];
        text_q <= text[address[11:1]];
    end
    always_ff @(posedge clk_pix) video_text_q <= text[video_text_address];

    // ------------------------------------------------------------------
    // I/O registers.
    logic [31:0] cycles_q;
    logic [15:0] cycles_high_q, scratch_q, io_q, frames_cpu;
    logic        led_q;
    wire  [15:0] port = {address[15:1], 1'b0};

    always_ff @(posedge clk_cpu) begin
        if (reset_cpu) begin
            cycles_q <= '0;
            cycles_high_q <= '0;
            scratch_q <= '0;
            post_code <= '0;
            led_q <= 1'b0;
        end else begin
            cycles_q <= cycles_q + 32'd1;
            if (start && is_io && bus_write) begin
                if (port == 16'h0080 && write_lo) post_code <= data_out[7:0];
                if (port == 16'h00E8 && write_lo) led_q <= data_out[0];
                if (port == 16'h00EC && write_lo) scratch_q[7:0]  <= data_out[7:0];
                if (port == 16'h00EC && write_hi) scratch_q[15:8] <= data_out[15:8];
            end
            if (start && is_io && !bus_write && port == 16'h00E0 && !address[0])
                cycles_high_q <= cycles_q[31:16];
        end
    end

    always_ff @(posedge clk_cpu) begin
        case (port)
            16'h00E0: io_q <= cycles_q[15:0];
            16'h00E2: io_q <= cycles_high_q;
            16'h00E4: io_q <= 16'(CPU_KHZ);
            16'h00E6: io_q <= frames_cpu;
            16'h00EA: io_q <= HW_VERSION;
            16'h00EC: io_q <= scratch_q;
            default:  io_q <= 16'hFFFF;
        endcase
    end

    // Read data source for the cycle being acknowledged.
    typedef enum logic [2:0] {SRC_NONE, SRC_RAM0, SRC_RAM1, SRC_TEXT, SRC_ROM, SRC_IO} source_t;
    source_t source_q;
    always_ff @(posedge clk_cpu) begin
        if (start) begin
            if (is_io)         source_q <= SRC_IO;
            else if (sel_ram0) source_q <= SRC_RAM0;
            else if (sel_ram1) source_q <= SRC_RAM1;
            else if (sel_text) source_q <= SRC_TEXT;
            else if (sel_rom)  source_q <= SRC_ROM;
            else               source_q <= SRC_NONE;
        end
    end
    always_comb begin
        case (source_q)
            SRC_RAM0: data_in = ram0_q;
            SRC_RAM1: data_in = ram1_q;
            SRC_TEXT: data_in = text_q;
            SRC_ROM:  data_in = rom_q;
            SRC_IO:   data_in = io_q;
            default:  data_in = 16'hFFFF;
        endcase
    end

    logic fault_q;
    always_ff @(posedge clk_cpu) begin
        if (reset_cpu) fault_q <= 1'b0;
        else if (control_error || unsupported_opcode || microcode_fault) fault_q <= 1'b1;
    end
    assign cpu_fault = fault_q;
    assign led_user = led_q;

    // ------------------------------------------------------------------
    // Clock-domain crossings: CPU state to the status line, frames back.
    logic [42:0] status_cpu, status_pix;
    assign status_cpu = {post_code, debug_cs, debug_ip, cpu_halted, cpu_shutdown, fault_q};
    /* verilator lint_off PINCONNECTEMPTY */
    zxtres_cdc_snapshot #(.WIDTH(43)) u_status_cdc (
        .src_clk(clk_cpu), .src_send(1'b1), .src_data(status_cpu), .src_ready(),
        .dst_clk(clk_pix), .dst_data(status_pix), .dst_update()
    );

    logic [15:0] frames_pix;
    zxtres_cdc_snapshot #(.WIDTH(16)) u_frames_cdc (
        .src_clk(clk_pix), .src_send(1'b1), .src_data(frames_pix), .src_ready(),
        .dst_clk(clk_cpu), .dst_data(frames_cpu), .dst_update()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    zxtres_text_vga #(.FONT_FILE(FONT_FILE)) u_video (
        .clk(clk_pix),
        .reset(reset_pix),
        .text_address(video_text_address),
        .text_data(video_text_q),
        .status_post(status_pix[42:35]),
        .status_cs(status_pix[34:19]),
        .status_ip(status_pix[18:3]),
        .status_halted(status_pix[2]),
        .status_shutdown(status_pix[1]),
        .status_fault(status_pix[0]),
        .frames(frames_pix),
        .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
        .vga_hs(vga_hs), .vga_vs(vga_vs)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{1'b0, bus_lock, hlda, data_oe};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
