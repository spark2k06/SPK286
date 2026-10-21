// SPDX-License-Identifier: MIT
// Behavioural RAMB18E1 and RAMB36E1 for simulating Yosys netlists of the
// ZXTRES+ demo (run_netlist_sim.sh). The cell library Yosys ships
// (share/yosys/xilinx/cells_sim.v) declares these two primitives without any
// behaviour, so a netlist simulated with it reads zeros from every block RAM.
//
// Only what synth_xilinx emits for this design is modelled: true dual-port
// mode, read and write widths of 1, 2, 4, 9, 18 and (RAMB36) 36 bits per
// port, no output registers, no cascade or ECC, READ_FIRST, WRITE_FIRST and
// NO_CHANGE, byte-lane write enables, INIT_xx/INITP_xx contents, INIT_A/B and
// SRVAL_A/B with RSTRAM. Any other setting stops the simulation at time zero.
// Addressing follows UG473: a port of width W uses the address bits from
// log2(W without parity) up, and data and parity bits are separate arrays.
// Collisions between the two ports are not modelled.
`timescale 1ns/1ps

// The full primitive interface is declared; the unused pins and parameters
// are those of settings this model rejects or does not need. Both ports
// update the shared arrays with blocking writes, in their clock order.
/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off DECLFILENAME */
module RAMB18E1 #(
    parameter [255:0] INIT_00 = 256'h0,
    parameter [255:0] INIT_01 = 256'h0,
    parameter [255:0] INIT_02 = 256'h0,
    parameter [255:0] INIT_03 = 256'h0,
    parameter [255:0] INIT_04 = 256'h0,
    parameter [255:0] INIT_05 = 256'h0,
    parameter [255:0] INIT_06 = 256'h0,
    parameter [255:0] INIT_07 = 256'h0,
    parameter [255:0] INIT_08 = 256'h0,
    parameter [255:0] INIT_09 = 256'h0,
    parameter [255:0] INIT_0A = 256'h0,
    parameter [255:0] INIT_0B = 256'h0,
    parameter [255:0] INIT_0C = 256'h0,
    parameter [255:0] INIT_0D = 256'h0,
    parameter [255:0] INIT_0E = 256'h0,
    parameter [255:0] INIT_0F = 256'h0,
    parameter [255:0] INIT_10 = 256'h0,
    parameter [255:0] INIT_11 = 256'h0,
    parameter [255:0] INIT_12 = 256'h0,
    parameter [255:0] INIT_13 = 256'h0,
    parameter [255:0] INIT_14 = 256'h0,
    parameter [255:0] INIT_15 = 256'h0,
    parameter [255:0] INIT_16 = 256'h0,
    parameter [255:0] INIT_17 = 256'h0,
    parameter [255:0] INIT_18 = 256'h0,
    parameter [255:0] INIT_19 = 256'h0,
    parameter [255:0] INIT_1A = 256'h0,
    parameter [255:0] INIT_1B = 256'h0,
    parameter [255:0] INIT_1C = 256'h0,
    parameter [255:0] INIT_1D = 256'h0,
    parameter [255:0] INIT_1E = 256'h0,
    parameter [255:0] INIT_1F = 256'h0,
    parameter [255:0] INIT_20 = 256'h0,
    parameter [255:0] INIT_21 = 256'h0,
    parameter [255:0] INIT_22 = 256'h0,
    parameter [255:0] INIT_23 = 256'h0,
    parameter [255:0] INIT_24 = 256'h0,
    parameter [255:0] INIT_25 = 256'h0,
    parameter [255:0] INIT_26 = 256'h0,
    parameter [255:0] INIT_27 = 256'h0,
    parameter [255:0] INIT_28 = 256'h0,
    parameter [255:0] INIT_29 = 256'h0,
    parameter [255:0] INIT_2A = 256'h0,
    parameter [255:0] INIT_2B = 256'h0,
    parameter [255:0] INIT_2C = 256'h0,
    parameter [255:0] INIT_2D = 256'h0,
    parameter [255:0] INIT_2E = 256'h0,
    parameter [255:0] INIT_2F = 256'h0,
    parameter [255:0] INIT_30 = 256'h0,
    parameter [255:0] INIT_31 = 256'h0,
    parameter [255:0] INIT_32 = 256'h0,
    parameter [255:0] INIT_33 = 256'h0,
    parameter [255:0] INIT_34 = 256'h0,
    parameter [255:0] INIT_35 = 256'h0,
    parameter [255:0] INIT_36 = 256'h0,
    parameter [255:0] INIT_37 = 256'h0,
    parameter [255:0] INIT_38 = 256'h0,
    parameter [255:0] INIT_39 = 256'h0,
    parameter [255:0] INIT_3A = 256'h0,
    parameter [255:0] INIT_3B = 256'h0,
    parameter [255:0] INIT_3C = 256'h0,
    parameter [255:0] INIT_3D = 256'h0,
    parameter [255:0] INIT_3E = 256'h0,
    parameter [255:0] INIT_3F = 256'h0,
    parameter [255:0] INITP_00 = 256'h0,
    parameter [255:0] INITP_01 = 256'h0,
    parameter [255:0] INITP_02 = 256'h0,
    parameter [255:0] INITP_03 = 256'h0,
    parameter [255:0] INITP_04 = 256'h0,
    parameter [255:0] INITP_05 = 256'h0,
    parameter [255:0] INITP_06 = 256'h0,
    parameter [255:0] INITP_07 = 256'h0,
    parameter [17:0] INIT_A = 18'h0,
    parameter [17:0] INIT_B = 18'h0,
    parameter [17:0] SRVAL_A = 18'h0,
    parameter [17:0] SRVAL_B = 18'h0,
    parameter integer DOA_REG = 0,
    parameter integer DOB_REG = 0,
    parameter RAM_MODE = "TDP",
    parameter integer READ_WIDTH_A = 0,
    parameter integer READ_WIDTH_B = 0,
    parameter integer WRITE_WIDTH_A = 0,
    parameter integer WRITE_WIDTH_B = 0,
    parameter WRITE_MODE_A = "WRITE_FIRST",
    parameter WRITE_MODE_B = "WRITE_FIRST",
    parameter RDADDR_COLLISION_HWCONFIG = "DELAYED_WRITE",
    parameter RSTREG_PRIORITY_A = "RSTREG",
    parameter RSTREG_PRIORITY_B = "RSTREG",
    parameter SIM_COLLISION_CHECK = "ALL",
    parameter SIM_DEVICE = "7SERIES",
    parameter INIT_FILE = "NONE",
    parameter [0:0] IS_CLKARDCLK_INVERTED = 1'b0,
    parameter [0:0] IS_CLKBWRCLK_INVERTED = 1'b0,
    parameter [0:0] IS_ENARDEN_INVERTED = 1'b0,
    parameter [0:0] IS_ENBWREN_INVERTED = 1'b0,
    parameter [0:0] IS_RSTRAMARSTRAM_INVERTED = 1'b0,
    parameter [0:0] IS_RSTRAMB_INVERTED = 1'b0,
    parameter [0:0] IS_RSTREGARSTREG_INVERTED = 1'b0,
    parameter [0:0] IS_RSTREGB_INVERTED = 1'b0
) (
    input  wire CLKARDCLK, CLKBWRCLK,
    input  wire ENARDEN, ENBWREN,
    input  wire REGCEAREGCE, REGCEB,
    input  wire RSTRAMARSTRAM, RSTRAMB, RSTREGARSTREG, RSTREGB,
    input  wire [13:0] ADDRARDADDR, ADDRBWRADDR,
    input  wire [15:0] DIADI, DIBDI,
    input  wire [1:0] DIPADIP, DIPBDIP,
    input  wire [1:0] WEA,
    input  wire [3:0] WEBWE,
    output reg  [15:0] DOADO, DOBDO,
    output reg  [1:0] DOPADOP, DOPBDOP
);
    reg [16383:0] data = {INIT_3F, INIT_3E, INIT_3D, INIT_3C, INIT_3B, INIT_3A, INIT_39, INIT_38, INIT_37, INIT_36, INIT_35, INIT_34, INIT_33, INIT_32, INIT_31, INIT_30, INIT_2F, INIT_2E, INIT_2D, INIT_2C, INIT_2B, INIT_2A, INIT_29, INIT_28, INIT_27, INIT_26, INIT_25, INIT_24, INIT_23, INIT_22, INIT_21, INIT_20, INIT_1F, INIT_1E, INIT_1D, INIT_1C, INIT_1B, INIT_1A, INIT_19, INIT_18, INIT_17, INIT_16, INIT_15, INIT_14, INIT_13, INIT_12, INIT_11, INIT_10, INIT_0F, INIT_0E, INIT_0D, INIT_0C, INIT_0B, INIT_0A, INIT_09, INIT_08, INIT_07, INIT_06, INIT_05, INIT_04, INIT_03, INIT_02, INIT_01, INIT_00};
    reg [2047:0] parity = {INITP_07, INITP_06, INITP_05, INITP_04, INITP_03, INITP_02, INITP_01, INITP_00};

    function automatic integer data_width(input integer width);
        data_width = (width >= 9) ? (width / 9) * 8 : width;
    endfunction
    function automatic integer parity_width(input integer width);
        parity_width = (width >= 9) ? width / 9 : 0;
    endfunction
    function automatic integer log2(input integer value);
        integer bits;
        bits = 0;
        while ((1 << bits) < value) bits = bits + 1;
        log2 = bits;
    endfunction
    function automatic integer word_index(input [13:0] address, input integer width);
        word_index = 32'(address[13:0]) >> log2(data_width(width));
    endfunction
    function automatic bit supported(input integer width);
        supported = width == 0 || width == 1 || width == 2 || width == 4 || width == 9 ||
                    width == 18 || (width == 36 && 18 >= 36);
    endfunction

    initial begin
        if (RAM_MODE != "TDP" || DOA_REG != 0 || DOB_REG != 0 ||
            !supported(READ_WIDTH_A) || !supported(READ_WIDTH_B) ||
            !supported(WRITE_WIDTH_A) || !supported(WRITE_WIDTH_B) ||
            IS_CLKARDCLK_INVERTED || IS_CLKBWRCLK_INVERTED || IS_ENARDEN_INVERTED ||
            IS_ENBWREN_INVERTED || IS_RSTRAMARSTRAM_INVERTED || IS_RSTRAMB_INVERTED ||
            IS_RSTREGARSTREG_INVERTED || IS_RSTREGB_INVERTED)
            $fatal(1, "RAMB18E1 %m: configuration not modelled");
        {DOPADOP, DOADO} = INIT_A;
        {DOPBDOP, DOBDO} = INIT_B;
    end

    // One port access on its clock edge: the read uses the read width, the
    // write the write width with one enable per 9-bit lane (WE[0] below
    // 8 data bits). READ_FIRST reads before writing, WRITE_FIRST after, and
    // NO_CHANGE leaves the output alone while writing. RSTRAM loads SRVAL.
    task automatic access(input [13:0] address, input [15:0] din,
                          input [1:0] dinp, input [3:0] we,
                          input integer read_width, input integer write_width,
                          input bit write_first, input bit no_change, input bit reset,
                          input [17:0] srval,
                          inout [15:0] dout, inout [1:0] doutp);
        integer rd, rp, wd, wp, index, lane;
        bit writing;
        rd = data_width(read_width);
        rp = parity_width(read_width);
        wd = data_width(write_width);
        wp = parity_width(write_width);
        writing = 0;
        if (write_width != 0) begin
            if (wd < 8) writing = we[0];
            else begin
                lane = 0;
                while (lane < wd / 8) begin
                    if (we[lane]) writing = 1;
                    lane = lane + 1;
                end
            end
        end
        if (read_width != 0 && !write_first && !(writing && no_change))
            read_word(address, read_width, rd, rp, dout, doutp);
        if (writing) begin
            index = 0;
            while (index < wd) begin
                if (wd < 8 ? we[0] : we[index / 8])
                    data[word_index(address, write_width) * wd + index] = din[index];
                index = index + 1;
            end
            index = 0;
            while (index < wp) begin
                if (we[index]) parity[word_index(address, write_width) * wp + index] = dinp[index];
                index = index + 1;
            end
        end
        if (read_width != 0 && write_first && !(writing && no_change))
            read_word(address, read_width, rd, rp, dout, doutp);
        if (reset) {doutp, dout} = srval;
    endtask

    task automatic read_word(input [13:0] address, input integer read_width,
                             input integer rd, input integer rp,
                             inout [15:0] dout, inout [1:0] doutp);
        integer index;
        dout = '0;
        doutp = '0;
        index = 0;
        while (index < rd) begin
            dout[index] = data[word_index(address, read_width) * rd + index];
            index = index + 1;
        end
        index = 0;
        while (index < rp) begin
            doutp[index] = parity[word_index(address, read_width) * rp + index];
            index = index + 1;
        end
    endtask

    reg [15:0] doa_next, dob_next;
    reg [1:0] dopa_next, dopb_next;
    always @(posedge CLKARDCLK) if (ENARDEN) begin
        doa_next = DOADO;
        dopa_next = DOPADOP;
        access(ADDRARDADDR, DIADI, DIPADIP, {2'b0, WEA}, READ_WIDTH_A, WRITE_WIDTH_A,
               WRITE_MODE_A == "WRITE_FIRST", WRITE_MODE_A == "NO_CHANGE", RSTRAMARSTRAM,
               SRVAL_A, doa_next, dopa_next);
        DOADO <= doa_next;
        DOPADOP <= dopa_next;
    end
    always @(posedge CLKBWRCLK) if (ENBWREN) begin
        dob_next = DOBDO;
        dopb_next = DOPBDOP;
        access(ADDRBWRADDR, DIBDI, DIPBDIP, WEBWE, READ_WIDTH_B, WRITE_WIDTH_B,
               WRITE_MODE_B == "WRITE_FIRST", WRITE_MODE_B == "NO_CHANGE", RSTRAMB,
               SRVAL_B, dob_next, dopb_next);
        DOBDO <= dob_next;
        DOPBDOP <= dopb_next;
    end
endmodule
/* verilator lint_on DECLFILENAME */
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on BLKSEQ */

// The full primitive interface is declared; the unused pins and parameters
// are those of settings this model rejects or does not need. Both ports
// update the shared arrays with blocking writes, in their clock order.
/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off DECLFILENAME */
module RAMB36E1 #(
    parameter [255:0] INIT_00 = 256'h0,
    parameter [255:0] INIT_01 = 256'h0,
    parameter [255:0] INIT_02 = 256'h0,
    parameter [255:0] INIT_03 = 256'h0,
    parameter [255:0] INIT_04 = 256'h0,
    parameter [255:0] INIT_05 = 256'h0,
    parameter [255:0] INIT_06 = 256'h0,
    parameter [255:0] INIT_07 = 256'h0,
    parameter [255:0] INIT_08 = 256'h0,
    parameter [255:0] INIT_09 = 256'h0,
    parameter [255:0] INIT_0A = 256'h0,
    parameter [255:0] INIT_0B = 256'h0,
    parameter [255:0] INIT_0C = 256'h0,
    parameter [255:0] INIT_0D = 256'h0,
    parameter [255:0] INIT_0E = 256'h0,
    parameter [255:0] INIT_0F = 256'h0,
    parameter [255:0] INIT_10 = 256'h0,
    parameter [255:0] INIT_11 = 256'h0,
    parameter [255:0] INIT_12 = 256'h0,
    parameter [255:0] INIT_13 = 256'h0,
    parameter [255:0] INIT_14 = 256'h0,
    parameter [255:0] INIT_15 = 256'h0,
    parameter [255:0] INIT_16 = 256'h0,
    parameter [255:0] INIT_17 = 256'h0,
    parameter [255:0] INIT_18 = 256'h0,
    parameter [255:0] INIT_19 = 256'h0,
    parameter [255:0] INIT_1A = 256'h0,
    parameter [255:0] INIT_1B = 256'h0,
    parameter [255:0] INIT_1C = 256'h0,
    parameter [255:0] INIT_1D = 256'h0,
    parameter [255:0] INIT_1E = 256'h0,
    parameter [255:0] INIT_1F = 256'h0,
    parameter [255:0] INIT_20 = 256'h0,
    parameter [255:0] INIT_21 = 256'h0,
    parameter [255:0] INIT_22 = 256'h0,
    parameter [255:0] INIT_23 = 256'h0,
    parameter [255:0] INIT_24 = 256'h0,
    parameter [255:0] INIT_25 = 256'h0,
    parameter [255:0] INIT_26 = 256'h0,
    parameter [255:0] INIT_27 = 256'h0,
    parameter [255:0] INIT_28 = 256'h0,
    parameter [255:0] INIT_29 = 256'h0,
    parameter [255:0] INIT_2A = 256'h0,
    parameter [255:0] INIT_2B = 256'h0,
    parameter [255:0] INIT_2C = 256'h0,
    parameter [255:0] INIT_2D = 256'h0,
    parameter [255:0] INIT_2E = 256'h0,
    parameter [255:0] INIT_2F = 256'h0,
    parameter [255:0] INIT_30 = 256'h0,
    parameter [255:0] INIT_31 = 256'h0,
    parameter [255:0] INIT_32 = 256'h0,
    parameter [255:0] INIT_33 = 256'h0,
    parameter [255:0] INIT_34 = 256'h0,
    parameter [255:0] INIT_35 = 256'h0,
    parameter [255:0] INIT_36 = 256'h0,
    parameter [255:0] INIT_37 = 256'h0,
    parameter [255:0] INIT_38 = 256'h0,
    parameter [255:0] INIT_39 = 256'h0,
    parameter [255:0] INIT_3A = 256'h0,
    parameter [255:0] INIT_3B = 256'h0,
    parameter [255:0] INIT_3C = 256'h0,
    parameter [255:0] INIT_3D = 256'h0,
    parameter [255:0] INIT_3E = 256'h0,
    parameter [255:0] INIT_3F = 256'h0,
    parameter [255:0] INIT_40 = 256'h0,
    parameter [255:0] INIT_41 = 256'h0,
    parameter [255:0] INIT_42 = 256'h0,
    parameter [255:0] INIT_43 = 256'h0,
    parameter [255:0] INIT_44 = 256'h0,
    parameter [255:0] INIT_45 = 256'h0,
    parameter [255:0] INIT_46 = 256'h0,
    parameter [255:0] INIT_47 = 256'h0,
    parameter [255:0] INIT_48 = 256'h0,
    parameter [255:0] INIT_49 = 256'h0,
    parameter [255:0] INIT_4A = 256'h0,
    parameter [255:0] INIT_4B = 256'h0,
    parameter [255:0] INIT_4C = 256'h0,
    parameter [255:0] INIT_4D = 256'h0,
    parameter [255:0] INIT_4E = 256'h0,
    parameter [255:0] INIT_4F = 256'h0,
    parameter [255:0] INIT_50 = 256'h0,
    parameter [255:0] INIT_51 = 256'h0,
    parameter [255:0] INIT_52 = 256'h0,
    parameter [255:0] INIT_53 = 256'h0,
    parameter [255:0] INIT_54 = 256'h0,
    parameter [255:0] INIT_55 = 256'h0,
    parameter [255:0] INIT_56 = 256'h0,
    parameter [255:0] INIT_57 = 256'h0,
    parameter [255:0] INIT_58 = 256'h0,
    parameter [255:0] INIT_59 = 256'h0,
    parameter [255:0] INIT_5A = 256'h0,
    parameter [255:0] INIT_5B = 256'h0,
    parameter [255:0] INIT_5C = 256'h0,
    parameter [255:0] INIT_5D = 256'h0,
    parameter [255:0] INIT_5E = 256'h0,
    parameter [255:0] INIT_5F = 256'h0,
    parameter [255:0] INIT_60 = 256'h0,
    parameter [255:0] INIT_61 = 256'h0,
    parameter [255:0] INIT_62 = 256'h0,
    parameter [255:0] INIT_63 = 256'h0,
    parameter [255:0] INIT_64 = 256'h0,
    parameter [255:0] INIT_65 = 256'h0,
    parameter [255:0] INIT_66 = 256'h0,
    parameter [255:0] INIT_67 = 256'h0,
    parameter [255:0] INIT_68 = 256'h0,
    parameter [255:0] INIT_69 = 256'h0,
    parameter [255:0] INIT_6A = 256'h0,
    parameter [255:0] INIT_6B = 256'h0,
    parameter [255:0] INIT_6C = 256'h0,
    parameter [255:0] INIT_6D = 256'h0,
    parameter [255:0] INIT_6E = 256'h0,
    parameter [255:0] INIT_6F = 256'h0,
    parameter [255:0] INIT_70 = 256'h0,
    parameter [255:0] INIT_71 = 256'h0,
    parameter [255:0] INIT_72 = 256'h0,
    parameter [255:0] INIT_73 = 256'h0,
    parameter [255:0] INIT_74 = 256'h0,
    parameter [255:0] INIT_75 = 256'h0,
    parameter [255:0] INIT_76 = 256'h0,
    parameter [255:0] INIT_77 = 256'h0,
    parameter [255:0] INIT_78 = 256'h0,
    parameter [255:0] INIT_79 = 256'h0,
    parameter [255:0] INIT_7A = 256'h0,
    parameter [255:0] INIT_7B = 256'h0,
    parameter [255:0] INIT_7C = 256'h0,
    parameter [255:0] INIT_7D = 256'h0,
    parameter [255:0] INIT_7E = 256'h0,
    parameter [255:0] INIT_7F = 256'h0,
    parameter [255:0] INITP_00 = 256'h0,
    parameter [255:0] INITP_01 = 256'h0,
    parameter [255:0] INITP_02 = 256'h0,
    parameter [255:0] INITP_03 = 256'h0,
    parameter [255:0] INITP_04 = 256'h0,
    parameter [255:0] INITP_05 = 256'h0,
    parameter [255:0] INITP_06 = 256'h0,
    parameter [255:0] INITP_07 = 256'h0,
    parameter [255:0] INITP_08 = 256'h0,
    parameter [255:0] INITP_09 = 256'h0,
    parameter [255:0] INITP_0A = 256'h0,
    parameter [255:0] INITP_0B = 256'h0,
    parameter [255:0] INITP_0C = 256'h0,
    parameter [255:0] INITP_0D = 256'h0,
    parameter [255:0] INITP_0E = 256'h0,
    parameter [255:0] INITP_0F = 256'h0,
    parameter [35:0] INIT_A = 36'h0,
    parameter [35:0] INIT_B = 36'h0,
    parameter [35:0] SRVAL_A = 36'h0,
    parameter [35:0] SRVAL_B = 36'h0,
    parameter RAM_EXTENSION_A = "NONE",
    parameter RAM_EXTENSION_B = "NONE",
    parameter EN_ECC_READ = "FALSE",
    parameter EN_ECC_WRITE = "FALSE",
    parameter integer DOA_REG = 0,
    parameter integer DOB_REG = 0,
    parameter RAM_MODE = "TDP",
    parameter integer READ_WIDTH_A = 0,
    parameter integer READ_WIDTH_B = 0,
    parameter integer WRITE_WIDTH_A = 0,
    parameter integer WRITE_WIDTH_B = 0,
    parameter WRITE_MODE_A = "WRITE_FIRST",
    parameter WRITE_MODE_B = "WRITE_FIRST",
    parameter RDADDR_COLLISION_HWCONFIG = "DELAYED_WRITE",
    parameter RSTREG_PRIORITY_A = "RSTREG",
    parameter RSTREG_PRIORITY_B = "RSTREG",
    parameter SIM_COLLISION_CHECK = "ALL",
    parameter SIM_DEVICE = "7SERIES",
    parameter INIT_FILE = "NONE",
    parameter [0:0] IS_CLKARDCLK_INVERTED = 1'b0,
    parameter [0:0] IS_CLKBWRCLK_INVERTED = 1'b0,
    parameter [0:0] IS_ENARDEN_INVERTED = 1'b0,
    parameter [0:0] IS_ENBWREN_INVERTED = 1'b0,
    parameter [0:0] IS_RSTRAMARSTRAM_INVERTED = 1'b0,
    parameter [0:0] IS_RSTRAMB_INVERTED = 1'b0,
    parameter [0:0] IS_RSTREGARSTREG_INVERTED = 1'b0,
    parameter [0:0] IS_RSTREGB_INVERTED = 1'b0
) (
    input  wire CLKARDCLK, CLKBWRCLK,
    input  wire ENARDEN, ENBWREN,
    input  wire REGCEAREGCE, REGCEB,
    input  wire RSTRAMARSTRAM, RSTRAMB, RSTREGARSTREG, RSTREGB,
    input  wire [15:0] ADDRARDADDR, ADDRBWRADDR,
    input  wire [31:0] DIADI, DIBDI,
    input  wire [3:0] DIPADIP, DIPBDIP,
    input  wire [3:0] WEA,
    input  wire [7:0] WEBWE,
    input  wire CASCADEINA, CASCADEINB, INJECTDBITERR, INJECTSBITERR,
    output wire CASCADEOUTA, CASCADEOUTB, DBITERR, SBITERR,
    output wire [7:0] ECCPARITY,
    output wire [8:0] RDADDRECC,
    output reg  [31:0] DOADO, DOBDO,
    output reg  [3:0] DOPADOP, DOPBDOP
);
    reg [32767:0] data = {INIT_7F, INIT_7E, INIT_7D, INIT_7C, INIT_7B, INIT_7A, INIT_79, INIT_78, INIT_77, INIT_76, INIT_75, INIT_74, INIT_73, INIT_72, INIT_71, INIT_70, INIT_6F, INIT_6E, INIT_6D, INIT_6C, INIT_6B, INIT_6A, INIT_69, INIT_68, INIT_67, INIT_66, INIT_65, INIT_64, INIT_63, INIT_62, INIT_61, INIT_60, INIT_5F, INIT_5E, INIT_5D, INIT_5C, INIT_5B, INIT_5A, INIT_59, INIT_58, INIT_57, INIT_56, INIT_55, INIT_54, INIT_53, INIT_52, INIT_51, INIT_50, INIT_4F, INIT_4E, INIT_4D, INIT_4C, INIT_4B, INIT_4A, INIT_49, INIT_48, INIT_47, INIT_46, INIT_45, INIT_44, INIT_43, INIT_42, INIT_41, INIT_40, INIT_3F, INIT_3E, INIT_3D, INIT_3C, INIT_3B, INIT_3A, INIT_39, INIT_38, INIT_37, INIT_36, INIT_35, INIT_34, INIT_33, INIT_32, INIT_31, INIT_30, INIT_2F, INIT_2E, INIT_2D, INIT_2C, INIT_2B, INIT_2A, INIT_29, INIT_28, INIT_27, INIT_26, INIT_25, INIT_24, INIT_23, INIT_22, INIT_21, INIT_20, INIT_1F, INIT_1E, INIT_1D, INIT_1C, INIT_1B, INIT_1A, INIT_19, INIT_18, INIT_17, INIT_16, INIT_15, INIT_14, INIT_13, INIT_12, INIT_11, INIT_10, INIT_0F, INIT_0E, INIT_0D, INIT_0C, INIT_0B, INIT_0A, INIT_09, INIT_08, INIT_07, INIT_06, INIT_05, INIT_04, INIT_03, INIT_02, INIT_01, INIT_00};
    reg [4095:0] parity = {INITP_0F, INITP_0E, INITP_0D, INITP_0C, INITP_0B, INITP_0A, INITP_09, INITP_08, INITP_07, INITP_06, INITP_05, INITP_04, INITP_03, INITP_02, INITP_01, INITP_00};
    assign {CASCADEOUTA, CASCADEOUTB, DBITERR, SBITERR} = 4'b0000;
    assign ECCPARITY = 8'h00;
    assign RDADDRECC = 9'h000;
    initial if (RAM_EXTENSION_A != "NONE" || RAM_EXTENSION_B != "NONE" ||
                EN_ECC_READ != "FALSE" || EN_ECC_WRITE != "FALSE")
        $fatal(1, "RAMB36E1 %m: cascade or ECC not modelled");

    function automatic integer data_width(input integer width);
        data_width = (width >= 9) ? (width / 9) * 8 : width;
    endfunction
    function automatic integer parity_width(input integer width);
        parity_width = (width >= 9) ? width / 9 : 0;
    endfunction
    function automatic integer log2(input integer value);
        integer bits;
        bits = 0;
        while ((1 << bits) < value) bits = bits + 1;
        log2 = bits;
    endfunction
    function automatic integer word_index(input [15:0] address, input integer width);
        word_index = 32'(address[14:0]) >> log2(data_width(width));
    endfunction
    function automatic bit supported(input integer width);
        supported = width == 0 || width == 1 || width == 2 || width == 4 || width == 9 ||
                    width == 18 || (width == 36 && 36 >= 36);
    endfunction

    initial begin
        if (RAM_MODE != "TDP" || DOA_REG != 0 || DOB_REG != 0 ||
            !supported(READ_WIDTH_A) || !supported(READ_WIDTH_B) ||
            !supported(WRITE_WIDTH_A) || !supported(WRITE_WIDTH_B) ||
            IS_CLKARDCLK_INVERTED || IS_CLKBWRCLK_INVERTED || IS_ENARDEN_INVERTED ||
            IS_ENBWREN_INVERTED || IS_RSTRAMARSTRAM_INVERTED || IS_RSTRAMB_INVERTED ||
            IS_RSTREGARSTREG_INVERTED || IS_RSTREGB_INVERTED)
            $fatal(1, "RAMB36E1 %m: configuration not modelled");
        {DOPADOP, DOADO} = INIT_A;
        {DOPBDOP, DOBDO} = INIT_B;
    end

    // One port access on its clock edge: the read uses the read width, the
    // write the write width with one enable per 9-bit lane (WE[0] below
    // 8 data bits). READ_FIRST reads before writing, WRITE_FIRST after, and
    // NO_CHANGE leaves the output alone while writing. RSTRAM loads SRVAL.
    task automatic access(input [15:0] address, input [31:0] din,
                          input [3:0] dinp, input [7:0] we,
                          input integer read_width, input integer write_width,
                          input bit write_first, input bit no_change, input bit reset,
                          input [35:0] srval,
                          inout [31:0] dout, inout [3:0] doutp);
        integer rd, rp, wd, wp, index, lane;
        bit writing;
        rd = data_width(read_width);
        rp = parity_width(read_width);
        wd = data_width(write_width);
        wp = parity_width(write_width);
        writing = 0;
        if (write_width != 0) begin
            if (wd < 8) writing = we[0];
            else begin
                lane = 0;
                while (lane < wd / 8) begin
                    if (we[lane]) writing = 1;
                    lane = lane + 1;
                end
            end
        end
        if (read_width != 0 && !write_first && !(writing && no_change))
            read_word(address, read_width, rd, rp, dout, doutp);
        if (writing) begin
            index = 0;
            while (index < wd) begin
                if (wd < 8 ? we[0] : we[index / 8])
                    data[word_index(address, write_width) * wd + index] = din[index];
                index = index + 1;
            end
            index = 0;
            while (index < wp) begin
                if (we[index]) parity[word_index(address, write_width) * wp + index] = dinp[index];
                index = index + 1;
            end
        end
        if (read_width != 0 && write_first && !(writing && no_change))
            read_word(address, read_width, rd, rp, dout, doutp);
        if (reset) {doutp, dout} = srval;
    endtask

    task automatic read_word(input [15:0] address, input integer read_width,
                             input integer rd, input integer rp,
                             inout [31:0] dout, inout [3:0] doutp);
        integer index;
        dout = '0;
        doutp = '0;
        index = 0;
        while (index < rd) begin
            dout[index] = data[word_index(address, read_width) * rd + index];
            index = index + 1;
        end
        index = 0;
        while (index < rp) begin
            doutp[index] = parity[word_index(address, read_width) * rp + index];
            index = index + 1;
        end
    endtask

    reg [31:0] doa_next, dob_next;
    reg [3:0] dopa_next, dopb_next;
    always @(posedge CLKARDCLK) if (ENARDEN) begin
        doa_next = DOADO;
        dopa_next = DOPADOP;
        access(ADDRARDADDR, DIADI, DIPADIP, {4'b0, WEA}, READ_WIDTH_A, WRITE_WIDTH_A,
               WRITE_MODE_A == "WRITE_FIRST", WRITE_MODE_A == "NO_CHANGE", RSTRAMARSTRAM,
               SRVAL_A, doa_next, dopa_next);
        DOADO <= doa_next;
        DOPADOP <= dopa_next;
    end
    always @(posedge CLKBWRCLK) if (ENBWREN) begin
        dob_next = DOBDO;
        dopb_next = DOPBDOP;
        access(ADDRBWRADDR, DIBDI, DIPBDIP, WEBWE, READ_WIDTH_B, WRITE_WIDTH_B,
               WRITE_MODE_B == "WRITE_FIRST", WRITE_MODE_B == "NO_CHANGE", RSTRAMB,
               SRVAL_B, dob_next, dopb_next);
        DOBDO <= dob_next;
        DOPBDOP <= dopb_next;
    end
endmodule
/* verilator lint_on DECLFILENAME */
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on BLKSEQ */
