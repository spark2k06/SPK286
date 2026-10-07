`timescale 1ns/1ps

module spk286_execution_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    logic bus_seen = 1'b0;
    logic [23:0] last_bus_address = 24'h000000;
    integer stall_remaining = 0;
    integer bus_transactions = 0;
    integer cycles = 0;
    logic single_done = 1'b0, multi_done = 1'b0;
    logic [127:0] saved_ud_gpr;

    spk286 dut (.*);

    task automatic drive_bus_data;
        logic [23:0] aligned_address;
        begin
            data_in = 16'h0000;
            if (bus_valid) begin
                aligned_address = address & 24'hFFFFFE;
                if (aligned_address[23:16] == 8'h00)
                    data_in = {memory[aligned_address[15:0] + 16'd1],
                               memory[aligned_address[15:0]]};
            end
        end
    endtask

    task automatic tick;
        drive_bus_data();
        #5; clk = 1'b1; #5; clk = 1'b0; #1;
    endtask

    task automatic service_cycle;
        begin
            if (bus_valid) begin
                if (!bus_seen || address !== last_bus_address) begin
                    bus_seen = 1'b1;
                    last_bus_address = address;
                    bus_transactions = bus_transactions + 1;
                    // Every transaction gets a deterministic READY delay.
                    stall_remaining = (bus_transactions % 3) + 1;
                end
                if (stall_remaining != 0) begin
                    ready = 1'b0;
                    stall_remaining = stall_remaining - 1;
                end else begin
                    ready = 1'b1;
                end
            end else begin
                ready = 1'b0;
                bus_seen = 1'b0;
            end
            tick();
            if (!bus_valid) bus_seen = 1'b0;
        end
    endtask

    task automatic load_byte(input logic [15:0] address_value, input logic [7:0] value);
        memory[address_value] = value;
    endtask

    task automatic check_word(input logic [2:0] index,
                              input logic [15:0] expected,
                              input string name);
        if (debug_gpr[index * 16 +: 16] !== expected)
            $fatal(1, "%s got=%h expected=%h", name, debug_gpr[index * 16 +: 16], expected);
    endtask

    initial begin
        for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;

        // First instruction proves a complete single MOV and leaves an old
        // stream byte behind for the redirect/flush check.
        load_byte(16'h0000, 8'hB8);
        load_byte(16'h0001, 8'h34);
        load_byte(16'h0002, 8'h12);
        load_byte(16'h0003, 8'h0F); // Unsupported if stale bytes escape a flush.

        // The redirected stream covers the remaining seven destination codes.
        load_byte(16'h0100, 8'hB9); load_byte(16'h0101, 8'h78); load_byte(16'h0102, 8'h56);
        load_byte(16'h0103, 8'hBA); load_byte(16'h0104, 8'hBC); load_byte(16'h0105, 8'h9A);
        load_byte(16'h0106, 8'hBB); load_byte(16'h0107, 8'hED); load_byte(16'h0108, 8'h0F);
        load_byte(16'h0109, 8'hBC); load_byte(16'h010A, 8'h00); load_byte(16'h010B, 8'h10);
        load_byte(16'h010C, 8'hBD); load_byte(16'h010D, 8'h00); load_byte(16'h010E, 8'h20);
        load_byte(16'h010F, 8'hBE); load_byte(16'h0110, 8'h00); load_byte(16'h0111, 8'h30);
        load_byte(16'h0112, 8'hBF); load_byte(16'h0113, 8'h00); load_byte(16'h0114, 8'h40);

        // Reset and initialize through the normal state commit ports.
        tick();
        reset = 1'b0;
        for (integer i = 0; i < 8; i = i + 1) begin
            gpr_write_en = 1'b1;
            gpr_write_index = 3'(i);
            gpr_write_data = 16'hA000 + 16'(i);
            tick();
        end
        gpr_write_en = 1'b0;
        flags_write_en = 1'b1;
        flags_write_mask = 16'hFFFF;
        flags_write_data = 16'h0041;
        tick();
        flags_write_en = 1'b0;

        // Far restart is intentionally performed while the old reset fetch is
        // outstanding. Its response must be discarded before the new stream.
        segment_load_en = 1'b1;
        segment_load_index = 2'd1;
        segment_load_selector = 16'h0000;
        ip_write_en = 1'b1;
        ip_write_data = 16'h0000;
        redirect = 1'b1;
        #1;
        if (control_error !== 1'b0) $fatal(1, "initial program redirect rejected");
        tick();
        segment_load_en = 1'b0;
        ip_write_en = 1'b0;
        redirect = 1'b0;
        ready = 1'b1;
        tick();
        ready = 1'b0;
        tick();

        execute_enable = 1'b1;
        single_done = 1'b0;
        for (cycles = 0; cycles < 1200 && !single_done; cycles = cycles + 1) begin
            service_cycle();
            if (debug_ip === 16'h0003 && debug_gpr[15:0] === 16'h1234)
                single_done = 1'b1;
        end
        if (!single_done) $fatal(1, "single MOV did not complete");
        check_word(3'd0, 16'h1234, "AX after MOV");
        check_word(3'd1, 16'hA001, "CX before redirect");
        if (debug_ip !== 16'h0003 || debug_flags !== 16'h0043 || unsupported_opcode)
            $fatal(1, "single MOV architectural result IP=%h FLAGS=%h unsupported=%b",
                   debug_ip, debug_flags, unsupported_opcode);

        // Redirect with prefetched old bytes present. This must invalidate the
        // queue and restart the frontend at the new architectural IP.
        ip_write_en = 1'b1;
        ip_write_data = 16'h0100;
        redirect = 1'b1;
        #1;
        if (control_error !== 1'b0) $fatal(1, "near execution redirect rejected");
        tick();
        ip_write_en = 1'b0;
        redirect = 1'b0;

        multi_done = 1'b0;
        for (cycles = 0; cycles < 2400 && !multi_done; cycles = cycles + 1) begin
            service_cycle();
            if (debug_ip === 16'h0115 &&
                debug_gpr[15:0] === 16'h1234 &&
                debug_gpr[31:16] === 16'h5678 &&
                debug_gpr[47:32] === 16'h9ABC &&
                debug_gpr[63:48] === 16'h0FED &&
                debug_gpr[79:64] === 16'h1000 &&
                debug_gpr[95:80] === 16'h2000 &&
                debug_gpr[111:96] === 16'h3000 &&
                debug_gpr[127:112] === 16'h4000)
                multi_done = 1'b1;
        end
        if (!multi_done) $fatal(1, "multi-instruction MOV program did not complete");
        check_word(3'd0, 16'h1234, "AX final");
        check_word(3'd1, 16'h5678, "CX final");
        check_word(3'd2, 16'h9ABC, "DX final");
        check_word(3'd3, 16'h0FED, "BX final");
        check_word(3'd4, 16'h1000, "SP final");
        check_word(3'd5, 16'h2000, "BP final");
        check_word(3'd6, 16'h3000, "SI final");
        check_word(3'd7, 16'h4000, "DI final");
        if (debug_ip !== 16'h0115 || debug_flags !== 16'h0043 || unsupported_opcode)
            $fatal(1, "multi MOV architectural result IP=%h FLAGS=%h unsupported=%b",
                   debug_ip, debug_flags, unsupported_opcode);
        if (debug_prefetch_count > 4'd6)
            $fatal(1, "prefetch queue count overflow: %d", debug_prefetch_count);

        // An invalid 0F second byte must reach architectural #UD acceptance.
        // Stop before stack entry: retain origin and the complete MOV signature.
        saved_ud_gpr = debug_gpr;
        ip_write_en = 1'b1;
        ip_write_data = 16'h0200;
        redirect = 1'b1;
        load_byte(16'h0200, 8'h0F);
        load_byte(16'h0201, 8'hFF);
        #1;
        tick();
        ip_write_en = 1'b0;
        redirect = 1'b0;
        for (cycles = 0; cycles < 600 && !dut.event_active; cycles = cycles + 1) begin
            if ((bus_valid && bus_write) || instruction_retired)
                $fatal(1, "invalid sentinel retired or entered the stack before acceptance");
            service_cycle();
        end
        if (cycles == 0 || cycles >= 600 || !dut.event_active || !dut.event_cancel ||
            debug_event_vector !== 8'd6 || debug_event_kind !== 3'd1 ||
            debug_event_error_valid || unsupported_opcode || instruction_retired || event_completed ||
            (bus_valid && bus_write) || dut.event_ip !== 16'h0200 || dut.event_cs !== 16'h0000 ||
            dut.event_flags !== 16'h0043 || debug_gpr !== saved_ud_gpr || debug_flags !== 16'h0043)
            $fatal(1, "0F invalid form failed pre-entry #UD/context/signature preservation");
        execute_enable = 1'b0;
        $display("EXECUTION_SENTINEL_PASS origin=%h cycles=%0d", dut.event_ip, cycles);

        $display("EXECUTION PASS: MOV single/multi-instruction, stalls, redirect flush and unsupported opcode; bus transactions=%0d",
                 bus_transactions);
        $finish;
    end
endmodule
