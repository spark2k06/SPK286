`timescale 1ns/1ps
// Compare the new ROM/sequencer pair with the committed asynchronous pair.
module spk286_sync_microcode_tb;
    localparam integer AW = spk286_microcode_pkg::MC_ADDR_WIDTH;
    localparam integer WW = spk286_microcode_pkg::MC_WORD_WIDTH;
    logic clk = 0, reset = 1, cancel = 0, enable = 1, start = 0;
    logic operation_done = 0, operation_retire = 0;
    logic branch_request = 0, branch_target_valid = 0;
    logic [AW-1:0] start_entry = 0, branch_target = 0;
    wire old_ready, old_operation, old_active, old_retired, old_fault;
    wire new_ready, new_operation, new_active, new_retired, new_fault;
    wire [AW-1:0] old_pc, new_pc, old_entry, new_entry, next_pc;
    wire [WW-1:0] old_word, new_word;
    wire old_valid, new_valid;
    logic [AW-1:0] sweep_address = 0;
    wire [WW-1:0] sweep_old_word, sweep_new_word;
    wire sweep_old_valid, sweep_new_valid;
    logic [31:0] random_state = 32'h286C_7A51;
    integer checks = 0;
    integer valid_entries = 0, invalid_entries = 0, random_cycles = 0;

    spk286_microcode_rom reference_rom(.address(old_pc), .word(old_word), .valid(old_valid));
    spk286_microcode_sync_rom synchronous_rom(.clk(clk), .address(next_pc), .word(new_word), .valid(new_valid));
    reference_microsequencer #(.ADDRESS_WIDTH(AW), .ROM_DEPTH(spk286_microcode_pkg::MC_DEPTH)) old_sequencer (
        .clk(clk), .reset(reset), .cancel(cancel), .enable(enable), .start(start), .start_entry(start_entry),
        .start_ready(old_ready), .rom_valid(old_valid), .rom_end(old_word == spk286_microcode_pkg::MC_END),
        .operation_done(operation_done), .operation_retire(operation_retire),
        .branch_request(branch_request), .branch_target_valid(branch_target_valid), .branch_target(branch_target),
        .operation_valid(old_operation), .active(old_active), .micro_pc(old_pc), .micro_entry(old_entry),
        .retired(old_retired), .fault(old_fault)
    );
    spk286_microsequencer #(.ADDRESS_WIDTH(AW), .ROM_DEPTH(spk286_microcode_pkg::MC_DEPTH)) new_sequencer (
        .clk(clk), .reset(reset), .cancel(cancel), .enable(enable), .start(start), .start_entry(start_entry),
        .start_ready(new_ready), .rom_valid(new_valid), .rom_end(new_word == spk286_microcode_pkg::MC_END),
        .operation_done(operation_done), .operation_retire(operation_retire),
        .branch_request(branch_request), .branch_target_valid(branch_target_valid), .branch_target(branch_target),
        .operation_valid(new_operation), .active(new_active), .micro_pc(new_pc), .next_micro_pc(next_pc),
        .micro_entry(new_entry), .retired(new_retired), .fault(new_fault)
    );
    spk286_microcode_rom sweep_reference(.address(sweep_address), .word(sweep_old_word), .valid(sweep_old_valid));
    spk286_microcode_sync_rom sweep_sync(.clk(clk), .address(sweep_address), .word(sweep_new_word), .valid(sweep_new_valid));

    task automatic check;
        if ({old_ready,old_operation,old_active,old_retired,old_fault,old_pc,old_entry,old_word,old_valid} !==
            {new_ready,new_operation,new_active,new_retired,new_fault,new_pc,new_entry,new_word,new_valid})
            $fatal(1, "ROM/sequencer divergence old=%h/%h new=%h/%h at check %0d",old_pc,old_word,new_pc,new_word,checks);
        checks = checks + 1;
    endtask
    task automatic tick;
        logic [AW-1:0] expected_pc;
        #4; expected_pc = next_pc; clk = 1; #4;
        if (new_pc !== expected_pc) $fatal(1, "sampled ROM address differs from new PC");
        check(); clk = 0; #1;
    endtask
    initial begin
        tick(); reset = 0;
        // Every encoded and invalid address is compared after a single edge.
        for (integer address = 0; address < (1 << AW); address = address + 1) begin
            sweep_address = AW'(address); tick();
            if ({sweep_old_valid,sweep_old_word} !== {sweep_new_valid,sweep_new_word})
                $fatal(1,"synchronous ROM content differs at address %h",sweep_address);
            checks = checks + 1;
            if (sweep_old_valid) valid_entries = valid_entries + 1;
            else invalid_entries = invalid_entries + 1;
            // Launch each address, including invalid starts, then hold and
            // advance. Cancellation must discard its context in one edge.
            cancel = 1; tick(); cancel = 0; start = 1; start_entry = AW'(address);
            operation_done = 0; tick(); start = 0; tick();
            operation_done = 1; tick(); tick();
        end
        for (integer cycle = 0; cycle < 100000; cycle = cycle + 1) begin
            random_state = {random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            reset = random_state[18:14] == 0;
            cancel = random_state[23:19] == 0;
            enable = random_state[0]; start = random_state[1];
            operation_done = random_state[2]; operation_retire = random_state[3];
            branch_request = random_state[4]; branch_target_valid = random_state[5];
            start_entry = random_state[AW+5:6]; branch_target = random_state[AW+16:17];
            tick(); random_cycles = random_cycles + 1;
        end
        if (valid_entries != 743 || invalid_entries != 281 || random_cycles != 100000)
            $fatal(1,"ROM/sequence coverage incomplete");
        $display("SYNC_MICROCODE PASS: %0d cycle/content checks, %0d valid / %0d invalid words, %0d arbitrary control cycles",
                 checks,valid_entries,invalid_entries,random_cycles);
        $finish;
    end
endmodule
