// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module spk286_alu_tb;
    logic operand_byte=0;
    logic [2:0] operation;
    logic [15:0] operand_a, operand_b;
    logic carry_in;
    wire [15:0] result, candidate_flags;
    logic [15:0] expected_result, expected_flags, mask;
    logic [2:0] vector_operation;
    logic [15:0] vector_a, vector_b;
    logic vector_carry;
    integer file_handle, fields, cases = 0;
    string path;
    spk286_alu dut (.*);
    initial begin
        if (!$value$plusargs("alu_vectors=%s", path)) $fatal(1, "missing ALU vectors");
        file_handle = $fopen(path, "r");
        if (file_handle == 0) $fatal(1, "cannot open ALU vectors");
        while (!$feof(file_handle)) begin
            fields = $fscanf(file_handle, "%h %h %h %h %h %h %h\n", vector_operation, vector_a, vector_b,
                             vector_carry, expected_result, expected_flags, mask);
            if (fields != 7) $fatal(1, "malformed ALU vector");
            // Explicit signal assignments keep file I/O separate from DUT scheduling.
            operation = vector_operation; operand_a = vector_a;
            operand_b = vector_b; carry_in = vector_carry;
            #1;
            if (result !== expected_result) $fatal(1, "ALU result case=%0d op=%d A=%h B=%h C=%b got=%h expected=%h", cases, operation, operand_a, operand_b, carry_in, result, expected_result);
            for (integer bit_index = 0; bit_index < 16; bit_index = bit_index + 1)
                if (mask[bit_index] && candidate_flags[bit_index] !== expected_flags[bit_index])
                    $fatal(1, "ALU flag bit=%0d case=%0d op=%d A=%h B=%h C=%b got=%h expected=%h", bit_index, cases, operation, operand_a, operand_b, carry_in, candidate_flags, expected_flags);
            cases = cases + 1;
        end
        $fclose(file_handle);
        if (cases != 29912) $fatal(1, "incomplete ALU vector set: %0d", cases);
        $display("ALU PASS: %0d independent reference vectors", cases);
        $finish;
    end
endmodule
