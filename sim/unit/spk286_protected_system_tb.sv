`timescale 1ns/1ps

module spk286_protected_system_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer cycles = 0;
    integer retired_count = 0;
    integer checks = 0;
    integer protected_data_reads = 0;

    spk286 dut (.*);

    task automatic tick;
        begin
            #1;
            ready = bus_valid && ((cycles % 4) != 1);
            data_in = 16'h0000;
            if (bus_valid && !bus_write) begin
                if (address[0]) data_in = {memory[address[15:0]], 8'h00};
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
            if (bus_valid && ready && !bus_write && bus_status == 4'h5 && address[15:0] == 16'h0003)
                protected_data_reads = protected_data_reads + 1;
            #4; clk = 1'b1; #5; clk = 1'b0; #1;
            cycles = cycles + 1;
            if (instruction_retired) retired_count = retired_count + 1;
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
            tick();
        end
    endtask

    task automatic retire_one;
        integer deadline;
        integer start_retired;
        begin
            start_retired = retired_count;
            deadline = 0;
            while (retired_count == start_retired && !halted && deadline < 500) begin
                tick();
                deadline = deadline + 1;
            end
            if (retired_count != start_retired + 1)
                $fatal(1, "system instruction did not retire before timeout; IP=%h opcode=%h pc=%h bus=%h", debug_ip, debug_opcode, debug_micro_pc, bus_status);
        end
    endtask

    task automatic wait_fault(input logic [7:0] expected_vector);
        integer deadline;
        begin
            deadline = 0;
            while ((!event_completed || debug_event_vector != expected_vector) && deadline < 500) begin
                tick();
                deadline = deadline + 1;
            end
            if (!event_completed || debug_event_vector != expected_vector)
                $fatal(1, "protected fault did not complete; vector=%h expected=%h IP=%h opcode=%h", debug_event_vector, expected_vector, debug_ip, debug_opcode);
        end
    endtask

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "%s: IP=%h opcode=%h flags=%h gpr=%h gdtr=%h:%h idtr=%h:%h msw=%h", message,
                       debug_ip, debug_opcode, debug_flags, debug_gpr, debug_gdtr_base, debug_gdtr_limit,
                       debug_idtr_base, debug_idtr_limit, debug_protected_msw);
        end
    endtask

    initial begin
        for (integer i = 0; i < 65536; i = i + 1) memory[i] = 8'h00;

        // LGDT [0300], SGDT [0200], LIDT [0310], SIDT [0210].
        memory[16'h0000] = 8'h0F; memory[16'h0001] = 8'h01; memory[16'h0002] = 8'h16;
        memory[16'h0003] = 8'h00; memory[16'h0004] = 8'h03;
        memory[16'h0005] = 8'h0F; memory[16'h0006] = 8'h01; memory[16'h0007] = 8'h06;
        memory[16'h0008] = 8'h00; memory[16'h0009] = 8'h02;
        memory[16'h000A] = 8'h0F; memory[16'h000B] = 8'h01; memory[16'h000C] = 8'h1E;
        memory[16'h000D] = 8'h10; memory[16'h000E] = 8'h03;
        memory[16'h000F] = 8'h0F; memory[16'h0010] = 8'h01; memory[16'h0011] = 8'h0E;
        memory[16'h0012] = 8'h10; memory[16'h0013] = 8'h02;
        // LMSW AX, SMSW BX, SLDT AX, STR BX, LLDT AX, LTR BX,
        // VERR/VERW over GDT data/code descriptors and an LDT descriptor.
        memory[16'h0014] = 8'h0F; memory[16'h0015] = 8'h01; memory[16'h0016] = 8'hF0;
        memory[16'h0017] = 8'h0F; memory[16'h0018] = 8'h01; memory[16'h0019] = 8'hE3;
        memory[16'h001A] = 8'h0F; memory[16'h001B] = 8'h00; memory[16'h001C] = 8'hC0;
        memory[16'h001D] = 8'h0F; memory[16'h001E] = 8'h00; memory[16'h001F] = 8'hCB;
        memory[16'h0020] = 8'hB8; memory[16'h0021] = 8'h08; memory[16'h0022] = 8'h00;
        memory[16'h0023] = 8'h0F; memory[16'h0024] = 8'h00; memory[16'h0025] = 8'hD0;
        memory[16'h0026] = 8'hBB; memory[16'h0027] = 8'h10; memory[16'h0028] = 8'h00;
        memory[16'h0029] = 8'h0F; memory[16'h002A] = 8'h00; memory[16'h002B] = 8'hDB;
        memory[16'h002C] = 8'hB8; memory[16'h002D] = 8'h18; memory[16'h002E] = 8'h00;
        memory[16'h002F] = 8'h0F; memory[16'h0030] = 8'h00; memory[16'h0031] = 8'hE0;
        memory[16'h0032] = 8'h0F; memory[16'h0033] = 8'h00; memory[16'h0034] = 8'hE8;
        memory[16'h0035] = 8'hB8; memory[16'h0036] = 8'h20; memory[16'h0037] = 8'h00;
        memory[16'h0038] = 8'h0F; memory[16'h0039] = 8'h00; memory[16'h003A] = 8'hE0;
        memory[16'h003B] = 8'h0F; memory[16'h003C] = 8'h00; memory[16'h003D] = 8'hE8;
        memory[16'h003E] = 8'hB8; memory[16'h003F] = 8'h28; memory[16'h0040] = 8'h00;
        memory[16'h0041] = 8'h0F; memory[16'h0042] = 8'h00; memory[16'h0043] = 8'hE0;
        memory[16'h0044] = 8'h0F; memory[16'h0045] = 8'h00; memory[16'h0046] = 8'hE8;
        memory[16'h0047] = 8'hB8; memory[16'h0048] = 8'h1B; memory[16'h0049] = 8'h00;
        memory[16'h004A] = 8'h0F; memory[16'h004B] = 8'h00; memory[16'h004C] = 8'hE0;
        memory[16'h004D] = 8'hB8; memory[16'h004E] = 8'h0C; memory[16'h004F] = 8'h00;
        memory[16'h0050] = 8'h0F; memory[16'h0051] = 8'h00; memory[16'h0052] = 8'hE0;
        memory[16'h0053] = 8'hB8; memory[16'h0054] = 8'h00; memory[16'h0055] = 8'h00;
        memory[16'h0056] = 8'h0F; memory[16'h0057] = 8'h00; memory[16'h0058] = 8'hE0;
        memory[16'h0059] = 8'hB8; memory[16'h005A] = 8'h40; memory[16'h005B] = 8'h00;
        memory[16'h005C] = 8'h0F; memory[16'h005D] = 8'h00; memory[16'h005E] = 8'hE0;
        memory[16'h005F] = 8'hB8; memory[16'h0060] = 8'h18; memory[16'h0061] = 8'h00;
        memory[16'h0062] = 8'h0F; memory[16'h0063] = 8'h02; memory[16'h0064] = 8'hD8;
        memory[16'h0065] = 8'hB8; memory[16'h0066] = 8'h18; memory[16'h0067] = 8'h00;
        memory[16'h0068] = 8'h0F; memory[16'h0069] = 8'h03; memory[16'h006A] = 8'hC8;
        memory[16'h006B] = 8'hB8; memory[16'h006C] = 8'h28; memory[16'h006D] = 8'h00;
        memory[16'h006E] = 8'h0F; memory[16'h006F] = 8'h02; memory[16'h0070] = 8'hD0;
        memory[16'h0071] = 8'hB8; memory[16'h0072] = 8'h00; memory[16'h0073] = 8'h00;
        memory[16'h0074] = 8'h0F; memory[16'h0075] = 8'h02; memory[16'h0076] = 8'hD8;
        memory[16'h0077] = 8'h0F; memory[16'h0078] = 8'h03; memory[16'h0079] = 8'hC8;
        memory[16'h007A] = 8'hF4;
        // PM2 data/stack segment reloads and a pre-cycle limit fault.
        memory[16'h0080] = 8'hB8; memory[16'h0081] = 8'h18; memory[16'h0082] = 8'h00;
        memory[16'h0083] = 8'h8E; memory[16'h0084] = 8'hD8;
        memory[16'h0085] = 8'h8E; memory[16'h0086] = 8'hC0;
        memory[16'h0087] = 8'h8E; memory[16'h0088] = 8'hD0;
        memory[16'h0089] = 8'hB8; memory[16'h008A] = 8'h0C; memory[16'h008B] = 8'h00;
        memory[16'h008C] = 8'h8E; memory[16'h008D] = 8'hD8;
        memory[16'h008E] = 8'hB8; memory[16'h008F] = 8'h30; memory[16'h0090] = 8'h00;
        memory[16'h0091] = 8'h8E; memory[16'h0092] = 8'hD8;
        memory[16'h0093] = 8'hB8; memory[16'h0094] = 8'h03; memory[16'h0095] = 8'h00;
        memory[16'h0096] = 8'hA1; memory[16'h0097] = 8'h03; memory[16'h0098] = 8'h00;

        memory[16'h0300] = 8'h34; memory[16'h0301] = 8'h12;
        memory[16'h0302] = 8'h78; memory[16'h0303] = 8'h56; memory[16'h0304] = 8'h9A;
        memory[16'h0310] = 8'h78; memory[16'h0311] = 8'h56;
        memory[16'h0312] = 8'hBC; memory[16'h0313] = 8'h9A; memory[16'h0314] = 8'hDE;

        // GDT entries at GDTR.base + 8 and +16: an LDT and an available TSS.
        memory[16'h5680] = 8'hFF; memory[16'h5681] = 8'h00;
        memory[16'h5682] = 8'h00; memory[16'h5683] = 8'h40;
        memory[16'h5684] = 8'h02; memory[16'h5685] = 8'h82;
        memory[16'h5686] = 8'h00; memory[16'h5687] = 8'h00;
        memory[16'h5688] = 8'h67; memory[16'h5689] = 8'h00;
        memory[16'h568A] = 8'h00; memory[16'h568B] = 8'h80;
        memory[16'h568C] = 8'h03; memory[16'h568D] = 8'h81;
        memory[16'h568E] = 8'h00; memory[16'h568F] = 8'h00;
        // GDT index 3: writable data, index 4: readable code, index 5: read-only data.
        memory[16'h5690] = 8'hFF; memory[16'h5691] = 8'hFF;
        memory[16'h5692] = 8'h00; memory[16'h5693] = 8'h00;
        memory[16'h5694] = 8'h00; memory[16'h5695] = 8'h93;
        memory[16'h5696] = 8'h00; memory[16'h5697] = 8'h00;
        memory[16'h5698] = 8'hFF; memory[16'h5699] = 8'hFF;
        memory[16'h569A] = 8'h00; memory[16'h569B] = 8'h00;
        memory[16'h569C] = 8'h00; memory[16'h569D] = 8'h9B;
        memory[16'h569E] = 8'h00; memory[16'h569F] = 8'h00;
        memory[16'h56A0] = 8'hFF; memory[16'h56A1] = 8'hFF;
        memory[16'h56A2] = 8'h00; memory[16'h56A3] = 8'h00;
        memory[16'h56A4] = 8'h00; memory[16'h56A5] = 8'h91;
        memory[16'h56A6] = 8'h00; memory[16'h56A7] = 8'h00;
        // GDT index 6: present writable data, limit 0002, accessed initially clear.
        memory[16'h56A8] = 8'h02; memory[16'h56A9] = 8'h00;
        memory[16'h56AA] = 8'h00; memory[16'h56AB] = 8'h00;
        memory[16'h56AC] = 8'h00; memory[16'h56AD] = 8'h92;
        memory[16'h56AE] = 8'h00; memory[16'h56AF] = 8'h00;
        // LDT index 1 at the loaded LDT base, writable data.
        memory[16'h4008] = 8'hFF; memory[16'h4009] = 8'hFF;
        memory[16'h400A] = 8'h00; memory[16'h400B] = 8'h00;
        memory[16'h400C] = 8'h00; memory[16'h400D] = 8'h93;
        memory[16'h400E] = 8'h00; memory[16'h400F] = 8'h00;

        reset = 1'b1;
        execute_enable = 1'b0;
        ready = 1'b0;
        tick();
        reset = 1'b0;
        far_restart(16'h0000, 16'h0000);
        check(debug_protected_msw == 16'hFFF0 && debug_gdtr_limit == 16'h0000 && debug_idtr_limit == 16'h03FF,
              "PM1 state reset values");

        gpr_write_en = 1'b1;
        gpr_write_index = 3'd0;
        gpr_write_data = 16'h0001;
        tick();
        gpr_write_en = 1'b0;
        execute_enable = 1'b1;

        retire_one();
        check(debug_gdtr_limit == 16'h1234 && debug_gdtr_base == 24'h9A5678, "LGDT commits only after complete table read");
        retire_one();
        check({memory[16'h0205], memory[16'h0204], memory[16'h0203], memory[16'h0202], memory[16'h0201], memory[16'h0200]} == 48'h009A56781234,
              "SGDT stores limit and 24-bit base in Intel byte order");
        retire_one();
        check(debug_idtr_limit == 16'h5678 && debug_idtr_base == 24'hDE9ABC, "LIDT commits only after complete table read");
        retire_one();
        check({memory[16'h0215], memory[16'h0214], memory[16'h0213], memory[16'h0212], memory[16'h0211], memory[16'h0210]} == 48'h00DE9ABC5678,
              "SIDT stores limit and 24-bit base in Intel byte order");
        retire_one();
        check(debug_protected_msw == 16'hFFF1 && debug_gpr[15:0] == 16'h0001, "LMSW sets PE without writing its source GPR");
        retire_one();
        check(debug_gpr[63:48] == 16'hFFF1, "SMSW writes the MSW through the normal operand channel");
        retire_one();
        check(debug_ldtr_selector == 16'h0000 && debug_gpr[15:0] == 16'h0000,
              "SLDT stores the visible reset selector");
        retire_one();
        check(debug_tr_selector == 16'h0000 && debug_gpr[63:48] == 16'h0000,
              "STR stores the visible reset selector");
        retire_one();
        check(debug_gpr[15:0] == 16'h0008, "MOV loads the LLDT selector source");
        retire_one();
        check(debug_ldtr_selector == 16'h0008 && debug_ldtr_base == 24'h024000 && debug_ldtr_limit == 16'h00FF &&
              memory[16'h5685] == 8'h82, "LLDT validates and commits the GDT LDT descriptor without a write");
        retire_one();
        check(debug_gpr[63:48] == 16'h0010, "MOV loads the LTR selector source");
        retire_one();
        check(debug_tr_selector == 16'h0010 && debug_tr_base == 24'h038000 && debug_tr_limit == 16'h0067 &&
              memory[16'h568D] == 8'h83, "LTR marks the available TSS busy before committing TR");
        retire_one();
        check(debug_gpr[15:0] == 16'h0018, "MOV loads the writable data selector for VERR/VERW");
        retire_one();
        check(debug_flags[6] == 1'b1, "VERR sets ZF for readable writable data");
        retire_one();
        check(debug_flags[6] == 1'b1, "VERW sets ZF for writable data");
        retire_one();
        check(debug_gpr[15:0] == 16'h0020, "MOV loads the readable code selector");
        retire_one();
        check(debug_flags[6] == 1'b1, "VERR sets ZF for readable code");
        retire_one();
        check(debug_flags[6] == 1'b0, "VERW clears ZF for code");
        retire_one();
        check(debug_gpr[15:0] == 16'h0028, "MOV loads the read-only data selector");
        retire_one();
        check(debug_flags[6] == 1'b1, "VERR accepts read-only data");
        retire_one();
        check(debug_flags[6] == 1'b0, "VERW rejects read-only data");
        retire_one();
        retire_one();
        check(debug_flags[6] == 1'b0, "VERR rejects a selector whose RPL exceeds the descriptor DPL");
        retire_one();
        retire_one();
        check(debug_flags[6] == 1'b1, "VERR selects a readable descriptor through the loaded LDT");
        retire_one();
        check(debug_gpr[15:0] == 16'h0000, "MOV loads the null selector for a non-faulting negative verification");
        retire_one();
        check(debug_flags[6] == 1'b0, "VERR clears ZF for a null selector without raising a fault");
        retire_one();
        retire_one();
        check(debug_flags[6] == 1'b0, "VERR clears ZF for an invalid descriptor without raising a fault");
        retire_one();
        check(debug_gpr[15:0] == 16'h0018, "MOV loads the LAR selector");
        retire_one();
        check(debug_gpr[63:48] == 16'h9300 && debug_flags[6] == 1'b1,
              "LAR loads the descriptor access rights in the high result byte");
        retire_one();
        check(debug_gpr[15:0] == 16'h0018, "MOV reloads the LSL selector");
        retire_one();
        check(debug_gpr[31:16] == 16'hFFFF && debug_flags[6] == 1'b1,
              "LSL loads the visible data-segment limit");
        retire_one();
        check(debug_gpr[15:0] == 16'h0028, "MOV loads a second visible selector for LAR");
        retire_one();
        check(debug_gpr[47:32] == 16'h9100 && debug_flags[6] == 1'b1,
              "LAR returns read-only data access rights without changing the selector");
        retire_one();
        check(debug_gpr[15:0] == 16'h0000, "MOV loads the null selector for negative LAR/LSL cases");
        retire_one();
        check(debug_gpr[63:48] == 16'h9300 && debug_flags[6] == 1'b0,
              "LAR clears ZF and preserves its destination for a null selector");
        retire_one();
        check(debug_gpr[31:16] == 16'hFFFF && debug_flags[6] == 1'b0,
              "LSL clears ZF and preserves its destination for a null selector");

        far_restart(16'h0000, 16'h0080);
        retire_one();
        check(debug_gpr[15:0] == 16'h0018, "PM2 loads the GDT data selector source");
        retire_one();
        check(debug_segment_selectors[63:48] == 16'h0018 && debug_segment_limits[63:48] == 16'hFFFF &&
              debug_segment_access[31:24] == 8'h93, "PM2 atomically commits the protected DS cache");
        retire_one();
        check(debug_segment_selectors[15:0] == 16'h0018 && debug_segment_access[7:0] == 8'h93,
              "PM2 commits the protected ES cache from the same descriptor service");
        retire_one();
        check(debug_segment_selectors[47:32] == 16'h0018 && debug_segment_access[23:16] == 8'h93,
              "PM2 commits the protected SS cache coherently");
        retire_one();
        check(debug_gpr[15:0] == 16'h000C, "PM2 loads the LDT selector source");
        retire_one();
        check(debug_segment_selectors[63:48] == 16'h000C && debug_segment_access[31:24] == 8'h93,
              "PM2 resolves and commits a protected DS selector through the LDT");
        retire_one();
        check(debug_gpr[15:0] == 16'h0030, "PM2 loads the limited data selector source");
        retire_one();
        check(debug_segment_selectors[63:48] == 16'h0030 && debug_segment_limits[63:48] == 16'h0002,
              "PM2 commits the limited data selector and limit");
        check(debug_segment_access[31:24] == 8'h93, "PM2 commits the accessed bit into the hidden cache");
        check(memory[16'h56AD] == 8'h93, "PM2 writes the descriptor accessed bit before cache commit");
        retire_one();
        protected_data_reads = 0;
        wait_fault(8'd13);
        check(protected_data_reads == 0, "PM2 blocks an out-of-limit word before its first physical data cycle");

        $display("PROTECTED_SYSTEM PASS: %0d checks, READY stalls=%0d", checks, cycles);
        $finish;
    end
endmodule
