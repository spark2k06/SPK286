// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

// Whole-stream measurements include opcode dispatch, retirement boundaries and
// instruction fetch. This bench also runs against the pre-optimization RTL.
module spk286_register_throughput_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:4095];
    integer cycles=0, retires=0, start_cycle=-1, timeout_count=0;
    integer measured_fetches=0, queue_empty=0;
    logic measuring=0, slow_ready=0;
    spk286 dut (.*);

    task automatic tick;
        #1; data_in=16'hF4F4;
        if(bus_valid && address<4096)
            data_in={memory[{address[11:1],1'b1}],memory[{address[11:1],1'b0}]};
        if(measuring) begin
            if(bus_valid && ready) measured_fetches=measured_fetches+1;
            if(debug_prefetch_count==0) queue_empty=queue_empty+1;
            if(bus_write || (bus_valid && bus_status!=13))
                $fatal(1,"register stream unexpectedly accesses operands");
        end
        #4; clk=1; #5; clk=0; #1; cycles=cycles+1;
        if(measuring && start_cycle<0 && debug_micro_active) start_cycle=cycles;
        if(instruction_retired) retires=retires+1;
        if(microcode_fault || unsupported_opcode || operand_blocked || shutdown)
            $fatal(1,"throughput stream failed IP=%h",debug_ip);
    endtask

    task automatic service;
        ready=!slow_ready || (cycles%5==0);
        tick();
    endtask

    initial begin
        for(integer mode=0;mode<3;mode=mode+1)
          for(integer delayed=0;delayed<2;delayed=delayed+1) begin
            measuring=0; execute_enable=0; reset=1; ready=0; tick(); reset=0;
            for(integer i=0;i<4096;i=i+1) memory[i]=8'hF4;
            for(integer i=0;i<64;i=i+1) begin
                if(mode==0 || (mode==2 && i%2==0)) begin
                    memory[256+2*i]=8'h01; memory[257+2*i]=8'hD8; // ADD AX,BX
                end else if(mode==1 && i%2==1) begin
                    memory[256+2*i]=8'h89; memory[257+2*i]=8'hCA; // MOV DX,CX
                end else begin
                    memory[256+2*i]=8'h89; memory[257+2*i]=8'hC1; // MOV CX,AX
                end
            end
            gpr_write_en=1; gpr_write_index=3; gpr_write_data=1; tick();
            gpr_write_index=0; gpr_write_data=mode==1 ? 16'h1234 : 16'd0; tick(); gpr_write_en=0;
            segment_load_en=1; segment_load_index=1; segment_load_selector=0;
            redirect=1; ip_write_en=1; ip_write_data=16'h0100; tick();
            segment_load_en=0; redirect=0; ip_write_en=0;
            execute_enable=1; measuring=1; slow_ready=1'(delayed);
            start_cycle=-1; cycles=0; retires=0; queue_empty=0; measured_fetches=0; timeout_count=0;
            while(retires<64 && timeout_count<3000) begin service(); timeout_count=timeout_count+1; end
            if(retires!=64 || debug_ip!=16'h0180 ||
               debug_gpr[15:0]!=(mode==0 ? 16'd64 : mode==1 ? 16'h1234 : 16'd32) ||
               debug_gpr[31:16]!=(mode==0 ? 16'd0 : mode==1 ? 16'h1234 : 16'd32) ||
               debug_gpr[47:32]!=(mode==1 ? 16'h1234 : 16'd0) ||
               debug_flags!=(mode==1 ? 16'h0002 : 16'h0012))
                $fatal(1,"throughput architectural mismatch mode=%0d GPR=%h FLAGS=%h",mode,debug_gpr,debug_flags);
            $display("REGISTER THROUGHPUT mode=%0d delayed=%0d instructions=64 cycles=%0d fetches=%0d queue_empty=%0d",
                     mode,delayed,cycles-start_cycle,measured_fetches,queue_empty);
          end
        $display("REGISTER THROUGHPUT PASS: six checked streams");
        $finish;
    end
endmodule
