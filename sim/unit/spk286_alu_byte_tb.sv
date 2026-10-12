// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module spk286_alu_byte_tb;
    logic[2:0]operation;
    logic[15:0]operand_a,operand_b;
    logic carry_in,operand_byte=1;
    wire[15:0]result,candidate_flags;
    logic[15:0]expected_result,expected_flags;
    integer file,status,count=0;
    logic [31:0] vector_op, vector_a, vector_b, vector_c, vector_result, vector_flags;
    string vectors;
    spk286_alu dut(.*);
    initial begin
        if(!$value$plusargs("vectors=%s",vectors))$fatal(1,"missing independent vectors");
        file=$fopen(vectors,"r");if(file==0)$fatal(1,"cannot open vectors");
        while(!$feof(file))begin
            status=$fscanf(file,"%h %h %h %h %h %h\n",vector_op,vector_a,vector_b,vector_c,vector_result,vector_flags);
            if(status!=6)$fatal(1,"malformed independent vector");
            // The high input halves must not participate in byte arithmetic.
            operation=vector_op[2:0];operand_a={8'hE7,vector_a[7:0]};operand_b={8'h51,vector_b[7:0]};carry_in=vector_c[0];
            expected_result=vector_result[15:0];expected_flags=vector_flags[15:0];#1;
            if(result!==expected_result || candidate_flags!==expected_flags)
                $fatal(1,"byte arithmetic mismatch op=%h a=%h b=%h c=%h got=%h/%h expected=%h/%h",operation,operand_a,operand_b,carry_in,result,candidate_flags,expected_result,expected_flags);
            count++;
        end
        $fclose(file);if(count!=589824)$fatal(1,"incomplete exhaustive domain");
        $display("ALU_BYTE PASS: %0d exhaustive independent byte input/carry cases",count);$finish;
    end
endmodule
