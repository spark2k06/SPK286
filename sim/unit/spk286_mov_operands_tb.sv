// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module spk286_mov_operands_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:1114111];
    logic [127:0] initial_gpr, expected_gpr;
    logic [63:0] saved_selectors, saved_limits;
    logic [95:0] saved_bases;
    logic [31:0] saved_access;
    integer checks = 0, cases = 0, retirements = 0, data_cycles = 0;
    integer cycle_count = 0, wait_count = 0, wait_length = 0;
    integer reg_cases = 0, mem_cases = 0, data_waits = 0, coexist_cycles = 0;
    integer target_address, target_offset, expected_cycles, instruction_length;
    integer source_index, destination_index, displacement_value;
    integer code_start, address_register;
    logic [15:0] expected_value, disp;
    logic expect_write, expect_data, waiting;
    logic [23:0] held_address;
    logic [15:0] held_data;
    logic [3:0] held_status;
    logic held_bhe, held_write;
    spk286 dut (.*);

    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1)
            $fatal(1, "%s case=%0d opcode=%h modrm=%h IP=%h EA=%h seg=%d pc=%h bus=%h/%h data=%h cycles=%d",
                   message, cases, debug_opcode, debug_modrm, debug_ip, debug_effective_offset,
                   debug_operand_segment, debug_micro_pc, bus_status, address, data_out, data_cycles);
    endtask
    task automatic tick;
        #1;
        data_in = 16'h0F0F;
        if (bus_valid && address < 24'd1114112)
            data_in = {memory[{address[20:1], 1'b1}], memory[{address[20:1], 1'b0}]};
        // Poison inactive lanes; only selected lanes may affect a logical operand.
        if (bus_valid && address[0]) data_in[7:0] = 8'hE7;
        if (bus_valid && bus_bhe_n) data_in[15:8] = 8'hC3;
        #4;
        if (bus_valid && ready && !reset && (bus_status == 5 || bus_status == 6)) begin
            check(expect_data, "unexpected data access / register-direct must not access memory");
            check(bus_write == expect_write && data_oe == expect_write, "data direction");
            check(int'(address) == target_address + (data_cycles == 1 ? 1 : 0), "physical data address/order");
            check(bus_bhe_n == (data_cycles == 1), "word/split byte lanes");
            if (expect_write) begin
                if (address[0]) begin
                    check(data_out[15:8] == expected_value[7:0], "odd first write lane");
                    memory[address[20:0]] = data_out[15:8];
                end else begin
                    check(data_out[7:0] == (data_cycles == 1 ? expected_value[15:8] : expected_value[7:0]), "low write lane");
                    memory[address[20:0]] = data_out[7:0];
                    if (!bus_bhe_n) begin
                        check(data_out[15:8] == expected_value[15:8], "aligned high write lane");
                        memory[address+1] = data_out[15:8];
                    end
                end
            end
            data_cycles = data_cycles + 1;
            check(data_cycles <= expected_cycles, "no duplicate physical data transfer");
        end
        clk = 1; #5; clk = 0; #1;
        cycle_count = cycle_count + 1;
        if (instruction_retired) retirements = retirements + 1;
        check(debug_prefetch_count <= 6 && !microcode_fault, "queue bounds / microcode validity");
    endtask
    task automatic service;
        #1;
        if (waiting) check(bus_valid && address == held_address && data_out == held_data &&
                           bus_status == held_status && bus_bhe_n == held_bhe && bus_write == held_write,
                           "READY holds transaction including arbitration owner");
        ready = bus_valid && wait_count >= wait_length;
        waiting = bus_valid && !ready;
        if (waiting) begin
            held_address = address; held_data = data_out; held_status = bus_status;
            held_bhe = bus_bhe_n; held_write = bus_write;
            wait_count = wait_count + 1;
            if (bus_status == 5 || bus_status == 6) data_waits = data_waits + 1;
        end else wait_count = 0;
        if ((bus_status == 5 || bus_status == 6) && debug_prefetch_count > 0) begin
            coexist_cycles = coexist_cycles + 1;
            check(!dut.queue_flush, "ordinary data access preserves queued stream");
        end
        tick();
    endtask
    task automatic setup(input logic [15:0] ip, input logic high_segment);
        execute_enable = 0; reset = 1; ready = 0;
        gpr_write_en = 0; flags_write_en = 0; segment_load_en = 0;
        ip_write_en = 0; redirect = 0; gpr_write_byte = 0;
        waiting = 0; wait_count = 0; tick(); reset = 0;
        initial_gpr = {16'h0035,16'hF007,16'h2345,16'hBEED,16'hFFFC,16'h2468,16'h1357,16'hAA55};
        for (integer r = 0; r < 8; r = r + 1) begin
            gpr_write_en = 1; gpr_write_index = 3'(r); gpr_write_data = initial_gpr[r*16 +: 16]; tick();
        end
        gpr_write_en = 0;
        flags_write_en = 1; flags_write_mask = 16'hFFFF; flags_write_data = 16'h7ED7; tick(); flags_write_en = 0;
        for (integer s = 0; s < 4; s = s + 1) begin
            segment_load_en = 1; segment_load_index = 2'(s);
            case (s)
                0: segment_load_selector = 16'h2000;
                1: segment_load_selector = 16'h1000;
                2: segment_load_selector = 16'h8000;
                3: segment_load_selector = high_segment ? 16'hFFFF : 16'h4000;
                default: $fatal(1, "test segment");
            endcase
            redirect = s == 1; ip_write_en = s == 1; ip_write_data = ip; tick();
        end
        segment_load_en = 0; redirect = 0; ip_write_en = 0;
        expected_gpr = initial_gpr;
        saved_selectors = debug_segment_selectors; saved_bases = debug_segment_bases;
        saved_limits = debug_segment_limits; saved_access = debug_segment_access;
        data_cycles = 0; retirements = 0; execute_enable = 1;
    endtask
    task automatic run_to_retire;
        integer timeout_count;
        timeout_count = 0;
        if (instruction_retired) service();
        while (!instruction_retired && timeout_count < 500) begin
            service(); timeout_count = timeout_count + 1;
            check(!unsupported_opcode && !operand_blocked, "supported instruction runs");
        end
        check(instruction_retired, "bounded retirement");
        check(debug_gpr == expected_gpr && debug_flags == 16'h7ED7, "exact GPR/FLAGS result and preservation");
        check(debug_segment_selectors == saved_selectors && debug_segment_bases == saved_bases &&
              debug_segment_limits == saved_limits && debug_segment_access == saved_access, "all segment state preserved");
        check(data_cycles == expected_cycles, "exact physical transfer count");
    endtask
    function automatic integer reference_base(input integer rm);
        case (rm)
            0: reference_base = 65532 + 61447;
            1: reference_base = 65532 + 53;
            2: reference_base = 9029 + 61447;
            3: reference_base = 9029 + 53;
            4: reference_base = 61447;
            5: reference_base = 53;
            6: reference_base = 9029;
            7: reference_base = 65532;
            default: reference_base = 0;
        endcase
    endfunction
    initial begin
        // Only initialize the code region; operand bytes/guards are explicit per case.
        for (integer a = 65536; a < 69632; a = a + 1) memory[a] = 8'h0F;
        for (integer direction = 0; direction < 2; direction = direction + 1)
            for (integer r = 0; r < 8; r = r + 1)
                for (integer rm = 0; rm < 8; rm = rm + 1) begin
                    memory[65792] = direction == 0 ? 8'h89 : 8'h8B;
                    memory[65793] = 8'(192 + r*8 + rm); memory[65794] = 8'h0F;
                    wait_length = (r + rm) % 4;
                    setup(16'h0100, 0);
                    source_index = direction == 0 ? r : rm; destination_index = direction == 0 ? rm : r;
                    expected_gpr[destination_index*16 +: 16] = initial_gpr[source_index*16 +: 16];
                    expect_data = 0; expected_cycles = 0;
                    run_to_retire(); check(debug_ip == 16'h0102 && retirements == 1, "register MOV length / single END");
                    execute_enable = 0; ready = 1;
                    repeat (3) begin tick(); check(retirements == 1, "no repeated END"); end
                    cases = cases + 1; reg_cases = reg_cases + 1;
                end
        for (integer direction = 0; direction < 2; direction = direction + 1)
          for (integer alignment = 0; alignment < 2; alignment = alignment + 1)
            for (integer m = 0; m < 3; m = m + 1)
                for (integer rm = 0; rm < 8; rm = rm + 1)
                    for (integer d = 0; d < 5; d = d + 1) begin
                        case (d)
                            0: disp = 16'h0000;
                            1: disp = 16'h0001;
                            2: disp = m == 1 ? 16'h007F : 16'h7FFF;
                            3: disp = m == 1 ? 16'hFF80 : 16'h8000;
                            4: disp = 16'hFFFF;
                            default: $fatal(1, "test displacement");
                        endcase
                        if (m == 0 && rm != 6) disp = 0;
                        if (m == 0 && rm == 6 && alignment != 0) disp = disp ^ 16'h0001;
                        instruction_length = 2 + (m == 1 ? 1 : ((m == 2 || rm == 6 && m == 0) ? 2 : 0));
                        target_offset = ((m == 0 && rm == 6 ? 0 : reference_base(rm)+alignment) + int'(disp)) & 65535;
                        code_start = 65792 + alignment;
                        memory[code_start] = direction == 0 ? 8'h89 : 8'h8B;
                        memory[code_start+1] = 8'(m*64 + ((rm+d)%8)*8 + rm);
                        memory[code_start+2] = disp[7:0]; memory[code_start+3] = disp[15:8];
                        memory[code_start+instruction_length] = 8'h0F;
                        wait_length = d % 4;
                        setup(16'h0100 + 16'(alignment), d == 4);
                        if (alignment != 0 && !(m == 0 && rm == 6)) begin
                            // Flip one participating register's parity so each EA form
                            // exercises both native word alignments, including mod=00.
                            address_register = rm == 4 ? 6 : (rm == 5 ? 7 : (rm == 2 || rm == 3 || rm == 6 ? 5 : 3));
                            initial_gpr[address_register*16 +: 16] = initial_gpr[address_register*16 +: 16] + 16'd1;
                            expected_gpr = initial_gpr;
                            execute_enable = 0; gpr_write_en = 1; gpr_write_index = 3'(address_register);
                            gpr_write_data = initial_gpr[address_register*16 +: 16]; tick();
                            gpr_write_en = 0; execute_enable = 1;
                        end
                        target_address = (rm == 2 || rm == 3 || rm == 6 && m != 0 ? 524288 : (d == 4 ? 1048560 : 262144)) + target_offset;
                        expect_data = target_offset != 65535; expect_write = direction == 0;
                        expected_cycles = expect_data ? (target_address % 2 == 0 ? 1 : 2) : 0;
                        expected_value = direction == 0 ? initial_gpr[((rm+d)%8)*16 +: 16] : 16'hC17E;
                        memory[target_address-1] = 8'h4D; memory[target_address] = 8'h7E;
                        memory[target_address+1] = 8'hC1; memory[target_address+2] = 8'hB6;
                        if (expect_data) begin
                            if (direction == 1) expected_gpr[((rm+d)%8)*16 +: 16] = expected_value;
                            run_to_retire();
                            check(debug_ip == 16'h0100 + 16'(alignment+instruction_length) && retirements == 1, "memory MOV length / single END");
                            check({memory[target_address+1], memory[target_address]} == expected_value, "little-endian memory contents");
                        end else begin
                            // Pause at the real fault producer; the event benches check its
                            // completed frame separately with the physical corpus.
                            for (integer cycle=0;cycle<150 && !operand_blocked;cycle=cycle+1) service();
                            execute_enable=0; repeat (6) service();
                            check(operand_blocked && retirements == 0 && data_cycles == 0 && debug_gpr == initial_gpr,
                                  "word at FFFF blocked before side effects");
                            check({memory[target_address+1],memory[target_address]} == 16'hC17E, "blocked write did not modify memory");
                        end
                        check(memory[target_address-1] == 8'h4D && memory[target_address+2] == 8'hB6, "neighbor preservation");
                        cases = cases + 1; mem_cases = mem_cases + 1;
                    end
        // Uninterrupted code/data coexistence: write odd word, read it to BX,
        // then use the new BX as a direct-register source to AX, then immediate SI.
        memory[66048] = 8'h89; memory[66049] = 8'h06; memory[66050] = 8'h01; memory[66051] = 8'h10;
        memory[66052] = 8'h8B; memory[66053] = 8'h1E; memory[66054] = 8'h01; memory[66055] = 8'h10;
        memory[66056] = 8'h89; memory[66057] = 8'hD8;
        memory[66058] = 8'hBE; memory[66059] = 8'h34; memory[66060] = 8'h12; memory[66061] = 8'h0F;
        setup(16'h0200, 0); wait_length = 3;
        target_address = 266241; expected_value = 16'hAA55;
        expect_data = 1; expect_write = 1; expected_cycles = 2;
        run_to_retire(); check(debug_ip == 16'h0204, "stream store IP");
        expect_write = 0; data_cycles = 0; expected_gpr[63:48] = expected_value;
        run_to_retire(); check(debug_ip == 16'h0208, "stream load IP");
        data_cycles = 0; expected_cycles = 0; expect_data = 0;
        run_to_retire(); check(debug_ip == 16'h020A, "stream register IP");
        expected_gpr[111:96] = 16'h1234;
        run_to_retire(); check(debug_ip == 16'h020D && retirements == 4, "stream immediate IP and four ENDs");
        // Consecutive address-register updates, wrapped DS EA, self-dependent
        // load into BX, signed BP+SI SS EA, then direct DS and register transfer.
        // Every value is checked at its own retirement, with no intervening flush.
        memory[66304]=8'hBB; memory[66305]=8'hF0; memory[66306]=8'hFF;
        memory[66307]=8'hBE; memory[66308]=8'h31; memory[66309]=8'h00;
        memory[66310]=8'h89; memory[66311]=8'h00;
        memory[66312]=8'h8B; memory[66313]=8'h18;
        memory[66314]=8'hBD; memory[66315]=8'h22; memory[66316]=8'h00;
        memory[66317]=8'h89; memory[66318]=8'h5A; memory[66319]=8'hAE;
        memory[66320]=8'h8B; memory[66321]=8'h3E; memory[66322]=8'h01; memory[66323]=8'h00;
        memory[66324]=8'h89; memory[66325]=8'hF8; memory[66326]=8'h0F;
        memory[262144]=8'h19; memory[262145]=8'h3A; memory[262146]=8'h4B; memory[262147]=8'h91;
        memory[262176]=8'h27; memory[262177]=8'h00; memory[262178]=8'h00; memory[262179]=8'h72;
        memory[524288]=8'h38; memory[524289]=8'h00; memory[524290]=8'h00; memory[524291]=8'h83;
        setup(16'h0300,0); wait_length=4; expect_data=0; expected_cycles=0;
        expected_gpr[63:48]=16'hFFF0; run_to_retire(); check(debug_ip==16'h0303,"dependent stream BX immediate");
        expected_gpr[111:96]=16'h0031; run_to_retire(); check(debug_ip==16'h0306,"dependent stream SI immediate");
        expect_data=1; expect_write=1; target_address=262177; expected_cycles=2; expected_value=16'hAA55;
        run_to_retire(); check(debug_ip==16'h0308 && debug_effective_offset==16'h0021 && debug_operand_segment==3,
                              "new BX+SI wraps to odd DS offset");
        data_cycles=0; expect_write=0; expected_gpr[63:48]=16'hAA55;
        run_to_retire(); check(debug_ip==16'h030A && debug_effective_offset==16'h0021,
                              "load into address register preserves captured EA");
        data_cycles=0; expect_data=0; expected_cycles=0; expected_gpr[95:80]=16'h0022;
        run_to_retire(); check(debug_ip==16'h030D,"dependent stream BP immediate");
        expect_data=1; expect_write=1; target_address=524289; expected_cycles=2;
        run_to_retire(); check(debug_ip==16'h0310 && debug_effective_offset==1 &&
                              debug_operand_segment==2 && debug_displacement==16'hFFAE,"signed BP+SI uses distinct SS");
        data_cycles=0; expect_write=0; target_address=262145; expected_value=16'h4B3A; expected_gpr[127:112]=expected_value;
        run_to_retire(); check(debug_ip==16'h0314 && debug_effective_offset==1 && debug_operand_segment==3 &&
                              debug_modrm==8'h3E && debug_displacement==1,"direct displacement restores DS context");
        data_cycles=0; expect_data=0; expected_cycles=0; expected_gpr[15:0]=expected_value;
        run_to_retire(); check(debug_ip==16'h0316 && retirements==8,"eight dependent instructions retire once each");
        check({memory[262178],memory[262177]}==16'hAA55 && {memory[524290],memory[524289]}==16'hAA55 &&
              {memory[262146],memory[262145]}==16'h4B3A,"distinct segment data survives uninterrupted stream");
        check(memory[262144]==8'h19 && memory[262147]==8'h91 && memory[262176]==8'h27 &&
              memory[262179]==8'h72 && memory[524288]==8'h38 && memory[524291]==8'h83,"all stream write guards preserved");
        check(data_waits > 0 && coexist_cycles > 0, "READY and populated-queue data coexistence exercised");
        $display("MOV_OPERANDS PASS: %0d register cases, %0d memory/boundary cases, 4- and 8-instruction streams; %0d checks, %0d data waits, %0d coexistence cycles",
                 reg_cases, mem_cases, checks, data_waits, coexist_cycles);
        $finish;
    end
endmodule
