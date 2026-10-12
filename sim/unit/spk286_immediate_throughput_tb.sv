// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

// Same architectural stream on the old and new CPUs. Counts include fetch,
// dispatch and retirement. Memory forms must keep their old service schedule.
module spk286_immediate_throughput_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:4095];
    logic [127:0] expected_gpr;
    logic [15:0] expected_flags, expected_memory;
    integer cycles=0, retires=0, start_cycle=-1, timeout_count=0;
    integer fetches=0, reads=0, writes=0, queue_empty=0, length;
    logic measuring=0, slow_ready=0;
    spk286 dut (.*);

    task automatic tick;
        #1; data_in=16'hF4F4;
        if(bus_valid && address<4096)
            data_in={memory[{address[11:1],1'b1}],memory[{address[11:1],1'b0}]};
        if(measuring) begin
            if(debug_prefetch_count==0) queue_empty=queue_empty+1;
            if(bus_valid && ready) begin
                if(bus_status==13) fetches=fetches+1;
                else if(bus_status==5 || bus_status==6) begin
                    if(address!=24'h000600) $fatal(1,"unexpected operand address %h",address);
                    if(bus_write) begin
                        if(!address[0]) memory[address[11:0]]=data_out[7:0];
                        if(!bus_bhe_n) memory[{address[11:1],1'b1}]=data_out[15:8];
                        writes=writes+1;
                    end else reads=reads+1;
                end else $fatal(1,"unexpected bus class %h",bus_status);
            end
        end
        #4; clk=1; #5; clk=0; #1; cycles=cycles+1;
        if(measuring && start_cycle<0 && debug_micro_active) start_cycle=cycles;
        if(instruction_retired) retires=retires+1;
        if(microcode_fault || unsupported_opcode || operand_blocked || shutdown)
            $fatal(1,"immediate throughput stream failed IP=%h",debug_ip);
    endtask
    task automatic service;
        ready=!slow_ready || (cycles%5==0);
        tick();
    endtask

    initial begin
        for(integer mode=0;mode<13;mode=mode+1)
          for(integer delayed=0;delayed<2;delayed=delayed+1) begin
            measuring=0; execute_enable=0; reset=1; ready=0; tick(); reset=0;
            for(integer i=0;i<4096;i=i+1) memory[i]=8'hF4;
            memory[1536]=0; memory[1537]=0;
            expected_gpr=0; expected_flags=2; expected_memory=0;
            case(mode)
                0,1: begin length=3; expected_gpr[15:0]=64; expected_flags=16'h12; end
                2: begin length=3; expected_gpr[47:32]=16'h1234; end
                3: begin length=2; expected_gpr[15:0]=64; expected_flags=16'h12; end
                4: begin length=2; expected_gpr[15:0]=16'h1200; end
                5: begin length=4; expected_gpr[15:0]=64; expected_flags=16'h12; end
                6: begin length=3; expected_gpr[63:48]=16'h1200; end
                7: begin length=4; expected_gpr[63:48]=16'h1234; end
                8,10: begin length=5; expected_memory=64; expected_flags=16'h12; end
                9: begin length=6; expected_memory=64; expected_flags=16'h12; end
                11: begin length=5; expected_memory=16'h34; end
                12: begin length=6; expected_memory=16'h1234; end
                default: $fatal(1,"unknown mode");
            endcase
            for(integer i=0;i<64;i=i+1) begin
                case(mode)
                    0: begin memory[256+length*i]=8'h05; memory[257+length*i]=1; memory[258+length*i]=0; end
                    1: begin memory[256+length*i]=8'h83; memory[257+length*i]=8'hC0; memory[258+length*i]=1; end
                    2: begin memory[256+length*i]=8'hBA; memory[257+length*i]=8'h34; memory[258+length*i]=8'h12; end
                    3: begin memory[256+length*i]=8'h04; memory[257+length*i]=1; end
                    4: begin memory[256+length*i]=8'hB4; memory[257+length*i]=8'h12; end
                    5: begin memory[256+length*i]=8'h81; memory[257+length*i]=8'hC0; memory[258+length*i]=1; memory[259+length*i]=0; end
                    6: begin memory[256+length*i]=8'hC6; memory[257+length*i]=8'hC7; memory[258+length*i]=8'h12; end
                    7: begin memory[256+length*i]=8'hC7; memory[257+length*i]=8'hC3; memory[258+length*i]=8'h34; memory[259+length*i]=8'h12; end
                    default: begin
                        memory[256+length*i]=mode==8 ? 8'h80 : mode==9 ? 8'h81 : mode==10 ? 8'h83 : mode==11 ? 8'hC6 : 8'hC7;
                        memory[257+length*i]=8'h06; memory[258+length*i]=0; memory[259+length*i]=6;
                        memory[260+length*i]=mode<11 ? 8'h01 : 8'h34;
                        if(length==6) memory[261+length*i]=mode==12 ? 8'h12 : 8'h00;
                    end
                endcase
            end
            segment_load_en=1; segment_load_index=1; segment_load_selector=0;
            redirect=1; ip_write_en=1; ip_write_data=16'h0100; tick();
            segment_load_en=0; redirect=0; ip_write_en=0;
            execute_enable=1; measuring=1; slow_ready=1'(delayed);
            start_cycle=-1; cycles=0; retires=0; reads=0; writes=0; queue_empty=0; fetches=0; timeout_count=0;
            while(retires<64 && timeout_count<10000) begin service(); timeout_count=timeout_count+1; end
            if(retires!=64 || debug_ip!=16'(256+64*length) || debug_gpr!=expected_gpr ||
               debug_flags!=expected_flags || {memory[1537],memory[1536]}!=expected_memory ||
               reads!=(mode>=8 && mode<=10 ? 64 : 0) || writes!=(mode>=8 ? 64 : 0))
                $fatal(1,"immediate stream mismatch mode=%0d GPR=%h FLAGS=%h memory=%h reads=%0d writes=%0d",mode,debug_gpr,debug_flags,{memory[1537],memory[1536]},reads,writes);
            $display("IMMEDIATE THROUGHPUT mode=%0d delayed=%0d instructions=64 cycles=%0d fetches=%0d queue_empty=%0d reads=%0d writes=%0d",
                     mode,delayed,cycles-start_cycle,fetches,queue_empty,reads,writes);
          end
        $display("IMMEDIATE THROUGHPUT PASS: 26 checked register and memory streams");
        $finish;
    end
endmodule
