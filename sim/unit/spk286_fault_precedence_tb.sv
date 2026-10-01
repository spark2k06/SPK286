`timescale 1ns/1ps

// H13: Intel 80286 load/call/return algorithms validate type/privilege
// before presence. Combine independent invalid conditions explicitly.
module spk286_fault_precedence_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    integer cycles = 0, checks = 0, cases = 0;
    logic fault_seen = 0;
    logic [7:0] first_vector;
    logic [15:0] first_error, first_sp, first_cs, first_flags;
    logic observe=0, delivery_only=0;
    integer stack_writes=0;
    spk286 dut (.*);

    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1)
            $fatal(1,"FAULT_PRECEDENCE %s case=%0d CS:IP=%h:%h SS:SP=%h:%h FLAGS=%h event=%h micro=%h",
                   message,cases,debug_cs,debug_ip,debug_segment_selectors[47:32],
                   debug_gpr[79:64],debug_flags,debug_event_vector,debug_micro_pc);
    endtask
    task automatic tick;
        #1;
        if (observe && dut.fault_request && !fault_seen && (!delivery_only || dut.event_active)) begin
            fault_seen=1; first_vector=dut.fault_vector; first_error=dut.fault_error_code;
            first_sp=debug_gpr[79:64]; first_cs=debug_cs; first_flags=debug_flags;
        end
        ready = bus_valid && ((cycles % 4) != 1);
        data_in = 0;
        if (bus_valid && !bus_write) begin
            if (address[0]) data_in = {memory[address[15:0]],8'd0};
            else if (bus_bhe_n) data_in = {8'd0,memory[address[15:0]]};
            else data_in = {memory[address[15:0]+16'd1],memory[address[15:0]]};
        end
        if (bus_valid && bus_status == 0) data_in = 16'h0020; // PIC INTA vector.
        if (bus_valid && ready && bus_write && bus_status == 6) begin
            if (observe && address>=24'h00D000) stack_writes++;
            if (address[0]) memory[address[15:0]] = data_out[15:8];
            else begin
                memory[address[15:0]] = data_out[7:0];
                if (!bus_bhe_n) memory[address[15:0]+16'd1] = data_out[15:8];
            end
        end
        #4; clk = 1; #5; clk = 0; #1;
        cycles = cycles + 1;
    endtask
    task automatic word_at(input integer addr, input logic [15:0] value);
        memory[addr] = value[7:0]; memory[addr+1] = value[15:8];
    endtask
    function automatic logic [15:0] read_word(input integer addr);
        read_word = {memory[addr+1],memory[addr]};
    endfunction
    task automatic cache(input integer addr, input logic [15:0] base_addr,
                         input logic [7:0] access_byte, input logic [15:0] limit_value);
        word_at(addr,base_addr); word_at(addr+2,{access_byte,8'd0}); word_at(addr+4,limit_value);
    endtask
    task automatic descriptor(input integer addr, input logic [7:0] access_byte);
        word_at(addr,16'hFFFF); word_at(addr+2,0); word_at(addr+4,{access_byte,8'd0}); word_at(addr+6,0);
    endtask



    task automatic run_case(input integer form, input integer bad, input logic present_bit,
                            input logic [1:0] rpl, input logic [1:0] policy);
        logic [1:0] cpl, target_cpl, target_dpl;
        logic [15:0] source_cs, source_ss, target_selector, expected_error, operand_selector;
        logic [7:0] target_access, expected_vector, original_access;
        integer target_addr, deadline, frame_offset;
        reset=1; execute_enable=0; observe=0; delivery_only=0; intr=0; nmi=0;
        timing_policy_request=policy; repeat (4) tick();
        fault_seen=0; stack_writes=0;
        for (integer i='h800;i<'h866;i++) memory[i]=0;
        cpl=form<=3 ? rpl : form>=4 && form<=7 || form==13 || form==14 ? 0 :
            form==9 || form==18 ? 2 : form==10 ? 3 : 1;
        target_cpl=form==6 || form==7 ? (rpl==0 ? 2'd1 : rpl) : rpl;
        source_cs=16'h0008 | {14'd0,cpl}; source_ss=16'h0010 | {14'd0,cpl};
        target_selector=16'h0030 | {14'd0,rpl}; operand_selector=target_selector;
        target_addr='h4030; target_dpl=3; target_access=8'h13;
        if (form==1 || form==3) target_dpl=cpl;
        if (form==4 || form==5) begin target_access=8'h1B; target_dpl=rpl; end
        if (form==6 || form==7) begin target_dpl=target_cpl; target_selector=16'h0030 | {14'd0,target_cpl}; end
        if (form==8) target_access=8'h64;
        if (form==9 || form==12 || form==18) begin target_access=8'h1B; target_dpl=form==18 ? cpl : 0; end
        if (form==10) begin target_dpl=0; target_selector=16'h0030; end
        if (form==11) begin target_addr='h5100; target_access=8'h66; end
        if (form==13) begin target_access=8'h02; target_dpl=0; end
        if (form==14 || form==15 || form==17) target_access=8'h01;
        if (form==16) target_access=8'h65;
        if (bad==0) begin
            if (form==4 || form==5 || form==9 || form==12 || form==18) target_access=8'h13;
            else if (form==8 || form==11 || form==16) target_access=8'h66;
            else if (form==13) target_access=8'h01;
            else if (form==14 || form==15 || form==17) target_access=8'h03; // Busy, not available TSS.
            else target_access=8'h02;
            if (form==11) target_access=8'h64; // CALL gate is invalid in the IDT.
        end
        if (bad==1) begin
            if (form==1 || form==3 || form==4 || form==5 || form==6 || form==7) target_dpl=target_dpl^2'd1;
            else if (form==9 || form==12) target_dpl=cpl+2'd1;
            else if (form==18) target_dpl=cpl-2'd1;
            else if (form==10) target_dpl=1;
            else target_dpl=0;
            if (form==0 || form==2) target_selector=16'h0031; // Also rejects CPL0 via RPL.
        end
        target_access=(target_access & 8'h1F) | {1'b0,target_dpl,5'd0} | (present_bit ? 8'h80 : 0);
        expected_vector=bad==2 ? (form==1 || form==3 || form==6 || form==7 || form==10 ? 12 : 11) : form==10 ? 10 : 13;
        expected_error=form==11 ? 16'h0102 : 16'h0030;
        memory['h40]=8'h0F; memory['h41]=8'h05;
        word_at('h806,1); word_at('h816,16'h0028); word_at('h818,16'h3202); word_at('h81A,16'h0100);
        word_at('h81E,source_ss); word_at('h820,source_ss); word_at('h822,source_cs); word_at('h824,source_ss);
        word_at('h82C,16'hF000); word_at('h834,target_selector);
        cache('h836,0,8'h93 | {1'b0,cpl,5'd0},16'hFFFF);
        cache('h83C,0,8'h9B | {1'b0,cpl,5'd0},16'hFFFF);
        cache('h842,0,8'h93 | {1'b0,cpl,5'd0},16'hFFFF); cache('h848,0,8'h93 | {1'b0,cpl,5'd0},16'hFFFF);
        cache('h84E,16'h4000,0,bad==3 ? 16'h002F : 16'h003F); cache('h85A,16'h5000,0,16'h0107);
        cache('h860,16'h6000,8'h83,16'h002B);
        descriptor('h4008,8'h9B | {1'b0,cpl,5'd0}); descriptor('h4010,8'h93 | {1'b0,cpl,5'd0});
        descriptor('h4018,8'h9B | {1'b0,target_cpl,5'd0}); descriptor('h4020,8'hF3); descriptor('h4028,8'h81);
        descriptor(target_addr,target_access);
        if (form==8 || form==16) begin
            word_at(target_addr,form==16 ? 0 : 16'h0200); word_at(target_addr+2,16'h0028);
            if (form==8) word_at(target_addr+2,16'h0018);
        end
        word_at('h4038,form==17 ? 0 : 16'h0200); word_at('h403A,form==10 ? 16'h0018 : target_selector);
        word_at('h403C,form==17 ? 16'hE500 : 16'hE400); word_at('h403E,0);
        if (form==9 || form==10 || form==18) descriptor('h4018,8'h9B); // Inner/same target for gate.
        if (form==18) descriptor('h4018,8'hDB);
        word_at('h6002,16'hE000); word_at('h6004,target_selector);
        if (form!=11) begin word_at('h5100,16'h0200); word_at('h5102,target_selector); word_at('h5104,16'hE600); word_at('h5106,0); end
        else begin word_at('h5100,16'h0200); word_at('h5102,16'h0018); end
        memory['h100]=form==0 || form==1 ? 8'h8E : form==2 ? 8'h07 : form==3 ? 8'h17 :
                       form==4 || form==6 ? 8'hCB : form==5 || form==7 ? 8'hCF :
                       form==11 || form==12 ? 8'hCD : form==13 || form==14 ? 8'h0F : form==18 ? 8'hEA : 8'h9A;
        memory['h101]=form==0 ? 8'hD8 : form==1 ? 8'hD0 : form==11 || form==12 ? 8'h20 : 0;
        if (form==13 || form==14) begin memory['h101]=0; memory['h102]=form==13 ? 8'hD0 : 8'hD8; end
        if (form==2 || form==3) word_at('hF000,target_selector);
        if (form>=4 && form<=7) begin
            word_at('hF000,16'h0200); word_at('hF002,form==6 || form==7 ? (16'h0018 | {14'd0,target_cpl}) : target_selector);
            word_at('hF004,16'h3202); frame_offset=form==6 ? 4 : 6;
            if (form==6 || form==7) begin word_at('hF000+frame_offset,16'hE000); word_at('hF002+frame_offset,target_selector); end
        end
        if (form==8 || form==9 || form==10 || form>=15) begin
            word_at('h101,0); word_at('h103,form==9 || form==10 || form==17 || form==18 ? (16'h0038 | {14'd0,rpl}) : operand_selector);
        end
        original_access=memory[target_addr+5];
        reset=0; segment_load_en=1; segment_load_index=1; segment_load_selector=0;
        ip_write_en=1; ip_write_data=16'h0040; redirect=1;
        tick(); segment_load_en=0; ip_write_en=0; redirect=0; execute_enable=1; observe=1;
        deadline=0;
        while (!fault_seen && !shutdown && deadline<2000) begin tick(); deadline++; end
        check(fault_seen && first_vector==expected_vector && first_error==expected_error,
              $sformatf("form=%0d bad=%0d P=%0d RPL=%0d expected=%h:%h actual=%h:%h",form,bad,present_bit,rpl,expected_vector,expected_error,first_vector,first_error));
        check(first_sp==16'hF000 && first_cs==source_cs && first_flags==16'h3202 && stack_writes==0,
              "rejected operand preserves the source context and stack");
        check(memory[target_addr+5]==original_access && debug_tr_selector==16'h0028 && debug_ldtr_selector==0,
              "rejected descriptor does not publish Accessed/BUSY or TR/LDTR");
        check(debug_segment_selectors=={source_ss,source_ss,source_cs,source_ss} &&
              debug_gpr==((128'hF000<<64) | {112'd0,target_selector}),
              "failed transfer/load preserves every segment selector and GPR");
        cases++;
    endtask
    initial begin
        for (integer i=0;i<65536;i++) memory[i]=0;
        for (integer policy=0;policy<3;policy++)
            for (integer rpl=0;rpl<4;rpl++)
                for (integer form=0;form<19;form++)
                    for (integer bad=0;bad<4;bad++)
                        if (!(bad==1 && (form==13 || form==14 || form==17)) &&
                            (bad!=3 || form<=7 || form>=13 && form<=16))
                            for (integer present_bit=0;present_bit<2;present_bit++)
                                if (bad!=2 || present_bit==0) run_case(form,bad,1'(present_bit),2'(rpl),2'(policy));
        $display("FAULT_PRECEDENCE PASS: %0d checks / %0d cases",checks,cases); $finish;
    end
endmodule
