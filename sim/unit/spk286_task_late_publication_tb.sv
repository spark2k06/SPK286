`timescale 1ns/1ps
// Identical reset ROM bytes are also executable in native/SPK 86Box.
module spk286_task_late_publication_tb;
    `include "spk286_signals.svh"
    spk286 dut (.*);
    logic [7:0] rom [0:65535], memory [0:65535];
    integer cycles=0, checks=0, cases=0, stage, entry_kind, absent, task_handler;
    integer file_id, parsed, deadline, observation_only=0;
    string vectors_path, rom_path;
    logic captured;
    logic [7:0] expected_vector;
    logic [15:0] expected_error;
    logic [3:0] expected_valid;

    function automatic logic [7:0] read_byte(input logic [23:0] a);
        if (a >= 24'hFF0000 || (a >= 24'h0F0000 && a < 24'h100000)) read_byte=rom[a[15:0]];
        else if (a < 24'h010000) read_byte=memory[a[15:0]];
        else read_byte=0;
    endfunction
    function automatic logic [15:0] word_at(input integer a);
        word_at={memory[a+1],memory[a]};
    endfunction
    task automatic check(input logic ok, input string msg);
        checks++;
        if (ok !== 1'b1) $fatal(1,"%s case=%s CS=%h IP=%h TR=%h valid=%h segments=%h",msg,rom_path,
            debug_cs,debug_ip,debug_tr_selector,dut.protected_segment_valid,debug_segment_selectors);
    endtask
    task automatic tick;
        #1;
        if (!captured && dut.fault_request) begin
            captured=1;
            $display("TASK_LATE_OBSERVE stage=%0d entry=%0d absent=%0d handler=%0d vec=%0d err=%h selectors=%h valid=%h bases=%h access=%h TR=%h AX=%h LDTR=%h/%0d",
                stage,entry_kind,absent,task_handler,dut.fault_vector,dut.fault_error_code,
                debug_segment_selectors,dut.protected_segment_valid,debug_segment_bases,debug_segment_access,
                debug_tr_selector,debug_gpr[15:0],debug_ldtr_selector,dut.protected_ldtr_valid);
            if (observation_only == 0) begin
                check(dut.fault_vector==expected_vector && dut.fault_error_code==expected_error,"first exception metadata");
                check(debug_tr_selector==16'h20 && debug_gpr[15:0]==16'hBEEF,"incoming TR and general registers precede late faults");
                check(debug_segment_selectors==64'h0048003800300040,"all visible incoming selectors precede descriptor validation");
                check(dut.protected_segment_valid==expected_valid,"hidden validity reflects completed task stages only");
                check(debug_ldtr_selector==(stage==7 ? 16'h4 : stage==1 ? 16'h60 : 16'h50) && dut.protected_ldtr_valid==(stage!=1 && stage!=7),"incoming LDTR validity at fault");
                if (expected_valid[2]) check(debug_segment_bases[71:48]==24'h005000 && debug_segment_limits[47:32]==16'h1FFF,"incoming SS cache survives later fault");
                if (expected_valid[1]) check(debug_segment_bases[47:24]==24'h0F0000,"incoming CS cache survives data/IP fault");
                check(memory['h103D]==(expected_valid[2] ? 8'h93 : (stage==2 && absent!=0 ? 8'h12 : stage==2 ? 8'h90 : 8'h92)),"SS accessed update belongs to completed stage");
                check(memory['h1035]==(expected_valid[1] ? 8'h9B : (stage==3 && absent!=0 ? 8'h1A : stage==3 ? 8'h92 : 8'h9A)),"CS accessed update belongs to completed stage");
            end
        end
        ready=bus_valid && ((cycles%4)!=1);
        data_in=0;
        if (bus_valid && !bus_write) begin
            if (address[0]) data_in={read_byte(address),8'h00};
            else if (bus_bhe_n) data_in={8'h00,read_byte(address)};
            else data_in={read_byte(address+24'd1),read_byte(address)};
        end
        if (bus_valid && ready && bus_write && bus_status==4'h6 && address<24'h010000) begin
            if (address[0]) memory[address[15:0]]=data_out[15:8];
            else begin
                memory[address[15:0]]=data_out[7:0];
                if (!bus_bhe_n) memory[address[15:0]+16'd1]=data_out[15:8];
            end
        end
        #4; clk=1; #5; clk=0; #1; cycles++;
    endtask
    initial begin
        if (!$value$plusargs("task_vectors=%s",vectors_path)) $fatal(1,"task_vectors required");
        if ($value$plusargs("observe=%d",observation_only)) begin end
        file_id=$fopen(vectors_path,"r");
        if (file_id == 0) $fatal(1,"manifest unavailable");
        while (!$feof(file_id)) begin
            parsed=$fscanf(file_id,"%s %d %d %d %d\n",rom_path,stage,entry_kind,absent,task_handler);
            if (parsed==5) begin
                $readmemh(rom_path,rom);
                for (integer i=0;i<65536;i++) memory[i]=0;
                captured=0; cycles=0;
                case(stage)
                    1: begin expected_vector=10;expected_error='h60;expected_valid=0;end
                    2: begin expected_vector=absent!=0 ? 12 : 10;expected_error='h38;expected_valid=0;end
                    3: begin expected_vector=absent!=0 ? 11 : 10;expected_error='h30;expected_valid=4'b0100;end
                    4: begin expected_vector=absent!=0 ? 11 : 10;expected_error='h40;expected_valid=4'b0110;end
                    5: begin expected_vector=absent!=0 ? 11 : 10;expected_error='h48;expected_valid=4'b0111;end
                    6: begin expected_vector=13;expected_error=0;expected_valid=4'b1111;end
                    7: begin expected_vector=10;expected_error=4;expected_valid=0;end
                    default: begin expected_vector=0;expected_error=0;expected_valid=4'b1111;end
                endcase
                reset=1; execute_enable=0; repeat(8) tick(); reset=0; execute_enable=1;
                deadline=0;
                while (word_at('h3000)!=16'h444F && !shutdown && !control_error && !unsupported_opcode && deadline<150000) begin
                    tick();deadline++;
                end
                if (observation_only == 0) begin
                    check(word_at('h3000)==16'h444F,"guest reaches result signature");
                    check(captured==(stage!=0),"fault/success control");
                    check(memory['h1025]==8'h83,"incoming TSS busy");
                    check(memory['h101D]==(entry_kind==1 || entry_kind==3 ? 8'h81 : 8'h83),"outgoing BUSY policy");
                    check(word_at('h1300)==(entry_kind==1 || entry_kind==3 ? 0 : 'h18),"backlink policy");
                    if (stage>=3 && stage<=6 && task_handler==0) begin
                        check(word_at('h300A)==16'h38 && word_at('h300C)==16'h0EF8,"exception frame uses incoming SS:SP");
                        check(word_at('h3014)==expected_error && word_at('h3018)==16'h30 && word_at('h3016)==word_at('h130E),"exception frame contains new CS:IP/error context");
                    end
                    if (stage!=0 && task_handler!=0) begin
                        check(word_at('h1324)==16'h30 && word_at('h1326)==16'h38 && word_at('h1328)==16'h48 && word_at('h1322)==16'h40,
                              "exception task gate saves incoming visible selectors");
                    end
                end
                cases++;
            end
        end
        $fclose(file_id);
        if (observation_only != 0) $display("TASK_LATE_OBSERVATIONS cases=%0d",cases);
        else $display("TASK_LATE_PUBLICATION PASS: cases=%0d checks=%0d",cases,checks);
        $finish;
    end
endmodule
