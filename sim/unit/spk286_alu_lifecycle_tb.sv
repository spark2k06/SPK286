`timescale 1ns/1ps
module spk286_alu_lifecycle_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    integer checks=0, cases=0, retires=0, writes=0, timeout_count;
    logic permit_read, permit_write, compare_only;
    logic [127:0] saved_gpr;
    logic [15:0] saved_flags, saved_tmp0, saved_tmp1, saved_tmp2;
    logic [11:0] saved_pc;
    logic [15:0] stream_flags [0:7];
    logic [127:0] stream_gpr;
    integer stream_ip;
    integer immediate_cases=0;
    spk286 dut (.*);
    task automatic check(input logic condition, input string message);
        checks=checks+1;
        if (condition !== 1'b1) $fatal(1,"%s case=%0d IP=%h pc=%h flags=%h bus=%h/%h writes=%0d",message,cases,debug_ip,debug_micro_pc,debug_flags,bus_status,address,writes);
    endtask
    task automatic tick;
        #1; data_in=16'hF4F4;
        if (bus_valid && address<65536) data_in={memory[{address[15:1],1'b1}],memory[{address[15:1],1'b0}]};
        #4;
        if (bus_valid && bus_write && ready && !reset) begin
            writes=writes+1;
            if(address[0]) memory[address[15:0]]=data_out[15:8];
            else begin
                memory[address[15:0]]=data_out[7:0];
                if(!bus_bhe_n) memory[address[15:0]+16'd1]=data_out[15:8];
            end
        end
        clk=1; #5; clk=0; #1;
        if(instruction_retired) retires=retires+1;
        check(!microcode_fault && debug_prefetch_count<=6,"control invariants");
    endtask
    task automatic service;
        ready=bus_valid && (bus_status==13 || (bus_status==5 && permit_read) || (bus_status==6 && permit_write)); tick();
    endtask
    task automatic redirect_to(input logic [15:0] ip);
        redirect=1; ip_write_en=1; ip_write_data=ip; tick(); redirect=0; ip_write_en=0;
        check(!instruction_retired && !debug_micro_active && dut.micro_executor.temporary_valid_q==0 &&
              !dut.micro_executor.flags_valid_q,"redirect clears temporary and pending FLAGS state");
    endtask
    task automatic setup(input logic cmp);
        execute_enable=0; reset=1; ready=0; gpr_write_en=0; flags_write_en=0;
        segment_load_en=0; redirect=0; ip_write_en=0; tick(); reset=0;
        gpr_write_en=1; gpr_write_index=0; gpr_write_data=1; tick(); gpr_write_en=0;
        flags_write_en=1; flags_write_mask=16'hFFFF; flags_write_data=16'h7ED7; tick(); flags_write_en=0;
        segment_load_en=1; segment_load_index=1; segment_load_selector=0; redirect_to(16'h0100); segment_load_en=0;
        memory[256]=cmp?8'h39:8'h01; memory[257]=8'h06; memory[258]=1; memory[259]=8'h10; memory[260]=8'hF4;
        memory[512]=8'hBF; memory[513]=8'h34; memory[514]=8'h12; memory[515]=8'hF4;
        memory[4096]=8'h5A; memory[4097]=8'hFF; memory[4098]=8'hFF; memory[4099]=8'hA5;
        retires=0; writes=0; permit_read=0; permit_write=0; compare_only=cmp; execute_enable=1;
    endtask
    function automatic logic at_stage(input integer stage);
        case(stage)
            0,1,2: at_stage=debug_ip==16'h0101+16'(stage);
            3: at_stage=bus_status==5 && address==24'h001001;
            4: at_stage=bus_status==5 && address==24'h001002;
            5: at_stage=dut.memory_response_valid && debug_micro_instruction==spk286_microcode_pkg::MC_READ_RM16;
            6: at_stage=debug_micro_instruction==spk286_microcode_pkg::MC_ALU;
            7: at_stage=debug_micro_instruction==spk286_microcode_pkg::MC_WRITE_RESULT_RM16;
            8: at_stage=bus_status==6 && address==24'h001001;
            9: at_stage=bus_status==6 && address==24'h001002;
            10: at_stage=dut.memory_response_valid && debug_micro_instruction==spk286_microcode_pkg::MC_WRITE_RESULT_RM16;
            11: at_stage=debug_micro_instruction==spk286_microcode_pkg::MC_COMMIT_FLAGS;
            12: at_stage=debug_micro_instruction==spk286_microcode_pkg::MC_END;
            default: at_stage=0;
        endcase
    endfunction
    task automatic reach(input integer stage);
        permit_read=stage>=4; permit_write=stage>=9; timeout_count=0;
        while(!(debug_micro_active && at_stage(stage)) && timeout_count<200) begin service(); timeout_count=timeout_count+1; end
        check(timeout_count<200 && retires==0,"reach ALU dependency/commit boundary");
        ready=0; saved_pc=debug_micro_pc; saved_gpr=debug_gpr; saved_flags=debug_flags;
        saved_tmp0=dut.micro_executor.tmp0_q; saved_tmp1=dut.micro_executor.tmp1_q; saved_tmp2=dut.micro_executor.tmp2_q;
    endtask
    task automatic finish(input logic restarted);
        permit_read=1; permit_write=1; timeout_count=0;
        while(!instruction_retired && timeout_count<250) begin
            service(); timeout_count=timeout_count+1;
            check(!unsupported_opcode && !operand_blocked,"resumed stream executable");
        end
        check(retires==1,"single retirement after lifecycle transition");
        if(restarted) begin
            check(debug_ip==16'h0203 && debug_gpr[127:112]==16'h1234,"replacement stream result");
            check(debug_flags==saved_flags,"canceled ALU cannot commit stale FLAGS into MOV");
        end else begin
            check(debug_ip==16'h0104 && debug_gpr==saved_gpr,"resumed ALU state/IP");
            check(debug_flags==(compare_only?16'h7682:16'h7657),"resumed ALU exact FLAGS");
            check(writes==(compare_only?0:2),"one logical result or no CMP write");
        end
        check(memory[4096]==8'h5A && memory[4099]==8'hA5,"lifecycle neighbor preservation");
        execute_enable=0; repeat(3) service(); check(retires==1,"END pulse clears under pause");
    endtask
    initial begin
        for(integer i=0;i<65536;i=i+1) memory[i]=8'hF4;
        for(integer cmp=0;cmp<2;cmp=cmp+1)
          for(integer stage=0;stage<13;stage=stage+1)
            if(!(cmp!=0 && stage>=8 && stage<=10))
              for(integer action=0;action<4;action=action+1) begin
                setup(1'(cmp)); reach(stage);
                if(action==0) begin
                    execute_enable=0; ready=1;
                    repeat(7) begin
                        tick();
                        check(debug_micro_pc==saved_pc && debug_gpr==saved_gpr && debug_flags==saved_flags && retires==0,
                              "pause holds architectural state across physical completion");
                        check(dut.micro_executor.tmp0_q==saved_tmp0 && dut.micro_executor.tmp1_q==saved_tmp1 &&
                              dut.micro_executor.tmp2_q==saved_tmp2,"pause holds ALU temporaries");
                    end
                    execute_enable=1; redirect=1; ip_write_en=0;
                    repeat(3) begin tick(); check(control_error && debug_flags==saved_flags && debug_micro_pc==saved_pc,"malformed control holds FLAGS and micro-PC"); end
                    redirect=0; finish(0);
                end else if(action<3) begin
                    ready=action==2; redirect_to(16'h0200); finish(1);
                    check(writes==(cmp==0 && stage>=8?2:0),"redirect drains only accepted logical writes");
                end else begin
                    reset=1; ready=1; tick();
                    check(!bus_valid && debug_flags==2 && debug_gpr==0 && !dut.micro_executor.flags_valid_q &&
                          dut.micro_executor.temporary_valid_q==0,"reset cancels ALU and FLAGS");
                    reset=0; execute_enable=0; ready=0; saved_flags=2;
                    segment_load_en=1; segment_load_index=1; segment_load_selector=0;
                    redirect_to(16'h0200); segment_load_en=0; execute_enable=1; finish(1);
                end
                cases=cases+1;
              end
        // TMP1 immediate acquisition must cancel/hold just like operand reads.
        for(integer stage=0;stage<6;stage=stage+1)
          for(integer action=0;action<3;action=action+1) begin
            setup(0);
            memory[256]=8'h15; memory[257]=8'hFF; memory[258]=8'h7F; memory[259]=8'hF4;
            timeout_count=0;
            while(!(debug_micro_active &&
                   ((stage<2 && debug_ip==16'h0101+16'(stage)) ||
                    (stage==2 && debug_micro_instruction==spk286_microcode_pkg::MC_ALU) ||
                    (stage==3 && debug_micro_instruction==spk286_microcode_pkg::MC_WRITE_RESULT_DST) ||
                    (stage==4 && debug_micro_instruction==spk286_microcode_pkg::MC_COMMIT_FLAGS) ||
                    (stage==5 && debug_micro_instruction==spk286_microcode_pkg::MC_END))) && timeout_count<200) begin
                service(); timeout_count=timeout_count+1;
            end
            check(timeout_count<200,"reach immediate partial/result/FLAGS boundary");
            saved_flags=debug_flags; saved_gpr=debug_gpr; saved_pc=debug_micro_pc;
            saved_tmp1=dut.micro_executor.tmp1_q;
            if(action==0) begin
                execute_enable=0; ready=1;
                repeat(7) begin
                    tick(); check(debug_flags==saved_flags && debug_gpr==saved_gpr && debug_micro_pc==saved_pc &&
                                  dut.micro_executor.tmp1_q==saved_tmp1,"pause holds partial immediate and pending result");
                end
                execute_enable=1; timeout_count=0;
                while(!instruction_retired && timeout_count<200) begin service(); timeout_count=timeout_count+1; end
                check(retires==1 && debug_ip==16'h0103 && debug_gpr[15:0]==16'h8001 && debug_flags==16'h7E92,
                      "resumed immediate ADC includes carry and exact FLAGS");
                check(writes==0,"immediate accumulator does not access data memory");
            end else if(action==1) begin
                ready=1; redirect_to(16'h0200); finish(1);
            end else begin
                reset=1; ready=1; tick();
                check(debug_flags==2 && !dut.micro_executor.high_byte_q && dut.micro_executor.temporary_valid_q==0 &&
                      !dut.micro_executor.flags_valid_q,"reset clears partial immediate and candidate FLAGS");
                reset=0; execute_enable=0; ready=0; saved_flags=2;
                segment_load_en=1; segment_load_index=1; segment_load_selector=0;
                redirect_to(16'h0200); segment_load_en=0; execute_enable=1; finish(1);
            end
            immediate_cases=immediate_cases+1;
          end
        // One uninterrupted stream exposes carry and temporary reuse across
        // immediate, both directions, memory, no-write CMP and inherited MOV.
        setup(0); execute_enable=0; ready=0;
        gpr_write_en=1; gpr_write_index=1; gpr_write_data=16'h8000; tick(); gpr_write_en=0;
        memory[256]=8'h15; memory[257]=8'hFF; memory[258]=8'hFF;
        memory[259]=8'h1B; memory[260]=8'hC8;
        memory[261]=8'h09; memory[262]=8'h0E; memory[263]=8'h01; memory[264]=8'h10;
        memory[265]=8'h3B; memory[266]=8'h0E; memory[267]=8'h01; memory[268]=8'h10;
        memory[269]=8'h8B; memory[270]=8'hD9;
        memory[271]=8'h03; memory[272]=8'hD8;
        memory[273]=8'h33; memory[274]=8'hC0;
        memory[275]=8'h15; memory[276]=0; memory[277]=0; memory[278]=8'hF4;
        stream_flags[0]=16'h7613; stream_flags[1]=16'h7E12; stream_flags[2]=16'h7696;
        stream_flags[3]=16'h7617; stream_flags[4]=16'h7617; stream_flags[5]=16'h7606;
        stream_flags[6]=16'h7646; stream_flags[7]=16'h7646;
        stream_gpr=debug_gpr; stream_ip=256; permit_read=1; permit_write=1; execute_enable=1;
        for(integer instruction=0;instruction<8;instruction=instruction+1) begin
            if(instruction_retired) service();
            timeout_count=0;
            while(!instruction_retired && timeout_count<200) begin service(); timeout_count=timeout_count+1; end
            case(instruction)
                0: begin stream_gpr[15:0]=1; stream_ip=259; end
                1: begin stream_gpr[31:16]=16'h7FFE; stream_ip=261; end
                2: stream_ip=265;
                3: stream_ip=269;
                4: begin stream_gpr[63:48]=16'h7FFE; stream_ip=271; end
                5: begin stream_gpr[63:48]=16'h7FFF; stream_ip=273; end
                6: begin stream_gpr[15:0]=0; stream_ip=275; end
                7: stream_ip=278;
                default: $fatal(1,"stream index");
            endcase
            check(retires==instruction+1 && debug_ip==16'(stream_ip),"mixed stream single END and exact IP");
            check(debug_flags==stream_flags[instruction] && debug_gpr==stream_gpr,"mixed stream dependent GPR/FLAGS");
            check(writes==(instruction>=2?2:0),"mixed stream same-value write counted, CMP never writes");
            check({memory[4098],memory[4097]}==16'hFFFF,"mixed stream operand memory");
        end
        $display("ALU_LIFECYCLE PASS: %0d operand and %0d immediate pause/cancel/reset boundary cases; 8 dependent stream instructions; %0d checks",cases,immediate_cases,checks);
        $finish;
    end
endmodule
