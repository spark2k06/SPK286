`timescale 1ns/1ps
// Exercise the same module as both a source-list definition and repeated
// wrapper includes; the global guard must make this safe.
`include "spk286_instruction_timing.sv"
`include "spk286_instruction_timing.sv"
module spk286_instruction_timing_tb;
    logic [7:0] opcode;
    logic extended_opcode;
    logic [spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] micro_entry;
    logic modrm_valid;
    logic [1:0] modrm_mode;
    logic [2:0] modrm_reg, modrm_rm;
    logic protected_mode;
    logic [1:0] CPL;
    logic operand_odd, branch_known, branch_taken, count_known;
    logic [4:0] count;
    logic [1:0] repeat_kind;
    wire qualified, estimated, requires_modrm, requires_outcome, requires_count;
    wire [9:0] base_clocks, repeat_setup_clocks, repeat_iteration_clocks;
    wire permits_read_wait;
    wire [2:0] ea_clocks;
    wire supported, invalid_opcode;
    wire [2:0] destination, source_index;
    wire [spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] entry;
    integer vector_fd, trace_fd, parsed, vector_id, cases = 0;
    integer op, ext, manual_entry, mode, reg_field, rm_field, pm, privilege, odd;
    integer mod_valid, known_branch, taken, known_count, amount, rep;
    integer exp_qualified, exp_estimated, exp_modrm, exp_outcome, exp_count;
    integer exp_base, exp_setup, exp_iteration, exp_wait, exp_ea;
    string vector_path, trace_path;
    spk286_decoder decoder (.*);
    spk286_instruction_timing dut (.*);
    initial begin
        if (!$value$plusargs("vectors=%s", vector_path)) $fatal(1, "missing timing vectors");
        if (!$value$plusargs("trace=%s", trace_path)) $fatal(1, "missing timing trace");
        vector_fd = $fopen(vector_path, "r"); trace_fd = $fopen(trace_path, "w");
        if (vector_fd == 0 || trace_fd == 0) $fatal(1, "cannot open timing fixture");
        $fdisplay(trace_fd, "id,entry,qualified,estimated,modrm,outcome,count,base,setup,iteration,read_wait,ea");
        while (!$feof(vector_fd)) begin
            parsed = $fscanf(vector_fd,
                "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                vector_id, op, ext, manual_entry, mod_valid, mode, reg_field, rm_field,
                pm, privilege, odd, known_branch, taken, known_count, amount, rep,
                exp_qualified, exp_estimated, exp_modrm, exp_outcome, exp_count,
                exp_base, exp_setup, exp_iteration, exp_wait, exp_ea);
            if (parsed != 26) $fatal(1, "malformed timing fixture");
            opcode = 8'(op); extended_opcode = 1'(ext);
            modrm_valid = 1'(mod_valid); modrm_mode = 2'(mode);
            modrm_reg = 3'(reg_field); modrm_rm = 3'(rm_field);
            protected_mode = 1'(pm); CPL = 2'(privilege); operand_odd = 1'(odd);
            branch_known = 1'(known_branch); branch_taken = 1'(taken);
            count_known = 1'(known_count); count = 5'(amount); repeat_kind = 2'(rep);
            #1;
            micro_entry = manual_entry < 0 ? entry : 10'(manual_entry);
            #1;
            if (manual_entry < 0 && (!supported || invalid_opcode))
                $fatal(1, "caller fixture is not supported by functional decoder");
            if (vector_id != cases + 1) $fatal(1, "timing vector IDs not consecutive");
            if ({qualified, estimated, requires_modrm, requires_outcome, requires_count} !==
                {1'(exp_qualified), 1'(exp_estimated), 1'(exp_modrm), 1'(exp_outcome), 1'(exp_count)} ||
                base_clocks !== 10'(exp_base) || repeat_setup_clocks !== 10'(exp_setup) ||
                repeat_iteration_clocks !== 10'(exp_iteration) ||
                permits_read_wait !== 1'(exp_wait) || ea_clocks !== 3'(exp_ea))
                $fatal(1, "instruction timing caller oracle failed id=%0d opcode=%02h entry=%0d base=%0d expected=%0d",
                       vector_id, opcode, micro_entry, base_clocks, exp_base);
            if (base_clocks == 0) $fatal(1, "legal instruction has silent zero timing");
            $fdisplay(trace_fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                vector_id, micro_entry, qualified, estimated, requires_modrm, requires_outcome,
                requires_count, base_clocks, repeat_setup_clocks, repeat_iteration_clocks,
                permits_read_wait, ea_clocks);
            cases = cases + 1;
        end
        $fclose(vector_fd); $fclose(trace_fd);
        $display("SPK286_INSTRUCTION_TIMING_PASS cases=%0d", cases);
        $finish;
    end
    wire unused_decoder = ^{destination, source_index};
endmodule
