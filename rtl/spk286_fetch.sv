// One outstanding fetch and one response slot feeding the six-byte prefetch queue.
// Transaction semantics only: native 80286 Ts/Tc pin timing is not modeled.
`timescale 1ns/1ps

module spk286_fetch #(
    // When enabled, request also reserves the returning beat and the next
    // beat. The CPU caller accounts for queued and staged bytes before grant.
    parameter logic READY_CHAINING = 1'b0
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        ready,
    input  logic [15:0] data_in,
    input  logic [23:0] code_base,
    input  logic [15:0] code_limit,
    input  logic        wrap_ip,
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
    logic [16:0] completed_cursor, next_cursor;
    logic next_blocked;
    logic single_byte;
    localparam logic FETCH_CHAINING = 1'b1;
    wire response_fire = response_valid && response_ready;
    wire response_slot_available = !response_valid ||
                                   (FETCH_CHAINING && response_fire);

    assign cursor = cursor_q;
    assign blocked = (cursor_q[16] && !wrap_ip) || (cursor_q[15:0] > code_limit);
    assign completed_cursor = wrap_ip ?
        {1'b0, (request_ip_q + {14'h0000, request_count_q})} :
        ({1'b0, request_ip_q} + {15'h0000, request_count_q});
    assign next_cursor = READY_CHAINING && active_q ? completed_cursor : cursor_q;
    assign next_blocked = (next_cursor[16] && !wrap_ip) ||
                          (next_cursor[15:0] > code_limit);
    assign next_address = code_base + {8'h00, next_cursor[15:0]};
    assign single_byte = next_address[0] || (next_cursor[15:0] == code_limit);
    assign request_ready = !reset && !restart && !restart_pending_q &&
                           (!active_q || (READY_CHAINING && bus_valid && ready && !canceled_q)) &&
                           response_slot_available && !next_blocked;
    // A prepared request stays invisible until the preceding response can
    // leave its only slot. Once offered, that slot is empty until completion,
    // so READY/backpressure cannot withdraw an outstanding bus transaction.
    assign bus_valid = active_q && !reset &&
                       (!READY_CHAINING || response_slot_available);
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
            if (active_q && bus_valid && !ready) canceled_q <= 1'b1;
            else begin
                active_q <= 1'b0;
                canceled_q <= 1'b0;
            end
        end else begin
            if (response_fire) response_valid <= 1'b0;
            if (active_q) begin
                if (bus_valid && ready) begin
                    active_q <= 1'b0;
                    canceled_q <= 1'b0;
                    if (!canceled_q) begin
                        response_valid <= 1'b1;
                        response_ip <= request_ip_q;
                        response_count <= request_count_q;
                        if (request_count_q == 2'd2) response_data <= data_in;
                        else if (address_q[0]) response_data <= {8'h00, data_in[15:8]};
                        else response_data <= {8'h00, data_in[7:0]};
                        // Real-mode IP is a 16-bit register and wraps after FFFF.
                        // Protected fetches retain the 17th bit so an over-limit
                        // stream is reported instead of silently restarting.
                        cursor_q <= completed_cursor;
                        if (READY_CHAINING && !suspend && request &&
                            response_slot_available && !next_blocked) begin
                            // Capture the next address on the old READY edge.
                            // Its bus offer is separately qualified by the
                            // response slot, never by anticipating READY.
                            active_q <= 1'b1;
                            address_q <= next_address;
                            request_ip_q <= next_cursor[15:0];
                            request_count_q <= single_byte ? 2'd1 : 2'd2;
                            bhe_n_q <= single_byte && !next_address[0];
                        end
                    end
                end
            end else if (!suspend && response_slot_available && !blocked &&
                         (restart_pending_q || request)) begin
                // Retire a staged response and capture an ordinary request
                // on the same edge. READY chaining additionally prepares that
                // request on the preceding completion edge when reserved.
                active_q <= 1'b1;
                canceled_q <= 1'b0;
                restart_pending_q <= 1'b0;
                address_q <= next_address;
                request_ip_q <= next_cursor[15:0];
                request_count_q <= single_byte ? 2'd1 : 2'd2;
                bhe_n_q <= single_byte && !next_address[0];
            end
        end
    end
endmodule
