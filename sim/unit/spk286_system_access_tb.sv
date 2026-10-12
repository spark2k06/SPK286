// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

// Intel 80286 PRM chapter 10 and instruction appendices: mode/CPL checks
// precede operand side effects.  A valid descriptor cannot authorize LLDT/LTR.
module spk286_system_access_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    integer cycles=0, checks=0, cases=0, operand_reads=0, operand_writes=0, descriptor_reads=0, descriptor_writes=0;
    logic observe=0;
    spk286 dut (.*);
    task automatic check(input logic condition, input string message);
        checks=checks+1;
        if (condition !== 1'b1)
            $fatal(1,"SYSTEM_ACCESS %s case=%0d CS:IP=%h:%h AX=%h FLAGS=%h event=%h:%h operand=%0d/%0d descriptor=%0d/%0d micro=%h",
                   message,cases,debug_cs,debug_ip,debug_gpr[15:0],debug_flags,debug_event_vector,
                   debug_event_error_code,operand_reads,operand_writes,descriptor_reads,descriptor_writes,debug_micro_pc);
    endtask
    task automatic tick;
        #1;
        ready=bus_valid && ((cycles % 4)!=1); data_in=0;
        if (bus_valid && !bus_write) begin
            if (address[0]) data_in={memory[address[15:0]],8'd0};
            else if (bus_bhe_n) data_in={8'd0,memory[address[15:0]]};
            else data_in={memory[address[15:0]+16'd1],memory[address[15:0]]};
        end
        if (observe && bus_valid && ready && (bus_status==5 || bus_status==6)) begin
            if (address>=24'h002000 && address<24'h002006) begin
                if (bus_write) operand_writes=operand_writes+1; else operand_reads=operand_reads+1;
            end
            if (address>=24'h004000 && address<24'h004060) begin
                if (bus_write) descriptor_writes=descriptor_writes+1; else descriptor_reads=descriptor_reads+1;
            end
        end
        if (bus_valid && ready && bus_write && bus_status==6) begin
            if (address[0]) memory[address[15:0]]=data_out[15:8];
            else begin
                memory[address[15:0]]=data_out[7:0];
                if (!bus_bhe_n) memory[address[15:0]+16'd1]=data_out[15:8];
            end
        end
        #4; clk=1; #5; clk=0; #1; cycles=cycles+1;
    endtask
    task automatic word_put(input integer addr,input logic [15:0] value);
        memory[addr]=value[7:0]; memory[addr+1]=value[15:8];
    endtask
    function automatic logic [15:0] word_at(input integer addr);
        word_at={memory[addr+1],memory[addr]};
    endfunction
    task automatic cache(input integer addr,input logic [15:0] base_addr,
                         input logic [15:0] limit_value,input logic [7:0] access_byte);
        word_put(addr,base_addr); word_put(addr+2,{access_byte,8'd0}); word_put(addr+4,limit_value);
    endtask
    task automatic descriptor(input integer addr,input logic [15:0] base_addr,
                              input logic [15:0] limit_value,input logic [7:0] access_byte);
        word_put(addr,limit_value); word_put(addr+2,base_addr); word_put(addr+4,{access_byte,8'd0}); word_put(addr+6,0);
    endtask
    task automatic run_case(input integer kind,input logic pe,input logic [1:0] cpl,
                            input logic reg_form,input logic prefix,input logic bad_operand,input logic [1:0] policy,
                            input integer selector_case=0);
        logic protected_only, privileged, rejected, selector_fault;
        logic [15:0] input_value, caller_cs, old_msw, expected_value, expected_error;
        logic [7:0] opcode2, modrm_byte;
        integer p, deadline;
        reset=1; execute_enable=0; observe=0; timing_policy_request=policy; repeat (4) tick();
        for (integer i='h800;i<'h866;i=i+1) memory[i]=0;
        protected_only=(kind==3 || kind==4 || kind==8 || kind==9 || kind>=11);
        privileged=(kind>=5 && kind<=10);
        input_value=kind==8 ? 16'h0048 : kind==9 ? 16'h0050 : kind==7 ? 16'h0004 : 16'h0020;
        if (selector_case!=0) input_value=selector_case==1 ? 16'd0 : 16'h0004;
        selector_fault=selector_case==2 || (selector_case==1 && kind==9);
        rejected=(!pe && protected_only) || (pe && cpl!=0 && privileged) || bad_operand || selector_fault;
        expected_error=(pe && cpl==0 && selector_fault) ? (input_value & 16'hFFFC) : 16'd0;
        caller_cs=16'h0018 | {14'd0,cpl}; old_msw=16'h0008 | {15'd0,pe};
        memory[0]=8'h0F; memory[1]=8'h05;
        word_put('h806,old_msw); word_put('h816,16'h0028); word_put('h818,16'h0046); word_put('h81A,16'h0100);
        word_put('h81C,16'h0038); word_put('h81E,16'h0020 | {14'd0,cpl}); word_put('h820,16'h0020 | {14'd0,cpl});
        word_put('h822,caller_cs); word_put('h824,16'h0020 | {14'd0,cpl}); word_put('h82C,16'hF000);
        word_put('h832,16'h0003); word_put('h834,input_value); // CX / AX.
        cache('h836,0,16'hFFFF,8'h93 | {1'b0,cpl,5'd0});
        cache('h83C,0,16'hFFFF,8'h9B | {1'b0,cpl,5'd0});
        cache('h842,0,16'hFFFF,8'h93 | {1'b0,cpl,5'd0});
        cache('h848,0,bad_operand ? 16'h1FFF : 16'hFFFF,8'h93 | {1'b0,cpl,5'd0});
        cache('h84E,16'h4000,16'h005F,0); cache('h854,16'h7200,16'h0017,8'h82);
        cache('h85A,16'h5000,16'h00FF,0); cache('h860,16'h6000,16'h002B,8'h83);
        descriptor('h4020,0,16'hFFFF,8'h93 | {1'b0,cpl,5'd0});
        descriptor('h4028,16'h6000,16'h002B,8'h83);
        descriptor('h4048,16'h7000,16'h003F,8'h82); descriptor('h4050,16'h7100,16'h002B,8'h81);
        word_put('h2000,input_value); word_put('h2002,16'h7800); word_put('h2004,0);
        if (kind==5 || kind==6) word_put('h2000,16'h0055);
        opcode2=8'h00; modrm_byte=0;
        case (kind)
            0: begin opcode2=1; modrm_byte=8'h00; end // SGDT.
            1: begin opcode2=1; modrm_byte=8'h08; end // SIDT.
            2: begin opcode2=1; modrm_byte=8'h20; end // SMSW.
            3: modrm_byte=8'h00; // SLDT.
            4: modrm_byte=8'h08; // STR.
            5: begin opcode2=1; modrm_byte=8'h10; end // LGDT.
            6: begin opcode2=1; modrm_byte=8'h18; end // LIDT.
            7: begin opcode2=1; modrm_byte=8'h30; end // LMSW.
            8: modrm_byte=8'h10; // LLDT.
            9: modrm_byte=8'h18; // LTR.
            10: opcode2=6; // CLTS.
            11: begin opcode2=2; modrm_byte=0; end // LAR AX, operand.
            12: begin opcode2=3; modrm_byte=0; end // LSL AX, operand.
            13: modrm_byte=8'h20; // VERR.
            14: modrm_byte=8'h28; // VERW.
            15: modrm_byte=8'h08; // ARPL operand, CX.
        endcase
        p='h100;
        if (prefix) begin memory[p]=8'h3E; p=p+1; end
        if (kind!=15) begin memory[p]=8'h0F; p=p+1; end
        memory[p]=kind==15 ? 8'h63 : opcode2; p=p+1;
        if (kind!=10) begin
            memory[p]=modrm_byte | (reg_form ? 8'hC0 : 8'h06); p=p+1;
            if (!reg_form) begin word_put(p,16'h2000); p=p+2; end
        end
        memory[p]=8'hEB; memory[p+1]=8'hFE;
        reset=0; segment_load_en=1; segment_load_index=1; segment_load_selector=0;
        ip_write_en=1; ip_write_data=0; redirect=1;
        tick(); segment_load_en=0; ip_write_en=0; redirect=0; execute_enable=1; observe=1;
        operand_reads=0; operand_writes=0; descriptor_reads=0; descriptor_writes=0; deadline=0;
        while (!shutdown && debug_timing_event_requests==0 &&
               !(instruction_retired && debug_instruction_ip==16'h0100) && deadline<1800) begin tick(); deadline=deadline+1; end
        check(deadline<1800 && !shutdown,"bounded instruction or fault completion");
        if (rejected) begin
            check(debug_timing_event_requests==1 && debug_event_vector==(!pe && protected_only ? 6 : 13) &&
                  (!debug_event_error_valid || debug_event_error_code==expected_error),"exact mode/CPL/operand/selector fault and error code");
            check(debug_cs==caller_cs && debug_instruction_ip==16'h0100 && debug_gpr[79:64]==16'hF000 &&
                  debug_gpr[15:0]==input_value && debug_flags==16'h0046 && !instruction_retired,
                  "fault preserves instruction-start registers and FLAGS");
            check(debug_ldtr_selector==16'h0038 && debug_ldtr_base==24'h007200 && debug_tr_selector==16'h0028 &&
                  debug_tr_base==24'h006000 && debug_gdtr_base==24'h004000 && debug_idtr_base==24'h005000 &&
                  debug_protected_msw==old_msw && memory['h4055]==8'h81,"fault preserves tables, selectors, caches, MSW and BUSY");
            check(operand_reads==((pe && cpl==0 && selector_fault && !reg_form) ? 1 : 0) && operand_writes==0 && descriptor_reads==0 && descriptor_writes==0,
                  "mode/privilege denial precedes operand and descriptor transactions");
        end else begin
            check(instruction_retired && debug_ip==16'(p) && debug_timing_event_requests==0,"allowed instruction retires at every admitted CPL");
            case (kind)
                0,1: check(word_at('h2000)==(kind==0 ? 16'h005F : 16'h00FF) &&
                           word_at('h2002)==(kind==0 ? 16'h4000 : 16'h5000) && word_at('h2004)==16'hFF00 && operand_writes==3,"table stores publish six bytes");
                2,3,4: begin
                    expected_value=kind==2 ? old_msw : kind==3 ? 16'h0038 : 16'h0028;
                    check((reg_form ? debug_gpr[15:0] : word_at('h2000))==expected_value &&
                          operand_writes==(reg_form ? 0 : 1),"unprivileged stores publish the correct register/word");
                end
                5: check(debug_gdtr_base==24'h007800 && debug_gdtr_limit==16'h0055,"CPL0/real LGDT publishes its operand");
                6: check(debug_idtr_base==24'h007800 && debug_idtr_limit==16'h0055,"CPL0/real LIDT publishes its operand");
                7: check(debug_protected_msw[3:0]==(pe ? 4'h5 : 4'h4),"LMSW updates its low fields and preserves PE");
                8: begin
                    if (selector_case==1) check(debug_ldtr_selector==0 && descriptor_reads==0,"CPL0 LLDT accepts null without a descriptor fetch");
                    else check(debug_ldtr_selector==16'h0048 && debug_ldtr_base==24'h007000 && debug_ldtr_limit==16'h003F,"CPL0 LLDT accepts a valid LDT");
                end
                9: check(debug_tr_selector==16'h0050 && debug_tr_base==24'h007100 && memory['h4055]==8'h83 && descriptor_writes==1,"CPL0 LTR marks only the new TSS busy");
                10: check(!debug_protected_msw[3] && debug_protected_msw[0]==pe,"CLTS clears TS without changing PE");
                11: check(debug_flags[6] && debug_gpr[15:0]=={8'h93 | {1'b0,cpl,5'd0},8'd0},"LAR remains unprivileged in protected mode");
                12: check(debug_flags[6] && debug_gpr[15:0]==16'hFFFF,"LSL remains unprivileged in protected mode");
                13,14: check(debug_flags[6],"VERR/VERW remain unprivileged in protected mode");
                15: check(debug_flags[6] && (reg_form ? debug_gpr[15:0] : word_at('h2000))==16'h0023,"ARPL remains unprivileged in protected mode");
            endcase
        end
        observe=0; cases=cases+1;
    endtask
    initial begin
        for (integer i=0;i<65536;i=i+1) memory[i]=0;
        for (integer policy=0;policy<3;policy=policy+1)
            for (integer pe=0;pe<2;pe=pe+1)
                for (integer cpl=0;cpl<4;cpl=cpl+1)
                    for (integer kind=0;kind<16;kind=kind+1)
                        for (integer reg_form=0;reg_form<2;reg_form=reg_form+1)
                            if (!(reg_form!=0 && (kind==0 || kind==1 || kind==5 || kind==6 || kind==10)))
                                for (integer prefix=0;prefix<2;prefix=prefix+1) begin
                                    run_case(kind,1'(pe),2'(cpl),1'(reg_form),1'(prefix),0,2'(policy));
                                    if (reg_form==0 && kind!=10) run_case(kind,1'(pe),2'(cpl),0,1'(prefix),1,2'(policy));
                                end
        for (integer policy=0;policy<3;policy=policy+1)
            for (integer cpl=0;cpl<4;cpl=cpl+1)
                for (integer kind=8;kind<=9;kind=kind+1)
                    for (integer reg_form=0;reg_form<2;reg_form=reg_form+1)
                        for (integer selector_case=1;selector_case<=2;selector_case=selector_case+1)
                            run_case(kind,1,2'(cpl),1'(reg_form),1,0,2'(policy),selector_case);
        $display("SYSTEM_ACCESS PASS: %0d checks / %0d cases",checks,cases);
        $finish;
    end
endmodule
