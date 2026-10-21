// SPDX-License-Identifier: MIT
// 640x480 60 Hz VGA text display for the ZXTRES+ demo: 80x25 character and
// attribute words in the CGA layout, drawn with the 8x8 font doubled
// vertically, plus one status line generated in hardware from the CPU state.
`timescale 1ns/1ps
module zxtres_text_vga #(
    parameter FONT_FILE = "font8x8.mem"
) (
    input  logic        clk,            // 25 MHz dot clock
    input  logic        reset,
    output logic [10:0] text_address,   // to the text memory, read next clock
    input  logic [15:0] text_data,
    input  logic [7:0]  status_post,
    input  logic [15:0] status_cs,
    input  logic [15:0] status_ip,
    input  logic        status_halted,
    input  logic        status_shutdown,
    input  logic        status_fault,
    output logic [15:0] frames,
    output logic [5:0]  vga_r,
    output logic [5:0]  vga_g,
    output logic [5:0]  vga_b,
    output logic        vga_hs,
    output logic        vga_vs
);
    localparam int H_ACTIVE = 640, H_SYNC = 656, H_BACK = 752, H_TOTAL = 800;
    localparam int V_ACTIVE = 480, V_SYNC = 490, V_BACK = 492, V_TOTAL = 525;
    localparam int TEXT_TOP = 24, TEXT_LINES = 400;
    localparam int STATUS_TOP = 448;

    logic [9:0] h_q, v_q;
    always_ff @(posedge clk) begin
        if (reset) begin
            h_q <= '0;
            v_q <= '0;
            frames <= '0;
        end else if (h_q == 10'(H_TOTAL - 1)) begin
            h_q <= '0;
            v_q <= (v_q == 10'(V_TOTAL - 1)) ? '0 : v_q + 10'd1;
            if (v_q == 10'(V_SYNC - 1)) frames <= frames + 16'd1;
        end else begin
            h_q <= h_q + 10'd1;
        end
    end

    // The status values are sampled once per frame, before the first line,
    // so a character is never drawn from two different values.
    logic [7:0]  post_q;
    logic [15:0] cs_q, ip_q;
    logic        halted_q, shutdown_q, fault_q;
    always_ff @(posedge clk) begin
        if (h_q == '0 && v_q == '0) begin
            post_q     <= status_post;
            cs_q       <= status_cs;
            ip_q       <= status_ip;
            halted_q   <= status_halted;
            shutdown_q <= status_shutdown;
            fault_q    <= status_fault;
        end
    end

    // Stage 0: position decode and the text memory address.
    wire [9:0] text_y   = v_q - 10'(TEXT_TOP);
    wire [9:0] status_y = v_q - 10'(STATUS_TOP);
    wire in_text   = (v_q >= 10'(TEXT_TOP)) && (v_q < 10'(TEXT_TOP + TEXT_LINES));
    wire in_status = (v_q >= 10'(STATUS_TOP)) && (v_q < 10'(STATUS_TOP + 16));
    wire active    = (h_q < 10'(H_ACTIVE)) && (v_q < 10'(V_ACTIVE));
    wire [6:0] column = h_q[9:3];
    wire [4:0] row    = text_y[8:4];
    assign text_address = 11'(row) * 11'd80 + 11'(column);

    logic [2:0] p1_x, p1_font_row;
    logic [6:0] p1_column;
    logic       p1_text, p1_status, p1_hs, p1_vs;
    always_ff @(posedge clk) begin
        p1_x        <= h_q[2:0];
        p1_font_row <= in_status ? status_y[3:1] : text_y[3:1];
        p1_column   <= column;
        p1_text     <= in_text && active;
        p1_status   <= in_status && active;
        p1_hs       <= !((h_q >= 10'(H_SYNC)) && (h_q < 10'(H_BACK)));
        p1_vs       <= !((v_q >= 10'(V_SYNC)) && (v_q < 10'(V_BACK)));
    end

    // Stage 1: character and attribute, then the font lookup.
    function automatic logic [7:0] hex_char(input logic [3:0] nibble);
        hex_char = (nibble < 4'd10) ? 8'h30 + {4'h0, nibble} : 8'h37 + {4'h0, nibble};
    endfunction
    function automatic logic [7:0] flag_char(input logic flag);
        flag_char = flag ? 8'h31 : 8'h30;
    endfunction

    // 80 characters, the first (column 0) in the top byte.
    localparam logic [639:0] STATUS_TEMPLATE =
        " HW  POST --  CS:IP ----:----  HLT -  SHUTDOWN -  FAULT -  FRAME ----           ";

    wire  [6:0] status_index = 7'd79 - p1_column;
    logic [7:0] status_char;
    always_comb begin
        status_char = STATUS_TEMPLATE[{status_index, 3'b000} +: 8];
        case (p1_column)
            7'd10: status_char = hex_char(post_q[7:4]);
            7'd11: status_char = hex_char(post_q[3:0]);
            7'd20: status_char = hex_char(cs_q[15:12]);
            7'd21: status_char = hex_char(cs_q[11:8]);
            7'd22: status_char = hex_char(cs_q[7:4]);
            7'd23: status_char = hex_char(cs_q[3:0]);
            7'd25: status_char = hex_char(ip_q[15:12]);
            7'd26: status_char = hex_char(ip_q[11:8]);
            7'd27: status_char = hex_char(ip_q[7:4]);
            7'd28: status_char = hex_char(ip_q[3:0]);
            7'd35: status_char = flag_char(halted_q);
            7'd47: status_char = flag_char(shutdown_q);
            7'd56: status_char = flag_char(fault_q);
            7'd65: status_char = hex_char(frames[15:12]);
            7'd66: status_char = hex_char(frames[11:8]);
            7'd67: status_char = hex_char(frames[7:4]);
            7'd68: status_char = hex_char(frames[3:0]);
            default: ;
        endcase
    end

    wire [7:0] status_attr = (fault_q || shutdown_q) ? 8'h4F : 8'h70;
    wire [7:0] character = p1_status ? status_char : text_data[7:0];
    wire [7:0] attribute = p1_status ? status_attr : text_data[15:8];
    // The font holds characters 20h-9Fh; others are drawn blank.
    wire [7:0] glyph = character - 8'h20;
    wire       drawable = (character >= 8'h20) && (character < 8'hA0);

    logic [7:0] font [0:1023];
    logic [7:0] font_q;
    initial $readmemh(FONT_FILE, font);
    always_ff @(posedge clk) font_q <= font[{glyph[6:0], p1_font_row}];

    logic [2:0] p2_x;
    logic [7:0] p2_attribute;
    logic       p2_visible, p2_drawable, p2_hs, p2_vs;
    always_ff @(posedge clk) begin
        p2_x         <= p1_x;
        p2_attribute <= attribute;
        p2_visible   <= p1_text || p1_status;
        p2_drawable  <= drawable;
        p2_hs        <= p1_hs;
        p2_vs        <= p1_vs;
    end

    // Stage 2: pixel colour from the standard 16-colour CGA palette.
    function automatic logic [17:0] palette(input logic [3:0] index);
        case (index)
            4'h0: palette = {6'h00, 6'h00, 6'h00};
            4'h1: palette = {6'h00, 6'h00, 6'h2A};
            4'h2: palette = {6'h00, 6'h2A, 6'h00};
            4'h3: palette = {6'h00, 6'h2A, 6'h2A};
            4'h4: palette = {6'h2A, 6'h00, 6'h00};
            4'h5: palette = {6'h2A, 6'h00, 6'h2A};
            4'h6: palette = {6'h2A, 6'h15, 6'h00};
            4'h7: palette = {6'h2A, 6'h2A, 6'h2A};
            4'h8: palette = {6'h15, 6'h15, 6'h15};
            4'h9: palette = {6'h15, 6'h15, 6'h3F};
            4'hA: palette = {6'h15, 6'h3F, 6'h15};
            4'hB: palette = {6'h15, 6'h3F, 6'h3F};
            4'hC: palette = {6'h3F, 6'h15, 6'h15};
            4'hD: palette = {6'h3F, 6'h15, 6'h3F};
            4'hE: palette = {6'h3F, 6'h3F, 6'h15};
            default: palette = {6'h3F, 6'h3F, 6'h3F};
        endcase
    endfunction

    wire foreground = p2_drawable && font_q[3'd7 - p2_x];
    wire [17:0] colour = !p2_visible ? 18'd0 :
                         foreground ? palette(p2_attribute[3:0]) : palette(p2_attribute[7:4]);
    always_ff @(posedge clk) begin
        {vga_r, vga_g, vga_b} <= colour;
        vga_hs <= p2_hs;
        vga_vs <= p2_vs;
    end
    // Row and glyph bits above the 8x8 font and below the line doubling.
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = &{1'b0, text_y[9], text_y[0], status_y[9:4], status_y[0], glyph[7]};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
