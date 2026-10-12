// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

// Intel 80286 PRM 10.1. Derive each expected field independently;
// in particular use the executing CPL and the OLD IOPL on an outer IRET.
module spk286_return_flags_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    integer cycles = 0, checks = 0, cases = 0;
    logic observe = 0, fault_seen = 0;
    spk286 dut (.*);
    task automatic check(input logic condition, input string message);
        checks++;
        if (condition !== 1'b1)
            $fatal(1,"RETURN_FLAGS %s case=%0d CS:IP=%h:%h FLAGS=%h SP=%h micro=%h",
                   message,cases,debug_cs,debug_ip,debug_flags,debug_gpr[79:64],debug_micro_pc);
    endtask
    task automatic tick;
        #1;
        if (observe && dut.fault_request) fault_seen = 1;
        ready = bus_valid && ((cycles % 4) != 1);
        data_in = 0;
        if (bus_valid && !bus_write) begin
            if (address[0]) data_in = {memory[address[15:0]],8'd0};
            else if (bus_bhe_n) data_in = {8'd0,memory[address[15:0]]};
            else data_in = {memory[address[15:0]+16'd1],memory[address[15:0]]};
        end
        if (bus_valid && ready && bus_write && bus_status == 6) begin
            if (address[0]) memory[address[15:0]] = data_out[15:8];
            else begin
                memory[address[15:0]] = data_out[7:0];
                if (!bus_bhe_n) memory[address[15:0]+16'd1] = data_out[15:8];
            end
        end
        #4; clk = 1; #5; clk = 0; #1; cycles++;
    endtask
    task automatic word_at(input integer addr, input logic [15:0] value);
        memory[addr] = value[7:0]; memory[addr+1] = value[15:8];
    endtask
    task automatic cache(input integer addr, input logic [15:0] base_addr,
                         input logic [7:0] access_byte, input logic [15:0] limit_value);
        word_at(addr,base_addr); word_at(addr+2,{access_byte,8'd0}); word_at(addr+4,limit_value);
    endtask
    task automatic descriptor(input integer addr, input logic [7:0] access_byte);
        word_at(addr,16'hFFFF); word_at(addr+2,0); word_at(addr+4,{access_byte,8'd0}); word_at(addr+6,0);
    endtask
    task automatic run_case(input logic pe, input logic [1:0] cpl, input logic [1:0] iopl,
                            input integer form, input logic old_if, input logic old_nt,
                            input logic [15:0] popped, input logic [1:0] policy,
                            input logic bad_return);
        logic [15:0] old_flags, expected, source_cs, source_ss, target_cs, target_ss;
        logic [1:0] target_cpl;
        integer deadline;
        reset=1; execute_enable=0; observe=0; fault_seen=0; timing_policy_request=policy;
        repeat (4) tick();
        for (integer i='h800; i<'h866; i++) memory[i]=0;
        source_cs=16'h0008 | {14'd0,cpl}; source_ss=16'h0010 | {14'd0,cpl};
        target_cpl = form==2 ? cpl+2'd1 : cpl;
        target_cs = form==2 ? (16'h0018 | {14'd0,target_cpl}) : source_cs;
        target_ss = form==2 ? (16'h0020 | {14'd0,target_cpl}) : source_ss;
        old_flags=16'h00D7 | {2'd0,iopl,12'd0} | (old_if ? 16'h0200 : 0) | (old_nt ? 16'h4000 : 0);
        // Status/control bits common to real/protected POPF and ordinary IRET.
        expected=(popped & 16'h0DD5) | 16'h0002;
        expected[9]=!pe || cpl<=iopl ? popped[9] : old_if;
        expected[13:12]=pe && cpl==0 ? popped[13:12] : iopl;
        expected[14]=pe ? popped[14] : old_nt;
        memory['h40]=8'h0F; memory['h41]=8'h05;
        word_at('h806,{15'd0,pe}); word_at('h818,old_flags); word_at('h81A,16'h0100);
        word_at('h81E,16'h0033); word_at('h820,source_ss); word_at('h822,source_cs);
        word_at('h824,16'h0033); word_at('h82C,16'hF000);
        cache('h836,0,8'hF3,16'hFFFF); cache('h83C,0,8'h9B | {1'b0,cpl,5'd0},16'hFFFF);
        cache('h842,0,8'h93 | {1'b0,cpl,5'd0},16'hFFFF); cache('h848,0,8'hF3,16'hFFFF);
        cache('h84E,16'h4000,0,16'h003F);
        descriptor('h4008,8'h9B | {1'b0,cpl,5'd0}); descriptor('h4010,8'h93 | {1'b0,cpl,5'd0});
        descriptor('h4018,8'h9B | {1'b0,target_cpl,5'd0}); descriptor('h4020,8'h93 | {1'b0,target_cpl,5'd0});
        descriptor('h4030,8'hF3);
        memory['h100]=form==0 ? 8'h9D : 8'hCF;
        memory['h101]=8'hEB; memory['h102]=8'hFE; memory['h200]=8'hEB; memory['h201]=8'hFE;
        if (form==0) word_at('hF000,popped);
        else begin
            word_at('hF000,16'h0200); word_at('hF002,bad_return ? 16'h0033 : target_cs);
            word_at('hF004,popped); word_at('hF006,16'hE000); word_at('hF008,target_ss);
        end
        reset=0; segment_load_en=1; segment_load_index=1; segment_load_selector=0;
        ip_write_en=1; ip_write_data=16'h0040; redirect=1;
        tick(); segment_load_en=0; ip_write_en=0; redirect=0; execute_enable=1; observe=1;
        deadline=0;
        while (!fault_seen && !shutdown && !(instruction_retired && debug_opcode==(form==0 ? 8'h9D : 8'hCF)) && deadline<2200) begin
            tick(); deadline++;
        end
        if (bad_return) begin
            check(fault_seen && !instruction_retired,"invalid return faults before retirement");
            check(debug_flags==old_flags && debug_gpr[79:64]==16'hF000 && debug_cs==source_cs,
                  "failed return preserves FLAGS, source CPL and SP");
        end else begin
            check(!fault_seen && !shutdown && instruction_retired,"operation retires without exception");
            check(debug_flags==expected,$sformatf("exact FLAGS old=%h popped=%h expected=%h CPL=%0d IOPL=%0d form=%0d",old_flags,popped,expected,cpl,iopl,form));
            check(debug_gpr[79:64]==(form==0 ? 16'hF002 : form==2 ? 16'hE000 : 16'hF006),"SP advances once");
            if (pe && form!=0) check(dut.current_cpl==target_cpl && debug_cs==target_cs,"return publishes destination CPL");
        end
        cases++;
    endtask
    initial begin
        for (integer i=0;i<65536;i++) memory[i]=0;
        for (integer policy=0;policy<3;policy++)
            for (integer cpl=0;cpl<4;cpl++)
                for (integer iopl=0;iopl<4;iopl++)
                    for (integer form=0;form<3;form++)
                        if (form!=2 || cpl<3)
                            for (integer old_if=0;old_if<2;old_if++)
                                for (integer new_bits=0;new_bits<16;new_bits++) begin
                                    run_case(1,2'(cpl),2'(iopl),form,1'(old_if),0,
                                             16'h8DD5 | (16'(new_bits & 3)<<12) | ((new_bits & 4)!=0 ? 16'h0200 : 0) | ((new_bits & 8)!=0 ? 16'h4000 : 0),2'(policy),0);
                                    if (form==0) run_case(1,2'(cpl),2'(iopl),form,1'(old_if),1,
                                                         16'h0202 | (16'(new_bits & 3)<<12) | ((new_bits & 8)!=0 ? 16'h4000 : 0),2'(policy),0);
                                end
        for (integer policy=0;policy<3;policy++)
            for (integer iopl=0;iopl<4;iopl++)
                for (integer old_nt=0;old_nt<2;old_nt++)
                    for (integer form=0;form<2;form++)
                        run_case(0,0,2'(iopl),form,0,1'(old_nt),16'h7FD5,2'(policy),0);
        for (integer policy=0;policy<3;policy++)
            for (integer cpl=0;cpl<4;cpl++)
                for (integer iopl=0;iopl<4;iopl++)
                    for (integer form=1;form<3;form++)
                        if (form!=2 || cpl<3)
                            run_case(1,2'(cpl),2'(iopl),form,1,0,16'h7FD5,2'(policy),1);
        $display("RETURN_FLAGS PASS: %0d checks / %0d cases",checks,cases); $finish;
    end
endmodule
