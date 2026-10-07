`timescale 1ns/1ps

// Intel 80286 PRM 9.6 and CALL/INT/IRET algorithms.
// Expected vectors/error provenance are a handwritten fault-site ledger.
module spk286_fault_metadata_tb;
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
            $fatal(1,"FAULT_METADATA %s case=%0d CS:IP=%h:%h SS:SP=%h:%h FLAGS=%h event=%h micro=%h",
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


    task automatic run_case(input integer site, input integer origin, input logic [1:0] rpl,
                            input logic [1:0] policy);
        logic [15:0] source_cs, source_ss, source_sp, source_limit, expected_error, old_flags;
        logic [15:0] stack_selector, tr_selector, gate_selector;
        logic [7:0] expected_vector;
        logic external_origin, is_return;
        integer vector_num, gate_addr, deadline;
        reset=1; execute_enable=0; intr=0; nmi=0; observe=0; delivery_only=origin>=4;
        timing_policy_request=policy; repeat (4) tick();
        fault_seen=0; first_vector=0; first_error=0; stack_writes=0;
        for (integer i='h800;i<'h866;i++) memory[i]=0;
        is_return=site>=20;
        source_cs=is_return ? 16'h0008 : 16'h001B;
        source_ss=is_return ? 16'h0010 : 16'h0023;
        source_sp=site==22 ? 16'hFFFD : 16'hF000;
        source_limit=site==20 ? 16'hF003 : site==21 ? 16'hF005 : site==8 ? 16'hF001 : 16'hFFFF;
        old_flags=origin==5 ? 16'h3302 : 16'h3202;
        tr_selector=16'h0028 | {14'd0,rpl}; gate_selector=16'h0030 | {14'd0,rpl};
        stack_selector=site==2 ? {14'd0,rpl} : site==3 ? (16'h0090 | {14'd0,rpl}) : site==14 ? (16'h0094 | {14'd0,rpl}) :
                       site==4 ? (16'h0010 | {14'd0,(rpl==0 ? 2'd1 : rpl)}) : 16'h0010;
        external_origin=origin==2 || origin==3 || origin==5;
        vector_num=origin==2 ? 2 : origin==4 ? 13 : origin==5 ? 1 : 32;
        expected_vector=site==1 || site==2 || site==3 || site==4 || site==5 || site==13 || site==14 ? 10 :
                        site==9 || site==10 ? 11 : site==11 || site==12 ? 13 : 12;
        case (site)
            1,13: expected_error=16'h0028;
            2: expected_error=0;
            3: expected_error=16'h0090;
            14: expected_error=16'h0094;
            4,5,6: expected_error=16'h0010;
            9: expected_error=origin==0 ? 16'h0030 : (16'(vector_num*8) | 16'h0002);
            10,11: expected_error=16'h0008;
            default: expected_error=0;
        endcase
        // Range and offset failures have a literal zero error word, including
        // external delivery. Selector failures add EXT, never selector RPL.
        if (site>=1 && site<=6 || site>=9 && site<=11 || site==13 || site==14) expected_error[0]=external_origin;
        memory['h40]=8'h0F; memory['h41]=8'h05;
        word_at('h806,1); word_at('h816,tr_selector); word_at('h818,old_flags); word_at('h81A,16'h0100);
        word_at('h81E,16'h0023); word_at('h820,source_ss); word_at('h822,source_cs); word_at('h824,16'h0023); word_at('h82C,source_sp);
        cache('h836,0,8'hF3,16'hFFFF); cache('h83C,0,is_return ? 8'h9B : 8'hFB,16'hFFFF);
        cache('h842,0,is_return ? 8'h93 : 8'hF3,source_limit); cache('h848,0,8'hF3,16'hFFFF);
        cache('h84E,16'h4000,0,16'h003F); cache('h85A,16'h5000,0,16'h0107);
        cache('h860,16'h6000,site==13 ? 8'h03 : 8'h83,site==1 ? 16'h0004 : 16'h002B);
        descriptor('h4008,site==10 ? 8'h1B : site==11 ? 8'h93 : 8'h9B);
        descriptor('h4010,site==5 ? 8'h9B : site==6 ? 8'h13 : 8'h93);
        descriptor('h4018,8'hFB); descriptor('h4020,8'hF3);
        if (site==12) word_at('h4008,16'h0100);
        word_at('h6002,site==7 ? 16'h0005 : 16'hE000); word_at('h6004,stack_selector);
        word_at('h4030,16'h0200); word_at('h4032,16'h0008);
        word_at('h4034,site==9 ? 16'h6400 : site==8 ? 16'hE402 : 16'hE400); word_at('h4036,0);
        gate_addr='h5000+vector_num*8;
        word_at(gate_addr,16'h0200); word_at(gate_addr+2,16'h0008);
        word_at(gate_addr+4,site==9 ? 16'h6600 : 16'hE600); word_at(gate_addr+6,0);
        memory['h100]=is_return ? (site==21 ? 8'hCF : 8'hCB) : origin==0 ? 8'h9A : origin==1 ? 8'hCD : origin==4 ? 8'hF4 : 8'h90;
        if (!is_return && origin==0) begin word_at('h101,0); word_at('h103,gate_selector); end
        else memory['h101]=8'h20;
        memory['h200]=8'hEB; memory['h201]=8'hFE;
        if (is_return && site!=22) begin
            word_at('hF000,16'h0200); word_at('hF002,16'h001B); word_at('hF004,16'h3202);
            word_at('hF006,16'hE000); word_at('hF008,16'h0023);
        end
        if (site==23) begin
            word_at('h82E,16'hFFFD);
            memory['h100]=8'h36; memory['h101]=8'hC4; memory['h102]=8'h07; // LES AX,SS:[BX].
        end
        reset=0; segment_load_en=1; segment_load_index=1; segment_load_selector=0;
        ip_write_en=1; ip_write_data=16'h0040; redirect=1;
        tick(); segment_load_en=0; ip_write_en=0; redirect=0; execute_enable=1; observe=1;
        if (origin==2 || origin==3) begin
            deadline=0;
            while (!(instruction_retired && debug_opcode==8'h05) && deadline<1200) begin tick(); deadline++; end
            check(deadline<1200,"LOADALL setup completes");
            if (origin==2) nmi=1; else intr=1;
        end
        deadline=0;
        while (!fault_seen && !shutdown && deadline<2000) begin tick(); deadline++; end
        intr=0; nmi=0;
        check(fault_seen && first_vector==expected_vector && first_error==expected_error,
              $sformatf("fault ledger site=%0d origin=%0d RPL=%0d expected=%h:%h actual=%h:%h",site,origin,rpl,expected_vector,expected_error,first_vector,first_error));
        check(first_cs==source_cs && first_sp==source_sp && first_flags==old_flags,
              "fault-site snapshot preserves source FLAGS/CS/SP");
        check(stack_writes==0,"fault precedes any stack frame write");
        cases++;
    endtask
    initial begin
        for (integer i=0;i<65536;i++) memory[i]=0;
        for (integer policy=0;policy<3;policy++)
            for (integer rpl=0;rpl<4;rpl++) begin
                for (integer site=1;site<=14;site++)
                    for (integer origin=0;origin<6;origin++)
                        if (site!=8 || origin==0) run_case(site,origin,2'(rpl),2'(policy));
                for (integer site=20;site<=23;site++) run_case(site,0,2'(rpl),2'(policy));
            end
        $display("FAULT_METADATA PASS: %0d checks / %0d cases",checks,cases); $finish;
    end
endmodule
