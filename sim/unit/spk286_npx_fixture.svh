// Executable LOADALL/READY fixtures shared by NPX trap and ESC boundary banks.
    `include "spk286_signals.svh"
    spk286 dut (.*);
    logic fixture_custom = 0, fixture_null = 0;
    logic [1:0] fixture_segment = 3;
    logic [15:0] fixture_limit = 16'hFFFF, fixture_offset = 0;
    logic [7:0] fixture_access = 8'h93;
    logic [7:0] memory [0:65535];
    integer checks = 0, cases = 0, cycles = 0;
    integer events_seen, subject_retired, subject_reads, subject_writes, io_cycles;
    integer frame_writes;
    logic observe = 0, first_fault = 0;
    logic [15:0] fault_ip, fault_stream_ip, fault_flags, fault_cs, fault_sp;
    logic [127:0] fault_gpr;
    logic [63:0] fault_selectors;
    logic [7:0] first_vector;
    logic first_error_valid;
    logic [15:0] first_error;
    logic [15:0] caller_cs, caller_ss;
    logic [127:0] original_gpr;
    logic [63:0] original_selectors;
    logic [15:0] original_flags = 16'h0046;

    task automatic check(input logic condition, input string message);
        checks++;
        if (condition !== 1'b1)
            $fatal(1,"NPX_TRAPS %s case=%0d CS:IP=%h:%h MSW=%h opcode=%h event=%h/%h micro=%h",
                   message,cases,debug_cs,debug_ip,debug_protected_msw,debug_opcode,
                   debug_event_vector,debug_event_error_code,debug_micro_pc);
    endtask
    task automatic word_at(input integer addr, input logic [15:0] value);
        memory[addr] = value[7:0]; memory[addr+1] = value[15:8];
    endtask
    function automatic logic [15:0] read_word(input integer addr);
        return {memory[addr+1],memory[addr]};
    endfunction
    task automatic cache_at(input integer addr, input logic [23:0] base_addr,
                            input logic [7:0] access_byte, input logic [15:0] limit);
        word_at(addr,base_addr[15:0]); word_at(addr+2,{access_byte,base_addr[23:16]});
        word_at(addr+4,limit);
    endtask
    task automatic descriptor_at(input integer addr, input logic [7:0] access_byte);
        word_at(addr,16'hFFFF); word_at(addr+2,0);
        word_at(addr+4,{access_byte,8'd0}); word_at(addr+6,0);
    endtask
    task automatic tick;
        #1;
        ready = bus_valid && ((cycles % 5) != 1) && ((cycles % 5) != 2);
        data_in = 0;
        if (bus_valid && !bus_write) begin
            if (address[0]) data_in = {memory[address[15:0]],8'd0};
            else if (bus_bhe_n) data_in = {8'd0,memory[address[15:0]]};
            else data_in = {memory[address[15:0]+16'd1],memory[address[15:0]]};
        end
        if (observe && !reset) begin
            if (dut.fault_request && !first_fault) begin
                first_fault = 1;
                first_vector = debug_fault_vector; first_error = debug_fault_error_code;
                first_error_valid = dut.fault_error_valid;
                fault_ip = debug_instruction_ip; fault_flags = debug_flags;
                fault_stream_ip = debug_ip;
                fault_cs = debug_cs; fault_sp = debug_gpr[79:64];
                fault_gpr = debug_gpr; fault_selectors = debug_segment_selectors;
            end
            if (bus_valid && ready && (bus_status == 4'h9 || bus_status == 4'hA)) io_cycles++;
            if (bus_valid && ready && (bus_status == 4'h5 || bus_status == 4'h6)) begin
                if (debug_instruction_ip == 16'h0100 && !dut.event_active) begin
                    if (bus_write) subject_writes++; else subject_reads++;
                end
                if (bus_write && dut.event_active) frame_writes++;
            end
        end
        if (bus_valid && ready && bus_write && bus_status == 4'h6) begin
            if (address[0]) memory[address[15:0]] = data_out[15:8];
            else begin
                memory[address[15:0]] = data_out[7:0];
                if (!bus_bhe_n) memory[address[15:0]+16'd1] = data_out[15:8];
            end
        end
        #4; clk = 1; #5; clk = 0; #1;
        cycles++;
        if (observe) begin
            if (event_completed) events_seen++;
            if (instruction_retired) begin
                if (debug_instruction_ip == 16'h0100) subject_retired++;
            end
        end
    endtask

    // All fixture state enters through executable LOADALL, not force/release.
    // Protected #NM delivery uses a real same-level IDT gate and descriptor.
    task automatic setup(input logic pe, input logic [1:0] cpl,
                         input logic [2:0] control_bits,
                         input logic [7:0] op, input integer form,
                         input integer prefix_kind, input logic [1:0] policy,
                         output integer length);
        integer pos;
        logic [15:0] msw;
        reset = 1; execute_enable = 0; observe = 0;
        timing_policy_request = policy;
        intr = 0; nmi = 0; hold_request = 0;
        segment_load_en = 0; redirect = 0; ip_write_en = 0;
        repeat (4) tick();
        for (integer i = 'h800; i < 'h866; i++) memory[i] = 0;
        for (integer i = 'h100; i < 'h140; i++) memory[i] = 8'h90;
        caller_cs = pe ? (16'h0018 | {14'd0,cpl}) : 16'd0;
        caller_ss = pe ? (16'h0020 | {14'd0,cpl}) : 16'd0;
        msw = {12'd0,control_bits,pe};
        memory[0] = 8'h0F; memory[1] = 8'h05;
        word_at('h806,msw); word_at('h818,original_flags); word_at('h81A,'h100);
        word_at('h81E,fixture_custom && fixture_null && fixture_segment == 3 ? 0 : caller_ss); word_at('h820,caller_ss);
        word_at('h822,caller_cs); word_at('h824,fixture_custom && fixture_null && fixture_segment == 0 ? 0 : caller_ss);
        for (integer reg_index = 0; reg_index < 8; reg_index++)
            word_at('h826+2*reg_index,16'h6000+16'(reg_index));
        word_at('h82C,'h2000); // SP
        cache_at('h836,0,(fixture_custom && fixture_segment == 0 ? fixture_access : 8'h93) | {1'b0,cpl,5'd0},
                 fixture_custom && fixture_segment == 0 ? fixture_limit : 16'hFFFF);
        cache_at('h83C,0,(fixture_custom && fixture_segment == 1 ? fixture_access : 8'h9B) | {1'b0,cpl,5'd0},
                 fixture_custom && fixture_segment == 1 ? fixture_limit : 16'hFFFF);
        cache_at('h842,0,(fixture_custom && fixture_segment == 2 ? fixture_access : 8'h93) | {1'b0,cpl,5'd0},
                 fixture_custom && fixture_segment == 2 ? fixture_limit : 16'hFFFF);
        cache_at('h848,0,(fixture_custom && fixture_segment == 3 ? fixture_access : 8'h93) | {1'b0,cpl,5'd0},
                 fixture_custom && fixture_segment == 3 ? fixture_limit : 16'hFFFF);
        cache_at('h84E,'h1000,0,'h0027); // GDTR
        cache_at('h85A,pe ? 24'h001400 : 24'd0,0,'h007F); // IDTR
        descriptor_at('h1018,8'h9B | {1'b0,cpl,5'd0});
        descriptor_at('h1020,8'h93 | {1'b0,cpl,5'd0});
        word_at('h1438,'h0300); word_at('h143A,caller_cs);
        word_at('h143C,'h8600); word_at('h143E,0);
        for (integer vector_index = 12; vector_index <= 13; vector_index++) begin
            word_at('h1400+8*vector_index,'h0300); word_at('h1402+8*vector_index,caller_cs);
            word_at('h1404+8*vector_index,'h8600); word_at('h1406+8*vector_index,0);
            word_at(4*vector_index,'h0300); word_at(4*vector_index+2,0);
        end
        word_at('h001C,'h0300); word_at('h001E,0); // Real vector 7.
        memory['h300] = 8'h90;
        pos = 'h100;
        if (prefix_kind == 3) begin memory[pos] = 8'h26; pos++; end
        if (prefix_kind == 1) begin memory[pos] = 8'h2E; pos++; end
        if (prefix_kind == 2) begin
            memory[pos] = 8'hF3; memory[pos+1] = 8'h36; pos += 2;
        end
        memory[pos] = op; pos++;
        if (op != 8'h9B) begin
            case (form)
                0: begin memory[pos] = 8'hC0; pos++; end
                // Invalid word boundary stresses #NM priority only when EM/TS
                // demands #NM. Successful no-NPX syntax uses a valid pointer;
                // residual ESC boundary checking is tracked separately in H19.
                1: begin memory[pos] = 8'h06;
                    word_at(pos+1,(control_bits[2] || control_bits[1]) ? 'hFFFF : 'h4000);
                    pos += 3; end
                2: begin memory[pos] = 8'h46; memory[pos+1] = 8'h7F; pos += 2; end
                3: begin memory[pos] = 8'h06; word_at(pos+1,'h4000); pos += 3; end
                4: begin memory[pos] = 8'h06; word_at(pos+1,fixture_offset); pos += 3; end
            endcase
        end
        length = pos-'h100;
        memory[pos] = 8'hB8; word_at(pos+1,'hBEEF);
        for (integer i = 'h1FE0; i < 'h2000; i++) memory[i] = 8'hA5;
        events_seen = 0; subject_retired = 0; subject_reads = 0; subject_writes = 0;
        io_cycles = 0; frame_writes = 0; first_fault = 0;
        first_vector = 0; first_error = 0; first_error_valid = 0;
        reset = 0; segment_load_en = 1; segment_load_index = 1;
        segment_load_selector = 0; ip_write_en = 1; ip_write_data = 0; redirect = 1;
        tick(); segment_load_en = 0; ip_write_en = 0; redirect = 0; execute_enable = 1;
        begin : fixture_load
            integer deadline;
            deadline = 0;
            while (!(instruction_retired && debug_ip == 'h100) && deadline < 1500) begin
                tick(); deadline++;
            end
            check(deadline < 1500 && debug_protected_msw[3:0] == msw[3:0],"LOADALL fixture is complete");
        end
        original_gpr = debug_gpr; original_selectors = debug_segment_selectors;
        check(debug_timing_policy == (policy == 1 ? 0 : policy) &&
              debug_timing_policy_error == (policy == 1),
              "baseline/Max accepted; unsupported request 1 falls back to baseline with diagnostic");
        observe = 1;
    endtask

