// SPDX-License-Identifier: MIT
// Latest-value transfer between two clock domains with a request/acknowledge
// handshake: the source holds a payload until the destination has taken it,
// so the destination always sees a coherent word. Not a FIFO; intermediate
// values are dropped. Both sides start from configuration initialization.
`timescale 1ns/1ps
module zxtres_cdc_snapshot #(
    parameter int WIDTH = 1
) (
    input  logic             src_clk,
    input  logic             src_send,
    input  logic [WIDTH-1:0] src_data,
    output logic             src_ready,
    input  logic             dst_clk,
    output logic [WIDTH-1:0] dst_data = '0,
    output logic             dst_update = 1'b0
);
    logic [WIDTH-1:0] payload_q = '0;
    logic req_q = 1'b0, ack_q = 1'b0;
    (* ASYNC_REG = "TRUE" *) logic ack_meta = 1'b0, ack_sync = 1'b0;
    (* ASYNC_REG = "TRUE" *) logic req_meta = 1'b0, req_sync = 1'b0;

    assign src_ready = (req_q == ack_sync);
    always_ff @(posedge src_clk) begin
        ack_meta <= ack_q;
        ack_sync <= ack_meta;
        if (src_send && src_ready) begin
            payload_q <= src_data;
            req_q <= !req_q;
        end
    end

    // payload_q is stable from its launch until the request has crossed two
    // destination registers, so it is captured without a synchronizer.
    always_ff @(posedge dst_clk) begin
        req_meta <= req_q;
        req_sync <= req_meta;
        dst_update <= 1'b0;
        if (req_sync != ack_q) begin
            dst_data <= payload_q;
            dst_update <= 1'b1;
            ack_q <= req_sync;
        end
    end
endmodule
