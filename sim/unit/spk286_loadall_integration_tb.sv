// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module spk286_loadall_integration_tb;
    `include "spk286_signals.svh"

    // Keep enough physical space to exercise a post-LOADALL access above 1 MiB.
    logic [7:0] memory [0:21'h12FFFF];
    logic bus_seen = 1'b0;
    logic waiting_bus = 1'b0;
    logic [23:0] last_bus_address = 24'h000000;
    logic [15:0] held_bus_data = 16'h0000;
    logic [3:0] held_bus_status = 4'hF;
    logic held_bus_bhe_n = 1'b1, held_bus_write = 1'b0, held_bus_lock = 1'b0;
    integer stall_remaining = 0;
    integer bus_transactions = 0;
    integer cycles = 0;
    logic loaded_seen = 1'b0;
    logic unreal_access_seen = 1'b0;
    logic reset_injected = 1'b0, nmi_injected = 1'b0;
    logic hold_requested = 1'b0, hold_granted = 1'b0;
    integer hold_transaction_snapshot = 0;

    spk286 dut (.*);

    task automatic load_word(input logic [20:0] address_value, input logic [15:0] value);
        memory[address_value] = value[7:0];
        memory[address_value + 1] = value[15:8];
    endtask

    task automatic drive_bus_data;
        logic [23:0] aligned_address;
        begin
            data_in = 16'h0000;
            if (bus_valid) begin
                aligned_address = address & 24'hFFFFFE;
                if (aligned_address <= 24'h12FFFE)
                    data_in = {memory[21'(aligned_address + 24'd1)],
                               memory[21'(aligned_address)]};
            end
        end
    endtask

    task automatic tick;
        drive_bus_data();
        #5; clk = 1'b1; #5; clk = 1'b0; #1;
    endtask

    task automatic service_cycle;
        begin
            if (waiting_bus && (!bus_valid || address !== last_bus_address ||
                data_out !== held_bus_data || bus_status !== held_bus_status ||
                bus_bhe_n !== held_bus_bhe_n || bus_write !== held_bus_write ||
                bus_lock !== held_bus_lock))
                $fatal(1, "LOADALL READY wait changed bus transaction address=%h/%h status=%h/%h data=%h/%h",
                       address, last_bus_address, bus_status, held_bus_status, data_out, held_bus_data);
            if (bus_valid) begin
                if (!bus_seen || address !== last_bus_address) begin
                    bus_seen = 1'b1;
                    last_bus_address = address;
                    bus_transactions = bus_transactions + 1;
                    stall_remaining = (bus_transactions % 3) + 1;
                end
                if (stall_remaining != 0) begin
                    ready = 1'b0;
                    stall_remaining = stall_remaining - 1;
                end else ready = 1'b1;
                waiting_bus = !ready;
                if (waiting_bus) begin
                    held_bus_data = data_out;
                    held_bus_status = bus_status;
                    held_bus_bhe_n = bus_bhe_n;
                    held_bus_write = bus_write;
                    held_bus_lock = bus_lock;
                end
            end else begin
                ready = 1'b0;
                bus_seen = 1'b0;
                waiting_bus = 1'b0;
            end
            tick();
            if (!bus_valid) begin
                bus_seen = 1'b0;
                waiting_bus = 1'b0;
            end
        end
    endtask

    initial begin
        for (integer i = 0; i <= 24'h12FFFF; i = i + 1) memory[i] = 8'h00;

        // LOADALL is the complete instruction at the initial redirected IP.
        memory[21'(16'h0000)] = 8'h0F;
        memory[21'(16'h0001)] = 8'h05;

        // 80286 LOADALL image at physical 000800h.  Words not listed here
        // remain zero, including the reserved image gaps.
        load_word(21'h00806, 16'h0000); // MSW: remain in real mode
        load_word(21'h00816, 16'h1357); // TR selector
        load_word(21'h00818, 16'h0202); // FLAGS
        load_word(21'h0081A, 16'h0200); // IP
        load_word(21'h0081C, 16'h1111); // LDT selector
        load_word(21'h0081E, 16'h2222); // DS
        load_word(21'h00820, 16'h3333); // SS
        load_word(21'h00822, 16'h4444); // CS
        load_word(21'h00824, 16'h5555); // ES
        load_word(21'h00826, 16'h6161); // DI
        load_word(21'h00828, 16'h7171); // SI
        load_word(21'h0082A, 16'h8181); // BP
        load_word(21'h0082C, 16'h9191); // SP
        load_word(21'h0082E, 16'hA1A1); // BX
        load_word(21'h00830, 16'hB1B1); // DX
        load_word(21'h00832, 16'hC1C1); // CX
        load_word(21'h00834, 16'hD1D1); // AX

        // ES/CS/SS/DS six-byte cache records: base[23:0], access, limit.
        load_word(21'h00836, 16'h5678); load_word(21'h00838, 16'h9334); load_word(21'h0083A, 16'hABCD);
        load_word(21'h0083C, 16'h0000); load_word(21'h0083E, 16'h9A10); load_word(21'h00840, 16'hBCDE);
        load_word(21'h00842, 16'h4567); load_word(21'h00844, 16'hF023); load_word(21'h00846, 16'hCDEF);
        load_word(21'h00848, 16'h3456); load_word(21'h0084A, 16'h9212); load_word(21'h0084C, 16'hEF01);
        // GDTR, LDT cache, IDTR and TSS cache.
        load_word(21'h0084E, 16'hBCDE); load_word(21'h00850, 16'h000A); load_word(21'h00852, 16'hF0F0);
        load_word(21'h00854, 16'h2468); load_word(21'h00856, 16'h8220); load_word(21'h00858, 16'h1111);
        load_word(21'h0085A, 16'h1357); load_word(21'h0085C, 16'h0001); load_word(21'h0085E, 16'h2222);
        load_word(21'h00860, 16'h369C); load_word(21'h00862, 16'h8902); load_word(21'h00864, 16'h3333);

        // The loaded CS cache points at this instruction above 1 MiB.  The
        // loaded DS cache then supplies the physical address of its moffs16
        // operand, proving that this is hidden-cache translation, not a 386
        // address-size prefix.
        memory[21'(24'h100200)] = 8'hA1; memory[21'(24'h100201)] = 8'h40; memory[21'(24'h100202)] = 8'h00;
        load_word(21'h123496, 16'hCAFE);

        tick();
        reset = 1'b0;
        waiting_bus = 1'b0;

        // Start from a conventional real-mode CS:IP redirect, as the
        // execution harness does for every architectural instruction test.
        segment_load_en = 1'b1;
        segment_load_index = 2'd1;
        segment_load_selector = 16'h0000;
        ip_write_en = 1'b1;
        ip_write_data = 16'h0000;
        redirect = 1'b1;
        tick();
        segment_load_en = 1'b0;
        ip_write_en = 1'b0;
        redirect = 1'b0;
        execute_enable = 1'b1;

        for (cycles = 0; cycles < 12000 && !loaded_seen; cycles = cycles + 1) begin
            // Reset is injected only after the decoder has dispatched LOADALL,
            // so this is an in-flight image abort rather than a reset of the
            // ordinary fetch stream.
            if (!reset_injected && debug_micro_active &&
                debug_micro_entry == 12'(spk286_microcode_pkg::MC_ENTRY_LOADALL) &&
                bus_transactions >= 10) begin
                reset = 1'b1;
                execute_enable = 1'b0;
                hold_request = 1'b0;
                nmi = 1'b0;
                ready = 1'b0;
                waiting_bus = 1'b0;
                tick();
                if (bus_valid || hlda || debug_ip !== 16'hFFF0 ||
                    debug_cs_base !== 24'hFF0000 || debug_flags !== 16'h0002)
                    $fatal(1, "LOADALL reset did not restore reset boundary IP=%h CSbase=%h FLAGS=%h bus=%b hlda=%b",
                           debug_ip, debug_cs_base, debug_flags, bus_valid, hlda);
                reset = 1'b0;
                segment_load_en = 1'b1;
                segment_load_index = 2'd1;
                segment_load_selector = 16'h0000;
                ip_write_en = 1'b1;
                ip_write_data = 16'h0000;
                redirect = 1'b1;
                tick();
                segment_load_en = 1'b0;
                ip_write_en = 1'b0;
                redirect = 1'b0;
                execute_enable = 1'b1;
                reset_injected = 1'b1;
                bus_seen = 1'b0;
                waiting_bus = 1'b0;
                stall_remaining = 0;
            end
            if (reset_injected && !nmi_injected && debug_micro_active &&
                debug_micro_entry == 12'(spk286_microcode_pkg::MC_ENTRY_LOADALL) &&
                bus_transactions >= 10)
                nmi = 1'b1;
            service_cycle();
            if (nmi) begin
                nmi = 1'b0;
                nmi_injected = 1'b1;
            end
            if (!loaded_seen && event_completed)
                $fatal(1, "LOADALL accepted/completed an event before image commit vector=%0d", debug_event_vector);
            if (debug_cs === 16'h4444 &&
                debug_segment_bases[47:24] === 24'h100000 &&
                debug_gpr[15:0] === 16'hD1D1 &&
                debug_gpr[112 +: 16] === 16'h6161) begin
                loaded_seen = 1'b1;
                // Freeze immediately after the atomic commit, before the
                // newly loaded IP can dispatch the next instruction.
                execute_enable = 1'b0;
            end
            if (nmi_injected && !loaded_seen && !debug_nmi_pending)
                $fatal(1, "NMI edge was not retained while LOADALL was active");
            if (reset_injected && nmi_injected && !hold_requested &&
                debug_micro_active &&
                debug_micro_entry == 12'(spk286_microcode_pkg::MC_ENTRY_LOADALL) &&
                bus_transactions >= 12) begin
                hold_request = 1'b1;
                hold_requested = 1'b1;
            end
            if (hold_requested && hlda && !hold_granted) begin
                hold_granted = 1'b1;
                hold_transaction_snapshot = bus_transactions;
                if (bus_valid)
                    $fatal(1, "HLDA asserted with an active LOADALL bus transaction");
                repeat (3) begin
                    service_cycle();
                    if (bus_valid)
                        $fatal(1, "HLDA exposed a bus transaction while HOLD remained asserted");
                end
                if (bus_transactions !== hold_transaction_snapshot)
                    $fatal(1, "HLDA changed physical transaction count %0d -> %0d",
                           hold_transaction_snapshot, bus_transactions);
                hold_request = 1'b0;
                service_cycle();
                if (hlda)
                    $fatal(1, "HLDA did not release after HOLD was withdrawn");
            end
        end
        ready = 1'b0;
        if (!loaded_seen) $fatal(1, "LOADALL did not commit after %0d cycles", cycles);
        if (!reset_injected || !nmi_injected || !hold_requested || !hold_granted ||
            !debug_nmi_pending || event_completed)
            $fatal(1, "LOADALL lifecycle controls reset=%b nmi=%b hold=%b/%b pending=%b event=%b",
                   reset_injected, nmi_injected, hold_requested, hold_granted,
                   debug_nmi_pending, event_completed);
        if (debug_protected_msw !== 16'h0000 || debug_ip !== 16'h0200 || debug_flags !== 16'h0202 ||
            debug_cs !== 16'h4444 || debug_cs_base !== 24'h100000 ||
            debug_segment_selectors !== 64'h2222333344445555 ||
            debug_segment_bases !== 96'h123456234567100000345678 ||
            debug_segment_limits !== 64'hEF01CDEFBCDEABCD ||
            debug_segment_access !== 32'h92F09A93 ||
            debug_gpr !== 128'h6161717181819191A1A1B1B1C1C1D1D1 ||
            debug_gdtr_base !== 24'h0ABCDE || debug_gdtr_limit !== 16'hF0F0 ||
            debug_idtr_base !== 24'h011357 || debug_idtr_limit !== 16'h2222 ||
            debug_ldtr_selector !== 16'h1111 || debug_ldtr_base !== 24'h202468 ||
            debug_ldtr_limit !== 16'h1111 || debug_tr_selector !== 16'h1357 ||
            debug_tr_base !== 24'h02369C || debug_tr_limit !== 16'h3333 || unsupported_opcode)
            $fatal(1, "LOADALL architectural commit state CS=%h/%h IP=%h FLAGS=%h GPR=%h", debug_cs, debug_cs_base, debug_ip, debug_flags, debug_gpr);

        execute_enable = 1'b1;
        unreal_access_seen = 1'b0;
        for (cycles = 0; cycles < 4000 && !unreal_access_seen; cycles = cycles + 1) begin
            service_cycle();
            if (debug_ip === 16'h0203 && debug_gpr[15:0] === 16'hCAFE)
                unreal_access_seen = 1'b1;
        end
        if (!unreal_access_seen || unsupported_opcode || debug_gpr[15:0] !== 16'hCAFE)
            $fatal(1, "LOADALL hidden-cache access failed IP=%h AX=%h CSbase=%h DSbase=%h",
                   debug_ip, debug_gpr[15:0], debug_cs_base, debug_segment_bases[95:72]);
        if (bus_transactions < 51) $fatal(1, "LOADALL physical image bus count=%0d", bus_transactions);
        $display("LOADALL_INTEGRATION PASS: atomic 102-byte image commit and >1MiB hidden-cache access after %0d bus transactions", bus_transactions);
        $finish;
    end
endmodule
