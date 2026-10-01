`timescale 1ns/1ps
// Executable H16 reset probes; no direct protected-state initialization.
module spk286_null_ldtr_tb;
    `include "spk286_signals.svh"
    spk286 dut (.*);
    logic [7:0] rom [0:65535], memory [0:65535];
    integer cycles=0, checks=0, cases=0, scenario, entry_kind, selector;
    integer file_id, parsed, deadline, mode, gdt_zero_reads, ldt_zero_reads;
    string vectors_path, rom_path;
    logic captured, lldt_captured;
    logic [63:0] expected_selectors;
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
        if (ok !== 1'b1) $fatal(1,"%s case=%s mode=%0d LDTR=%h/%0d TR=%h CS:IP=%h:%h",
            msg,rom_path,mode,debug_ldtr_selector,dut.protected_ldtr_valid,debug_tr_selector,debug_cs,debug_ip);
    endtask
    task automatic tick;
        #1;
        if (!captured && dut.fault_request) begin
            captured=1;
            check(dut.fault_vector==(scenario==7 ? 8'd13 : 8'd10) && dut.fault_error_code==16'h4,"normalized LDTR/LDT-segment error");
            if (scenario==7) begin
                check(debug_tr_selector==16'h18 && debug_ldtr_selector==16'h50 && dut.protected_ldtr_valid,
                      "failed explicit LLDT preserves previous task and LDT");
                check(dut.protected_segment_valid==4'hF,"failed LLDT leaves segment caches usable");
            end else begin
                check(debug_tr_selector==16'h20 && debug_gpr[15:0]==16'hBEEF,"task LDTR fault belongs to incoming task");
                check(debug_segment_selectors==expected_selectors && dut.protected_segment_valid==expected_valid,
                      "LDT-dependent failure retains H15 completed cache stages");
                check(debug_ldtr_selector==16'(selector) && !dut.protected_ldtr_valid && !dut.protected_ldtr_present,
                      "invalid incoming LDT retains raw visible selector");
            end
        end
        if (!lldt_captured && word_at('h301C)==16'h4C44) begin
            lldt_captured=1;
            check(scenario==6 && word_at('h301A)==16'(selector),"SLDT preserves explicit null RPL");
            check(debug_ldtr_selector==16'(selector) && !dut.protected_ldtr_valid && !dut.protected_ldtr_present,
                  "explicit null LDT is disabled without canonicalizing selector");
            check(dut.protected_segment_valid==4'hF && debug_segment_selectors==64'h0060001000080060,
                  "LLDT does not invalidate other segment caches");
        end
        ready=bus_valid && ((cycles%4)!=1);
        data_in=0;
        if (bus_valid && !bus_write) begin
            if (address[0]) data_in={read_byte(address),8'h00};
            else if (bus_bhe_n) data_in={8'h00,read_byte(address)};
            else data_in={read_byte(address+24'd1),read_byte(address)};
            if (ready && bus_status==4'h5) begin
                if (address>=24'h1000 && address<24'h1008) gdt_zero_reads++;
                if (address>=24'h1A00 && address<24'h1A08) ldt_zero_reads++;
            end
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
        if (!$value$plusargs("ldtr_vectors=%s",vectors_path)) $fatal(1,"ldtr_vectors required");
        for (mode=0;mode<2;mode++) begin
            timing_policy_request=mode==0 ? 2'd0 : 2'd2;
            file_id=$fopen(vectors_path,"r");
            if (file_id==0) $fatal(1,"manifest unavailable");
            while (!$feof(file_id)) begin
                parsed=$fscanf(file_id,"%s %d %d %d\n",rom_path,scenario,entry_kind,selector);
                if (parsed==4) begin
                    $readmemh(rom_path,rom);
                    for (integer i=0;i<65536;i++) memory[i]=0;
                    captured=0;lldt_captured=0;cycles=0;gdt_zero_reads=0;ldt_zero_reads=0;
                    expected_selectors={16'h48,(scenario==3 || scenario==5 ? 16'h4 : 16'h38),
                                        (scenario==2 || scenario==4 ? 16'h4 : 16'h30),16'h40};
                    expected_valid=scenario==2 ? 4'h4 : 4'h0;
                    reset=1;execute_enable=0;repeat(8) tick();reset=0;execute_enable=1;
                    deadline=0;
                    while (word_at('h3000)!=16'h444F && !shutdown && !control_error && !unsupported_opcode && deadline<150000) begin
                        tick();deadline++;
                    end
                    check(word_at('h3000)==16'h444F,"guest reaches reporting signature");
                    check(captured==(scenario==1 || scenario==2 || scenario==3 || scenario==7),"fault/success discriminator");
                    check(gdt_zero_reads==0,"null and illegal-TI LDTR never fetch GDT entry zero");
                    check((scenario==4 || scenario==5) ? ldt_zero_reads>0 : ldt_zero_reads==0,
                          "LDT entry zero reads require a valid LDT and explicit TI segment");
                    check(lldt_captured==(scenario==6),"explicit null LLDT readback checkpoint");
                    if (scenario==0) begin
                        check(word_at('h3010)==16'(selector) && !dut.protected_ldtr_valid && !dut.protected_ldtr_present,
                              "successful task preserves null LDTR selector and disabled cache");
                        check(word_at('h300E)==16'h20 && word_at('h3004)==16'hBEEF,"null LDT permits valid global task segments");
                    end
                    if (scenario==4 || scenario==5) begin
                        check(word_at('h3010)==16'h50 && dut.protected_ldtr_valid,"valid incoming LDT remains available");
                        check(word_at('h300E)==16'h20 && word_at('h3002)==0,"valid LDT entry-zero control executes incoming task");
                    end
                    if (scenario==7) check(word_at('h3002)==13 && word_at('h3014)==4 && word_at('h3010)==16'h50,
                                          "explicit TI failure reports #GP and unchanged LDTR");
                    cases++;
                end
            end
            $fclose(file_id);
        end
        $display("NULL_LDTR PASS: cases=%0d checks=%0d modes=baseline,Max",cases,checks);
        $finish;
    end
endmodule
