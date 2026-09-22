`timescale 1ns/1ps

module spk286_loadall_protected_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer cycles = 0;
    integer bus_transactions = 0;
    logic protected_load_seen = 1'b0;

    spk286 dut (.*);

    task automatic load_word(input logic [15:0] address_value, input logic [15:0] value);
        memory[address_value] = value[7:0];
        memory[address_value + 1] = value[15:8];
    endtask

    task automatic drive_bus;
        begin
            ready = bus_valid && ((cycles % 4) != 1);
            data_in = 16'h0000;
            if (bus_valid && !bus_write) begin
                if (bus_status == 4'h0) data_in = 16'h0022;
                else if (address[0]) data_in = {memory[address[15:0]], 8'h00};
                else if (bus_bhe_n) data_in = {8'h00, memory[address[15:0]]};
                else data_in = {memory[address[15:0] + 16'd1], memory[address[15:0]]};
            end
            if (bus_valid && ready && bus_write && bus_status == 4'h6) begin
                if (address[0]) memory[address[15:0]] = data_out[15:8];
                else begin
                    memory[address[15:0]] = data_out[7:0];
                    if (!bus_bhe_n) memory[address[15:0] + 16'd1] = data_out[15:8];
                end
            end
            if (bus_valid && ready) bus_transactions = bus_transactions + 1;
            #4; clk = 1'b1; #5; clk = 1'b0; #1;
            cycles = cycles + 1;
        end
    endtask

    task automatic tick;
        begin
            drive_bus();
        end
    endtask

    task automatic far_restart(input logic [15:0] cs, input logic [15:0] ip);
        begin
            segment_load_en = 1'b1;
            segment_load_index = 2'd1;
            segment_load_selector = cs;
            ip_write_en = 1'b1;
            ip_write_data = ip;
            redirect = 1'b1;
            tick();
            segment_load_en = 1'b0;
            ip_write_en = 1'b0;
            redirect = 1'b0;
        end
    endtask

    task automatic wait_event(input logic [7:0] expected_vector);
        integer deadline;
        begin
            deadline = 0;
            while ((!event_completed || debug_event_vector != expected_vector) && deadline < 1200) begin
                tick();
                deadline = deadline + 1;
            end
            if (!event_completed || debug_event_vector != expected_vector)
                $fatal(1, "LOADALL protected event timeout vector=%h expected=%h IP=%h CS=%h opcode=%h bus=%h",
                       debug_event_vector, expected_vector, debug_ip, debug_cs, debug_opcode, bus_status);
        end
    endtask

    initial begin
        for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;

        // First LOADALL is entered from real mode. Its image enables PE and
        // installs a complete CPL=1 execution context. The next instruction
        // is another LOADALL, which must then fail the protected CPL check.
        memory[16'h0000] = 8'h0F;
        memory[16'h0001] = 8'h05;
        load_word(16'h0806, 16'h0001); // MSW: protected mode
        load_word(16'h0818, 16'h0202); // FLAGS
        load_word(16'h081A, 16'h0200); // IP of the second LOADALL
        load_word(16'h081E, 16'h0019); // DS, GDT index 3, RPL 1
        load_word(16'h0820, 16'h0011); // SS, GDT index 2, RPL 1
        load_word(16'h0822, 16'h0009); // CS, GDT index 1, RPL 1
        load_word(16'h0824, 16'h0019); // ES
        load_word(16'h082C, 16'h0400); // SP

        // ES/CS/SS/DS hidden records. Base zero, 80286 limits, DPL 1.
        load_word(16'h0836, 16'h0000); load_word(16'h0838, 16'hB200); load_word(16'h083A, 16'hFFFF);
        load_word(16'h083C, 16'h0000); load_word(16'h083E, 16'hBA00); load_word(16'h0840, 16'h03FF);
        load_word(16'h0842, 16'h0000); load_word(16'h0844, 16'hB200); load_word(16'h0846, 16'h03FF);
        load_word(16'h0848, 16'h0000); load_word(16'h084A, 16'hB200); load_word(16'h084C, 16'hFFFF);
        load_word(16'h084E, 16'h1000); load_word(16'h0850, 16'h0000); load_word(16'h0852, 16'h001F);
        load_word(16'h085A, 16'h2000); load_word(16'h085C, 16'h0000); load_word(16'h085E, 16'h006F);

        // GDT index 1: present DPL-1 readable code; index 2/3: DPL-1 data.
        load_word(16'h1008, 16'h03FF); load_word(16'h100A, 16'h0000); load_word(16'h100C, 16'h0000);
        memory[16'h100D] = 8'hBA; memory[16'h100E] = 8'h00; memory[16'h100F] = 8'h00;
        load_word(16'h1010, 16'hFFFF); load_word(16'h1012, 16'h0000); load_word(16'h1014, 16'h0000);
        load_word(16'h1016, 16'h0000); load_word(16'h1018, 16'hB200); load_word(16'h101A, 16'h0000);

        // IDT vector 13: same-level DPL-1 interrupt gate to 0009:0100.
        load_word(16'h2068, 16'h0100); load_word(16'h206A, 16'h0009);
        memory[16'h206C] = 8'h00; memory[16'h206D] = 8'h86;
        load_word(16'h206E, 16'h0000);

        // If the test accidentally runs past event entry, stop in the handler
        // rather than re-executing the faulting LOADALL indefinitely.
        memory[16'h0100] = 8'hF4;
        memory[16'h0200] = 8'h0F;
        memory[16'h0201] = 8'h05;

        tick();
        reset = 1'b0;
        far_restart(16'h0000, 16'h0000);
        execute_enable = 1'b1;

        for (cycles = 0; cycles < 1200 && !protected_load_seen; cycles = cycles + 1) begin
            tick();
            if (debug_protected_msw === 16'h0001 && debug_cs === 16'h0009 && debug_ip === 16'h0200)
                protected_load_seen = 1'b1;
        end
        if (!protected_load_seen)
            $fatal(1, "initial LOADALL did not enter protected CPL1 context");

        wait_event(8'd13);
        execute_enable = 1'b0;
        ready = 1'b0;

        if (debug_event_kind !== 3'd1 || debug_cs !== 16'h0009 || debug_ip !== 16'h0100 ||
            debug_protected_msw !== 16'h0001 || debug_gpr[79:64] !== 16'h03F8)
            $fatal(1, "LOADALL #GP entry context kind=%h CS=%h IP=%h MSW=%h SP=%h",
                   debug_event_kind, debug_cs, debug_ip, debug_protected_msw, debug_gpr[79:64]);
        if ({memory[16'h03FF], memory[16'h03FE]} !== 16'h0202 ||
            {memory[16'h03FD], memory[16'h03FC]} !== 16'h0009 ||
            {memory[16'h03FB], memory[16'h03FA]} !== 16'h0200 ||
            {memory[16'h03F9], memory[16'h03F8]} !== 16'h0000)
            $fatal(1, "LOADALL #GP frame flags=%h cs=%h ip=%h error=%h",
                   {memory[16'h03FF], memory[16'h03FE]}, {memory[16'h03FD], memory[16'h03FC]},
                   {memory[16'h03FB], memory[16'h03FA]}, {memory[16'h03F9], memory[16'h03F8]});

        $display("LOADALL_PROTECTED PASS: LOADALL CPL1 #GP(0) delivered with saved CS:IP and error frame after %0d bus transactions", bus_transactions);
        $finish;
    end
endmodule
