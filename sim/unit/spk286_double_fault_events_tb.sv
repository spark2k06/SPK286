`timescale 1ns/1ps
// Independent first-exception table from Intel 286 PRM 9.6.2/B-8.
// This bank drives the event-controller interface, never forced CPU state.
module spk286_double_fault_events_tb;
    logic fault_new_task=1'b0;
    logic clk=0,reset=1,cancel=0,enable=1,protected_mode=1,delivery_commit=0;
    logic intr=0,nmi=0,ss_load=0,repeat_boundary=0,repeat_stepped=0;
    logic instruction_start=0,opcode_dispatch=0,instruction_active=1,retired=0;
    logic[7:0] opcode='h90,fault_vector=0,software_vector=0,ack_vector='h20;
    logic[15:0] ip='h100,cs='h18,flags='h246,fault_error_code=0;
    logic fault_request=0,fault_error_valid=0,software_request=0,halt_request=0;
    logic dispatch_ready=1,ack_done=0;
    wire event_active,cancel_operation,dispatch,event_request,event_completed,event_software,event_external;
    wire[7:0] event_vector;
    wire[15:0] event_ip,event_cs,event_flags,event_error_code,instruction_ip;
    wire event_error_valid,event_needs_ack,halted,shutdown,nmi_pending,nmi_blocked,sti_shadow,ss_shadow;
    wire[2:0] event_kind;
    integer checks=0,cases=0,requests=0,dispatches=0;
    spk286_events dut(.*);
    task automatic check(input logic ok,input string message);
        checks++;
        if(ok!==1'b1) $fatal(1,"DF_EVENTS %s case=%0d kind/vector=%d/%d error=%b/%h IP=%h shutdown=%b requests=%0d dispatches=%0d",
            message,cases,event_kind,event_vector,event_error_valid,event_error_code,event_ip,shutdown,requests,dispatches);
    endtask
    task automatic tick;
        #4;if(event_request) requests++;if(dispatch) dispatches++;
        clk=1;#5;clk=0;#1;
    endtask
    task automatic setup(input logic pe);
        reset=1;cancel=0;enable=1;protected_mode=pe;delivery_commit=0;
        intr=0;nmi=0;ss_load=0;repeat_boundary=0;repeat_stepped=0;
        instruction_start=0;opcode_dispatch=0;instruction_active=1;retired=0;
        fault_request=0;fault_error_valid=0;fault_error_code=0;software_request=0;
        halt_request=0;dispatch_ready=1;ack_done=0;opcode='h90;
        ip='h100;cs='h18;flags='h246;tick();reset=0;
        instruction_start=1;tick();instruction_start=0;
        ip='h104;requests=0;dispatches=0;
    endtask
    task automatic settle_dispatch;
        tick();check(!cancel_operation && dispatch,"cancel precedes replacement dispatch");
        tick();check(!dispatch,"exactly one dispatch pulse");
    endtask
    function automatic integer vector_at(input integer index_value);
        case(index_value)
            0:vector_at=0;1:vector_at=1;2:vector_at=2;3:vector_at=3;
            4:vector_at=4;5:vector_at=5;6:vector_at=6;7:vector_at=7;
            8:vector_at=8;9:vector_at=9;10:vector_at=10;11:vector_at=11;
            12:vector_at=12;13:vector_at=13;default:vector_at=16;
        endcase
    endfunction
    task automatic accept_origin(input integer origin,input integer vector_value);
        case(origin)
            1:begin software_request=1;software_vector=8'(vector_value);end
            2:begin instruction_active=0;nmi=1;end
            3:begin instruction_active=0;intr=1;flags[9]=1;end
            4:begin
                // Sample TF at start, then deliver its owed post-instruction trap.
                ip='h100;flags[8]=1;instruction_start=1;tick();instruction_start=0;
                instruction_active=0;ip='h104;retired=1;
            end
            default:begin
                fault_request=1;fault_vector=8'(vector_value);
                fault_error_valid=protected_mode && (vector_value==8 || vector_value>=10 && vector_value<=13);
                fault_error_code=fault_error_valid ? 'h28 : 0;
            end
        endcase
        tick();fault_request=0;software_request=0;nmi=0;intr=0;retired=0;
        check(event_active && !shutdown && cancel_operation && requests==1,"initial origin accepted once");
        settle_dispatch();
        if(origin==3) begin ack_done=1;ack_vector=8'(vector_value);tick();ack_done=0;end
        check(!event_needs_ack,"initial INTA finished before testing entry failure");
    endtask
    task automatic matrix_case(input logic pe,input integer origin,input integer first,input integer second,input logic pause_it,input logic live_context);
        logic expect_df,expect_shutdown,external_origin;
        logic[15:0] expected_ip,expected_flags;
        setup(pe);accept_origin(origin,first);
        external_origin=origin>=2 || origin==0 && (first==7 || first==9);
        expected_ip=origin==0 || origin==1 ? 'h100 : 'h104;
        expected_flags=origin==4 ? 'h346 : 'h246;
        if(live_context) begin
            ip='h400;cs='h30;flags=2;delivery_commit=1;tick();delivery_commit=0;
            expected_ip='h400;expected_flags=2;
        end else begin ip='h500;cs='h38;flags=2;end
        expect_shutdown=origin==0 && first==8;
        expect_df=origin==0 && (first==0 || first>=10 && first<=13);
        fault_request=1;fault_vector=8'(second);fault_error_valid=pe && second>=10 && second<=13;fault_error_code='h6B;
        if(pause_it) begin
            enable=0;repeat(5) tick();
            check(!cancel_operation && !event_request && !shutdown && requests==1 && dispatches==1,"disabled failure preserves active delivery");
            enable=1;
        end
        tick();fault_request=0;
        if(expect_shutdown) begin
            check(shutdown && !event_active && cancel_operation && requests==1 && !event_needs_ack,"failure entering actual #DF shuts down without replacement");
            tick();check(!dispatch,"shutdown never dispatches abandoned entry");
        end else begin
            check(!shutdown && event_active && cancel_operation && !event_software && event_kind==1 &&
                  event_vector==8'(expect_df ? 8 : second) && event_external==external_origin &&
                  !event_needs_ack && requests==2,"286 first-vector classification and original EXT retained");
            check(event_error_valid==(expect_df ? pe : (pe && second>=10 && second<=13)) &&
                  event_error_code==(expect_df || !event_error_valid ? 16'd0 : 16'h6B),"DF zero error code and second-fault error routing");
            check(event_ip==expected_ip && event_cs==(live_context ? 'h30 : 'h18) && event_flags==expected_flags,
                  "original restart/external boundary or committed live context ledger");
            settle_dispatch();check(dispatches==2,"one new dispatch and no INTA replay");
            retired=1;tick();retired=0;
            check(event_completed && !event_active && !event_software,"replacement completion is not software INT retirement");
            // A handler-stream fault is a fresh exception, not the third member
            // of the completed delivery chain.
            instruction_active=1;instruction_start=1;ip='h600;cs='h30;tick();instruction_start=0;
            fault_request=1;fault_vector=13;fault_error_valid=pe;fault_error_code=0;tick();fault_request=0;
            check(!shutdown && event_vector==13 && event_ip=='h600 && requests==3,"fault after completed entry is ordinary #GP");
        end
        cases++;
    endtask
    task automatic recovery(input logic fail_nmi,input logic first_nmi);
        setup(1);accept_origin(first_nmi ? 2 : 0,first_nmi ? 2 : 8);
        fault_request=1;fault_vector=13;fault_error_valid=1;fault_error_code=0;tick();fault_request=0;
        if(first_nmi) begin
            settle_dispatch();fault_request=1;fault_vector=11;tick();fault_request=0;
            settle_dispatch();fault_request=1;fault_vector=13;tick();fault_request=0;
        end
        tick();instruction_active=0;
        check(shutdown && !nmi_blocked,"failed chain permits a fresh recovery NMI even after NMI origin");
        intr=1;repeat(4) tick();intr=0;check(shutdown && !event_active,"INTR cannot exit shutdown");
        nmi=1;tick();nmi=0;
        check(event_active && !shutdown && event_kind==3 && event_vector==2 && nmi_blocked,"NMI enters recovery while remaining in PE");
        settle_dispatch();
        if(fail_nmi) begin
            fault_request=1;fault_vector=13;tick();fault_request=0;tick();
            nmi=1;repeat(4) tick();nmi=0;repeat(3) tick();
            check(shutdown && !event_active && nmi_blocked,"failed recovery NMI cannot be retried until RESET");
        end else begin
            retired=1;tick();retired=0;
            check(event_completed && !shutdown && !dut.shutdown_nmi_q,"successful recovery clears recovery-entry latch");
        end
        reset=1;tick();reset=0;
        check(!shutdown && !event_active && !nmi_pending && !nmi_blocked && !dut.shutdown_reset_only_q,"RESET clears shutdown/NMI recovery state");cases++;
    endtask
    initial begin
        for(integer pe=0;pe<2;pe++) begin
            for(integer first=0;first<15;first++)
                for(integer second=0;second<15;second++)
                    matrix_case(1'(pe),0,vector_at(first),vector_at(second),1'(second%2),0);
            for(integer origin=1;origin<=4;origin++) begin
                matrix_case(1'(pe),origin,origin==2 ? 2 : origin==3 ? 32 : origin==4 ? 1 : 8,13,1,0);
                matrix_case(1'(pe),origin,origin==2 ? 2 : origin==3 ? 32 : origin==4 ? 1 : 0,11,0,1);
            end
            matrix_case(1'(pe),0,13,11,1,1);
        end
        for(integer first_nmi=0;first_nmi<2;first_nmi++)
            for(integer fail_nmi=0;fail_nmi<2;fail_nmi++) recovery(1'(fail_nmi),1'(first_nmi));
        setup(1);accept_origin(0,13);enable=0;fault_request=1;fault_vector=11;cancel=1;tick();cancel=0;fault_request=0;enable=1;repeat(3) tick();
        check(!shutdown && !event_active && !event_completed && !dispatch && !cancel_operation && !event_error_valid,
              "redirect cancels paused fault chain without stale metadata");cases++;
        setup(1);accept_origin(0,13);fault_request=1;fault_vector=11;fault_error_valid=1;
        retired=1;tick();retired=0;fault_request=0;
        check(event_active && event_vector==8 && !event_completed && cancel_operation,
              "delivery fault wins over a coincident completion pulse");cases++;
        setup(1);accept_origin(0,8);ss_load=1;fault_request=1;fault_vector=12;tick();
        ss_load=0;fault_request=0;tick();instruction_active=0;nmi=1;tick();nmi=0;
        check(!shutdown && event_active && event_kind==3 && event_vector==2,
              "SS shadow from a failed task handoff cannot block shutdown recovery NMI");cases++;
        $display("DOUBLE_FAULT_EVENTS PASS: %0d checks / %0d cases",checks,cases);$finish;
    end
endmodule
