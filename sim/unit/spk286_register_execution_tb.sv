// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

// Register execution must be atomic at retirement, including overlapping byte
// registers, pause/cancel/reset and events pending between capture and commit.
module spk286_register_execution_tb;
    `include "spk286_signals.svh"
    logic [7:0] memory [0:4095];
    logic [127:0] initial_gpr, expected_gpr, saved_gpr;
    logic [15:0] expected_flags, saved_flags;
    logic [11:0] saved_pc;
    integer checks=0, cases=0, cycles=0, retires=0, writes=0, timeout_count;
    integer active_cycles=0, byte_stalls=0;
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
            if (dut.operand_byte_ready && !dut.queue_consume_valid)
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
        memory[257]=(form==2 || form==3 || form==6 || form==7 || form==10) ? 8'hE0 : 8'hD8;
        case(form)
            0: begin memory[256]=8'h01; expected_gpr[15:0]=16'h8000; expected_flags=16'h0E96; end
            1: begin memory[256]=8'h03; expected_gpr[63:48]=16'h8000; expected_flags=16'h0E96; end
            2: begin memory[256]=8'h00; expected_gpr[15:0]=16'h7F7E; expected_flags=16'h0617; end
            3: begin memory[256]=8'h02; expected_gpr[15:0]=16'h7EFF; expected_flags=16'h0617; end
            4: begin memory[256]=8'h89; expected_gpr[15:0]=16'h0001; end
            5: begin memory[256]=8'h8B; expected_gpr[63:48]=16'h7FFF; end
            6: begin memory[256]=8'h88; expected_gpr[15:0]=16'h7F7F; end
            7: begin memory[256]=8'h8A; expected_gpr[15:0]=16'hFFFF; end
            8: begin memory[256]=8'h39; expected_flags=16'h0602; end // CMP: FE has odd low-byte parity
            9: begin memory[256]=8'h85; expected_flags=16'h0602; end // TEST, no GPR write
            10: begin memory[256]=8'h84; expected_flags=16'h0602; end
            11: begin memory[256]=8'h11; expected_gpr[15:0]=16'h8001; expected_flags=16'h0E92; end // ADC, carry in
            12: begin memory[256]=8'h19; expected_gpr[15:0]=16'h7FFD; expected_flags=16'h0602; end // SBB, borrow in
            default: $fatal(1,"invalid register execution form");
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
        for(integer form=0;form<13;form=form+1)
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
                check(instruction_retired && retires==1 && !debug_micro_active && debug_ip==16'h0102,
                      "second useful cycle commits and retires exactly once");
                check(debug_gpr==expected_gpr && debug_flags==expected_flags && writes==0,
                      "exact result, flags and absence of operand bus cycles");
                check(active_cycles-byte_stalls==2, "two execution cycles excluding real byte starvation and pause");
                if(action==0)
                    $display("REGISTER CYCLES form=%0d useful=%0d byte_stalls=%0d",form,active_cycles-byte_stalls,byte_stalls);
                if(action==5) begin
                    timeout_count=0;
                    while(!event_completed && timeout_count<200) begin service(); timeout_count=timeout_count+1; end
                    check(timeout_count<200 && debug_event_vector==2 && debug_ip==16'h0300,
                          "NMI delivered after optimized instruction");
                    check({memory[12'h7FB],memory[12'h7FA]}==16'h0102 &&
                          {memory[12'h7FF],memory[12'h7FE]}==expected_flags,
                          "NMI frame observes completed IP and FLAGS");
                end
                execute_enable=0; service(); check(!instruction_retired, "retirement pulse clears during pause");
            end
            cases=cases+1;
          end
        $display("REGISTER EXECUTION PASS: %0d cases, %0d checks",cases,checks);
        $finish;
    end
endmodule
