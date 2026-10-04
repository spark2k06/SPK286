`timescale 1ns/1ps
module spk286_instruction_schedule_tb;
    logic clk = 0;
    always #5 clk = !clk;
    logic reset=1, historical_enable=1, cpu_boundary=0;
    logic cancel=0, preserve_cancel=0, start_interval=0, start_body=0;
    logic metadata_valid=1, metadata_freeze=0, read_wait_event=0, alignment_event=0;
    logic functional_retired=0, repeat_checkpoint=0;
    logic [9:0] metadata_clocks=2, repeat_next_clocks=5;
    wire active, body_active, retire_pending, head_permit, deadline_ready, retire_fire;
    wire [9:0] elapsed_clocks, scheduled_clocks;
    wire implementation_extension;
    integer checks=0;
    spk286_instruction_schedule dut(.*);

    task automatic check(input logic condition, input string label);
        begin
            if (!condition) $fatal(1,"SCHEDULE_ORACLE_FAILED %s age%0d budget%0d",label,elapsed_clocks,scheduled_clocks);
            checks=checks+1;
        end
    endtask
    task automatic edge_begin(input logic boundary);
        begin @(negedge clk); cpu_boundary=boundary; #1; end
    endtask
    task automatic edge_end;
        begin @(posedge clk); #1; end
    endtask
    task automatic tick(input logic boundary);
        begin edge_begin(boundary); edge_end(); end
    endtask
    task automatic clear;
        begin
            reset=1; cancel=0; preserve_cancel=0; start_interval=0; start_body=0;
            metadata_valid=1; metadata_freeze=0; functional_retired=0;
            read_wait_event=0; alignment_event=0; repeat_checkpoint=0;
            tick(0); reset=0;
        end
    endtask
    task automatic start(input logic boundary, input integer budget);
        begin
            edge_begin(boundary); metadata_clocks=10'(budget);
            start_interval=1; start_body=1; edge_end();
            start_interval=0; start_body=0;
            check(active&&body_active&&elapsed_clocks==0,"interval admission starts age0");
        end
    endtask
    initial begin
        clear();
        historical_enable=0;
        for(integer k=0;k<4;k=k+1) begin
            edge_begin(k[0]); functional_retired=k[1]; #1;
            check(head_permit&&retire_fire==functional_retired&&!active,"MAX exact combinational bypass");
            edge_end();
        end
        historical_enable=1; functional_retired=0; clear();
        start(1,2);
        edge_begin(0); functional_retired=1; #1; check(!retire_fire,"early raw retirement retained"); edge_end();
        functional_retired=0; check(retire_pending,"single pending raw token");
        edge_begin(1); check(!retire_fire,"two clocks not one"); edge_end();
        edge_begin(1); check(retire_fire,"second virtual boundary retires"); edge_end();
        check(!active&&!retire_pending,"one qualified retirement consumes token");
        edge_begin(0); check(head_permit,"post-retire fabric admission window"); edge_end();
        start(0,3);
        for(integer k=1;k<=2;k=k+1) begin tick(1); check(elapsed_clocks==10'(k),"post-retire window shares boundary origin"); end
        edge_begin(1); functional_retired=1; #1; check(retire_fire,"same-edge raw at third boundary"); edge_end();
        functional_retired=0; tick(0); check(!retire_fire,"retirement is not replayed");

        clear(); metadata_valid=0; start(1,3);
        functional_retired=1; tick(0); functional_retired=0;
        tick(1); tick(1); tick(1); check(!retire_fire,"missing required current metadata blocks publication");
        metadata_valid=1; metadata_clocks=7; tick(0);
        check(scheduled_clocks==7,"late form replaces base without additive replay");
        for(integer k=4;k<=6;k=k+1) begin edge_begin(1); check(!retire_fire,"memory budget not early"); edge_end(); end
        edge_begin(1); check(retire_fire,"late qualified seven-clock row"); edge_end();

        clear(); start(1,7);
        alignment_event=1; tick(0); tick(0); alignment_event=0;
        read_wait_event=1; tick(1); read_wait_event=0;
        check(scheduled_clocks==11&&elapsed_clocks==0,"two odd references and productive-clock READ wait");
        metadata_freeze=1; tick(0); metadata_freeze=0;
        metadata_clocks=2; tick(0); check(scheduled_clocks==11,"freeze preserves accepted metadata");
        cancel=1; preserve_cancel=1; tick(0); check(active,"software transition preserves interval");
        cancel=0; preserve_cancel=0;
        repeat_checkpoint=1; tick(1); repeat_checkpoint=0;
        check(elapsed_clocks==0&&scheduled_clocks==5,"REP checkpoint starts next iteration only");
        metadata_clocks=100; tick(0); check(scheduled_clocks==5,"REP frozen per-iteration excludes setup replay");
        functional_retired=1; tick(0); functional_retired=0;
        for(integer k=1;k<5;k=k+1) begin edge_begin(1); check(!retire_fire,"REP per-iteration budget binding"); edge_end(); end
        edge_begin(1); check(retire_fire,"REP final raw token retires after iteration"); edge_end();

        clear(); start(1,2); functional_retired=1; tick(0); functional_retired=0;
        cancel=1; tick(0); cancel=0;
        tick(1); check(!active&&!retire_pending&&!retire_fire,"cancel invalidates raw and timing token");
        clear(); start(1,2); tick(1); tick(1); check(implementation_extension,"real functional lateness recorded");
        functional_retired=1; edge_begin(1); check(retire_fire,"late functional result still publishes safely"); edge_end();
        functional_retired=0;

        clear(); start(1,195); read_wait_event=1;
        for(integer k=0;k<1100;k=k+1) tick(1);
        read_wait_event=0; check(elapsed_clocks==0&&scheduled_clocks==195,"unbounded READ waits do not saturate a debt");
        functional_retired=1; tick(0); functional_retired=0;
        for(integer k=0;k<194;k=k+1) tick(1);
        edge_begin(1); check(retire_fire,"base195 after1100waits needs195productive boundaries"); edge_end();

        clear(); start(1,1020); alignment_event=1; tick(0); tick(0); alignment_event=0;
        check(scheduled_clocks==1023,"budget saturates without overflow");
        functional_retired=1; tick(0); functional_retired=0;
        for(integer k=0;k<1022;k=k+1) tick(1);
        edge_begin(1); check(retire_fire,"saturation does not strand boot"); edge_end();
        $display("PROFILE_SCHEDULE_PASS checks%0d",checks); $finish;
    end
endmodule
