`timescale 1ns/1ps

// Intel 80286 PRM B-42: HLT requires CPL0, independently of IOPL.
// A rejected instruction must fault at its start and must never assert HALT.
module spk286_hlt_privilege_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:65535];
    integer cycles = 0, checks = 0, cases = 0;
    logic observe_halt = 0, halt_seen = 0;
    spk286 dut (.*);

    task automatic tick;
        #1;
        ready = bus_valid && ((cycles % 4) != 1);
        data_in = 0;
        if (bus_valid && !bus_write) begin
            if (address[0]) data_in = {memory[address[15:0]], 8'h00};
            else if (bus_bhe_n) data_in = {8'h00, memory[address[15:0]]};
            else data_in = {memory[address[15:0]+16'd1], memory[address[15:0]]};
        end
        if (bus_valid && ready && bus_write && bus_status == 4'h6) begin
            if (address[0]) memory[address[15:0]] = data_out[15:8];
            else begin
                memory[address[15:0]] = data_out[7:0];
                if (!bus_bhe_n) memory[address[15:0]+16'd1] = data_out[15:8];
            end
        end
        if (observe_halt && dut.halt_request) halt_seen = 1;
        #4; clk = 1; #5; clk = 0; #1;
        cycles = cycles + 1;
    endtask
    task automatic put_word(input integer addr, input logic [15:0] value);
        memory[addr] = value[7:0]; memory[addr+1] = value[15:8];
    endtask
    task automatic cache(input integer addr, input logic [15:0] base_addr,
                         input logic [7:0] access_byte);
        put_word(addr, base_addr); put_word(addr+2, {access_byte,8'd0});
        put_word(addr+4, 16'hFFFF);
    endtask
    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1)
            $fatal(1,"HLT_PRIVILEGE %s CS:IP=%h:%h FLAGS=%h halted=%b event=%h:%h",
                   message,debug_cs,debug_ip,debug_flags,halted,debug_event_vector,debug_event_error_code);
    endtask
    task automatic run_case(input logic pe, input logic [1:0] cpl,
                            input logic [1:0] iopl, input logic prefix,
                            input logic [1:0] policy);
        logic [15:0] caller_cs, caller_ss, original_flags;
        integer deadline;
        string label;
        reset = 1; execute_enable = 0; observe_halt = 0; halt_seen = 0;
        timing_policy_request = policy;
        repeat (4) tick();
        for (integer i = 'h800; i < 'h866; i = i + 1) memory[i] = 0;
        caller_cs = 16'h0018 | {14'd0,cpl};
        caller_ss = 16'h0020 | {14'd0,cpl};
        original_flags = 16'h0046 | {2'd0,iopl,12'd0};
        memory[0] = 8'h0F; memory[1] = 8'h05; // LOADALL independent fixture.
        put_word('h806,{15'd0,pe}); put_word('h818,original_flags); put_word('h81A,16'h0100);
        put_word('h81E,caller_ss); put_word('h820,caller_ss);
        put_word('h822,caller_cs); put_word('h824,caller_ss); put_word('h82C,16'h1000);
        cache('h836,0,8'h93 | {1'b0,cpl,5'd0});
        cache('h83C,0,8'h9B | {1'b0,cpl,5'd0});
        cache('h842,0,8'h93 | {1'b0,cpl,5'd0});
        cache('h848,0,8'h93 | {1'b0,cpl,5'd0});
        memory['h100] = prefix ? 8'h2E : 8'hF4;
        memory['h101] = prefix ? 8'hF4 : 8'h90;
        memory['h102] = 8'h90;
        label = $sformatf("PE=%b CPL=%0d IOPL=%0d prefix=%b policy=%0d",pe,cpl,iopl,prefix,policy);
        reset = 0; segment_load_en = 1; segment_load_index = 1;
        segment_load_selector = 0; ip_write_en = 1; ip_write_data = 0; redirect = 1;
        tick(); segment_load_en = 0; ip_write_en = 0; redirect = 0; execute_enable = 1;
        observe_halt = 1; deadline = 0;
        while (!halted && !shutdown && debug_timing_event_requests == 0 && deadline < 1200) begin
            tick(); deadline = deadline + 1;
        end
        if (pe && cpl != 0) begin
            check(debug_timing_event_requests == 1 && debug_event_kind == 1 &&
                  debug_event_vector == 13 && debug_event_error_valid && debug_event_error_code == 0,
                  {label," rejects HLT with #GP(0), even when IOPL permits I/O"});
            check(!halted && !shutdown && !halt_seen && debug_instruction_ip == 16'h0100 &&
                  debug_cs == caller_cs && debug_gpr[79:64] == 16'h1000 &&
                  debug_flags == original_flags && debug_segment_selectors[47:32] == caller_ss,
                  {label," preserves fault context and never requests HALT"});
        end else begin
            check(halted && halt_seen && !shutdown && debug_timing_event_requests == 0,
                  {label," permits real-mode or CPL0 HLT"});
            check(debug_cs == caller_cs && debug_flags == original_flags &&
                  debug_gpr[79:64] == 16'h1000,
                  {label," permitted HLT preserves registers and FLAGS"});
        end
        observe_halt = 0; cases = cases + 1;
    endtask
    initial begin
        for (integer i = 0; i < 65536; i = i + 1) memory[i] = 0;
        for (integer policy = 0; policy < 3; policy = policy + 1)
            for (integer prefix = 0; prefix < 2; prefix = prefix + 1)
                for (integer cpl = 0; cpl < 4; cpl = cpl + 1)
                    for (integer iopl = 0; iopl < 4; iopl = iopl + 1)
                        run_case(1,2'(cpl),2'(iopl),1'(prefix),2'(policy));
        for (integer cpl = 0; cpl < 4; cpl = cpl + 1)
            for (integer prefix = 0; prefix < 2; prefix = prefix + 1)
                run_case(0,2'(cpl),3,1'(prefix),0);
        $display("HLT_PRIVILEGE PASS: %0d checks / %0d cases",checks,cases);
        $finish;
    end
endmodule
