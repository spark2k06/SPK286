`timescale 1ns/1ps

module spk286_microsequencer_tb;
    logic clk = 0, reset = 1, cancel = 0, enable = 1, start = 0;
    logic [3:0] start_entry = 0;
    logic rom_valid = 1, rom_end = 0, operation_done = 0, operation_retire = 0;
    wire start_ready, operation_valid, active, retired, fault;
    wire [3:0] micro_pc, micro_entry, next_micro_pc;
    logic branch_request=0, branch_target_valid=0;
    logic [3:0] branch_target=0;
    integer checks = 0;
    spk286_microsequencer #(.ADDRESS_WIDTH(4), .ROM_DEPTH(10)) dut (.*);

    task automatic tick;
        logic [3:0] expected_pc;
        #5; expected_pc = next_micro_pc; clk = 1; #5;
        if (micro_pc !== expected_pc) $fatal(1, "next ROM address differs from committed PC");
        clk = 0; #1;
    endtask
    task automatic check(input logic condition, input string message);
        if (condition !== 1'b1) $fatal(1, "%s pc=%h entry=%h active=%b retired=%b fault=%b",
                                      message, micro_pc, micro_entry, active, retired, fault);
        checks = checks + 1;
    endtask
    task automatic launch(input logic [3:0] entry_value);
        start = 1; start_entry = entry_value;
        #1; check(start_ready, "entry handshake ready");
        tick(); start = 0;
    endtask
    task automatic clear_context;
        cancel = 1; tick(); cancel = 0;
        rom_valid = 1; rom_end = 0; operation_done = 0; operation_retire = 0; branch_request = 0; branch_target_valid = 0;
        #1; check(!active && !retired && !fault && micro_pc == 0 && micro_entry == 0,
                  "cancel clears context");
    endtask

    initial begin
        tick();
        check(!active && !retired && !fault && micro_pc == 0 && micro_entry == 0,
              "reset microstate");
        check(!operation_valid && !start_ready, "reset suppresses handshakes");
        reset = 0;
        launch(4'd4);
        check(active && micro_pc == 4 && micro_entry == 4 && operation_valid,
              "load nonzero entry");
        // Busy starts cannot replace the decoder metadata or current micro-PC.
        start = 1; start_entry = 4'd7;
        repeat (4) begin
            tick(); check(micro_pc == 4 && micro_entry == 4 && !retired && !start_ready,
                          "unresolved functional dependency stalls");
        end
        start = 0; operation_done = 1; tick();
        check(micro_pc == 5 && micro_entry == 4 && active, "completion resumes sequentially");
        enable = 0;
        repeat (3) begin
            tick(); check(micro_pc == 5 && !operation_valid && !retired, "pause cannot repeat side effects");
        end
        enable = 1; tick();
        check(micro_pc == 6 && active, "resume after pause");
        rom_end = 1; operation_done = 0; tick();
        check(active && !retired && micro_pc == 6 && !operation_valid,
              "END can wait for completion permission");
        operation_done = 1; tick();
        check(!active && retired && start_ready && micro_pc == 6, "END retires once");
        enable = 0; tick();
        check(!retired && !active, "retirement pulse clears while disabled");
        enable = 1;
        repeat (3) begin
            tick(); check(!retired && !active, "no double retirement with END still visible");
        end
        rom_end = 0; operation_done = 0; launch(4'd2);
        check(active && micro_pc == 2 && micro_entry == 2, "next decoder entry");
        reset = 1; tick(); reset = 0;
        check(!active && micro_pc == 0 && micro_entry == 0 && !retired && !fault,
              "reset during execution");
        launch(4'd5); rom_end = 1; operation_done = 1;
        clear_context();
        check(!retired, "cancel at END suppresses retirement");
        launch(4'd10);
        check(fault && !active && !retired && !start_ready, "reject invalid entry");
        tick(); check(fault && !operation_valid, "fault is sticky");
        clear_context(); launch(4'd3); rom_valid = 0; operation_done = 1; tick();
        check(fault && !active && !retired && micro_pc == 3, "invalid ROM word faults");
        clear_context(); launch(4'd9); operation_done = 1; tick();
        check(fault && micro_pc == 9 && !retired, "fallthrough cannot wrap ROM boundary");
        clear_context(); launch(4'd9); rom_end = 1; operation_done = 1; tick();
        check(retired && !fault && !active, "last ROM address may END normally");
        clear_context(); launch(4'd9); branch_request=1; branch_target_valid=1; branch_target=2;
        operation_done=0; repeat(3) tick();
        check(micro_pc==9 && active && !fault && !retired,"branch waits for functional completion");
        operation_done=1; enable=0; repeat(3) tick();
        check(micro_pc==9 && !operation_valid && !retired,"pause suppresses branch");
        enable=1; tick();
        check(micro_pc==2 && micro_entry==9 && active && !fault && !retired,"branch target preserves macro entry without retirement");
        branch_target=2; tick(); check(micro_pc==2 && active && !retired,"generic self branch is permitted");
        branch_request=0; tick(); check(micro_pc==3 && active,"branch resumes target sequence");
        rom_end=1; tick(); check(retired && !fault && !active,"branched target END retires once");
        for(integer bad=0;bad<3;bad=bad+1) begin
            clear_context(); launch(4'd1); branch_request=1; operation_done=1;
            branch_target_valid=bad!=0; branch_target=bad==0?4'd2:(bad==1?4'd10:4'd15); tick();
            check(fault && !active && !retired && micro_pc==1,"invalid branch target fails closed");
        end
        clear_context(); launch(4'd1); branch_request=1; operation_done=1; branch_target_valid=1; branch_target=5;
        cancel=1; tick(); cancel=0;
        check(!active && !retired && !fault && micro_pc==0,"cancel suppresses branch");
        branch_request=0; operation_done=0; launch(4'd1); branch_request=1; operation_done=1;
        reset=1; tick(); reset=0;
        check(!active && !retired && !fault && micro_pc==0,"reset suppresses branch");
        clear_context(); launch(4'd4); operation_retire=1;
        repeat(3) tick();
        check(active && !retired && micro_pc==4, "terminal operation waits for completion");
        operation_done=1; enable=0; tick();
        check(active && !retired && micro_pc==4, "terminal operation respects pause");
        enable=1; tick();
        check(retired && !active && !fault && micro_pc==4, "terminal functional operation retires without END bubble");
        enable=0; tick(); check(!retired, "terminal retirement pulse clears while paused");
        enable=1; clear_context(); launch(4'd4); operation_done=1; operation_retire=1;
        cancel=1; tick(); cancel=0;
        check(!retired && !active && !fault, "cancel suppresses terminal functional operation");
        $display("MICROSEQUENCER PASS: %0d entry/stall/resume/END/reset/cancel/fault checks", checks);
        $finish;
    end
endmodule
