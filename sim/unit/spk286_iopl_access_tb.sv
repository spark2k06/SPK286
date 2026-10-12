// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

// Intel 80286 PRM 10.1: CLI/STI and I/O require CPL <= IOPL in protected
// mode. Denial must precede IF changes, port cycles and string side effects.
module spk286_iopl_access_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    integer cycles=0, checks=0, cases=0, io_cycles=0, data_reads=0, data_writes=0;
    logic observe=0, io_requested=0;
    logic [15:0] observed_address[0:15], observed_data[0:15];
    logic observed_write[0:15], observed_bhe[0:15];
    spk286 dut (.*);
    function automatic logic [7:0] port_byte(input logic [15:0] port_addr);
        port_byte=port_addr[7:0] ^ 8'hA5;
    endfunction
    task automatic check(input logic condition,input string message);
        checks=checks+1;
        if (condition !== 1'b1)
            $fatal(1,"IOPL_ACCESS %s case=%0d CS:IP=%h:%h AX=%h CX=%h SI=%h DI=%h FLAGS=%h event=%h:%h IO=%0d memory=%0d/%0d micro=%h",
                   message,cases,debug_cs,debug_ip,debug_gpr[15:0],debug_gpr[31:16],debug_gpr[111:96],
                   debug_gpr[127:112],debug_flags,debug_event_vector,debug_event_error_code,io_cycles,data_reads,data_writes,debug_micro_pc);
    endtask
    task automatic tick;
        #1;
        ready=bus_valid && ((cycles % 4)!=1); data_in=0;
        if (bus_valid && !bus_write) begin
            if (bus_status==9) data_in={port_byte({address[15:1],1'b1}),port_byte({address[15:1],1'b0})};
            else if (address[0]) data_in={memory[address[15:0]],8'd0};
            else if (bus_bhe_n) data_in={8'd0,memory[address[15:0]]};
            else data_in={memory[address[15:0]+16'd1],memory[address[15:0]]};
        end
        if (observe && dut.io_transfer) io_requested=1;
        if (observe && bus_valid && ready) begin
            if (bus_status==9 || bus_status==10) begin
                check(io_cycles<16,"bounded port transfers");
                observed_address[io_cycles]=address[15:0]; observed_data[io_cycles]=data_out;
                observed_write[io_cycles]=bus_write; observed_bhe[io_cycles]=bus_bhe_n;
                io_cycles=io_cycles+1;
            end
            if (address>=24'h003000 && address<24'h005000) begin
                if (bus_status==5) data_reads=data_reads+1;
                if (bus_status==6) data_writes=data_writes+1;
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
    task automatic cache(input integer addr,input logic [15:0] limit_value,input logic [7:0] access_byte);
        word_put(addr,0); word_put(addr+2,{access_byte,8'd0}); word_put(addr+4,limit_value);
    endtask
    task automatic run_case(input integer kind,input logic pe,input logic [1:0] cpl,input logic [1:0] iopl,
                            input integer variant,input logic [1:0] policy,input logic bad_segment=0,
                            input integer port_override=-1);
        logic string_form, input_form, word_form, repeated, df, denied, old_if;
        logic [15:0] old_flags, expected_flags, port_addr, caller_cs, initial_si, initial_di, value_word;
        logic [127:0] original_gpr, expected_gpr;
        logic [7:0] opcode;
        integer p, deadline, iterations, stride, src_addr, dst_addr, index, transfers_per_word;
        reset=1; execute_enable=0; observe=0; timing_policy_request=policy; repeat (4) tick();
        for (integer i='h800;i<'h866;i=i+1) memory[i]=0;
        for (integer i='h3000;i<'h3020;i=i+1) memory[i]=8'(i ^ 'h5A);
        for (integer i='h4000;i<'h4020;i=i+1) memory[i]=8'hCC;
        string_form=kind>=10; input_form=kind==2 || kind==3 || kind==6 || kind==7 || kind==10 || kind==11;
        word_form=kind==3 || kind==5 || kind==7 || kind==9 || kind==11 || kind==13;
        repeated=string_form && (variant & 2)!=0; df=string_form && (variant & 1)!=0;
        denied=pe && cpl>iopl; old_if=kind<2 && (variant & 1)!=0;
        old_flags=16'h0046 | {2'd0,iopl,12'd0} | (df ? 16'h0400 : 16'd0) | (old_if ? 16'h0200 : 16'd0);
        expected_flags=kind==0 ? old_flags & ~16'h0200 : kind==1 ? old_flags | 16'h0200 : old_flags;
        caller_cs=16'h0018 | {14'd0,cpl};
        port_addr=(kind>=6 ? 16'h0030 : 16'h0040) + 16'(variant >> 1);
        if (port_override>=0) port_addr=16'(port_override);
        initial_si=df ? 16'h3009 : 16'h3001; initial_di=df ? 16'h4009 : 16'h4001;
        original_gpr={initial_di,initial_si,16'hBEEF,16'hF000,16'hCAFE,port_addr,16'h0003,16'hA55A};
        expected_gpr=original_gpr; iterations=repeated ? 3 : 1; stride=word_form ? 2 : 1;
        memory[0]=8'h0F; memory[1]=8'h05;
        word_put('h806,{15'd0,pe}); word_put('h818,old_flags); word_put('h81A,16'h0100);
        word_put('h81E,16'h0020 | {14'd0,cpl}); word_put('h820,16'h0020 | {14'd0,cpl});
        word_put('h822,caller_cs); word_put('h824,16'h0020 | {14'd0,cpl});
        for (integer r=0;r<8;r=r+1) word_put('h834-r*2,original_gpr[r*16+:16]);
        cache('h836,bad_segment && input_form ? 16'd0 : 16'hFFFF,8'h93 | {1'b0,cpl,5'd0});
        cache('h83C,16'hFFFF,8'h9B | {1'b0,cpl,5'd0});
        cache('h842,16'hFFFF,8'h93 | {1'b0,cpl,5'd0});
        cache('h848,bad_segment && !input_form ? 16'd0 : 16'hFFFF,8'h93 | {1'b0,cpl,5'd0});
        case (kind)
            0: opcode=8'hFA; 1: opcode=8'hFB;
            2: opcode=8'hE4; 3: opcode=8'hE5; 4: opcode=8'hE6; 5: opcode=8'hE7;
            6: opcode=8'hEC; 7: opcode=8'hED; 8: opcode=8'hEE; 9: opcode=8'hEF;
            10: opcode=8'h6C; 11: opcode=8'h6D; 12: opcode=8'h6E; default: opcode=8'h6F;
        endcase
        p='h100;
        if ((variant & 1)!=0) begin memory[p]=8'h3E; p=p+1; end
        if (repeated) begin memory[p]=8'hF3; p=p+1; end
        memory[p]=opcode; p=p+1;
        if (kind>=2 && kind<=5) begin memory[p]=port_addr[7:0]; p=p+1; end
        memory[p]=8'hEB; memory[p+1]=8'hFE;
        reset=0; segment_load_en=1; segment_load_index=1; segment_load_selector=0;
        ip_write_en=1; ip_write_data=0; redirect=1;
        tick(); segment_load_en=0; ip_write_en=0; redirect=0; execute_enable=1; observe=1;
        io_cycles=0; data_reads=0; data_writes=0; io_requested=0; deadline=0;
        while (!shutdown && debug_timing_event_requests==0 &&
               !(instruction_retired && debug_instruction_ip==16'h0100) && deadline<2200) begin tick(); deadline=deadline+1; end
        check(deadline<2200 && !shutdown,"bounded execution or privilege fault");
        if (denied) begin
            check(debug_timing_event_requests==1 && debug_event_vector==13 && debug_event_error_valid &&
                  debug_event_error_code==0 && debug_instruction_ip==16'h0100 && !instruction_retired,
                  "CPL>IOPL produces restartable #GP(0)");
            check(debug_cs==caller_cs && debug_gpr==original_gpr && debug_flags==old_flags,
                  "denial preserves all registers, FLAGS and string count/indices");
            check(!io_requested && io_cycles==0 && data_reads==0 && data_writes==0 && !debug_sti_shadow,
                  "denial has no port, memory, IF or STI-shadow side effect");
            for (integer i='h4000;i<'h4020;i=i+1) check(memory[i]==8'hCC,"denied INS leaves destination untouched");
        end else begin
            if (input_form && !string_form)
                expected_gpr[15:0]=word_form ? {port_byte(port_addr+16'd1),port_byte(port_addr)} : {8'hA5,port_byte(port_addr)};
            if (string_form) begin
                if (repeated) expected_gpr[31:16]=0;
                if (input_form) expected_gpr[127:112]=initial_di+(df ? -16'(iterations*stride) : 16'(iterations*stride));
                else expected_gpr[111:96]=initial_si+(df ? -16'(iterations*stride) : 16'(iterations*stride));
            end
            check(instruction_retired && debug_ip==16'(p) && debug_timing_event_requests==0 && debug_gpr==expected_gpr && debug_flags==expected_flags,
                  "admitted CPL<=IOPL and real-mode operations have exact architectural results");
            transfers_per_word=word_form && port_addr[0] ? 2 : 1;
            check(io_cycles==(kind<2 ? 0 : iterations*transfers_per_word),"exact physical port transaction count");
            for (integer iteration=0;iteration<(kind<2 ? 0 : iterations);iteration=iteration+1) begin
                src_addr=int'(initial_si)+(df ? -iteration*stride : iteration*stride);
                dst_addr=int'(initial_di)+(df ? -iteration*stride : iteration*stride);
                value_word=string_form ? {memory[src_addr+1],memory[src_addr]} : 16'hA55A;
                index=iteration*transfers_per_word;
                check(observed_address[index]==port_addr && observed_write[index]==!input_form,"port address and transfer direction");
                if (!input_form) begin
                    if (port_addr[0]) check(observed_data[index][15:8]==value_word[7:0] && !observed_bhe[index],"odd port places the low byte on the high lane");
                    else check(observed_data[index][7:0]==value_word[7:0] && observed_bhe[index]==!word_form &&
                               (!word_form || observed_data[index]==value_word),"aligned port data and byte lanes");
                end
                if (word_form && port_addr[0]) begin
                    check(observed_address[index+1]==port_addr+16'd1 && observed_write[index+1]==!input_form && observed_bhe[index+1],"odd word's second port byte wraps at 16 bits");
                    if (!input_form) check(observed_data[index+1][7:0]==value_word[15:8],"second port byte carries the word's high byte");
                end
                if (string_form && input_form) begin
                    check(memory[dst_addr]==port_byte(port_addr) && (!word_form || memory[dst_addr+1]==port_byte(port_addr+16'd1)),"INS stores the exact port bytes in the selected direction");
                end
            end
            if (string_form) check(input_form ? data_reads==0 && data_writes==iterations*stride : data_reads==iterations*stride && data_writes==0,
                                   "odd string memory operands use paired byte cycles without extra accesses");
        end
        observe=0; cases=cases+1;
    endtask
    initial begin
        for (integer i=0;i<65536;i=i+1) memory[i]=0;
        for (integer policy=0;policy<3;policy=policy+1)
            for (integer cpl=0;cpl<4;cpl=cpl+1)
                for (integer iopl=0;iopl<4;iopl=iopl+1)
                    for (integer kind=0;kind<14;kind=kind+1)
                        for (integer variant=0;variant<4;variant=variant+1)
                            run_case(kind,1,2'(cpl),2'(iopl),variant,2'(policy));
        for (integer kind=0;kind<14;kind=kind+1)
            for (integer variant=0;variant<4;variant=variant+1) run_case(kind,0,3,0,variant,0);
        for (integer kind=10;kind<14;kind=kind+1) run_case(kind,1,3,0,3,0,1);
        for (integer policy=0;policy<3;policy=policy+1)
            for (integer cpl=0;cpl<4;cpl=cpl+1) begin
                run_case(7,1,2'(cpl),3,0,2'(policy),0,65535);
                run_case(9,1,2'(cpl),3,0,2'(policy),0,65535);
            end
        $display("IOPL_ACCESS PASS: %0d checks / %0d cases",checks,cases);
        $finish;
    end
endmodule
