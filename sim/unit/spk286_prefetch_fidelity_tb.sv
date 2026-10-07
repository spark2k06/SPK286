`timescale 1ns/1ps

// Integrated prefetch observation bank.  The reference stream below is built
// from accepted code-bus transfers and response handshakes; it never reads the
// DUT prefetch FIFO storage.  It therefore checks byte order, loss, duplicate
// bytes and stale responses at the instruction-unit boundary.
module spk286_prefetch_fidelity_tb;
    `include "spk286_signals.svh"

    logic [7:0] memory [0:65535];
    string trace_path;
    integer trace_fd;
    integer sample_cycle = 0;
    integer scenario = 0;
    integer epoch = 0;
    integer records = 0;
    integer code_accepts = 0;
    integer response_accepts = 0;
    integer consumes = 0;
    integer data_transfers = 0;
    integer queue_empty_samples = 0;
    integer instruction_wait_samples = 0;
    integer operand_wait_samples = 0;
    integer stale_invalidations = 0;
    integer max_queue_count = 0;
    integer queue_activity_without_demand_samples = 0;
    integer hlt_resume_samples = 0;
    integer model_head = 0;
    integer model_tail = 0;
    integer model_count = 0;
    integer pending_count = 0;
    logic [15:0] pending_ip = 16'h0000;
    logic cancelled_request_pending = 1'b0;
    logic [7:0] model_queue [0:31];
    logic [7:0] pending_bytes [0:1];
    logic ready_override_valid = 1'b0;
    logic ready_override = 1'b0;
    logic halted_seen = 1'b0;

    spk286 dut (.*);

    function automatic integer next_model_pointer(input integer pointer);
        next_model_pointer = (pointer == 31) ? 0 : pointer + 1;
    endfunction

    task automatic clear_model;
        begin
            model_head = 0;
            model_tail = 0;
            model_count = 0;
            pending_count = 0;
            pending_ip = 0;
            cancelled_request_pending = 1'b0;
        end
    endtask

    task automatic check(input logic condition, input string message);
        if (condition !== 1'b1)
            $fatal(1, "%s scenario=%0d epoch=%0d cycle=%0d queue=%0d model=%0d IP=%h",
                   message, scenario, epoch, sample_cycle, dut.queue_count,
                   model_count, debug_ip);
    endtask

    task automatic put_code_byte(input logic [15:0] address_value, input logic [7:0] value);
        memory[address_value] = value;
    endtask

    task automatic write_trace_record(
        input integer row_epoch,
        input integer row_model_count,
        input integer row_model_count_after,
        input integer row_pending_count,
        input integer row_pending_count_after,
        input logic row_code_accept,
        input logic row_model_code_accept,
        input logic row_response_accept,
        input logic row_consume_accept,
        input logic row_restart,
        input logic row_invalidated,
        input integer row_expected_consume,
        input logic row_instruction_wait,
        input logic row_operand_wait,
        input logic row_data_wait,
        input logic row_queue_empty_fetch_activity,
        input logic row_byte_demand,
        input logic row_hlt_resume
    );
        logic [1:0] output_response_count;
        logic [15:0] output_response_data;
        logic [7:0] output_consume_data;
        begin
            if (reset) begin
                // The first observation precedes the first reset edge.  Do
                // not publish simulator-specific X values from uninitialized
                // DUT state as if they were evidence.
                $fwrite(trace_fd, "%0d,%0d,%0d,", scenario, row_epoch, sample_cycle);
                for (integer reset_index = 3; reset_index < 55; reset_index = reset_index + 1) begin
                    if (reset_index == 3)
                        $fwrite(trace_fd, "1%s", reset_index == 54 ? "\n" : ",");
                    else if (reset_index == 23)
                        $fwrite(trace_fd, "-1%s", reset_index == 54 ? "\n" : ",");
                    else
                        $fwrite(trace_fd, "0%s", reset_index == 54 ? "\n" : ",");
                end
            end else begin
                output_response_count = dut.fetch_response_valid ? dut.fetch_response_count : 2'd0;
                output_response_data = dut.fetch_response_valid ? dut.fetch_response_data : 16'h0000;
                output_consume_data = dut.queue_consume_valid ? dut.queue_consume_data : 8'h00;
                $fwrite(trace_fd,
                    "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    scenario, row_epoch, sample_cycle, reset,
                    dut.queue_count, row_model_count, row_model_count_after,
                    row_pending_count, row_pending_count_after,
                    dut.bus_valid, dut.bus_status, dut.address, dut.bus_bhe_n,
                    ready, row_code_accept, row_model_code_accept,
                    dut.fetch_response_valid,
                    row_response_accept, output_response_count,
                    output_response_data, dut.queue_consume_valid,
                    row_consume_accept, output_consume_data,
                    row_expected_consume, row_restart, row_invalidated,
                    row_instruction_wait, row_operand_wait, row_data_wait,
                    dut.fetch_bus_valid, dut.fetch_response_ready,
                    dut.debug_timing_queue_empty_cycles,
                    dut.debug_timing_prefetch_requests,
                    dut.debug_timing_prefetch_responses,
                    dut.debug_timing_queue_consumes,
                    dut.debug_timing_redirects,
                    dut.debug_timing_cancels,
                    halted, dut.debug_ip, dut.debug_fetch_cursor,
                    dut.fetch_request_internal,
                    row_queue_empty_fetch_activity,
                    dut.execution_allowed,
                    dut.micro_active,
                    dut.decode_ready,
                    dut.executor_byte_ready,
                    dut.queue_consume_valid,
                    dut.event_active,
                    dut.event_request,
                    dut.event_completed,
                    dut.raw_retired,
                    dut.operand_blocked,
                    dut.unsupported_q,
                    row_byte_demand,
                    row_hlt_resume);
            end
            records = records + 1;
        end
    endtask

    task automatic observe_cycle;
        integer before_count;
        integer before_pending;
        integer after_count;
        integer after_pending;
        integer expected_consume;
        integer row_epoch;
        logic code_accept;
        logic logical_code_accept;
        logic response_accept;
        logic consume_accept;
        logic restart_event;
        logic invalidated_event;
        logic queue_empty;
        logic queue_empty_fetch_activity;
        logic instruction_wait;
        logic byte_demand;
        logic operand_waiting;
        logic data_waiting;
        logic hlt_resume;
        logic [7:0] low_byte;
        logic [7:0] high_byte;
        begin
            if (reset) begin
                clear_model();
                halted_seen = 1'b0;
                row_epoch = epoch;
                write_trace_record(row_epoch, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                   -1, 0, 0, 0, 0, 0, 0);
            end else begin
                before_count = model_count;
                before_pending = pending_count;
                row_epoch = epoch;
                if (dut.queue_count !== before_count[3:0])
                    $fatal(1, "integrated prefetch model count diverged before edge: dut=%0d model=%0d",
                           dut.queue_count, before_count);

                restart_event = (dut.stream_restart === 1'b1);
                code_accept = !restart_event && bus_valid && ready && bus_status == 4'hD;
                logical_code_accept = code_accept;
                response_accept = !restart_event && dut.fetch_response_valid &&
                                  dut.fetch_response_ready;
                consume_accept = !restart_event && dut.queue_consume_valid &&
                                 dut.queue_consume_ready;
                invalidated_event = restart_event &&
                                    (before_pending != 0 || dut.fetch_bus_valid);
                expected_consume = -1;

                if (response_accept) begin
                    if (before_pending == 0)
                        $fatal(1, "response accepted without a preceding accepted code transfer");
                    if (dut.fetch_response_count !== before_pending[1:0] ||
                        dut.fetch_response_ip !== pending_ip[15:0])
                        $fatal(1, "response metadata differs from accepted code transfer");
                    if (before_pending == 1) begin
                        if (dut.fetch_response_data[7:0] !== pending_bytes[0])
                            $fatal(1, "response byte differs from accepted bus data");
                    end else if (dut.fetch_response_data !== {pending_bytes[1], pending_bytes[0]}) begin
                        $fatal(1, "response word differs from accepted bus data");
                    end
                end

                if (consume_accept) begin
                    if (before_count == 0)
                        $fatal(1, "DUT consumed an instruction byte with an empty reference queue");
                    expected_consume = {24'd0, model_queue[model_head]};
                    if (dut.queue_consume_data !== model_queue[model_head])
                        $fatal(1, "instruction byte loss/duplication/order error: dut=%02h expected=%02h",
                               dut.queue_consume_data, model_queue[model_head]);
                    model_head = next_model_pointer(model_head);
                    model_count = model_count - 1;
                    consumes = consumes + 1;
                end

                if (restart_event) begin
                    if (invalidated_event)
                        stale_invalidations = stale_invalidations + 1;
                    clear_model();
                    cancelled_request_pending = dut.fetch_bus_valid && !ready;
                    epoch = epoch + 1;
                    row_epoch = epoch;
                end else begin
                    if (response_accept) begin
                        if (model_count + before_pending > 6)
                            $fatal(1, "reference queue overflow");
                        model_queue[model_tail] = pending_bytes[0];
                        model_tail = next_model_pointer(model_tail);
                        if (before_pending == 2) begin
                            model_queue[model_tail] = pending_bytes[1];
                            model_tail = next_model_pointer(model_tail);
                        end
                        model_count = model_count + before_pending;
                        pending_count = 0;
                        response_accepts = response_accepts + 1;
                    end

                    if (code_accept && cancelled_request_pending) begin
                        // BIU may complete the physical request that the fetch
                        // service marked cancelled on the redirect edge.  It
                        // is not a response belonging to the new stream.
                        logical_code_accept = 1'b0;
                        cancelled_request_pending = 1'b0;
                    end

                    if (logical_code_accept) begin
                        if (pending_count != 0)
                            $fatal(1, "accepted a new code transfer while a response was pending: scenario=%0d cycle=%0d pending=%0d response_valid=%b response_ready=%b bus=%b status=%h address=%h",
                                   scenario, sample_cycle, pending_count,
                                   dut.fetch_response_valid, dut.fetch_response_ready,
                                   bus_valid, bus_status, address);
                        pending_ip = dut.debug_fetch_cursor[15:0];
                        if (bus_bhe_n) begin
                            pending_bytes[0] = data_in[7:0];
                            pending_count = 1;
                        end else if (address[0]) begin
                            pending_bytes[0] = data_in[15:8];
                            pending_count = 1;
                        end else begin
                            low_byte = data_in[7:0];
                            high_byte = data_in[15:8];
                            pending_bytes[0] = low_byte;
                            pending_bytes[1] = high_byte;
                            pending_count = 2;
                        end
                        code_accepts = code_accepts + 1;
                    end
                end

                if (bus_valid && bus_status != 4'hD)
                    data_transfers = data_transfers + (ready ? 1 : 0);

                after_count = model_count;
                after_pending = pending_count;
                queue_empty = (dut.queue_count == 0);
                operand_waiting = (dut.operand_service_wait === 1'b1);
                data_waiting = bus_valid && !ready && bus_status != 4'hD;
                queue_empty_fetch_activity = queue_empty && !halted &&
                                             (dut.fetch_bus_valid || dut.fetch_response_valid ||
                                              dut.fetch_request_internal);
                byte_demand = dut.execution_allowed && !dut.event_active &&
                              !dut.event_request && !dut.event_completed &&
                              !dut.raw_retired && !dut.operand_blocked &&
                              !dut.unsupported_q && !dut.halted && queue_empty &&
                              !dut.queue_consume_valid &&
                              ((dut.micro_active && dut.executor_byte_ready) ||
                               (!dut.micro_active && dut.decode_ready));
                instruction_wait = byte_demand;
                hlt_resume = halted_seen && !halted && dut.event_active;
                if (queue_empty)
                    queue_empty_samples = queue_empty_samples + 1;
                if (queue_empty_fetch_activity && !instruction_wait)
                    queue_activity_without_demand_samples = queue_activity_without_demand_samples + 1;
                if (instruction_wait)
                    instruction_wait_samples = instruction_wait_samples + 1;
                if (operand_waiting)
                    operand_wait_samples = operand_wait_samples + 1;
                if (hlt_resume) begin
                    hlt_resume_samples = hlt_resume_samples + 1;
                    halted_seen = 1'b0;
                end else if (halted) begin
                    halted_seen = 1'b1;
                end
                if ({28'd0, dut.queue_count} > max_queue_count)
                    max_queue_count = {28'd0, dut.queue_count};

                write_trace_record(row_epoch, before_count, after_count,
                                   before_pending, after_pending, code_accept,
                                   logical_code_accept, response_accept, consume_accept,
                                   restart_event, invalidated_event,
                                   expected_consume, instruction_wait,
                                   operand_waiting, data_waiting,
                                   queue_empty_fetch_activity, byte_demand, hlt_resume);
            end
        end
    endtask

    task automatic tick;
        begin
            #1;
            if (bus_valid && address[23:16] == 8'h00)
                data_in = {memory[{address[15:1], 1'b1}],
                           memory[{address[15:1], 1'b0}]};
            else
                data_in = 16'h0F0F;
            if (ready_override_valid)
                ready = ready_override;
            else
                ready = bus_valid && ((sample_cycle % 5) != 2) &&
                        (!(bus_status != 4'hD && (sample_cycle % 3) == 0));
            #1;
            observe_cycle();
            #4;
            if (bus_valid && ready && !reset && bus_write && address[23:16] == 8'h00) begin
                memory[address[15:0]] = address[0] ? data_out[15:8] : data_out[7:0];
                if (!address[0] && !bus_bhe_n)
                    memory[address[15:0] + 16'd1] = data_out[15:8];
            end
            clk = 1'b1;
            #5;
            clk = 1'b0;
            #1;
            sample_cycle = sample_cycle + 1;
        end
    endtask

    task automatic reset_cpu;
        begin
            reset = 1'b1;
            execute_enable = 1'b0;
            ready_override_valid = 1'b0;
            ready_override = 1'b0;
            redirect = 1'b0;
            ip_write_en = 1'b0;
            segment_load_en = 1'b0;
            intr = 1'b0;
            nmi = 1'b0;
            hold_request = 1'b0;
            tick();
            tick();
            reset = 1'b0;
            segment_load_en = 1'b1;
            segment_load_index = 2'd1;
            segment_load_selector = 16'h0000;
            ip_write_en = 1'b1;
            ip_write_data = 16'h0100;
            redirect = 1'b1;
            tick();
            segment_load_en = 1'b0;
            ip_write_en = 1'b0;
            redirect = 1'b0;
            execute_enable = 1'b1;
            ready_override_valid = 1'b0;
            tick();
        end
    endtask

    task automatic fill_linear_program;
        integer i;
        integer code_address;
        begin
            for (i = 0; i < 65536; i = i + 1)
                memory[i] = 8'h0F;
            // MOV AX,1234; XCHG [0200],AX; a long NOP stream; HLT.
            put_code_byte(16'h0100, 8'hB8);
            put_code_byte(16'h0101, 8'h34);
            put_code_byte(16'h0102, 8'h12);
            put_code_byte(16'h0103, 8'h87);
            put_code_byte(16'h0104, 8'h06);
            put_code_byte(16'h0105, 8'h00);
            put_code_byte(16'h0106, 8'h02);
            for (i = 0; i < 18; i = i + 1) begin
                code_address = 32'h00000107 + i;
                put_code_byte(code_address[15:0], 8'h90);
            end
            put_code_byte(16'h0119, 8'hF4);
            put_code_byte(16'h0200, 8'h5A);
            put_code_byte(16'h0201, 8'hC3);
        end
    endtask

    task automatic fill_redirect_program;
        integer i;
        begin
            for (i = 0; i < 65536; i = i + 1)
                memory[i] = 8'h0F;
            // The old stream is deliberately different from the target.
            put_code_byte(16'h0100, 8'hB8);
            put_code_byte(16'h0101, 8'h11);
            put_code_byte(16'h0102, 8'h11);
            put_code_byte(16'h0103, 8'hF4);
            put_code_byte(16'h0300, 8'hA0);
            put_code_byte(16'h0301, 8'hB8);
            put_code_byte(16'h0302, 8'h78);
            put_code_byte(16'h0303, 8'h56);
            put_code_byte(16'h0304, 8'hF4);
        end
    endtask

    task automatic fill_hlt_resume_program;
        integer i;
        begin
            for (i = 0; i < 65536; i = i + 1)
                memory[i] = 8'h0F;
            // HLT at the entry point; NMI vector 2 targets an executable
            // handler that writes AX and halts again.
            put_code_byte(16'h0100, 8'hF4);
            put_code_byte(16'h0008, 8'h00);
            put_code_byte(16'h0009, 8'h02);
            put_code_byte(16'h000A, 8'h00);
            put_code_byte(16'h000B, 8'h00);
            put_code_byte(16'h0200, 8'hB8);
            put_code_byte(16'h0201, 8'h78);
            put_code_byte(16'h0202, 8'h56);
            put_code_byte(16'h0203, 8'hF4);
        end
    endtask

    initial begin
        if (!$value$plusargs("prefetch_trace_out=%s", trace_path))
            trace_path = "build/timing/spk286_prefetch_fidelity.csv";
        trace_fd = $fopen(trace_path, "w");
        if (trace_fd == 0)
            $fatal(1, "cannot open prefetch trace output: %s", trace_path);
        $fwrite(trace_fd,
            "scenario,epoch,cycle,reset,queue_count,model_queue_count,model_queue_count_after,model_pending_count,model_pending_count_after,bus_valid,bus_status,address,bhe_n,ready,code_accept,model_code_accept,fetch_response_valid,response_accept,response_count,response_data,consume_valid,consume_accept,consume_data,expected_consume,restart,invalidated_pending,instruction_wait,operand_wait,data_wait,fetch_bus_valid,fetch_response_ready,queue_empty_cycles,prefetch_requests,prefetch_responses,queue_consumes,redirects,cancels,halted,debug_ip,fetch_cursor,fetch_request_internal,queue_empty_fetch_activity,execution_allowed,micro_active,decode_ready,executor_byte_ready,queue_consume_valid,event_active,event_request,event_completed,raw_retired,operand_blocked,unsupported,byte_demand,hlt_resume\n");

        clear_model();
        fill_linear_program();
        scenario = 1;
        reset_cpu();
        for (integer cycle = 0; cycle < 360; cycle = cycle + 1)
            tick();
        check(halted, "linear program did not reach HLT");
        check(debug_gpr[15:0] == 16'hC35A, "linear data transfer produced wrong AX");
        check(memory[16'h0200] == 8'h34 && memory[16'h0201] == 8'h12,
              "linear data transfer did not complete");
        check(max_queue_count == 6, "linear run did not reach six-byte queue capacity");

        fill_redirect_program();
        scenario = 2;
        reset_cpu();
        // Hold the first old-stream request in READY wait, then redirect.
        ready_override_valid = 1'b1;
        ready_override = 1'b0;
        while (!(bus_valid && bus_status == 4'hD))
            tick();
        segment_load_en = 1'b0;
        ip_write_en = 1'b1;
        ip_write_data = 16'h0301;
        redirect = 1'b1;
        tick();
        redirect = 1'b0;
        ip_write_en = 1'b0;
        ready_override_valid = 1'b0;
        for (integer cycle = 0; cycle < 180; cycle = cycle + 1)
            tick();
        check(halted, "redirect target did not reach HLT");
        check(debug_gpr[15:0] == 16'h5678, "redirect consumed bytes from the old stream");
        check(stale_invalidations > 0, "redirect did not invalidate an in-flight old response/request");

        // Directly exercise the aligned-memory adapter with distinct bytes;
        // this catches the old {memory[A+1], memory[A]} construction at A=odd.
        check(memory[16'h0300] == 8'hA0 && memory[16'h0301] == 8'hB8 &&
              memory[16'h0302] == 8'h78, "odd redirect fixture lost distinct neighbor bytes");

        fill_linear_program();
        scenario = 3;
        reset_cpu();
        // A long READY-low span separates an empty queue from operand waits and
        // forces a real instruction-byte wait before the refill resumes.
        ready_override_valid = 1'b1;
        ready_override = 1'b0;
        for (integer cycle = 0; cycle < 32; cycle = cycle + 1)
            tick();
        ready_override_valid = 1'b0;
        for (integer cycle = 0; cycle < 260; cycle = cycle + 1)
            tick();
        check(halted, "starvation recovery did not reach HLT");
        check(queue_empty_samples > 0, "capture did not observe an empty queue");
        check(instruction_wait_samples > 0, "capture did not distinguish instruction-byte wait");
        check(operand_wait_samples > 0, "capture did not observe operand/bus wait separately");
        check(code_accepts > 0 && response_accepts > 0 && consumes > 0,
              "capture did not observe the complete code stream handshake");
        check(data_transfers > 0, "capture did not observe data traffic");
        check(queue_activity_without_demand_samples > 0,
              "capture lacks a negative queue-activity-without-demand control");

        fill_hlt_resume_program();
        scenario = 4;
        reset_cpu();
        for (integer cycle = 0; cycle < 80; cycle = cycle + 1)
            tick();
        check(halted, "HLT resume fixture did not reach its initial HLT");
        nmi = 1'b1;
        tick();
        nmi = 1'b0;
        for (integer cycle = 0; cycle < 260; cycle = cycle + 1)
            tick();
        check(halted, "HLT resume handler did not reach its final HLT");
        check(debug_gpr[15:0] == 16'h5678, "HLT resume handler did not execute");
        check(hlt_resume_samples > 0, "capture did not observe re-entry after HLT");
        check(records > 100, "integrated capture is unexpectedly short");
        $fclose(trace_fd);
        $display("PREFETCH FIDELITY PASS trace=%s records=%0d code=%0d responses=%0d consumes=%0d empty=%0d instruction_wait=%0d operand_wait=%0d max_queue=%0d stale=%0d hlt_resume=%0d",
                 trace_path, records, code_accepts, response_accepts, consumes,
                 queue_empty_samples, instruction_wait_samples,
                 operand_wait_samples, max_queue_count, stale_invalidations,
                 hlt_resume_samples);
        $finish;
    end
endmodule
