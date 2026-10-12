// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module spk286_muldiv_lifecycle_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    integer checks=0,cases=0,retired_count=0,deliveries=0,data_count=0,write_count=0,acknowledgements=0;
    integer timeout_count,waits=0,delay_length=0,kind,steps;
    logic narrow;
    logic [31:0] dividend;
    logic [15:0] source,normal_low,normal_high,normal_candidate,normal_mask,normal_flags,initial_flags;
    logic [127:0] initial_gpr,normal_gpr,saved_gpr;
    logic [15:0] saved_flags;
    logic [11:0] saved_pc;
    logic [217:0] saved_service;
    wire [217:0] service_state={dut.micro_executor.muldiv_service.product_q,dut.micro_executor.muldiv_service.quotient_q,
        dut.micro_executor.muldiv_service.factor_q,dut.micro_executor.muldiv_service.multiplier_q,
        dut.micro_executor.muldiv_service.divisor_q,dut.micro_executor.muldiv_service.remainder_q,
        dut.micro_executor.muldiv_service.remaining_q,dut.micro_executor.muldiv_service.response_valid,dut.micro_executor.muldiv_service.busy_q,
        dut.micro_executor.muldiv_service.result_low,dut.micro_executor.muldiv_service.result_high,
        dut.micro_executor.muldiv_service.candidate_flags,dut.micro_executor.muldiv_service.flags_mask,
        dut.micro_executor.muldiv_service.result_write,dut.micro_executor.muldiv_service.arithmetic_fault};
    spk286 dut (.*);
    task automatic check(input logic condition,input string message);
        checks++;
        if(condition !== 1'b1) $fatal(1,"%s case=%0d kind=%0d narrow=%0d IP=%h pc=%h AX=%h DX=%h flags=%h retired=%0d events=%0d",
            message,cases,kind,narrow,debug_ip,debug_micro_pc,debug_gpr[15:0],debug_gpr[47:32],debug_flags,retired_count,deliveries);
    endtask
    function automatic logic [15:0] word_at(input logic [15:0] offset);
        word_at={memory[offset+16'd1],memory[offset]};
    endfunction
    task automatic tick;
        #1; data_in=16'h0F0F;
        if(bus_valid && address<65536) data_in={memory[{address[15:1],1'b1}],memory[{address[15:1],1'b0}]};
        if(bus_valid && bus_status==0)data_in=16'h2323;
        #4;
        if(bus_valid && ready && !reset) begin
            if(bus_status==0) acknowledgements++;
            if(bus_status==5 || bus_status==6) begin
                data_count++;
                if(bus_write) begin
                    write_count++;
                    if(address[0]) memory[address[15:0]]=data_out[15:8];
                    else begin
                        memory[address[15:0]]=data_out[7:0];
                        if(!bus_bhe_n) memory[address[15:0]+16'd1]=data_out[15:8];
                    end
                end
            end
        end
        clk=1; #5; clk=0; #1;
        if(instruction_retired) retired_count++;
        if(event_completed) deliveries++;
        check(!microcode_fault && debug_prefetch_count<=6 && !shutdown,"arithmetic control/queue invariants");
    endtask
    task automatic service;
        ready=bus_valid && waits>=delay_length;
        if(bus_valid && !ready) waits++; else waits=0;
        tick();
    endtask
    task automatic setup(input integer variant,input logic [15:0] flags_value,input logic [15:0] sp);
        case(variant)
            0: begin kind=0; narrow=0; dividend=32'hABCD8001; source=16'h0003; normal_low=16'h8003; normal_high=16'h0001; normal_candidate=16'h0801; normal_mask=16'h08C5; end
            1: begin kind=1; narrow=0; dividend=32'h5678FFFD; source=16'h0007; normal_low=16'hFFEB; normal_high=16'hFFFF; normal_candidate=16'h0084; normal_mask=16'h08C5; end
            2: begin kind=2; narrow=0; dividend=32'h0001789A; source=16'h0101; normal_low=16'h0177; normal_high=16'h0023; normal_candidate=16'h0000; normal_mask=16'h0000; end
            3: begin kind=3; narrow=0; dividend=32'hFFFFD431; source=16'hFF85; normal_low=16'h005B; normal_high=16'hFFEA; normal_candidate=16'h0000; normal_mask=16'h0000; end
            4: begin kind=0; narrow=1; dividend=32'hABCDA580; source=16'h0003; normal_low=16'h0180; normal_high=16'h0000; normal_candidate=16'h0801; normal_mask=16'h08C5; end
            5: begin kind=1; narrow=1; dividend=32'h5678A5FD; source=16'h0007; normal_low=16'hFFEB; normal_high=16'h0000; normal_candidate=16'h0084; normal_mask=16'h08C5; end
            6: begin kind=2; narrow=1; dividend=32'hABCD02E2; source=16'h000D; normal_low=16'h0A38; normal_high=16'h0000; normal_candidate=16'h0000; normal_mask=16'h0000; end
            7: begin kind=3; narrow=1; dividend=32'h5678FFD1; source=16'h0007; normal_low=16'hFBFA; normal_high=16'h0000; normal_candidate=16'h0000; normal_mask=16'h0000; end
            default: $fatal(1,"unknown independent arithmetic vector");
        endcase
        steps=kind>=2?32:narrow?8:16;
        execute_enable=0;reset=1;ready=0;intr=0;nmi=0;hold_request=0;
        gpr_write_en=0;segment_load_en=0;flags_write_en=0;redirect=0;ip_write_en=0;waits=0;
        tick();reset=0;
        initial_gpr={16'h3344,16'h1122,16'h7000,sp,source,dividend[31:16],16'h5678,dividend[15:0]};
        normal_gpr=initial_gpr;normal_gpr[15:0]=normal_low;
        if(!narrow)normal_gpr[47:32]=normal_high;
        for(integer reg_index=0;reg_index<8;reg_index++)begin
            gpr_write_en=1;gpr_write_index=3'(reg_index);gpr_write_data=initial_gpr[reg_index*16+:16];tick();
        end
        gpr_write_en=0;flags_write_en=1;flags_write_mask=16'hFFFF;flags_write_data=flags_value;tick();flags_write_en=0;
        initial_flags=flags_value;normal_flags=(flags_value & ~normal_mask)|normal_candidate;
        segment_load_en=1;segment_load_index=1;segment_load_selector=0;
        redirect=1;ip_write_en=1;ip_write_data=16'h0100;tick();redirect=0;ip_write_en=0;segment_load_en=0;
        for(integer i=256;i<280;i++)memory[i]=8'h0F;
        memory[256]=8'hF3;memory[257]=8'h26;memory[258]=narrow?8'hF6:8'hF7;memory[259]=8'hE3+8'(kind*8);
        memory[512]=8'hF6;memory[513]=8'hD4;memory[514]=8'h0F;
        for(integer vector_value=0;vector_value<14;vector_value++)begin
            memory[vector_value*4]=0;memory[vector_value*4+1]=4;memory[vector_value*4+2]=0;memory[vector_value*4+3]=0;
        end
        memory[140]=0;memory[141]=4;memory[142]=0;memory[143]=0;memory[1024]=8'h0F;
        for(integer i=8160;i<8200;i++)memory[i]=8'hA5;
        retired_count=0;deliveries=0;data_count=0;write_count=0;acknowledgements=0;execute_enable=1;
    endtask
    task automatic wait_operation(input logic [spk286_microcode_pkg::MC_WORD_WIDTH-1:0] operation);
        timeout_count=0;
        while(!(debug_micro_active && debug_micro_instruction==operation) && timeout_count<300)begin service();timeout_count++;end
        check(timeout_count<300 && retired_count==0 && deliveries==0,"reach requested integer operation");ready=0;
    endtask
    task automatic reach(input integer variant,input integer stage);
        setup(variant,16'h0CD7,16'h2000);
        if(stage==0)wait_operation(spk286_microcode_pkg::MC_DECODE_MODRM);
        else if(stage==1)wait_operation(narrow?spk286_microcode_pkg::MC_READ_RM8:spk286_microcode_pkg::MC_READ_RM16);
        else begin
            wait_operation(narrow?spk286_microcode_pkg::MC_MULDIV8:spk286_microcode_pkg::MC_MULDIV16);
            if(stage>=3 && stage<=steps+3)begin
                tick();check(dut.micro_executor.muldiv_service.busy_q,"arithmetic request captured");
                repeat(stage-3)tick();
                check(stage==steps+3?dut.micro_executor.muldiv_valid:dut.micro_executor.muldiv_service.busy_q,"iteration/response boundary reached");
            end
            if(stage>=steps+4)wait_operation(spk286_microcode_pkg::MC_WRITE_RESULT_AX16);
            if(stage>=steps+5)wait_operation(narrow?spk286_microcode_pkg::MC_COMMIT_FLAGS:spk286_microcode_pkg::MC_WRITE_RESULT_DX16);
            if(stage>=steps+6)wait_operation(narrow?spk286_microcode_pkg::MC_CHECK_ARITHMETIC:spk286_microcode_pkg::MC_COMMIT_FLAGS);
            if(stage>=steps+7)wait_operation(narrow?spk286_microcode_pkg::MC_END:spk286_microcode_pkg::MC_CHECK_ARITHMETIC);
            if(stage>=steps+8)wait_operation(spk286_microcode_pkg::MC_END);
        end
    endtask
    task automatic finish_normal(input logic redirected);
        timeout_count=0;
        while(retired_count==0 && timeout_count<300)begin service();timeout_count++;check(!unsupported_opcode && !operand_blocked,"normal arithmetic stream executable");end
        check(retired_count==1 && deliveries==0 && data_count==0,"one arithmetic retirement without data writes or event");
        check(debug_ip==(redirected?16'h0202:16'h0104),"exact next instruction address");
        if(redirected)begin
            saved_gpr[15:0]=saved_gpr[15:0]^16'hFF00;
            check(debug_gpr==saved_gpr && debug_flags==saved_flags,"cancel discards only uncommitted state before independent NOT AH");
        end else check(debug_gpr==normal_gpr && debug_flags==normal_flags,"all arithmetic results and flags commit exactly once");
    endtask
    task automatic finish_event(input integer vector_value,input logic fault,input logic [15:0] sp);
        timeout_count=0;
        while(deliveries==0 && timeout_count<800)begin service();timeout_count++;end
        check(deliveries==1 && int'(debug_event_vector)==vector_value && debug_ip==16'h0400 && debug_cs==0 && retired_count==(fault?0:1),"correct event identity and retirement boundary");
        saved_gpr=fault?initial_gpr:normal_gpr;saved_gpr[79:64]=sp-6;
        saved_flags=fault?initial_flags:normal_flags;
        check(debug_gpr==saved_gpr && debug_flags==(saved_flags & ~16'h0300),"event preserves every arithmetic GPR and defined status");
        check(word_at(sp-6)==(fault?16'h0100:16'h0104) && word_at(sp-4)==0 && word_at(sp-2)==saved_flags,"complete unmasked first-prefix or next-IP/CS/FLAGS frame");
        check(write_count==(sp[0]?6:3) && data_count==write_count+2 && acknowledgements==(vector_value==35?2:0),"exact odd/even frame, IVT and acknowledge traffic");
    endtask
    initial begin
        for(integer i=0;i<65536;i++)memory[i]=8'h0F;
        for(integer variant=0;variant<8;variant++)begin
            setup(variant,16'h0CD7,16'h2000);
            for(integer stage=0;stage<steps+(narrow?8:9);stage++)begin
                reach(variant,stage);saved_pc=debug_micro_pc;saved_gpr=debug_gpr;saved_flags=debug_flags;saved_service=service_state;
                execute_enable=0;
                repeat(7)begin service();check(debug_micro_pc==saved_pc && debug_gpr==saved_gpr && debug_flags==saved_flags && service_state==saved_service && retired_count==0 && deliveries==0,"pause holds every arithmetic iteration and result boundary");end
                execute_enable=1;finish_normal(0);cases++;
                reach(variant,stage);saved_gpr=debug_gpr;saved_flags=debug_flags;
                redirect=1;ip_write_en=1;ip_write_data=16'h0200;tick();redirect=0;ip_write_en=0;
                check(!debug_micro_active && !dut.micro_executor.muldiv_valid && !dut.micro_executor.muldiv_service.busy_q && !dut.micro_executor.arithmetic_fault_q && !dut.micro_executor.result_high_pending_q,"redirect clears response, divide fault and high result ownership");
                finish_normal(1);cases++;
                reach(variant,stage);reset=1;ready=1;tick();
                check(!bus_valid && debug_gpr==0 && debug_flags==2 && debug_ip==16'hFFF0 && debug_cs_base==24'hFF0000 && !dut.micro_executor.muldiv_valid && !dut.micro_executor.muldiv_service.busy_q && !dut.micro_executor.arithmetic_fault_q,"reset abandons every arithmetic boundary");
                reset=0;execute_enable=0;ready=0;tick();check(bus_valid && address==24'hFFFFF0 && bus_status==13,"native reset fetch resumes");cases++;
            end
            // Asynchronous delivery observes both halves and committed FLAGS.
            for(integer event_kind=0;event_kind<3;event_kind++)begin
                setup(variant,event_kind==2?16'h0DD7:16'h0ED7,16'h2000);
                wait_operation(narrow?spk286_microcode_pkg::MC_MULDIV8:spk286_microcode_pkg::MC_MULDIV16);
                tick();repeat(3)tick();
                if(event_kind==0)nmi=1;
                if(event_kind==1)intr=1;
                finish_event(event_kind==0?2:event_kind==1?35:1,0,16'h2000);cases++;
            end
        end
        for(integer variant=2;variant<8;variant++)if(variant<4 || variant>=6)
        for(integer reason=0;reason<3;reason++)for(integer odd=0;odd<2;odd++)begin
            setup(variant,16'h0CD7,16'h2000+16'(odd));delay_length=(variant+reason)%3;
            execute_enable=0;
            gpr_write_en=1;gpr_write_index=3;gpr_write_data=reason==0?16'd0:reason==1?16'd1:16'hFFFF;tick();initial_gpr[63:48]=gpr_write_data;
            if(reason!=0)begin
                gpr_write_index=0;gpr_write_data=narrow?16'h8000:16'h0000;tick();initial_gpr[15:0]=gpr_write_data;
                gpr_write_index=2;gpr_write_data=16'h8000;tick();initial_gpr[47:32]=gpr_write_data;
                // Unsigned /FFFF does not overflow for every numerator; /1 does.
                if(kind==2)begin gpr_write_index=3;gpr_write_data=1;tick();initial_gpr[63:48]=1;end
            end
            gpr_write_en=0;execute_enable=1;finish_event(0,1,16'h2000+16'(odd));cases++;
        end
        $display("MULDIV_LIFECYCLE PASS: %0d iteration/pause/cancel/reset/event/fault cases; %0d checks",cases,checks);$finish;
    end
endmodule
