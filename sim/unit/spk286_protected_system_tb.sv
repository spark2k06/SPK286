`timescale 1ns/1ps

module spk286_protected_system_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    integer cycles = 0;
    integer retired_count = 0;
    integer checks = 0;
    integer protected_data_reads = 0;
    logic [15:0] pm4a_return_sp;

    spk286 dut (.*);

    task automatic tick;
        begin
            #1;
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

    task automatic wait_event(input logic [7:0] expected_vector);
        integer deadline;
        begin
            deadline = 0;
            while ((!event_completed || debug_event_vector != expected_vector) && deadline < 500) begin
                tick();
                deadline = deadline + 1;
            end
            if (!event_completed || debug_event_vector != expected_vector)
                $fatal(1, "protected event did not complete; vector=%h expected=%h IP=%h opcode=%h", debug_event_vector, expected_vector, debug_ip, debug_opcode);
        end
    endtask

    task automatic wait_shutdown;
        integer deadline;
        begin
            deadline = 0;
            while (!shutdown && deadline < 500) begin
                tick();
                deadline = deadline + 1;
            end
            if (!shutdown)
                $fatal(1, "nested protected event did not enter shutdown; vector=%h IP=%h opcode=%h", debug_event_vector, debug_ip, debug_opcode);
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
        // PM2b direct far transfers: valid code selector 0038 and invalid data selector 0018.
        memory[16'h0099] = 8'hEA; memory[16'h009A] = 8'h00; memory[16'h009B] = 8'h01;
        memory[16'h009C] = 8'h38; memory[16'h009D] = 8'h00;
        memory[16'h00A0] = 8'hEA; memory[16'h00A1] = 8'h00; memory[16'h00A2] = 8'h01;
        memory[16'h00A3] = 8'h18; memory[16'h00A4] = 8'h00;
        memory[16'h0100] = 8'hB8; memory[16'h0101] = 8'hEF; memory[16'h0102] = 8'hBE;
        memory[16'h0103] = 8'hF4;
        memory[16'h0120] = 8'hFB; memory[16'h0121] = 8'hCD; memory[16'h0122] = 8'h20;
        memory[16'h0140] = 8'hB8; memory[16'h0141] = 8'hDE; memory[16'h0142] = 8'hAD;
        memory[16'h0143] = 8'hF4;
        memory[16'h0160] = 8'hFB; memory[16'h0161] = 8'hCD; memory[16'h0162] = 8'h21;
        memory[16'h0180] = 8'hB8; memory[16'h0181] = 8'hA5; memory[16'h0182] = 8'h5A;
        memory[16'h0183] = 8'hF4;

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
        // GDT index 7: present readable code, base 000000, limit 01FF, accessed clear.
        memory[16'h56B0] = 8'hFF; memory[16'h56B1] = 8'h01;
        memory[16'h56B2] = 8'h00; memory[16'h56B3] = 8'h00;
        memory[16'h56B4] = 8'h00; memory[16'h56B5] = 8'h9A;
        memory[16'h56B6] = 8'h00; memory[16'h56B7] = 8'h00;
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

        // PM3a: vector 0D in the loaded IDT (base DE9ABC, low 16-bit bus
        // address 9ABC) points at the existing protected CS handler.
        memory[16'h9B24] = 8'h00; memory[16'h9B25] = 8'h01;
        memory[16'h9B26] = 8'h38; memory[16'h9B27] = 8'h00;
        memory[16'h9B28] = 8'h00; memory[16'h9B29] = 8'h86;
        memory[16'h9B2A] = 8'h00; memory[16'h9B2B] = 8'h00;
        // PM3a: software INT 20 uses an interrupt gate; INT 21 uses a trap
        // gate. Both remain same-level transitions to CS=0038.
        memory[16'h9BBC] = 8'h40; memory[16'h9BBD] = 8'h01;
        memory[16'h9BBE] = 8'h38; memory[16'h9BBF] = 8'h00;
        memory[16'h9BC0] = 8'h00; memory[16'h9BC1] = 8'h86;
        memory[16'h9BC2] = 8'h00; memory[16'h9BC3] = 8'h00;
        memory[16'h9BC4] = 8'h80; memory[16'h9BC5] = 8'h01;
        memory[16'h9BC6] = 8'h38; memory[16'h9BC7] = 8'h00;
        memory[16'h9BC8] = 8'h00; memory[16'h9BC9] = 8'h87;
        memory[16'h9BCA] = 8'h00; memory[16'h9BCB] = 8'h00;
        // PM3b: vector 02 and external vector 22 use same-level interrupt
        // gates whose handlers execute IRET back into the protected caller.
        memory[16'h9ACC] = 8'hC0; memory[16'h9ACD] = 8'h01;
        memory[16'h9ACE] = 8'h38; memory[16'h9ACF] = 8'h00;
        memory[16'h9AD0] = 8'h00; memory[16'h9AD1] = 8'h86;
        memory[16'h9AD2] = 8'h00; memory[16'h9AD3] = 8'h00;
        memory[16'h9BCC] = 8'hC0; memory[16'h9BCD] = 8'h01;
        memory[16'h9BCE] = 8'h38; memory[16'h9BCF] = 8'h00;
        memory[16'h9BD0] = 8'h00; memory[16'h9BD1] = 8'h86;
        memory[16'h9BD2] = 8'h00; memory[16'h9BD3] = 8'h00;
        memory[16'h9B14] = 8'hE0; memory[16'h9B15] = 8'h01;
        memory[16'h9B16] = 8'h38; memory[16'h9B17] = 8'h00;
        memory[16'h9B18] = 8'h00; memory[16'h9B19] = 8'h86;
        memory[16'h9B1A] = 8'h00; memory[16'h9B1B] = 8'h00;
        // GDT index 8: structurally valid but not-present writable data.
        memory[16'h56B8] = 8'hFF; memory[16'h56B9] = 8'hFF;
        memory[16'h56BA] = 8'h00; memory[16'h56BB] = 8'h00;
        memory[16'h56BC] = 8'h00; memory[16'h56BD] = 8'h12;
        memory[16'h56BE] = 8'h00; memory[16'h56BF] = 8'h00;
        // PM3d: ring-3 code/data descriptors for an outer-level IRET frame.
        memory[16'h56C0] = 8'hFF; memory[16'h56C1] = 8'h01;
        memory[16'h56C2] = 8'h00; memory[16'h56C3] = 8'h00;
        memory[16'h56C4] = 8'h00; memory[16'h56C5] = 8'hFA;
        memory[16'h56C6] = 8'h00; memory[16'h56C7] = 8'h00;
        memory[16'h56C8] = 8'hFF; memory[16'h56C9] = 8'hFF;
        memory[16'h56CA] = 8'h00; memory[16'h56CB] = 8'h00;
        memory[16'h56CC] = 8'h00; memory[16'h56CD] = 8'hF2;
        memory[16'h56CE] = 8'h00; memory[16'h56CF] = 8'h00;
        // PM4a: present DPL-0 call gate at selector 0058 targeting 0038:01C8.
        memory[16'h56D0] = 8'hD8; memory[16'h56D1] = 8'h01;
        memory[16'h56D2] = 8'h38; memory[16'h56D3] = 8'h00;
        memory[16'h56D4] = 8'h00; memory[16'h56D5] = 8'h84;
        memory[16'h56D6] = 8'h00; memory[16'h56D7] = 8'h00;
        // PM4b: ring-1 code/data descriptors and DPL-1 call gates back into
        // the existing ring-0 code segment.  Selector 0071 is the zero-word
        // PM4b.1 gate; selector 0079 is the PM4b.2 two-word gate.
        memory[16'h56D8] = 8'hFF; memory[16'h56D9] = 8'h03;
        memory[16'h56DA] = 8'h00; memory[16'h56DB] = 8'h00;
        memory[16'h56DC] = 8'h00; memory[16'h56DD] = 8'hBA;
        memory[16'h56DE] = 8'h00; memory[16'h56DF] = 8'h00;
        memory[16'h56E0] = 8'hFF; memory[16'h56E1] = 8'hFF;
        memory[16'h56E2] = 8'h00; memory[16'h56E3] = 8'h00;
        memory[16'h56E4] = 8'h00; memory[16'h56E5] = 8'hB2;
        memory[16'h56E6] = 8'h00; memory[16'h56E7] = 8'h00;
        memory[16'h56E8] = 8'h00; memory[16'h56E9] = 8'h01;
        memory[16'h56EA] = 8'h38; memory[16'h56EB] = 8'h00;
        memory[16'h56EC] = 8'h00; memory[16'h56ED] = 8'hA4;
        memory[16'h56EE] = 8'h00; memory[16'h56EF] = 8'h00;
        // PM4b.2: a second DPL-1 gate targeting the same entry point with
        // two 80286 parameter words.
        memory[16'h56F0] = 8'h00; memory[16'h56F1] = 8'h01;
        memory[16'h56F2] = 8'h38; memory[16'h56F3] = 8'h00;
        memory[16'h56F4] = 8'h02; memory[16'h56F5] = 8'hA4;
        memory[16'h56F6] = 8'h00; memory[16'h56F7] = 8'h00;
        // TSS SP0/SS0 and SP1/SS1 at the loaded 80286 TSS base 038000.
        memory[16'h8002] = 8'h00; memory[16'h8003] = 8'hA0;
        memory[16'h8004] = 8'h18; memory[16'h8005] = 8'h00;
        memory[16'h8006] = 8'h00; memory[16'h8007] = 8'hFF;
        memory[16'h8008] = 8'h69; memory[16'h8009] = 8'h00;
        // Ring-1 entry calls the DPL-1 gate.  The ring-0 target restores the
        // pre-test SP before continuing with the existing PM3 checks.
        memory[16'h0240] = 8'h9A; memory[16'h0241] = 8'h00; memory[16'h0242] = 8'h01;
        memory[16'h0243] = 8'h79; memory[16'h0244] = 8'h00; memory[16'h0245] = 8'hF4;
        memory[16'h01B8] = 8'hCF;
        memory[16'h0190] = 8'hCF;
        memory[16'h0194] = 8'hB8; memory[16'h0195] = 8'h34; memory[16'h0196] = 8'h12;
        memory[16'h0197] = 8'hF4;
        memory[16'h01C8] = 8'h9A; memory[16'h01C9] = 8'hD8; memory[16'h01CA] = 8'h01;
        memory[16'h01CB] = 8'h58; memory[16'h01CC] = 8'h00;
        memory[16'h01D8] = 8'hB8; memory[16'h01D9] = 8'hFE; memory[16'h01DA] = 8'hCA;
        memory[16'h01DB] = 8'hCB;
        memory[16'h01A0] = 8'hFB; memory[16'h01A1] = 8'h40; memory[16'h01A2] = 8'hF4;
        memory[16'h01B0] = 8'hCD; memory[16'h01B1] = 8'h22; memory[16'h01B2] = 8'h90;
        memory[16'h01C0] = 8'hCF;
        // PM3c handler consumes the saved error word, then leaves the event
        // path so the following directed nested-entry failure can be tested.
        memory[16'h01D0] = 8'hB8; memory[16'h01D1] = 8'h40; memory[16'h01D2] = 8'h00;
        memory[16'h01D3] = 8'h8E; memory[16'h01D4] = 8'hD8;
        memory[16'h01E0] = 8'h58; memory[16'h01E1] = 8'hE9; memory[16'h01E2] = 8'h0C; memory[16'h01E3] = 8'h00;
        memory[16'h01F0] = 8'hCD; memory[16'h01F1] = 8'h0B;

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

        far_restart(16'h0000, 16'h0099);
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h0100 && debug_cs_base == 24'h000000 &&
              debug_segment_limits[31:16] == 16'h01FF && debug_segment_access[15:8] == 8'h9B && memory[16'h56B5] == 8'h9B,
              "PM2b validates and atomically commits a direct far JMP CS cache with the accessed bit");
        retire_one();
        check(debug_gpr[15:0] == 16'hBEEF, "PM2b executes at the validated protected CS target");

        far_restart(16'h0000, 16'h00A0);
        wait_fault(8'd13);
        check(debug_cs == 16'h0038 && debug_cs_base == 24'h000000 && debug_segment_limits[31:16] == 16'h01FF,
              "PM2b rejects a data descriptor as CS without changing the current CS cache");

        far_restart(16'h0038, 16'h0120);
        wait_event(8'h20);
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h0143 && debug_gpr[15:0] == 16'hADDE && !debug_flags[9] && !debug_flags[8],
              "PM3a interrupt gate validates IDT and clears IF/TF at same privilege");

        far_restart(16'h0038, 16'h0160);
        wait_event(8'h21);
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h0183 && debug_gpr[15:0] == 16'h5AA5 && debug_flags[9] && !debug_flags[8],
              "PM3a trap gate preserves IF while clearing TF at same privilege");

        flags_write_en = 1'b1;
        flags_write_mask = 16'hFFFF;
        flags_write_data = 16'h0202;
        tick();
        flags_write_en = 1'b0;
        far_restart(16'h0038, 16'h01A0);
        retire_one();
        nmi = 1'b1;
        wait_event(8'h02);
        nmi = 1'b0;
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h01A1 && debug_flags[9] && !debug_flags[8],
              "PM3b NMI enters through the protected IDT and same-level IRET restores IP/FLAGS");
        retire_one();
        intr = 1'b1;
        wait_event(8'h22);
        intr = 1'b0;
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h01A2 && debug_flags[9] && !debug_flags[8],
              "PM3b external INTR consumes INTA vector 22 and returns through protected IRET");

        pm4a_return_sp = debug_gpr[79:64];
        far_restart(16'h0038, 16'h01C8);
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h01D8 && debug_gpr[79:64] == pm4a_return_sp - 16'd4 &&
              memory[pm4a_return_sp - 16'd4] == 8'hCD && memory[pm4a_return_sp - 16'd3] == 8'h01 &&
              memory[pm4a_return_sp - 16'd2] == 8'h38 && memory[pm4a_return_sp - 16'd1] == 8'h00 &&
              memory[16'h56D5] == 8'h84,
              "PM4a same-level call gate validates target and pushes return IP/CS before committing");
        retire_one();
        check(debug_gpr[15:0] == 16'hCAFE && debug_cs == 16'h0038,
              "PM4a call-gate target executes at the validated same-level CS");
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h01CD && debug_gpr[79:64] == pm4a_return_sp,
              "PM4a far return restores the same-level call-gate frame");

        // PM4b.2: use the already validated outer IRET path to enter ring 1,
        // then call back through a DPL-1 gate into ring 0 with a TSS stack
        // switch and a copied two-parameter return frame.
        memory[pm4a_return_sp] = 8'h40; memory[pm4a_return_sp + 16'd1] = 8'h02;
        memory[pm4a_return_sp + 16'd2] = 8'h61; memory[pm4a_return_sp + 16'd3] = 8'h00;
        memory[pm4a_return_sp + 16'd4] = 8'h02; memory[pm4a_return_sp + 16'd5] = 8'h02;
        memory[pm4a_return_sp + 16'd6] = 8'h00; memory[pm4a_return_sp + 16'd7] = 8'hFF;
        memory[pm4a_return_sp + 16'd8] = 8'h69; memory[pm4a_return_sp + 16'd9] = 8'h00;
        memory[16'hFF00] = 8'h57; memory[16'hFF01] = 8'h13;
        memory[16'hFF02] = 8'h68; memory[16'hFF03] = 8'h24;
        // The target offset is 0100, which was used by PM2b before this
        // point; rewrite it with a target that restores the saved SP.
        memory[16'h0100] = 8'hB8; memory[16'h0101] = pm4a_return_sp[7:0]; memory[16'h0102] = pm4a_return_sp[15:8];
        memory[16'h0103] = 8'h89; memory[16'h0104] = 8'hC4;
        memory[16'h0105] = 8'hB8; memory[16'h0106] = 8'hDE; memory[16'h0107] = 8'hAD;
        memory[16'h0108] = 8'hF4;
        far_restart(16'h0038, 16'h01B8);
        retire_one();
        check(debug_cs == 16'h0061 && debug_ip == 16'h0240 &&
              debug_segment_selectors[47:32] == 16'h0069 && debug_gpr[79:64] == 16'hFF00 &&
              memory[16'h56DD] == 8'hBB && memory[16'h56E5] == 8'hB3,
              "PM4b.1 outer IRET enters the ring-1 caller and accesses its code/stack descriptors");
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h0100 && debug_segment_selectors[47:32] == 16'h0018 &&
              debug_gpr[79:64] == 16'h9FF4 &&
              memory[16'h9FF4] == 8'h45 && memory[16'h9FF5] == 8'h02 &&
              memory[16'h9FF6] == 8'h61 && memory[16'h9FF7] == 8'h00 &&
              memory[16'h9FF8] == 8'h57 && memory[16'h9FF9] == 8'h13 &&
              memory[16'h9FFA] == 8'h68 && memory[16'h9FFB] == 8'h24 &&
              memory[16'h9FFC] == 8'h00 && memory[16'h9FFD] == 8'hFF &&
              memory[16'h9FFE] == 8'h69 && memory[16'h9FFF] == 8'h00,
              "PM4b.2 inter-level call gate copies parameters before committing the return frame");
        retire_one();
        retire_one();
        check(debug_gpr[79:64] == pm4a_return_sp, "PM4b.2 target can restore the caller stack after parameter copying");
        retire_one();
        check(debug_gpr[15:0] == 16'hADDE && debug_cs == 16'h0038,
              "PM4b.2 target executes after the copied-parameter frame commits");

        flags_write_en = 1'b1;
        flags_write_mask = 16'hFFFF;
        flags_write_data = 16'h0202;
        tick();
        flags_write_en = 1'b0;
        far_restart(16'h0038, 16'h01B0);
        wait_event(8'h22);
        retire_one();
        check(debug_cs == 16'h0038 && debug_ip == 16'h01B2 && debug_flags[9] && !debug_flags[8],
              "PM3b software event returns through validated same-level protected IRET");
        far_restart(16'h0038, 16'h01D0);
        wait_fault(8'h0B);
        retire_one();
        check(debug_gpr[15:0] == 16'h0040 && debug_gpr[79:64] == 16'hFFDE &&
              memory[16'hFFDC] == 8'h40 && memory[16'hFFDD] == 8'h00,
              "PM3c #NP pushes one 16-bit selector error word and the handler consumes it");

        // PM3d uses the current post-error-handler stack position.  The
        // earlier PM3c event occupied the initially reserved FFE0 area, so
        // install the outer-return frame at the live SP after that event.
        memory[16'hFFDE] = 8'h94; memory[16'hFFDF] = 8'h01;
        memory[16'hFFE0] = 8'h4B; memory[16'hFFE1] = 8'h00;
        memory[16'hFFE2] = 8'h02; memory[16'hFFE3] = 8'h02;
        memory[16'hFFE4] = 8'h00; memory[16'hFFE5] = 8'h80;
        memory[16'hFFE6] = 8'h53; memory[16'hFFE7] = 8'h00;
        far_restart(16'h0038, 16'h0190);
        retire_one();
        check(debug_cs == 16'h004B && debug_ip == 16'h0194 && debug_gpr[79:64] == 16'h8000 &&
              debug_segment_selectors[47:32] == 16'h0053 && debug_segment_access[23:16] == 8'hF3 &&
              memory[16'h56C5] == 8'hFB && memory[16'h56CD] == 8'hF3,
              "PM3d outer IRET validates CS and SS then commits IP/CS/SS/FLAGS/SP coherently");
        retire_one();
        check(debug_gpr[15:0] == 16'h1234 && debug_cs == 16'h004B && debug_segment_selectors[47:32] == 16'h0053,
              "PM3d resumes execution on the less-privileged code and stack caches");

        // The gate descriptor remains valid, but its target is now a data
        // segment.  INT 0B therefore faults during protected event entry,
        // while an event is already active, and follows the shutdown policy.
        memory[16'h9B16] = 8'h18; memory[16'h9B17] = 8'h00;
        far_restart(16'h0038, 16'h01F0);
        wait_shutdown();
        check(shutdown && debug_cs == 16'h004B,
              "PM3c nested protected event failure enters shutdown without committing a bad CS");

        $display("PROTECTED_SYSTEM PASS: %0d checks, READY stalls=%0d", checks, cycles);
        $finish;
    end
endmodule
