// SPDX-License-Identifier: MIT
// Simulation of the ZXTRES+ demo system: 40 MHz CPU clock, 25 MHz dot clock.
// Logs POST codes, checks the VGA sync timing, and once the demo reaches its
// live loop (POST F0h), halts or faults, captures two VGA frames as PPM files
// and writes the text screen as plain text.
//   +OUT=<prefix>       output file prefix (default zxtres_demo)
//   +MAX_MS=<ms>        simulated time limit (default 400)
`timescale 1ns/1ps
module zxtres_demo_tb;
    logic clk_cpu = 1'b0, clk_pix = 1'b0;
    logic reset_cpu = 1'b1, reset_pix = 1'b1;
    always #12.5 clk_cpu = !clk_cpu;
    always #20.0 clk_pix = !clk_pix;

    logic [5:0] vga_r, vga_g, vga_b;
    logic vga_hs, vga_vs, led_user, cpu_halted, cpu_shutdown, cpu_fault;
    logic [7:0] post_code;

    zxtres_demo_system #(.CPU_KHZ(40000)) dut (
        .clk_cpu(clk_cpu), .reset_cpu(reset_cpu),
        .clk_pix(clk_pix), .reset_pix(reset_pix),
        .vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
        .vga_hs(vga_hs), .vga_vs(vga_vs),
        .led_user(led_user), .post_code(post_code),
        .cpu_halted(cpu_halted), .cpu_shutdown(cpu_shutdown), .cpu_fault(cpu_fault)
    );

    string prefix;
    longint max_ms;
    initial begin
        if (!$value$plusargs("OUT=%s", prefix)) prefix = "zxtres_demo";
        if (!$value$plusargs("MAX_MS=%d", max_ms)) max_ms = 400;
        repeat (20) @(posedge clk_pix);
        @(posedge clk_pix) reset_pix <= 1'b0;
        @(posedge clk_cpu) reset_cpu <= 1'b0;
    end

    // POST codes and CPU state changes.
    logic [7:0] last_post = 8'h00;
    logic       last_led = 1'b0;
    always @(posedge clk_cpu) begin
        if (post_code != last_post) begin
            $display("[%0t ns] POST %02h", $time, post_code);
            last_post <= post_code;
        end
        if (led_user != last_led) begin
            $display("[%0t ns] led_user %0d", $time, led_user);
            last_led <= led_user;
        end
    end

    // VGA timing: 800 dots per line, 96-dot HSYNC, 525 lines, 2-line VSYNC.
    // Checked from the second VSYNC on, after the start-up partial frame.
    int sync_errors = 0, sync_frames = 0;
    longint dot = 0, hs_fall = -1, hs_rise = -1, vs_fall = -1;
    logic hs_q = 1'b1, vs_q = 1'b1;
    always @(posedge clk_pix) begin
        dot <= dot + 1;
        hs_q <= vga_hs;
        vs_q <= vga_vs;
        if (vs_q && !vga_vs) sync_frames <= sync_frames + 1;
        if (hs_q && !vga_hs) begin
            if (sync_frames >= 2 && dot - hs_fall != 800) begin
                sync_errors <= sync_errors + 1;
                $display("VGA_SYNC_ERROR line length %0d", dot - hs_fall);
            end
            hs_fall <= dot;
        end
        if (!hs_q && vga_hs) begin
            if (sync_frames >= 2 && dot - hs_fall != 96) begin
                sync_errors <= sync_errors + 1;
                $display("VGA_SYNC_ERROR hsync width %0d", dot - hs_fall);
            end
            hs_rise <= dot;
        end
        if (vs_q && !vga_vs) begin
            if (sync_frames >= 2 && dot - vs_fall != 800 * 525) begin
                sync_errors <= sync_errors + 1;
                $display("VGA_SYNC_ERROR frame length %0d", dot - vs_fall);
            end
            if (sync_frames >= 2 && (dot - hs_fall) % 800 != 144) begin
                sync_errors <= sync_errors + 1;
                $display("VGA_SYNC_ERROR vsync to hsync phase %0d", (dot - hs_fall) % 800);
            end
            vs_fall <= dot;
        end
        if (!vs_q && vga_vs && sync_frames >= 2 && dot - vs_fall != 1600) begin
            sync_errors <= sync_errors + 1;
            $display("VGA_SYNC_ERROR vsync width %0d", dot - vs_fall);
        end
    end

    // Frame capture. VSYNC falls at the start of line 490, so a dot t after
    // that edge is at line (490 + t / 800) % 525, column t % 800.
    int  frames_to_capture = 0, captured = 0, capture_fd = 0;
    bit  capturing = 1'b0;
    longint t = 0;
    task automatic start_capture();
        string name;
        name = $sformatf("%s_frame%0d.ppm", prefix, captured);
        capture_fd = $fopen(name, "wb");
        $fwrite(capture_fd, "P6\n640 480\n63\n");
        capturing = 1'b1;
        t = 0;
    endtask
    always @(posedge clk_pix) begin
        if (frames_to_capture > 0 && !capturing && vs_q && !vga_vs) start_capture();
        if (capturing) begin
            int x, y;
            x = int'(t % 800);
            y = int'((490 + t / 800) % 525);
            if (x < 640 && y < 480) $fwrite(capture_fd, "%c%c%c", vga_r, vga_g, vga_b);
            t = t + 1;
            if (t == 800 * 525) begin
                $fclose(capture_fd);
                capturing = 1'b0;
                captured = captured + 1;
                frames_to_capture = frames_to_capture - 1;
            end
        end
    end

    task automatic dump_text();
        int fd;
        fd = $fopen({prefix, "_screen.txt"}, "w");
        for (int row = 0; row < 25; row++) begin
            string line;
            line = "";
            for (int column = 0; column < 80; column++) begin
                logic [7:0] character;
                character = dut.text[row * 80 + column][7:0];
                if (character < 8'h20 || character > 8'h7E) character = 8'h2E;
                line = {line, $sformatf("%c", character)};
            end
            $fwrite(fd, "%s\n", line);
        end
        $fclose(fd);
    endtask

    // Finish: wait for the live loop (or a halt/fault), let the screen settle
    // for a few frames, capture two frames, dump the text and stop.
    initial begin
        string reason;
        reason = "time limit";
        @(negedge reset_cpu);
        forever begin
            @(posedge clk_cpu);
            if (post_code == 8'hF0) begin
                reason = "live loop";
                break;
            end
            if (cpu_halted || cpu_shutdown || cpu_fault) begin
                reason = "CPU halted, shut down or faulted";
                break;
            end
            if ($time >= max_ms * 1000000) break;
        end
        $display("[%0t ns] stop condition: %s", $time, reason);
        repeat (3) @(negedge vga_vs);
        frames_to_capture = 2;
        wait (frames_to_capture == 0);
        dump_text();
        $display("POST %02h halted %0d shutdown %0d fault %0d cs:ip %04h:%04h",
                 post_code, cpu_halted, cpu_shutdown, cpu_fault, dut.debug_cs, dut.debug_ip);
        $display("VGA sync errors: %0d", sync_errors);
        $display("ZXTRES_DEMO_SIM_END %s", reason);
        $finish;
    end
endmodule
