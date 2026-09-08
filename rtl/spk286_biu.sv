// Shared normalized 80286 bus. Fetch supplies code-cycle metadata; the BIU
// sequences logical data words and arbitrates every physical READY handshake.
// This is functional transaction timing, not native Ts/Tc/Ti timing.
`timescale 1ns/1ps
module spk286_biu (
    input  logic clk, reset, cancel_data,
    input  logic ready,
    input  logic hold_request,
    output logic hlda,
    input  logic ack_request,
    output logic ack_request_ready, ack_response_valid,
    input  logic ack_response_ready,
    output logic [7:0] ack_vector,
    output logic bus_lock,
    input  logic [15:0] data_in,
    input  logic code_valid, code_bhe_n,
    input  logic [23:0] code_address,
    output logic code_ready,
    input  logic data_request, data_write,
    input  logic [23:0] data_address,
    input  logic [15:0] data_write_data,
    output logic data_request_ready,
    output logic data_response_valid,
    input  logic data_response_ready,
    output logic [15:0] data_read_data,
    output logic [23:0] address,
    output logic [15:0] data_out,
    output logic data_oe, bus_valid, bus_write, bus_bhe_n,
    output logic [3:0] bus_status
);
    logic data_active_q, write_q, second_q, canceled_q;
    logic [23:0] address_q;
    logic [15:0] write_data_q;
    logic [7:0] low_byte_q;
    logic owner_valid_q, select_data, select_ack, data_complete;
    logic [1:0] owner_q, selected_owner;
    logic ack_active_q, ack_second_q, lock_chain_q, ack_canceled_q;
    assign data_request_ready = !reset && !cancel_data && !data_active_q && !data_response_valid && !ack_active_q && !hlda;
    assign ack_request_ready = !reset && !cancel_data && !data_active_q && !data_response_valid && !ack_active_q && !ack_response_valid && !hlda;
    // Data has priority at a free boundary. Once a cycle is visible and waiting,
    // its owner cannot change even if a higher-priority request appears.
    assign selected_owner = owner_valid_q ? owner_q : (ack_active_q ? 2'd2 : (data_active_q ? 2'd1 : 2'd0));
    assign select_data = selected_owner == 2'd1;
    assign select_ack = selected_owner == 2'd2;
    assign bus_valid = !reset && !hlda && (select_ack ? ack_active_q : (select_data ? data_active_q : (code_valid && !lock_chain_q)));
    assign address = !bus_valid || select_ack ? 24'h000000 : (select_data ? address_q : code_address);
    assign bus_write = bus_valid && select_data && write_q;
    assign bus_bhe_n = !bus_valid || select_ack ? 1'b1 : (select_data ? second_q : code_bhe_n);
    assign data_out = !bus_write ? 16'h0000 :
                      (address_q[0] ? {write_data_q[7:0], 8'h00} :
                       (second_q ? {8'h00, write_data_q[15:8]} : write_data_q));
    assign data_oe = bus_write;
    assign bus_status = !bus_valid ? 4'hF : (select_ack ? 4'h0 : (!select_data ? 4'hD : (write_q ? 4'h6 : 4'h5)));
    assign code_ready = bus_valid && !select_data && !select_ack && ready;
    assign data_complete = bus_valid && select_data && ready;
    assign bus_lock = !reset && (lock_chain_q || (bus_valid && select_ack));

    always_ff @(posedge clk) begin
        if (reset) hlda <= 1'b0;
        else if (hlda) begin
            if (!hold_request) hlda <= 1'b0;
        end else if (hold_request && !bus_lock && !data_active_q && !ack_active_q &&
                     (!bus_valid || ready)) hlda <= 1'b1;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            ack_active_q <= 1'b0; ack_second_q <= 1'b0; lock_chain_q <= 1'b0;
            ack_response_valid <= 1'b0; ack_vector <= 8'd0; ack_canceled_q <= 1'b0;
        end else begin
            if (ack_response_valid && ack_response_ready) ack_response_valid <= 1'b0;
            if (ack_request && ack_request_ready) begin
                ack_active_q <= 1'b1; ack_second_q <= 1'b0; ack_canceled_q <= 1'b0;
            end
            if (bus_valid && select_ack) begin
                lock_chain_q <= 1'b1;
                if (ready) begin
                    if (!ack_second_q) ack_second_q <= 1'b1;
                    else begin
                        ack_active_q <= 1'b0;
                        ack_vector <= data_in[7:0];
                        ack_response_valid <= !cancel_data && !ack_canceled_q;
                        if (cancel_data || ack_canceled_q) lock_chain_q <= 1'b0;
                    end
                end
            end
            // B-2 correction: link both INTA cycles to the first complete frame
            // word. The second half of an odd push is still the same word.
            if (data_complete && !address_q[0] && write_q) lock_chain_q <= 1'b0;
            if (cancel_data) begin
                ack_response_valid <= 1'b0;
                if (ack_active_q) ack_canceled_q <= 1'b1;
                else lock_chain_q <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            owner_valid_q <= 1'b0; owner_q <= 2'd0;
        end else if (bus_valid) begin
            owner_valid_q <= !ready;
            owner_q <= selected_owner;
        end
    end
    always_ff @(posedge clk) begin
        if (reset) begin
            data_active_q <= 1'b0; write_q <= 1'b0; second_q <= 1'b0; canceled_q <= 1'b0;
            address_q <= 24'h000000; write_data_q <= 16'h0000; low_byte_q <= 8'h00;
            data_response_valid <= 1'b0; data_read_data <= 16'h0000;
        end else begin
            if (data_response_valid && data_response_ready) data_response_valid <= 1'b0;
            if (cancel_data) begin
                data_response_valid <= 1'b0;
                if (data_active_q) canceled_q <= 1'b1;
            end
            if (data_request && data_request_ready) begin
                data_active_q <= 1'b1; write_q <= data_write; second_q <= 1'b0;
                canceled_q <= 1'b0; address_q <= data_address; write_data_q <= data_write_data;
            end
            if (data_complete) begin
                if (address_q[0]) begin
                    low_byte_q <= data_in[15:8];
                    address_q <= address_q + 24'd1;
                    second_q <= 1'b1;
                end else begin
                    data_active_q <= 1'b0;
                    data_read_data <= second_q ? {data_in[7:0], low_byte_q} : data_in;
                    data_response_valid <= !canceled_q && !cancel_data;
                    canceled_q <= 1'b0;
                end
            end
        end
    end
endmodule
