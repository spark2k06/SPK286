// Generic functional sequencing. No x86 decode, byte assembly or bus policy.
// enable permits implementation progress; it is not a historical timing mode.
`timescale 1ns/1ps

module spk286_microsequencer #(
    parameter integer ADDRESS_WIDTH = 2,
    parameter integer ROM_DEPTH = 3
) (
    input  logic                     clk,
    input  logic                     reset,
    input  logic                     cancel,
    input  logic                     enable,
    input  logic                     start,
    input  logic [ADDRESS_WIDTH-1:0] start_entry,
    output logic                     start_ready,
    input  logic                     rom_valid,
    input  logic                     rom_end,
    input  logic                     operation_done,
    input  logic                     branch_request, branch_target_valid,
    input  logic [ADDRESS_WIDTH-1:0] branch_target,
    output logic                     operation_valid,
    output logic                     active,
    output logic [ADDRESS_WIDTH-1:0] micro_pc,
    output logic [ADDRESS_WIDTH-1:0] micro_entry,
    output logic                     retired,
    output logic                     fault
);
    localparam logic [ADDRESS_WIDTH:0] DEPTH = (ADDRESS_WIDTH+1)'(ROM_DEPTH);
    assign start_ready = enable && !reset && !cancel && !active && !fault;
    assign operation_valid = enable && !reset && !cancel && active && !fault &&
                             rom_valid && !rom_end && ({1'b0, micro_pc} < DEPTH);

    always_ff @(posedge clk) begin
        if (reset || cancel) begin
            active <= 1'b0;
            micro_pc <= '0;
            micro_entry <= '0;
            retired <= 1'b0;
            fault <= 1'b0;
        end else begin
            // A pulse clears even when execution is paused after retirement.
            retired <= 1'b0;
            if (enable) begin
                if (active) begin
                    if (!rom_valid || {1'b0, micro_pc} >= DEPTH) begin
                        active <= 1'b0;
                        fault <= 1'b1;
                    end else if (operation_done) begin
                        if (rom_end) begin
                            active <= 1'b0;
                            retired <= 1'b1;
                        end else if (branch_request) begin
                            if (!branch_target_valid || {1'b0, branch_target} >= DEPTH) begin
                                active <= 1'b0;
                                fault <= 1'b1;
                            end else begin
                                micro_pc <= branch_target;
                            end
                        end else if ({1'b0, micro_pc} + 1'b1 >= DEPTH) begin
                            // Never wrap or silently fall off an entry lacking END.
                            active <= 1'b0;
                            fault <= 1'b1;
                        end else begin
                            micro_pc <= micro_pc + 1'b1;
                        end
                    end
                end else if (start && start_ready) begin
                    micro_pc <= start_entry;
                    micro_entry <= start_entry;
                    if ({1'b0, start_entry} >= DEPTH)
                        fault <= 1'b1;
                    else
                        active <= 1'b1;
                end
            end
        end
    end
endmodule
