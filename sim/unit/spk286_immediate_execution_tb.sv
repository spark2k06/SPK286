`timescale 1ns/1ps

// Immediate execution must be atomic at retirement, including overlapping byte
// registers, pause/cancel/reset and events pending between capture and commit.
module spk286_immediate_execution_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:4095];
    logic [127:0] initial_gpr, expected_gpr, saved_gpr;
    logic [15:0] expected_flags, saved_flags;
    logic [11:0] saved_pc;
    integer checks=0, cases=0, cycles=0, retires=0, writes=0, timeout_count;
    integer active_cycles=0, byte_stalls=0, expected_useful=0;
    logic [15:0] expected_ip;
    logic count_interval=0, slow_ready=0;
    spk286 dut (.*);

    task automatic check(input logic condition, input string message);
        checks=checks+1;
        if (condition !== 1'b1)
            $fatal(1, "%s case=%0d IP=%h PC=%h op=%h FLAGS=%h GPR=%h",
                   message, cases, debug_ip, debug_micro_pc, debug_opcode, debug_flags, debug_gpr);
    endtask

    task automatic tick;
        #1;
        data_in=16'hFFFF;
        if (bus_valid && address<4096)
            data_in={memory[{address[11:1],1'b1}],memory[{address[11:1],1'b0}]};
        if (!reset && bus_valid && ready && bus_write && address<4096) begin
            if (!address[0]) memory[{address[11:1],1'b0}]=data_out[7:0];
            if (!bus_bhe_n) memory[{address[11:1],1'b1}]=data_out[15:8];
            writes=writes+1;
        end
        if (count_interval && debug_micro_active && execute_enable && !control_error) begin
            active_cycles=active_cycles+1;
            if (dut.micro_executor.byte_ready && !dut.queue_consume_valid)
                byte_stalls=byte_stalls+1;
        end
        #4; clk=1; #5; clk=0; #1;
        cycles=cycles+1;
        if (instruction_retired) retires=retires+1;
        check(!microcode_fault && !unsupported_opcode && !shutdown, "valid execution state");
    endtask

    task automatic service;
        ready=!slow_ready || (cycles%5==0);
        tick();
    endtask

    task automatic redirect_to(input logic [15:0] ip);
        redirect=1; ip_write_en=1; ip_write_data=ip;
        tick(); redirect=0; ip_write_en=0;
    endtask

    task automatic setup(input integer form, input logic delayed);
        execute_enable=0; count_interval=0; reset=1; nmi=0; ready=0;
        flags_write_en=0; gpr_write_en=0; segment_load_en=0; redirect=0; ip_write_en=0;
        tick(); reset=0;
        for (integer i=0;i<4096;i=i+1) memory[i]=8'hF4;
        memory[8]=0; memory[9]=3; memory[10]=0; memory[11]=0;
        memory[512]=8'hBF; memory[513]=8'h34; memory[514]=8'h12;
        initial_gpr={16'h6666,16'h5555,16'h4444,16'h0800,16'h0001,16'h1234,16'h8000,16'h7FFF};
        for (integer r=0;r<8;r=r+1) begin
            gpr_write_en=1; gpr_write_index=3'(r); gpr_write_data=initial_gpr[r*16+:16]; tick();
        end
        gpr_write_en=0; flags_write_en=1; flags_write_mask=16'hFFFF; flags_write_data=16'h0603;
        tick(); flags_write_en=0;
        segment_load_en=1; segment_load_index=1; segment_load_selector=0;
        redirect_to(16'h0100); segment_load_en=0;
        expected_gpr=initial_gpr; expected_flags=16'h0603;
        case(form)
            0: begin
                memory[256]=8'h05; memory[257]=8'h01; memory[258]=8'h00;
                expected_gpr[15:0]=16'h8000;
                expected_flags=16'h0E96; expected_ip=16'h0103; expected_useful=3;
            end
            1: begin
                memory[256]=8'h15; memory[257]=8'h01; memory[258]=8'h00;
                expected_gpr[15:0]=16'h8001;
                expected_flags=16'h0E92; expected_ip=16'h0103; expected_useful=3;
            end
            2: begin
                memory[256]=8'h1D; memory[257]=8'h01; memory[258]=8'h00;
                expected_gpr[15:0]=16'h7FFD;
                expected_flags=16'h0602; expected_ip=16'h0103; expected_useful=3;
            end
            3: begin
                memory[256]=8'h3D; memory[257]=8'h01; memory[258]=8'h00;
                expected_flags=16'h0602; expected_ip=16'h0103; expected_useful=3;
            end
            4: begin
                memory[256]=8'hA9; memory[257]=8'h00; memory[258]=8'h80;
                expected_flags=16'h0646; expected_ip=16'h0103; expected_useful=3;
            end
            5: begin
                memory[256]=8'h04; memory[257]=8'h01;
                expected_gpr[15:0]=16'h7F00;
                expected_flags=16'h0657; expected_ip=16'h0102; expected_useful=2;
            end
            6: begin
                memory[256]=8'h14; memory[257]=8'h00;
                expected_gpr[15:0]=16'h7F00;
                expected_flags=16'h0657; expected_ip=16'h0102; expected_useful=2;
            end
            7: begin
                memory[256]=8'h1C; memory[257]=8'h00;
                expected_gpr[15:0]=16'h7FFE;
                expected_flags=16'h0682; expected_ip=16'h0102; expected_useful=2;
            end
            8: begin
                memory[256]=8'h3C; memory[257]=8'hFF;
                expected_flags=16'h0646; expected_ip=16'h0102; expected_useful=2;
            end
            9: begin
                memory[256]=8'hA8; memory[257]=8'h80;
                expected_flags=16'h0682; expected_ip=16'h0102; expected_useful=2;
            end
            10: begin
                memory[256]=8'h83; memory[257]=8'hC0; memory[258]=8'hFF;
                expected_gpr[15:0]=16'h7FFE;
                expected_flags=16'h0613; expected_ip=16'h0103; expected_useful=4;
            end
            11: begin
                memory[256]=8'h83; memory[257]=8'hD3; memory[258]=8'hFF;
                expected_gpr[63:48]=16'h0001;
                expected_flags=16'h0613; expected_ip=16'h0103; expected_useful=4;
            end
            12: begin
                memory[256]=8'h83; memory[257]=8'hDB; memory[258]=8'h80;
                expected_gpr[63:48]=16'h0080;
                expected_flags=16'h0603; expected_ip=16'h0103; expected_useful=4;
            end
            13: begin
                memory[256]=8'h83; memory[257]=8'hFB; memory[258]=8'hFF;
                expected_flags=16'h0613; expected_ip=16'h0103; expected_useful=4;
            end
            14: begin
                memory[256]=8'h80; memory[257]=8'hF4; memory[258]=8'hFF;
                expected_gpr[15:0]=16'h80FF;
                expected_flags=16'h0682; expected_ip=16'h0103; expected_useful=4;
            end
            15: begin
                memory[256]=8'h80; memory[257]=8'hC4; memory[258]=8'h01;
                expected_gpr[15:0]=16'h80FF;
                expected_flags=16'h0E92; expected_ip=16'h0103; expected_useful=4;
            end
            16: begin
                memory[256]=8'h81; memory[257]=8'hC0; memory[258]=8'h01; memory[259]=8'h00;
                expected_gpr[15:0]=16'h8000;
                expected_flags=16'h0E96; expected_ip=16'h0104; expected_useful=5;
            end
            17: begin
                memory[256]=8'hB8; memory[257]=8'h34; memory[258]=8'h12;
                expected_gpr[15:0]=16'h1234;
                expected_flags=16'h0603; expected_ip=16'h0103; expected_useful=3;
            end
            18: begin
                memory[256]=8'hB4; memory[257]=8'h80;
                expected_gpr[15:0]=16'h80FF;
                expected_flags=16'h0603; expected_ip=16'h0102; expected_useful=2;
            end
            19: begin
                memory[256]=8'hB2; memory[257]=8'h80;
                expected_gpr[47:32]=16'h1280;
                expected_flags=16'h0603; expected_ip=16'h0102; expected_useful=2;
            end
            20: begin
                memory[256]=8'hC6; memory[257]=8'hC4; memory[258]=8'hFF;
                expected_gpr[15:0]=16'hFFFF;
                expected_flags=16'h0603; expected_ip=16'h0103; expected_useful=4;
            end
            21: begin
                memory[256]=8'hC7; memory[257]=8'hC3; memory[258]=8'h00; memory[259]=8'h80;
                expected_gpr[63:48]=16'h8000;
                expected_flags=16'h0603; expected_ip=16'h0104; expected_useful=5;
            end
            22: begin
                memory[256]=8'h81; memory[257]=8'hE9; memory[258]=8'h01; memory[259]=8'h80;
                expected_gpr[31:16]=16'hFFFF;
                expected_flags=16'h0697; expected_ip=16'h0104; expected_useful=5;
            end
            23: begin
                memory[256]=8'h81; memory[257]=8'hCE; memory[258]=8'h00; memory[259]=8'h00;
                expected_gpr[111:96]=16'h5555;
                expected_flags=16'h0606; expected_ip=16'h0104; expected_useful=5;
            end
            default: $fatal(1,"invalid immediate execution form");
        endcase
        writes=0; retires=0; active_cycles=0; byte_stalls=0;
        execute_enable=1; slow_ready=delayed; count_interval=1;
    endtask

    task automatic reach_capture;
        timeout_count=0;
        while(!dut.micro_executor.register_pending_q && timeout_count<150) begin
            service(); timeout_count=timeout_count+1;
            check(debug_gpr==initial_gpr && debug_flags==16'h0603 && retires==0,
                  "decode and starvation cannot commit architectural state");
        end
        check(timeout_count<150 && debug_micro_active, "parallel capture reached");
        saved_pc=debug_micro_pc; saved_gpr=debug_gpr; saved_flags=debug_flags;
    endtask

    initial begin
        for(integer form=0;form<24;form=form+1)
          for(integer action=0;action<6;action=action+1) begin
            setup(form,1'(action%2)); reach_capture();
            if(action==1 || action==5) begin
                execute_enable=0;
                if(action==5) nmi=1;
                repeat(6) begin
                    service();
                    check(debug_gpr==saved_gpr && debug_flags==saved_flags &&
                          debug_micro_pc==saved_pc && retires==0 && dut.micro_executor.register_pending_q,
                          "pause holds operands and defers GPR/FLAGS/retirement");
                end
                nmi=0; execute_enable=1;
            end
            if(action==2) begin
                redirect=1; ip_write_en=0;
                repeat(3) begin
                    service();
                    check(control_error && debug_gpr==saved_gpr && debug_flags==saved_flags && retires==0,
                          "malformed redirect prevents commit");
                end
                redirect=0;
            end
            if(action==3 || action==4) begin
                count_interval=0;
                if(action==4) begin
                    reset=1; tick(); reset=0; execute_enable=0;
                    saved_gpr=0; saved_flags=2;
                    check(!dut.micro_executor.register_pending_q, "reset clears captured operands");
                    segment_load_en=1; segment_load_index=1; segment_load_selector=0;
                end
                redirect_to(16'h0200); segment_load_en=0; execute_enable=1;
                check(retires==0 && !dut.micro_executor.register_pending_q, "cancel suppresses fused commit");
                timeout_count=0;
                while(!instruction_retired && timeout_count<150) begin service(); timeout_count=timeout_count+1; end
                saved_gpr[127:112]=16'h1234;
                check(timeout_count<150 && retires==1 && debug_ip==16'h0203 &&
                      debug_gpr==saved_gpr && debug_flags==saved_flags, "replacement stream has no stale write or flags");
            end else begin
                service(); count_interval=0;
                check(instruction_retired && retires==1 && !debug_micro_active && debug_ip==expected_ip,
                      "captured immediate commits and retires exactly once");
                check(debug_gpr==expected_gpr && debug_flags==expected_flags && writes==0,
                      "exact result, flags and absence of operand bus cycles");
                check(active_cycles-byte_stalls==expected_useful,
                      $sformatf("useful execution cycles expected=%0d active=%0d stalls=%0d",expected_useful,active_cycles,byte_stalls));
                if(action==0)
                    $display("IMMEDIATE CYCLES form=%0d useful=%0d byte_stalls=%0d",form,active_cycles-byte_stalls,byte_stalls);
                if(action==5) begin
                    timeout_count=0;
                    while(!event_completed && timeout_count<200) begin service(); timeout_count=timeout_count+1; end
                    check(timeout_count<200 && debug_event_vector==2 && debug_ip==16'h0300,
                          "NMI delivered after optimized instruction");
                    check({memory[12'h7FB],memory[12'h7FA]}==expected_ip &&
                          {memory[12'h7FF],memory[12'h7FE]}==expected_flags,
                          "NMI frame observes completed IP and FLAGS");
                end
                execute_enable=0; service(); check(!instruction_retired, "retirement pulse clears during pause");
            end
            cases=cases+1;
          end
        // Word constants can be interrupted between their bytes, including
        // ModR/M register forms. The low byte must neither commit nor survive
        // cancellation into the replacement instruction.
        for(integer form=0;form<24;form=form+1)
          if(form<5 || form==16 || form==17 || form>=21)
            for(integer action=0;action<4;action=action+1) begin
                setup(form,1'b1); count_interval=0; timeout_count=0;
                while(!(dut.micro_executor.immediate_fetch && dut.micro_executor.high_byte_q) && timeout_count<150) begin
                    service(); timeout_count=timeout_count+1;
                    check(debug_gpr==initial_gpr && debug_flags==16'h0603 && retires==0,
                          "partial immediate cannot commit");
                end
                check(timeout_count<150 && !dut.micro_executor.register_pending_q &&
                      dut.micro_executor.tmp1_q[7:0]==memory[expected_ip[11:0]-12'd2],
                      "only the low immediate byte has been retained");
                saved_pc=debug_micro_pc; saved_gpr=debug_gpr; saved_flags=debug_flags;
                if(action<2) begin
                    if(action==0) execute_enable=0;
                    else begin redirect=1; ip_write_en=0; end
                    repeat(6) begin
                        service();
                        check(debug_micro_pc==saved_pc && debug_gpr==saved_gpr && debug_flags==saved_flags &&
                              dut.micro_executor.high_byte_q && !dut.micro_executor.register_pending_q && retires==0,
                              "pause or malformed redirect preserves partial immediate");
                    end
                    execute_enable=1; redirect=0; timeout_count=0;
                    while(!instruction_retired && timeout_count<150) begin service(); timeout_count=timeout_count+1; end
                    check(timeout_count<150 && retires==1 && debug_ip==expected_ip &&
                          debug_gpr==expected_gpr && debug_flags==expected_flags && writes==0,
                          "resumed partial constant has exact result and FLAGS");
                end else begin
                    if(action==3) begin
                        reset=1; tick(); reset=0; execute_enable=0;
                        saved_gpr=0; saved_flags=2;
                        segment_load_en=1; segment_load_index=1; segment_load_selector=0;
                    end
                    redirect_to(16'h0200); segment_load_en=0; execute_enable=1;
                    check(!dut.micro_executor.high_byte_q && !dut.micro_executor.register_pending_q && retires==0,
                          "cancellation clears partial immediate state");
                    timeout_count=0;
                    while(!instruction_retired && timeout_count<150) begin service(); timeout_count=timeout_count+1; end
                    saved_gpr[127:112]=16'h1234;
                    check(timeout_count<150 && retires==1 && debug_ip==16'h0203 &&
                          debug_gpr==saved_gpr && debug_flags==saved_flags && writes==0,
                          "replacement instruction does not inherit the low byte");
                end
                cases=cases+1;
            end
        $display("IMMEDIATE EXECUTION PASS: %0d cases, %0d checks",cases,checks);
        $finish;
    end
endmodule
