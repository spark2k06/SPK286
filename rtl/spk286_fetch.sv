// One outstanding fetch and one response slot for the future six-byte prefetch.
// Transaction semantics only: native 80286 Ts/Tc timing is not implemented yet.
`timescale 1ns/1ps

module spk286_fetch (
    input  logic        clk,
    input  logic        reset,
    input  logic        ready,
    input  logic [15:0] data_in,
    input  logic [23:0] code_base,
    input  logic [15:0] code_limit,
    input  logic        restart,
    input  logic [15:0] restart_ip,
    input  logic        request,
    input  logic        suspend,
    output logic        request_ready,
    input  logic        response_ready,
    output logic        response_valid,
    output logic [15:0] response_data,
    output logic [15:0] response_ip,
    output logic [1:0]  response_count,
    output logic [16:0] cursor,
    output logic        blocked,
    output logic        bus_valid,
    output logic        bus_bhe_n,
    output logic [23:0] address
);
    logic active_q, canceled_q, restart_pending_q;
    logic [16:0] cursor_q;
    logic [23:0] address_q;
    logic [15:0] request_ip_q;
    logic [1:0] request_count_q;
    logic bhe_n_q;
    logic [23:0] next_address;
    logic single_byte;

    assign cursor = cursor_q;
    assign blocked = cursor_q[16] || (cursor_q[15:0] > code_limit);
    assign next_address = code_base + {8'h00, cursor_q[15:0]};
    assign single_byte = next_address[0] || (cursor_q[15:0] == code_limit);
    assign request_ready = !reset && !restart && !restart_pending_q &&
                           !active_q && !response_valid && !blocked;
    assign bus_valid = active_q && !reset;
    assign address = bus_valid ? address_q : 24'h000000;
    assign bus_bhe_n = bus_valid ? bhe_n_q : 1'b1;

    always_ff @(posedge clk) begin
        if (reset) begin
            active_q <= 1'b0;
            canceled_q <= 1'b0;
            restart_pending_q <= 1'b1;
            cursor_q <= 17'h0FFF0;
            address_q <= 24'h000000;
            request_ip_q <= 16'h0000;
            request_count_q <= 2'd0;
            bhe_n_q <= 1'b1;
            response_valid <= 1'b0;
            response_data <= 16'h0000;
            response_ip <= 16'h0000;
            response_count <= 2'd0;
        end else if (restart) begin
            // The new architectural CS cache is available on the following edge.
            cursor_q <= {1'b0, restart_ip};
            restart_pending_q <= 1'b1;
            response_valid <= 1'b0;
            if (active_q && !ready) canceled_q <= 1'b1;
            else begin
                active_q <= 1'b0;
                canceled_q <= 1'b0;
            end
        end else begin
            if (response_valid && response_ready) response_valid <= 1'b0;
            if (active_q) begin
                if (ready) begin
                    active_q <= 1'b0;
                    canceled_q <= 1'b0;
                    if (!canceled_q) begin
                        response_valid <= 1'b1;
                        response_ip <= request_ip_q;
                        response_count <= request_count_q;
                        if (request_count_q == 2'd2) response_data <= data_in;
                        else if (address_q[0]) response_data <= {8'h00, data_in[15:8]};
                        else response_data <= {8'h00, data_in[7:0]};
                        // Preserve overflow so the next request cannot wrap to zero.
                        cursor_q <= {1'b0, request_ip_q} + {15'h0000, request_count_q};
                    end
                end
            end else if (!suspend && !response_valid && !blocked && (restart_pending_q || request)) begin
                active_q <= 1'b1;
                canceled_q <= 1'b0;
                restart_pending_q <= 1'b0;
                address_q <= next_address;
                request_ip_q <= cursor_q[15:0];
                request_count_q <= single_byte ? 2'd1 : 2'd2;
                bhe_n_q <= single_byte && !next_address[0];
            end
        end
    end
endmodule
