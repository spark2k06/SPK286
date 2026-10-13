// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

// Pin-level bench for spk286_native (docs/NATIVE_BUS.md). A small program runs
// through the 80286 pins against a memory/I/O model with random wait states.
// An independent processor-clock monitor checks the T-state sequence, status
// and byte-lane encodings, the INTA LOCK# chain, HOLD/HLDA floating, the halt
// cycle and reset pin states, then the program results in memory.
module spk286_native_tb;
    logic clk = 1'b0, reset = 1'b1;
    logic ready_n = 1'b1, hold = 1'b0, intr = 1'b0;
    logic [15:0] d_in = 16'hDEAD;
    wire [23:0] a;
    wire bhe_n, s1_n, s0_n, m_io, cod_inta_n, bus_oe;
    wire [15:0] d_out;
    wire d_oe, lock_n, hlda, peack_n, halted, shutdown;

    spk286_native dut (
        .clk(clk), .reset(reset), .timing_policy(2'd0),
        .a(a), .bhe_n(bhe_n), .s1_n(s1_n), .s0_n(s0_n), .m_io(m_io),
        .cod_inta_n(cod_inta_n), .bus_oe(bus_oe),
        .d_in(d_in), .d_out(d_out), .d_oe(d_oe), .lock_n(lock_n),
        .ready_n(ready_n), .hold(hold), .hlda(hlda), .intr(intr), .nmi(1'b0),
        .pereq(1'b0), .busy_n(1'b1), .error_n(1'b1), .peack_n(peack_n),
        .halted(halted), .shutdown(shutdown)
    );

    always #5 clk = ~clk;

    localparam int M_IDLE = 0, M_COMMAND = 1;
    localparam logic [7:0] VECTOR = 8'h20;

    logic [7:0] rom [0:65535];
    logic [7:0] ram [0:65535];
    integer checks = 0, edge_index = 0, pclk = 0, mon_state = M_IDLE;
    integer cycles = 0, zero_wait_cycles = 0, waited_cycles = 0, waits_left = 0, waits_used = 0;
    integer inta_count = 0, halt_count = 0, io_reads = 0, io_writes = 0, hlda_grants = 0;
    integer hold_clocks = 0, hold_requested_at = -1, done_at = -1, unannounced_halt = 0;
    logic ready_level = 1'b1, first_cycle = 1'b1, chain_active = 1'b0, chain_seen = 1'b0;
    logic expect_odd_high = 1'b0, odd_word_seen = 1'b0, release_seen = 1'b0, halt_announced = 1'b0;
    logic [3:0] cur_status;
    logic [23:0] cur_a;
    logic cur_bhe_n;
    logic [15:0] cur_wdata, lfsr = 16'hACE1;
    // Phase-1 snapshot and previous processor clock of every pin output.
    logic [23:0] p1_a, prev_a = 24'hFFFFFF;
    logic [15:0] p1_d_out;
    logic [10:0] p1_ctl;
    logic prev_bus_oe = 1'b1, prev_hlda = 1'b0, prev_passive = 1'b1, prev_bhe_n = 1'b1;
    logic [1:0] prev_cycle_type = 2'b11;

    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1)
            $fatal(1, "%s pclk=%0d a=%h status=%b%b%b%b bhe_n=%b oe=%b d_oe=%b lock_n=%b hlda=%b",
                   message, pclk, a, cod_inta_n, m_io, s1_n, s0_n, bhe_n, bus_oe, d_oe, lock_n, hlda);
    endtask

    function automatic logic [10:0] controls();
        controls = {bhe_n, s1_n, s0_n, m_io, cod_inta_n, bus_oe, d_oe, lock_n, hlda, peack_n, 1'b0};
    endfunction

    function automatic logic [7:0] mem(input logic [23:0] address);
        if (address[23:16] == 8'hFF) mem = rom[address[15:0]];
        else if (address[23:16] == 8'h00) mem = ram[address[15:0]];
        else mem = 8'h00;
    endfunction

    // Read data on the lanes selected by BHE#/A0; the idle lane carries noise.
    function automatic logic [15:0] read_value(input logic [3:0] status, input logic [23:0] address,
                                               input logic bhe);
        logic [7:0] value;
        if (status == 4'h0) return inta_count == 1 ? {8'hEE, VECTOR} : 16'h1111;
        if (status == 4'h9) value = address[15:0] == 16'h0061 ? 8'hA5 : 8'hFF;
        else value = mem(address);
        if (!bhe && !address[0] && status != 4'h9) return {mem(address + 24'd1), value};
        if (address[0]) return {value, 8'h5C};
        return {8'hC5, value};
    endfunction

    task automatic load_program;
        integer i;
        for (i = 0; i < 65536; i = i + 1) begin
            rom[i] = 8'h00;
            ram[i] = 8'h00;
        end
        // FFFFF0: JMP FAR 0000:0100
        rom[16'hFFF0] = 8'hEA; rom[16'hFFF1] = 8'h00; rom[16'hFFF2] = 8'h01;
        rom[16'hFFF3] = 8'h00; rom[16'hFFF4] = 8'h00;
        // Vector 20h -> 0000:0180
        ram[16'h0080] = 8'h80; ram[16'h0081] = 8'h01;
        ram[16'h0082] = 8'h00; ram[16'h0083] = 8'h00;
        // 0100: MOV AX,1234h; MOV [0200h],AX; MOV [0301h],AX; MOV BX,[0200h];
        //       MOV [0206h],BX; OUT 60h,AL; IN AL,61h; MOV [0204h],AL;
        //       MOV SP,1000h; STI; HLT; HLT
        ram[16'h0100] = 8'hB8; ram[16'h0101] = 8'h34; ram[16'h0102] = 8'h12;
        ram[16'h0103] = 8'hA3; ram[16'h0104] = 8'h00; ram[16'h0105] = 8'h02;
        ram[16'h0106] = 8'hA3; ram[16'h0107] = 8'h01; ram[16'h0108] = 8'h03;
        ram[16'h0109] = 8'h8B; ram[16'h010A] = 8'h1E; ram[16'h010B] = 8'h00; ram[16'h010C] = 8'h02;
        ram[16'h010D] = 8'h89; ram[16'h010E] = 8'h1E; ram[16'h010F] = 8'h06; ram[16'h0110] = 8'h02;
        ram[16'h0111] = 8'hE6; ram[16'h0112] = 8'h60;
        ram[16'h0113] = 8'hE4; ram[16'h0114] = 8'h61;
        ram[16'h0115] = 8'hA2; ram[16'h0116] = 8'h04; ram[16'h0117] = 8'h02;
        ram[16'h0118] = 8'hBC; ram[16'h0119] = 8'h00; ram[16'h011A] = 8'h10;
        ram[16'h011B] = 8'hFB;
        ram[16'h011C] = 8'hF4;
        ram[16'h011D] = 8'hF4;
        // 0180: MOV BYTE [0220h],5Ah; HLT
        ram[16'h0180] = 8'hC6; ram[16'h0181] = 8'h06; ram[16'h0182] = 8'h20;
        ram[16'h0183] = 8'h02; ram[16'h0184] = 8'h5A;
        ram[16'h0185] = 8'hF4;
    endtask

    task automatic write_lanes;
        check(cur_a[23:16] == 8'h00, "memory writes stay in the RAM model");
        if (!cur_bhe_n && !cur_a[0]) begin
            ram[cur_a[15:0]] = cur_wdata[7:0];
            ram[cur_a[15:0] + 16'd1] = cur_wdata[15:8];
        end else if (!cur_bhe_n) ram[cur_a[15:0]] = cur_wdata[15:8];
        else ram[cur_a[15:0]] = cur_wdata[7:0];
    endtask

    task automatic complete_cycle;
        if (waits_used == 0) zero_wait_cycles = zero_wait_cycles + 1;
        else waited_cycles = waited_cycles + 1;
        case (cur_status)
            4'h6: begin
                if (expect_odd_high) begin
                    check(cur_a == 24'h000302 && cur_bhe_n && cur_wdata[7:0] == 8'h12,
                          "odd word continues with A=N+1 on the low lane");
                    expect_odd_high = 1'b0;
                    odd_word_seen = 1'b1;
                end
                if (cur_a == 24'h000301) begin
                    check(!cur_bhe_n && cur_wdata[15:8] == 8'h34, "odd word starts on the high lane");
                    expect_odd_high = 1'b1;
                end
                write_lanes();
                if (chain_active) chain_active = 1'b0;
            end
            4'h9: begin
                check(cur_a == 24'h000061 && !cur_bhe_n, "IN 61h is an odd-port byte read");
                io_reads = io_reads + 1;
            end
            4'hA: begin
                check(cur_a == 24'h000060 && cur_bhe_n && cur_wdata[7:0] == 8'h34,
                      "OUT 60h writes AL on the low lane");
                io_writes = io_writes + 1;
            end
            4'h0: begin
                check(cur_a == 24'h000000, "INTA drives address 0");
                inta_count = inta_count + 1;
                if (inta_count == 2) intr <= 1'b0;
            end
            4'h4: begin
                check(cur_a == 24'h000002 && cur_bhe_n && !shutdown, "HLT issues a halt cycle with A1 set");
                halt_count = halt_count + 1;
                halt_announced = 1'b1;
                if (halt_count == 1) intr <= 1'b1;
                if (halt_count == 2) done_at = pclk;
            end
            default: ;
        endcase
    endtask

    // Called once per processor clock, at its closing CLK edge.
    task automatic process_clock;
        logic active;
        pclk = pclk + 1;
        active = bus_oe && (!s1_n || !s0_n);
        check(peack_n, "PEACK# stays inactive");
        check(!shutdown, "the program never shuts down");
        if (!bus_oe) check(!d_oe && !active, "a floated bus carries no cycle or data");
        if (hlda) check(!bus_oe, "the bus floats while HLDA is high");
        if (hlda && !prev_hlda) begin
            check(!prev_bus_oe, "the bus floats one processor clock before HLDA");
            hlda_grants = hlda_grants + 1;
        end
        if (!hlda && prev_hlda) check(!bus_oe, "HLDA falls before the bus is driven again");
        if (bus_oe && !prev_bus_oe) begin
            check(!active && !prev_hlda, "the bus returns passive after HLDA falls");
            release_seen = 1'b1;
        end
        if (chain_active) check(!lock_n, "LOCK# covers the INTA pair and the first push");
        if (!halted) halt_announced = 1'b0;
        unannounced_halt = halted && !halt_announced ? unannounced_halt + 1 : 0;
        check(unannounced_halt < 12, "a halted core shows its halt cycle promptly");

        case (mon_state)
            M_IDLE: begin
                check(!d_oe, "data floats outside Tc");
                if (active) begin
                    cur_status = {cod_inta_n, m_io, s1_n, s0_n};
                    cur_a = a;
                    cur_bhe_n = bhe_n;
                    check(prev_bus_oe && prev_passive && prev_a == a && prev_bhe_n == bhe_n &&
                          prev_cycle_type == {cod_inta_n, m_io},
                          "address and cycle type are valid one processor clock before Ts");
                    check(cur_status == 4'h0 || cur_status == 4'h4 || cur_status == 4'h5 ||
                          cur_status == 4'h6 || cur_status == 4'h9 || cur_status == 4'hA ||
                          cur_status == 4'hD, "status uses a defined 80286 encoding");
                    if (cur_status != 4'h0 && cur_status != 4'h4)
                        check(!(bhe_n && a[0]), "BHE#/A0 select at least one lane");
                    if (first_cycle)
                        check(cur_status == 4'hD && a == 24'hFFFFF0 && !bhe_n,
                              "the first cycle fetches the reset vector word");
                    first_cycle = 1'b0;
                    if (cur_status == 4'h0 && !chain_seen) begin
                        chain_active = 1'b1;
                        chain_seen = 1'b1;
                    end
                    if (!chain_active) check(lock_n, "LOCK# is inactive outside the INTA chain");
                    else check(!lock_n, "LOCK# is active at Ts in the INTA chain");
                    cycles = cycles + 1;
                    lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
                    waits_left = lfsr[1:0] == 2'b11 ? 0 : {30'd0, lfsr[1:0]};
                    waits_used = 0;
                    ready_level = waits_left == 0 ? 1'b0 : 1'b1;
                    ready_n <= ready_level;
                    if (cur_status == 4'h5 || cur_status == 4'hD || cur_status == 4'h9 ||
                        cur_status == 4'h0)
                        d_in <= read_value(cur_status, a, bhe_n);
                    mon_state = M_COMMAND;
                end
            end
            M_COMMAND: begin
                check(!active && bus_oe && a == cur_a && bhe_n == cur_bhe_n &&
                      {cod_inta_n, m_io} == cur_status[3:2], "Tc keeps status passive and the address held");
                if (cur_status == 4'h6 || cur_status == 4'hA) begin
                    if (waits_used == 0) cur_wdata = d_out;
                    check(d_oe && d_out == cur_wdata, "write data is driven and stable through Tc");
                end else check(!d_oe, "reads leave the data bus to the system");
                if (!ready_level) begin
                    complete_cycle();
                    ready_level = 1'b1;
                    ready_n <= 1'b1;
                    d_in <= 16'hDEAD ^ pclk[15:0];
                    mon_state = M_IDLE;
                end else begin
                    waits_left = waits_left - 1;
                    waits_used = waits_used + 1;
                    ready_level = waits_left == 0 ? 1'b0 : 1'b1;
                    ready_n <= ready_level;
                end
            end
            default: ;
        endcase

        // HOLD once during the main program, released four clocks after HLDA.
        if (cycles == 10 && hold_requested_at < 0) begin
            hold <= 1'b1;
            hold_requested_at = pclk;
        end
        if (hold && hlda) begin
            hold_clocks = hold_clocks + 1;
            if (hold_clocks == 4) hold <= 1'b0;
        end
        if (hold && !hlda) check(pclk - hold_requested_at < 40, "HOLD is granted promptly");

        prev_bus_oe = bus_oe;
        prev_hlda = hlda;
        prev_passive = s1_n && s0_n;
        prev_a = a;
        prev_bhe_n = bhe_n;
        prev_cycle_type = {cod_inta_n, m_io};
    endtask

    // The adapter relies on the core keeping an offered transaction unchanged
    // until READY (docs/NATIVE_BUS.md, section 6).
    always @(posedge clk) begin
        if (!dut.reset_q && ((dut.state_q >= 3'd1 && dut.state_q <= 3'd3 && !dut.halt_cycle_q) ||
                             dut.notify_q))
            check(dut.core_bus_valid && dut.core_address == dut.a && dut.core_bhe_n == dut.bhe_n &&
                  dut.core_status == {dut.cod_inta_n, dut.m_io, dut.status_q} && dut.core_bus_write == dut.write_q &&
                  (!dut.write_q || dut.core_data_out == dut.d_out),
                  "the core holds its offered transaction until READY");
    end

    always @(posedge clk) begin
        if (reset) edge_index <= 0;
        else begin
            edge_index <= edge_index + 1;
            // edge_index + 1 numbers this edge; odd edges start a processor clock.
            if ((edge_index + 1) % 2 == 0) begin
                p1_a = a;
                p1_d_out = d_out;
                p1_ctl = controls();
            end else if (edge_index + 1 >= 3) begin
                check(a == p1_a && d_out == p1_d_out && controls() == p1_ctl,
                      "pins change only where a processor clock begins");
                process_clock();
            end
        end
    end

    initial begin
        load_program();
        repeat (20) @(posedge clk);
        check(a == 24'hFFFFFF && bhe_n && s1_n && s0_n && m_io && cod_inta_n && bus_oe &&
              !d_oe && lock_n && !hlda && peack_n, "reset pin states");
        @(negedge clk);
        reset = 1'b0;
        wait (done_at >= 0);
        wait (pclk >= done_at + 30);
        @(posedge clk);
        check(mon_state == M_IDLE, "the bus is idle after the final halt");
        check(halted && halt_count == 2, "exactly one halt cycle per HLT");
        check(inta_count == 2, "one INTA pair");
        check(io_writes == 1 && io_reads == 1, "one OUT and one IN cycle");
        check(odd_word_seen, "the odd word was written as two ordered byte cycles");
        check(hlda_grants == 1 && release_seen, "HOLD was granted and released once");
        check(zero_wait_cycles > 0 && waited_cycles > 0, "both zero-wait and waited cycles ran");
        check({ram[16'h0201], ram[16'h0200]} == 16'h1234, "MOV [0200h],AX");
        check(ram[16'h0301] == 8'h34 && ram[16'h0302] == 8'h12, "MOV [0301h],AX");
        check({ram[16'h0207], ram[16'h0206]} == 16'h1234, "MOV BX,[0200h]; MOV [0206h],BX");
        check(ram[16'h0204] == 8'hA5, "IN AL,61h; MOV [0204h],AL");
        check(ram[16'h0220] == 8'h5A, "the INTR handler ran");
        check({ram[16'h0FFB], ram[16'h0FFA]} == 16'h011D, "INTR return IP follows the HLT");
        check({ram[16'h0FFD], ram[16'h0FFC]} == 16'h0000, "INTR pushes CS");
        check(ram[16'h0FFF][1], "INTR pushes FLAGS with IF set");
        $display("SPK286_NATIVE_PASS checks%0d cycles%0d waited%0d pclk%0d", checks, cycles,
                 waited_cycles, pclk);
        $finish;
    end

    initial begin
        #400000;
        $fatal(1, "native bench timeout pclk=%0d cycles=%0d halts=%0d", pclk, cycles, halt_count);
    end
endmodule
