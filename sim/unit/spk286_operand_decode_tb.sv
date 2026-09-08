`timescale 1ns/1ps
module spk286_operand_decode_tb;
    wire modrm_valid;
    logic clk=0, reset=1, cancel=0, start=0, enable=0, byte_valid=0;
    logic [7:0] byte_data=0;
    wire byte_ready, done, register_direct;
    logic [15:0] bx=16'h1000, bp=16'h2000, si=16'h0011, di=16'h0023;
    wire [1:0] mode, segment_index;
    wire [2:0] reg_index, rm_index;
    wire [15:0] displacement, effective_offset;
    integer checks=0, cases=0, consumed=0;
    logic [15:0] expected_disp;
    logic [7:0] encoded;
    logic [15:0] held_ea;
    spk286_operand_decode dut (.*);
    task automatic check(input logic condition,input string message);
        checks=checks+1;
        if(condition !== 1'b1) $fatal(1,"%s encoding=%h disp=%h",message,encoded,displacement);
    endtask
    task automatic tick;
        #5;
        if(byte_valid && byte_ready) consumed=consumed+1;
        clk=1; #5; clk=0; #1;
    endtask
    task automatic send_byte(input logic [7:0] value);
        byte_valid=0; byte_data=~value; repeat(2) tick();
        check(!done,"empty queue cannot invent instruction bytes");
        enable=0; byte_valid=1; byte_data=value; #1;
        check(!byte_ready && !done,"paused acquisition"); tick();
        enable=1; #1; check(byte_ready,"resume byte acquisition"); tick(); byte_valid=0;
    endtask
    initial begin
        tick(); reset=0;
        for(integer m=0;m<4;m=m+1)
            for(integer r=0;r<8;r=r+1)
                for(integer rm=0;rm<8;rm=rm+1)
                    for(integer value=0;value<5;value=value+1) begin
                        start=1; enable=0; tick(); start=0; enable=1; consumed=0;
                        encoded=8'(m*64+r*8+rm);
                        case(value)
                            0: expected_disp=16'h0000;
                            1: expected_disp=16'h0001;
                            2: expected_disp=m==1?16'h007F:16'h7FFF;
                            3: expected_disp=m==1?16'hFF80:16'h8000;
                            4: expected_disp=16'hFFFF;
                            default: $fatal(1,"test value");
                        endcase
                        send_byte(encoded);
                        if(m==1) send_byte(expected_disp[7:0]);
                        else if(m==2 || m==0 && rm==6) begin
                            send_byte(expected_disp[7:0]); send_byte(expected_disp[15:8]);
                        end else expected_disp=0;
                        check(done && !byte_ready,"all bytes acquired before resolution");
                        check(mode==2'(m) && reg_index==3'(r) && rm_index==3'(rm) &&
                              register_direct==(m==3) && displacement==expected_disp,"stable decoded fields and sign extension");
                        check(consumed==1+(m==1?1:(m==2 || m==0 && rm==6?2:0)),"exact byte consumption");
                        tick(); held_ea=effective_offset;
                        byte_data=8'hFF; byte_valid=1; bx=16'hFFFF; tick();
                        check(!done && !byte_ready && effective_offset==held_ea && displacement==expected_disp,
                              "following queue/GPR values cannot replace resolved context");
                        byte_valid=0; bx=16'h1000; cases=cases+1;
                    end
        for(integer after_low=0;after_low<2;after_low=after_low+1) begin
            start=1; tick(); start=0; send_byte(8'h86);
            if(after_low!=0) send_byte(8'hEF);
            cancel=1; byte_valid=1; byte_data=8'hBE; tick(); cancel=0; byte_valid=0;
            check(displacement==0 && !done,"redirect discards partial displacement");
            send_byte(8'hC1); check(done && register_direct,"fresh register context after cancellation"); tick();
        end
        $display("OPERAND_DECODE PASS: %0d streaming contexts plus partial cancellation; %0d checks",cases,checks);
        $finish;
    end
endmodule
