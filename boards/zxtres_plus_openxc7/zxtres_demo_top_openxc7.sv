// SPDX-License-Identifier: MIT
// ZXTRES+ (XC7A100T) top level of the SPK286 bring-up demo for the openXC7
// flow. It is boards/zxtres_plus/zxtres_demo_top.sv with a PLLE2_BASE, the
// clock primitive nextpnr-xilinx places, in place of the MMCME2_BASE: the PLL
// makes the CPU clock and the 25 MHz VGA dot clock from the 50 MHz
// oscillator. led[0] blinks from the oscillator (bitstream loaded); led[1]
// follows the demo program.
`timescale 1ns/1ps
module zxtres_demo_top_openxc7 #(
    // CPU clock = 1000 MHz VCO / CPU_DIVIDE: 25 gives 40 MHz, 30 gives
    // 33.333 MHz, 32 gives 31.25 MHz.
    parameter int CPU_DIVIDE = 30
) (
    input  logic       clk50mhz,
    output logic [5:0] vga_r,
    output logic [5:0] vga_g,
    output logic [5:0] vga_b,
    output logic       vga_hs,
    output logic       vga_vs,
    output logic [1:0] led
);
    localparam int unsigned CPU_KHZ = 1000000 / CPU_DIVIDE;

    logic clk_feedback, clk_cpu_pll, clk_pix_pll, clk_cpu, clk_pix, locked;
    /* verilator lint_off PINCONNECTEMPTY */
    PLLE2_BASE #(
        .CLKIN1_PERIOD(20.0),
        .DIVCLK_DIVIDE(1),
        .CLKFBOUT_MULT(20),              // VCO 1000 MHz
        .CLKOUT0_DIVIDE(CPU_DIVIDE),
        .CLKOUT1_DIVIDE(40)              // 25 MHz
    ) u_pll (
        .CLKIN1(clk50mhz), .CLKFBIN(clk_feedback), .CLKFBOUT(clk_feedback),
        .CLKOUT0(clk_cpu_pll), .CLKOUT1(clk_pix_pll),
        .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(),
        .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0)
    );
    /* verilator lint_on PINCONNECTEMPTY */
    BUFG u_cpu_bufg (.I(clk_cpu_pll), .O(clk_cpu));
    BUFG u_pix_bufg (.I(clk_pix_pll), .O(clk_pix));

    // Each domain leaves reset 2^16 of its clocks after the PLL locks.
    (* ASYNC_REG = "TRUE" *) logic [1:0] cpu_lock_sync = '0, pix_lock_sync = '0;
    logic [16:0] cpu_reset_count = '0, pix_reset_count = '0;
    always_ff @(posedge clk_cpu) begin
        cpu_lock_sync <= {cpu_lock_sync[0], locked};
        if (!cpu_lock_sync[1])           cpu_reset_count <= '0;
        else if (!cpu_reset_count[16])   cpu_reset_count <= cpu_reset_count + 17'd1;
    end
    always_ff @(posedge clk_pix) begin
        pix_lock_sync <= {pix_lock_sync[0], locked};
        if (!pix_lock_sync[1])           pix_reset_count <= '0;
        else if (!pix_reset_count[16])   pix_reset_count <= pix_reset_count + 17'd1;
    end

    logic [25:0] blink_q = '0;
    always_ff @(posedge clk50mhz) blink_q <= blink_q + 26'd1;

    logic led_user;
    /* verilator lint_off PINCONNECTEMPTY */
    zxtres_demo_system #(.CPU_KHZ(CPU_KHZ)) u_system (
        .clk_cpu(clk_cpu), .reset_cpu(!cpu_reset_count[16]),
        .clk_pix(clk_pix), .reset_pix(!pix_reset_count[16]),
        .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b), .vga_hs(vga_hs), .vga_vs(vga_vs),
        .led_user(led_user), .post_code(),
        .cpu_halted(), .cpu_shutdown(), .cpu_fault()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    assign led = {led_user, blink_q[25]};
endmodule
