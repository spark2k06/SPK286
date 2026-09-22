`timescale 1ns/1ps

module spk286_loadall_service_tb;
    logic clk = 1'b0, reset = 1'b1, cancel = 1'b0, start = 1'b0;
    logic current_protected = 1'b0;
    logic [1:0] current_cpl = 2'd0;
    logic memory_done = 1'b0;
    logic [15:0] memory_read_data = 16'h0000;
    wire memory_request, memory_write, memory_byte;
    wire [23:0] memory_address;
    wire [15:0] memory_write_data;
    wire busy, complete, fault, commit_valid;
    wire [7:0] fault_vector;
    wire [15:0] fault_error_code;
    wire [15:0] loaded_msw, loaded_ip, loaded_flags;
    wire [127:0] loaded_gpr;
    wire [15:0] loaded_gdtr_limit, loaded_idtr_limit, loaded_ldtr_selector, loaded_tr_selector;
    wire [23:0] loaded_gdtr_base, loaded_idtr_base, loaded_ldtr_base, loaded_tr_base;
    wire [15:0] loaded_ldtr_limit, loaded_tr_limit;
    wire [7:0] loaded_ldtr_access, loaded_tr_access;
    wire [3:0] loaded_ldtr_class, loaded_tr_class;
    wire loaded_ldtr_valid, loaded_ldtr_present, loaded_tr_valid, loaded_tr_present;
    wire [63:0] cache_selectors, cache_limits;
    wire [95:0] cache_bases;
    wire [31:0] cache_access;
    wire [15:0] cache_classes;
    wire [3:0] cache_valid, cache_present, cache_protected, cache_tables;
    wire [7:0] cache_dpl, cache_rpl;
    logic [15:0] image [0:50];
    integer checks = 0;

    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (condition !== 1'b1)
            $fatal(1, "%s address=%h request=%b complete=%b fault=%b",
                   message, memory_address, memory_request, complete, fault);
    endtask

    spk286_loadall_service dut (.*);

    task automatic tick;
        #5; clk = 1'b1; #5; clk = 1'b0; #1;
    endtask

    task automatic feed_image;
        for (integer i = 0; i <= 50; i = i + 1) begin
            while (!memory_request) tick();
            if (memory_address !== (24'h000800 + 24'(i * 2)))
                $fatal(1, "word %0d address=%h", i, memory_address);
            // A READY wait is represented at this service boundary by
            // withholding memory_done.  The physical BIU test covers pin
            // stability; this check keeps the LOADALL source address stable
            // while its logical word is outstanding.
            if (i == 0 || i == 17 || i == 50) begin
                repeat (2) begin
                    check(memory_request && memory_address == (24'h000800 + 24'(i * 2)) &&
                          !complete && !fault, "READY wait retains LOADALL image word");
                    tick();
                end
            end
            memory_read_data = image[i];
            memory_done = 1'b1;
            tick();
            memory_done = 1'b0;
            if (i != 50 && commit_valid) $fatal(1, "commit became visible before final word");
            checks = checks + 1;
        end
    endtask

    initial begin
        for (integer i = 0; i <= 50; i = i + 1) image[i] = 16'h0000;
        image[3] = 16'h0000;
        image[11] = 16'h1357; image[12] = 16'h0202; image[13] = 16'h5678;
        image[14] = 16'h1111; image[15] = 16'h2222; image[16] = 16'h3333;
        image[17] = 16'h4444; image[18] = 16'h5555;
        image[19] = 16'hD1D1; image[20] = 16'hC1C1; image[21] = 16'hB1B1; image[22] = 16'hA1A1;
        image[23] = 16'h9191; image[24] = 16'h8181; image[25] = 16'h7171; image[26] = 16'h6161;
        image[27] = 16'h3456; image[28] = 16'h9312; image[29] = 16'hABCD;
        image[30] = 16'h4567; image[31] = 16'h9A23; image[32] = 16'hBCDE;
        image[33] = 16'h5678; image[34] = 16'hF034; image[35] = 16'hCDEF;
        image[36] = 16'h6789; image[37] = 16'h9245; image[38] = 16'hEF01;
        image[39] = 16'hBCDE; image[40] = 16'h000A; image[41] = 16'hF0F0;
        image[42] = 16'h2468; image[43] = 16'h8220; image[44] = 16'h1111;
        image[45] = 16'h1357; image[46] = 16'h0001; image[47] = 16'h2222;
        image[48] = 16'h369C; image[49] = 16'h8902; image[50] = 16'h3333;

        tick();
        reset = 1'b0;
        start = 1'b1;
        tick();
        start = 1'b0;
        feed_image();
        if (!complete || !commit_valid || loaded_msw !== 16'h0000 || loaded_ip !== 16'h5678 ||
            loaded_flags !== 16'h0202 || loaded_gpr[15:0] !== 16'h6161 ||
            loaded_gpr[16 +: 16] !== 16'h7171 || loaded_gpr[112 +: 16] !== 16'hD1D1)
            $fatal(1, "architectural image decode");
        if (loaded_gdtr_base !== 24'h0ABCDE || loaded_gdtr_limit !== 16'hF0F0 ||
            loaded_idtr_base !== 24'h011357 || loaded_idtr_limit !== 16'h2222)
            $fatal(1, "table image decode GDTR=%h/%h IDTR=%h/%h", loaded_gdtr_base, loaded_gdtr_limit, loaded_idtr_base, loaded_idtr_limit);
        if (loaded_ldtr_base !== 24'h202468 || loaded_ldtr_limit !== 16'h1111 ||
            loaded_ldtr_access !== 8'h82 || loaded_ldtr_selector !== 16'h1111 ||
            loaded_tr_base !== 24'h02369C || loaded_tr_limit !== 16'h3333 ||
            loaded_tr_access !== 8'h89 || loaded_tr_selector !== 16'h1357)
            $fatal(1, "system cache image decode");
        if (cache_selectors !== 64'h2222333344445555 || cache_bases[23:0] !== 24'h123456 ||
            cache_bases[47:24] !== 24'h234567 || cache_bases[71:48] !== 24'h345678 ||
            cache_bases[95:72] !== 24'h456789 || cache_limits[63:48] !== 16'hEF01 ||
            cache_access !== 32'h92F09A93)
            $fatal(1, "segment cache image decode selectors=%h bases=%h limits=%h access=%h", cache_selectors, cache_bases, cache_limits, cache_access);
        checks = checks + 6;

        // Keep the current SPK286 FLAGS publication contract explicit.  The
        // emulator differential records that 86Box and PCem normalize
        // reserved positions; SPK286 currently exposes the image word and
        // leaves any future architectural normalization to evidence review.
        reset = 1'b1; tick(); reset = 1'b0;
        current_protected = 1'b0; current_cpl = 2'd0; image[12] = 16'hFFFF;
        start = 1'b1; tick(); start = 1'b0;
        feed_image();
        if (!complete || !commit_valid || loaded_flags !== 16'hFFFF)
            $fatal(1, "SPK286 LOADALL FLAGS image publication flags=%h", loaded_flags);
        checks = checks + 1;

        // CPL 0 may execute LOADALL while protected mode remains enabled.
        reset = 1'b1; tick(); reset = 1'b0;
        current_protected = 1'b1; current_cpl = 2'd0; image[3] = 16'h0001; image[12] = 16'h0202;
        start = 1'b1; tick(); start = 1'b0;
        feed_image();
        if (!complete || !commit_valid || loaded_msw !== 16'h0001 || !cache_protected[0] ||
            !cache_protected[1] || !cache_protected[2] || !cache_protected[3])
            $fatal(1, "CPL0 protected LOADALL success path");
        checks = checks + 1;

        // RESET aborts an in-flight image, clears its staged contents, and
        // allows a later start to begin again at physical 000800h.
        reset = 1'b1; tick(); reset = 1'b0;
        image[3] = 16'h0000; current_protected = 1'b0; current_cpl = 2'd0;
        start = 1'b1; tick(); start = 1'b0;
        while (!memory_request) tick();
        memory_read_data = image[0];
        memory_done = 1'b1;
        tick();
        memory_done = 1'b0;
        if (!memory_request || memory_address !== 24'h000802)
            $fatal(1, "reset precondition did not advance LOADALL image");
        reset = 1'b1; tick(); reset = 1'b0;
        if (memory_request || complete || fault || commit_valid)
            $fatal(1, "reset leaked LOADALL partial completion");
        start = 1'b1; tick(); start = 1'b0;
        if (!memory_request || memory_address !== 24'h000800)
            $fatal(1, "reset did not restart LOADALL image at word zero");
        checks = checks + 3;

        // Cancellation drops an in-flight image and restarts at word zero;
        // no completion pulse may escape from the discarded transaction.
        reset = 1'b1; tick(); reset = 1'b0;
        image[3] = 16'h0000; current_protected = 1'b0; current_cpl = 2'd0;
        start = 1'b1; tick(); start = 1'b0;
        while (!memory_request) tick();
        memory_read_data = image[0]; memory_done = 1'b1; tick(); memory_done = 1'b0;
        while (!memory_request) tick();
        cancel = 1'b1; tick(); cancel = 1'b0;
        if (memory_request || complete || fault || commit_valid)
            $fatal(1, "cancel leaked LOADALL completion");
        start = 1'b1; tick(); start = 1'b0;
        if (!memory_request || memory_address !== 24'h000800)
            $fatal(1, "cancel did not restart LOADALL image at word zero");
        checks = checks + 2;

        // CPL != 0 is rejected before the first physical image read.
        reset = 1'b1; tick(); reset = 1'b0;
        current_protected = 1'b1; current_cpl = 2'd1; start = 1'b1; tick(); start = 1'b0;
        if (!fault || memory_request || commit_valid || fault_vector !== 8'd13 || fault_error_code !== 16'h0000)
            $fatal(1, "non-CPL0 LOADALL privilege fault");
        checks = checks + 1;

        // A protected-mode image with PE cleared is rejected when MSW arrives.
        reset = 1'b1; tick(); reset = 1'b0;
        current_cpl = 2'd0; start = 1'b1; tick(); start = 1'b0;
        for (integer i = 0; i <= 3; i = i + 1) begin
            while (!memory_request) tick();
            memory_read_data = image[i]; memory_done = 1'b1; tick(); memory_done = 1'b0;
        end
        if (!fault || memory_request || commit_valid) $fatal(1, "protected-to-real LOADALL fault");
        checks = checks + 1;

        $display("LOADALL_SERVICE PASS: %0d image/privilege/atomicity checks", checks);
        $finish;
    end
endmodule
