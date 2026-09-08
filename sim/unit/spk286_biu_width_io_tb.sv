`timescale 1ns/1ps
module spk286_biu_width_io_tb;
    logic lock_request=0;
    logic clk=0, reset=1, cancel_data=0, ready=0;
    logic hold_request=0, ack_request=0, ack_response_ready=0;
    wire hlda, ack_request_ready, ack_response_valid, bus_lock;
    wire [7:0] ack_vector;
    logic [15:0] data_in=0;
    logic code_valid=0, code_bhe_n=0;
    logic [23:0] code_address=24'h123400;
    wire code_ready;
    logic data_request=0, data_write=0, data_byte=0, data_io=0;
    logic [23:0] data_address=0;
    logic [15:0] data_write_data=0;
    wire data_request_ready, data_response_valid;
    logic data_response_ready=0;
    wire [15:0] data_read_data;
    wire [23:0] address;
    wire [15:0] data_out;
    wire data_oe, bus_valid, bus_write, bus_bhe_n;
    wire [3:0] bus_status;
    integer checks=0, cases=0, accepted=0, responses=0;
    spk286_biu dut(.*);
    task automatic check(input logic condition,input string message);
        checks++;
        if(condition!==1'b1)$fatal(1,"%s case=%0d address=%h status=%h data=%h",message,cases,address,bus_status,data_out);
    endtask
    task automatic tick;
        #5;
        if(!reset && bus_valid && ready && (bus_status==5 || bus_status==6 || bus_status==9 || bus_status==10))accepted++;
        if(!reset && !cancel_data && data_response_valid && data_response_ready)responses++;
        clk=1;#5;clk=0;#1;
    endtask
    task automatic initialize;
        reset=1;cancel_data=0;ready=0;hold_request=0;ack_request=0;ack_response_ready=0;
        code_valid=0;data_request=0;data_response_ready=0;tick();reset=0;#1;
        accepted=0;responses=0;
        check(data_request_ready && !bus_valid && !data_response_valid,"initial ownership");
    endtask
    task automatic request_transfer(input logic io_space,byte_width,wr,input logic[23:0]addr);
        data_request=1;data_io=io_space;data_byte=byte_width;data_write=wr;
        data_address=addr;data_write_data=16'hB37D;
        check(data_request_ready,"request admission");tick();data_request=0;
        data_io=!io_space;data_byte=!byte_width;data_write=!wr;data_address=24'hABCDEF;data_write_data=16'h195E;#1;
    endtask
    task automatic physical(input logic io_space,wr,input logic[23:0]addr,input logic bhe,
                            input logic[15:0]driven,sampled,input integer waits);
        for(integer n=0;n<=waits;n++)begin
            ready=0;data_in=16'(n*503);#1;
            check(bus_valid && address==addr && bus_bhe_n==bhe && bus_write==wr && data_oe==wr,"address, lanes and direction held");
            check(bus_status==(io_space ? (wr ? 10 : 9) : (wr ? 6 : 5)),"memory and I/O status separation");
            check(!code_ready && !data_response_valid,"only physical owner observes completion");
            if(wr)check(data_out==driven,"captured write value and selected lane");
            if(n<waits)tick();
        end
        data_in=sampled;ready=1;tick();ready=0;
    endtask
    initial begin
        for(integer io_space=0;io_space<2;io_space++)
            for(integer byte_width=0;byte_width<2;byte_width++)
                for(integer wr=0;wr<2;wr++)
                    for(integer boundary=0;boundary<4;boundary++)
                        for(integer waits=0;waits<4;waits++)begin : transfer
                            logic[23:0]addr,pins;
                            logic[15:0]expected;
                            integer cycles;
                            addr=boundary==0 ? 24'h100100 : boundary==1 ? 24'h100101 : boundary==2 ? 24'h10FFFE : 24'h10FFFF;
                            pins=io_space!=0 ? {8'd0,addr[15:0]} : addr;
                            initialize();request_transfer(1'(io_space),1'(byte_width),1'(wr),addr);
                            expected=byte_width!=0 ? 16'h007D : 16'hB37D;
                            cycles=byte_width==0 && addr[0] ? 2 : 1;
                            if(addr[0])begin
                                physical(1'(io_space),1'(wr),pins,0,16'h7D00,16'h7D19,waits);
                                if(byte_width==0)begin
                                    check(!data_response_valid,"odd word first byte is not a response");
                                    physical(1'(io_space),1'(wr),pins+24'd1,1,16'h00B3,16'hE2B3,3-waits);
                                end
                            end else physical(1'(io_space),1'(wr),pins,1'(byte_width),byte_width!=0 ? 16'h007D : 16'hB37D,16'hB37D,waits);
                            check(data_response_valid && data_read_data==expected,"assembled byte or word response");
                            data_request=1;ready=1;
                            repeat(5)begin tick();check(!bus_valid && !data_request_ready && data_response_valid && data_read_data==expected,"held response cannot replay I/O or memory");end
                            data_response_ready=1;tick();data_request=0;data_response_ready=0;ready=0;repeat(2)tick();
                            check(accepted==cycles && responses==1 && !bus_valid,"exact physical/response counts");cases++;
                        end
        // Canceled accepted I/O still drains once; side effects are not undone.
        for(integer byte_width=0;byte_width<2;byte_width++)
            for(integer wr=0;wr<2;wr++)
                for(integer stage=0;stage<3;stage++)begin
                    initialize();request_transfer(1,1'(byte_width),1'(wr),24'h00FFFF);
                    if(stage==0)begin cancel_data=1;tick();cancel_data=0;end
                    if(stage==1)cancel_data=1;
                    physical(1,1'(wr),24'h00FFFF,0,16'h7D00,16'h7D19,2);cancel_data=0;
                    if(byte_width==0)begin
                        if(stage==2)cancel_data=1;
                        physical(1,1'(wr),24'h010000,1,16'h00B3,16'hE2B3,3);cancel_data=0;
                    end else if(stage==2)begin cancel_data=1;tick();cancel_data=0;end
                    data_response_ready=1;ready=1;repeat(4)tick();
                    check(!bus_valid && !data_response_valid && responses==0 && accepted==(byte_width!=0 ? 1 : 2),"canceled I/O drains without duplicate or stale response");cases++;
                end
        // HOLD cannot divide an odd I/O word, then permits response retention.
        initialize();request_transfer(1,0,0,24'h00FFFF);hold_request=1;
        physical(1,0,24'h00FFFF,0,0,16'h7D19,2);check(!hlda,"HOLD does not split I/O word");
        physical(1,0,24'h010000,1,0,16'hE2B3,1);tick();check(hlda && !bus_valid && data_response_valid,"HOLD after whole I/O word");
        data_response_ready=1;tick();check(responses==1 && !data_response_valid,"response consumed once during HOLD");
        hold_request=0;tick();check(!hlda,"HOLD released");
        $display("BIU_WIDTH_IO PASS: %0d cases; exact lane, READY, side-effect, cancellation and HOLD counts; %0d checks",cases,checks);
        $finish;
    end
endmodule
