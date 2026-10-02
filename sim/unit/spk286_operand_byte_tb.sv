`timescale 1ns/1ps
module spk286_operand_byte_tb;
    logic clk=0,reset=1,cancel=0;
    logic request_valid=0,request_write=0,request_check=0,request_byte=0,select_rm=0;
    logic[15:0]write_data=0;
    wire done, unlimited_memory_done;
    wire[15:0]read_data;
    wire[127:0]register_state;
    logic[2:0]reg_index=0,rm_index=0;
    logic register_direct=1;
    logic[23:0]physical_address=24'h10FFFF;
    logic[15:0]offset=16'hFFFF,segment_limit=16'hFFFF;
    logic segment_expand_down=1'b0;
    logic parallel_within_limit=1'b0;
    wire blocked,gpr_write_en,gpr_write_byte;
    wire[2:0]gpr_write_index;
    wire[15:0]gpr_write_data;
    wire memory_request,memory_write,memory_byte;
    logic memory_request_ready=0;
    wire[23:0]memory_address;
    wire[15:0]memory_write_data;
    logic memory_response_valid=0;
    wire memory_response_ready;
    wire timing_wait;
    logic[15:0]memory_read_data=0;
    logic setup=0;
    logic[2:0]setup_index=0;
    logic[15:0]setup_data=0;
    wire[15:0]read_a,read_b,ip,flags;
    logic[127:0]expected;
    integer checks=0,cases=0,requests=0;
    spk286_operand dut(.*);
    spk286_registers storage(
        .clk(clk),.reset(reset),.read_a_index(3'd0),.read_b_index(3'd0),
        .loadall_commit_en(1'b0),.loadall_gpr(128'd0),.loadall_ip(16'd0),.loadall_flags(16'd0),
        .read_a_byte(1'b0),.read_b_byte(1'b0),.read_a_data(read_a),.read_b_data(read_b),
        .write_en(setup || gpr_write_en),.write_byte(!setup && gpr_write_byte),
        .write_index(setup ? setup_index : gpr_write_index),.write_data(setup ? setup_data : gpr_write_data),
        .ip_write_en(1'b0),.ip_write_data(16'd0),.flags_write_en(1'b0),.flags_write_data(16'd0),
        .flags_write_mask(16'd0),.flags_write_protected_task(1'b0),.gpr_state(register_state),.ip(ip),.flags(flags));
    task automatic check(input logic condition,input string message);
        checks++;if(condition!==1'b1)$fatal(1,"%s case=%0d",message,cases);
    endtask
    task automatic tick;
        #5;if(memory_request && memory_request_ready && !reset && !cancel)requests++;
        clk=1;#5;clk=0;#1;
    endtask
    task automatic clear;
        reset=1;request_valid=0;cancel=0;memory_request_ready=0;memory_response_valid=0;setup=0;
        tick();reset=0;requests=0;
    endtask
    initial begin
        clear();setup=1;
        for(integer r=0;r<8;r++)begin setup_index=3'(r);setup_data=16'(32'h9182+r*257);tick();expected[r*16+:16]=setup_data;end
        setup=0;
        for(integer source=0;source<2;source++)
            for(integer regno=0;regno<8;regno++)
                for(integer rmno=0;rmno<8;rmno++)begin : byte_register
                    integer encoded,word_index,shift;
                    encoded=source!=0 ? rmno : regno;word_index=encoded%4;shift=encoded>=4 ? 8 : 0;
                    select_rm=1'(source);reg_index=3'(regno);rm_index=3'(rmno);register_direct=1;
                    request_byte=1;request_write=0;request_check=0;request_valid=1;#1;
                    check(done && read_data=={8'd0,expected[word_index*16+shift+:8]} && !memory_request,"byte read selects independent low/high alias");
                    request_write=1;write_data=16'(regno*17+rmno*83+source*131);#1;
                    check(done && gpr_write_en && gpr_write_byte && gpr_write_index==3'(encoded),"byte commit encoding");
                    tick();request_valid=0;request_write=0;
                    expected[word_index*16+shift+:8]=write_data[7:0];
                    check(register_state==expected,"byte write preserves every other architectural byte");cases++;
                end
        // A byte at FFFF is legal; a word is rejected before any bus request.
        for(integer wr=0;wr<2;wr++)begin
            clear();register_direct=0;select_rm=1;request_byte=1;request_write=1'(wr);request_valid=1;
            request_check=1;#1;
            check(done && !memory_request && !blocked,"validate-only byte at segment end");
            request_check=0;memory_request_ready=1;#1;
            check(memory_request && memory_byte && memory_address==24'h10FFFF && memory_write==1'(wr),"byte memory metadata and A20");
            tick();memory_request_ready=0;
            repeat(4)begin tick();check(!memory_request && timing_wait && !done && !blocked,"pending byte request not resubmitted");end
            request_valid=0;memory_response_valid=1;memory_read_data=16'h00A7;
            repeat(3)begin tick();check(!memory_response_ready && !done,"paused consumer holds completion");end
            request_valid=1;#1;check(done && !timing_wait && memory_response_ready && read_data==16'h00A7,"completed byte consumed normally");
            tick();request_valid=0;memory_response_valid=0;
            check(requests==1 && !blocked,"one byte logical acceptance");
            clear();select_rm=1;register_direct=0;request_byte=0;request_write=1'(wr);request_valid=1;memory_request_ready=1;#1;
            check(!memory_request && !done,"word FFFF suppressed before first lane");tick();
            check(blocked && requests==0 && !gpr_write_en,"word limit fault latched without side effect");
            cancel=1;tick();request_valid=0;cancel=0;#1;check(!blocked,"cancellation clears logical limit state");cases++;
        end
        check(read_a==read_b && ip==16'hFFF0 && flags==16'h0002,"architectural storage owner remains authoritative");
        $display("OPERAND_BYTE PASS: %0d cases; %0d alias, preservation, limit and response checks",cases,checks);
        $finish;
    end
endmodule
