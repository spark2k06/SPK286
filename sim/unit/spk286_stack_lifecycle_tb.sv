`timescale 1ns/1ps
module spk286_stack_lifecycle_tb;
    // TF delivery is verified by the event suite; this stream isolates its original datapath contract.
    `include "spk286_signals.svh"
    logic [7:0] memory[0:65535];
    integer checks=0,cases=0,retires=0,writes=0,timeout_count,kind_q;
    logic [127:0] saved_gpr;
    logic [15:0] saved_flags,saved_ip,saved_target,saved_tmp0,saved_tmp1;
    logic [11:0] saved_pc;
    logic saved_target_valid;
    integer expected_stream_ip[0:19];
    integer expected_stream_sp[0:6];
    integer stale_redirects=0,full_redirects=0,accepted_stack_writes=0;
    logic reset_aborted=0;
    spk286 dut(.*);
    task automatic check(input logic ok,input string message);
        checks=checks+1;
        if(ok!==1'b1) $fatal(1,"%s case=%0d kind=%0d IP=%h pc=%h bus=%h/%h retires=%0d SP=%h",message,cases,kind_q,debug_ip,debug_micro_pc,bus_status,address,retires,debug_gpr[79:64]);
    endtask
    task automatic tick;
        #1;data_in=16'hF4F4;
        if(bus_valid && address<65536)data_in={memory[{address[15:1],1'b1}],memory[{address[15:1],1'b0}]};
        #4;
        if(dut.memory_request && dut.memory_request_ready && dut.memory_write)accepted_stack_writes=accepted_stack_writes+1;
        if(bus_valid && bus_write && ready && !reset)begin
            writes=writes+1;
            if(address[0])memory[address[15:0]]=data_out[15:8];
            else begin
                memory[address[15:0]]=data_out[7:0];
                if(!bus_bhe_n)memory[address[15:0]+16'd1]=data_out[15:8];
            end
        end
        if(dut.internal_redirect && bus_valid && bus_status==13 && !ready)stale_redirects=stale_redirects+1;
        if(dut.internal_redirect && debug_prefetch_count==6)full_redirects=full_redirects+1;
        clk=1;#5;clk=0;#1;
        if(instruction_retired)retires=retires+1;
        check(!microcode_fault && debug_prefetch_count<=6,"lifecycle control invariants");
    endtask
    task automatic service;
        ready=bus_valid;tick();
    endtask
    task automatic redirect_to(input logic[15:0] ip);
        redirect=1;ip_write_en=1;ip_write_data=ip;tick();redirect=0;ip_write_en=0;
        check(!debug_micro_active && !instruction_retired && !dut.micro_executor.target_valid_q &&
              dut.micro_executor.temporary_valid_q==0,"external redirect clears candidate target/temporaries");
    endtask
    task automatic setup(input integer kind);
        kind_q=kind;execute_enable=0;reset=1;ready=0;gpr_write_en=0;flags_write_en=0;
        segment_load_en=0;redirect=0;ip_write_en=0;tick();reset=0;
        for(integer r=0;r<8;r=r+1)begin
            gpr_write_en=1;gpr_write_index=3'(r);gpr_write_data=r==4?16'h1003:(r==1?16'd2:16'h55AA);tick();
        end
        gpr_write_en=0;flags_write_en=1;flags_write_mask=16'hFFFF;flags_write_data=16'h7ED7;tick();flags_write_en=0;
        segment_load_en=1;segment_load_index=1;segment_load_selector=0;redirect_to(16'h0100);segment_load_en=0;
        for(integer b=256;b<300;b=b+1)memory[b]=8'hF4;
        case(kind)
            0:begin memory[256]=8'hE8;memory[257]=8'h7D;memory[258]=0;end
            1:begin memory[256]=8'hC2;memory[257]=5;memory[258]=0;end
            2:memory[256]=8'h54;
            3:memory[256]=8'h5C;
            4:begin memory[256]=8'hFF;memory[257]=8'h16;memory[258]=1;memory[259]=8'h12;end
            5:begin memory[256]=8'hEB;memory[257]=8'h7E;end
            default:$fatal(1,"invalid lifecycle kind");
        endcase
        memory[512]=8'hBF;memory[513]=8'h34;memory[514]=8'h12;memory[515]=8'hF4;
        memory[520]=8'hBF;memory[521]=8'h78;memory[522]=8'h56;memory[523]=8'hF4;
        memory[16'h1000]=8'h5A;memory[16'h1001]=0;memory[16'h1002]=0;
        memory[16'h1003]=8'h80;memory[16'h1004]=1;memory[16'h1005]=8'hA5;
        memory[16'h1201]=8'h80;memory[16'h1202]=1;
        retires=0;writes=0;accepted_stack_writes=0;reset_aborted=0;execute_enable=1;
    endtask
    function automatic logic at_stage(input integer stage);
        case(stage)
            0:at_stage=debug_ip==16'h0101;
            1:at_stage=debug_ip==16'h0102;
            2:at_stage=dut.stack_request && !dut.operand.pending_q;
            3:at_stage=bus_valid && (bus_status==5 || bus_status==6) &&
                       address==(kind_q==1 || kind_q==3?24'h001003:24'h001001);
            4:at_stage=bus_valid && (bus_status==5 || bus_status==6) &&
                       address==(kind_q==1 || kind_q==3?24'h001004:24'h001002);
            5:at_stage=dut.stack_request && dut.memory_response_valid;
            6:at_stage=debug_micro_instruction==spk286_microcode_pkg::MC_REDIRECT;
            7:at_stage=debug_micro_instruction==spk286_microcode_pkg::MC_END;
            default:at_stage=0;
        endcase
    endfunction
    task automatic reach(input integer stage);
        timeout_count=0;
        while(!(debug_micro_active && at_stage(stage)) && timeout_count<300)begin service();timeout_count=timeout_count+1;end
        check(timeout_count<300 && retires==0,"reach stack/target/END dependency boundary");
        ready=0;saved_gpr=debug_gpr;saved_flags=debug_flags;saved_pc=debug_micro_pc;saved_ip=debug_ip;
        saved_tmp0=dut.micro_executor.tmp0_q;saved_tmp1=dut.micro_executor.tmp1_q;
        saved_target=dut.micro_executor.target_q;saved_target_valid=dut.micro_executor.target_valid_q;
    endtask
    task automatic finish(input integer replacement);
        timeout_count=0;
        while(!instruction_retired && timeout_count<300)begin
            service();timeout_count=timeout_count+1;
            check(!unsupported_opcode && !operand_blocked,"resumed stack/control executable");
        end
        check(retires==1 && debug_flags==saved_flags,"exactly one retirement and FLAGS preserved");
        if(replacement!=0)begin
            check(debug_ip==(replacement==2?16'h020B:16'h0203),"latest external redirect IP");
            check(debug_gpr[111:0]==saved_gpr[111:0] && debug_gpr[127:112]==(replacement==2?16'h5678:16'h1234),
                  "no stale SP/destination update after cancel");
        end else begin
            check(debug_ip==(kind_q==2 || kind_q==3?16'h0101:16'h0180),"resumed exact stack/control IP");
            check(debug_gpr[79:64]==(kind_q==1?16'h100A:kind_q==3?16'h0180:16'h1001),"resumed exact SP ordering");
            if(kind_q==0 || kind_q==2 || kind_q==4)begin
                check(writes==2,"one accepted odd stack word");
                check({memory[16'h1002],memory[16'h1001]}==(kind_q==2?16'h1003:kind_q==4?16'h0104:16'h0103),
                      "PUSH SP source and CALL architectural return IP");
            end else check(writes==0,"POP and RET do not write stack");
        end
        if(!reset_aborted)check(writes==2*accepted_stack_writes,"cancel drains each accepted stack word exactly once");
        check(memory[16'h1000]==8'h5A && memory[16'h1005]==8'hA5,"stack neighbors preserved");
        execute_enable=0;repeat(3)service();check(retires==1,"no duplicate END under pause");
    endtask
    initial begin
        for(integer a=0;a<65536;a=a+1)memory[a]=8'hF4;
        for(integer kind=0;kind<5;kind=kind+1)
          for(integer stage=0;stage<8;stage=stage+1)
            if(!((kind==2 || kind==3) && (stage==1 || stage==6)))
              for(integer action=0;action<5;action=action+1)begin
                setup(kind);reach(stage);
                if(action==0)begin
                    execute_enable=0;ready=1;
                    repeat(7)begin
                        tick();check(debug_gpr==saved_gpr && debug_flags==saved_flags && debug_ip==saved_ip &&
                                     debug_micro_pc==saved_pc && retires==0,"pause holds architectural stack and target state");
                        check(dut.micro_executor.tmp0_q==saved_tmp0 && dut.micro_executor.tmp1_q==saved_tmp1 &&
                              dut.micro_executor.target_q==saved_target && dut.micro_executor.target_valid_q==saved_target_valid,
                              "pause holds temporaries and candidate target");
                    end
                    execute_enable=1;redirect=1;ip_write_en=0;
                    repeat(3)begin tick();check(control_error && debug_gpr==saved_gpr && debug_micro_pc==saved_pc,
                                               "malformed control suppresses SP and redirect");end
                    redirect=0;finish(0);
                end else if(action==3)begin
                    reset_aborted=1;reset=1;ready=1;tick();
                    check(debug_gpr==0 && debug_flags==2 && !bus_valid && !dut.micro_executor.target_valid_q,
                          "reset aborts stack bus and candidate target");
                    reset=0;execute_enable=0;ready=0;saved_gpr=0;saved_flags=2;
                    segment_load_en=1;segment_load_index=1;segment_load_selector=0;
                    redirect_to(16'h0200);segment_load_en=0;execute_enable=1;finish(1);
                end else begin
                    ready=action==2;redirect_to(16'h0200);
                    if(action==4)begin ready=0;redirect_to(16'h0208);end
                    finish(action==4?2:1);
                end
                cases=cases+1;
              end
        // A full queue and an outstanding wrong-path fetch must both be discarded.
        for(integer fill=0;fill<2;fill=fill+1)begin
            setup(5);timeout_count=0;
            while(debug_micro_instruction!=spk286_microcode_pkg::MC_TARGET_REL16 && timeout_count<100)begin service();timeout_count=timeout_count+1;end
            check(timeout_count<100,"reach relative target formation");
            if(fill==0)begin
                redirect=1;ip_write_en=0;ready=0;repeat(8)tick();
                check(bus_valid && bus_status==13,"hold outstanding wrong-path code fetch");redirect=0;
            end else begin
                redirect=1;ip_write_en=0;repeat(20)service();
                check(control_error && debug_prefetch_count==6,"fill complete six-byte queue under execution hold");redirect=0;
            end
            memory[16'h0180]=8'hBE;memory[16'h0181]=8'hEF;memory[16'h0182]=8'hBE;
            ready=0;tick();tick();
            check(debug_ip==16'h0180 && debug_prefetch_count==0,"taken redirect atomically flushes queue and sets target IP");
            timeout_count=0;
            while(retires<2 && timeout_count<150)begin service();timeout_count=timeout_count+1;end
            check(retires==2 && debug_ip==16'h0183 && debug_gpr[111:96]==16'hBEEF,"wrong-path fetch cannot execute after redirect");
        end
        check(stale_redirects>0 && full_redirects>0,"outstanding stale fetch and full queue exercised");
        // Observe the pre-delivery invalid/unsupported boundary under pause.
        // Complete #UD frames and non-retirement belong to the event suite.
        for(integer group_number=0;group_number<8;group_number=group_number+1)
          for(integer form=0;form<2;form=form+1)
            if((form==0 && group_number!=0) || (form==1 && group_number!=2 && group_number!=4 && group_number!=6))begin
                setup(0);memory[256]=form==0?8'h8F:8'hFF;memory[257]=8'hC0+8'(group_number*8);
                saved_gpr=debug_gpr;saved_flags=debug_flags;timeout_count=0;
                while(!unsupported_opcode && !dut.invalid_form && timeout_count<100)begin service();timeout_count=timeout_count+1;end
                execute_enable=0;
                repeat(6)service();
                check((unsupported_opcode || dut.invalid_form) && retires==0 && writes==0 && debug_gpr==saved_gpr && debug_flags==saved_flags,
                      "invalid group cannot partially execute");
                check(dut.invalid_form==(form==0 || group_number==3 || group_number==5 || group_number==7),
                      "invalid encoding is distinct from legal unsupported form");
                execute_enable=1;
                redirect_to(16'h0200);finish(1);
            end
        // Repeated transfer to the identical address must still flush and retire.
        setup(5);memory[257]=8'hFE;
        for(integer i=0;i<4;i=i+1)begin
            if(instruction_retired)service();timeout_count=0;
            while(!instruction_retired && timeout_count<100)begin service();timeout_count=timeout_count+1;end
            check(retires==i+1 && debug_ip==16'h0100 && debug_prefetch_count==0,"same-target redirect has one retirement");
        end
        // Two nested calls per iteration, stack dependencies, taken/backward LOOP,
        // then not-taken LOOP/JNZ, JCXZ and chained redirects with poison fallthrough.
        setup(0);execute_enable=0;ready=0;
        memory[16'h0100]=8'hE8;memory[16'h0101]=8'h3D;memory[16'h0102]=0;
        memory[16'h0140]=8'hE8;memory[16'h0141]=8'h1D;memory[16'h0142]=0;memory[16'h0143]=8'hC3;
        memory[16'h0160]=8'h50;memory[16'h0161]=8'h5B;memory[16'h0162]=8'hC3;
        memory[16'h0103]=8'hE2;memory[16'h0104]=8'hFB;
        memory[16'h0105]=8'h74;memory[16'h0106]=3;
        memory[16'h0107]=8'hBF;memory[16'h0108]=8'hAD;memory[16'h0109]=8'hDE;
        memory[16'h010A]=8'hE3;memory[16'h010B]=3;
        memory[16'h010C]=8'hBF;memory[16'h010D]=8'hAD;memory[16'h010E]=8'hDE;
        memory[16'h010F]=8'hEB;memory[16'h0110]=3;
        memory[16'h0111]=8'hBF;memory[16'h0112]=8'hAD;memory[16'h0113]=8'hDE;
        memory[16'h0114]=8'hBE;memory[16'h0115]=8'hEF;memory[16'h0116]=8'hBE;
        memory[16'h0117]=8'h75;memory[16'h0118]=8'hE7;
        memory[16'h0119]=8'hBA;memory[16'h011A]=8'hFE;memory[16'h011B]=8'hCA;
        expected_stream_ip[0]='h140;expected_stream_ip[1]='h160;expected_stream_ip[2]='h161;expected_stream_ip[3]='h162;
        expected_stream_ip[4]='h143;expected_stream_ip[5]='h103;expected_stream_ip[6]='h100;
        for(integer i=0;i<7;i=i+1)expected_stream_ip[i+7]=expected_stream_ip[i];expected_stream_ip[13]='h105;
        expected_stream_ip[14]='h10A;expected_stream_ip[15]='h10F;expected_stream_ip[16]='h114;
        expected_stream_ip[17]='h117;expected_stream_ip[18]='h119;expected_stream_ip[19]='h11C;
        expected_stream_sp[0]='h1001;expected_stream_sp[1]='h0FFF;expected_stream_sp[2]='h0FFD;
        expected_stream_sp[3]='h0FFF;expected_stream_sp[4]='h1001;expected_stream_sp[5]='h1003;expected_stream_sp[6]='h1003;
        execute_enable=1;
        for(integer i=0;i<20;i=i+1)begin
            if(instruction_retired)service();timeout_count=0;
            while(!instruction_retired && timeout_count<200)begin service();timeout_count=timeout_count+1;end
            check(retires==i+1 && debug_ip==16'(expected_stream_ip[i]),"nested stream exact retirement IP");
            check(debug_gpr[79:64]==(i<14?16'(expected_stream_sp[i%7]):16'h1003),"nested stream stack balance");
            check(debug_gpr[31:16]==(i<6?16'd2:i<13?16'd1:16'd0),"LOOP count dependencies");
            check(debug_flags==16'h7ED7 && debug_cs==0 && debug_gpr[127:112]==16'h55AA,"FLAGS CS and poisoned wrong-path register preserved");
        end
        check(debug_gpr[111:96]==16'hBEEF && debug_gpr[47:32]==16'hCAFE && debug_gpr[63:48]==16'h55AA,
              "nested stream dependent stack values and fallthrough results");
        $display("STACK_LIFECYCLE PASS: %0d pause/cancel/reset cases; full/stale queue redirects; 20 nested stream instructions; %0d checks",cases,checks);
        $finish;
    end
endmodule
