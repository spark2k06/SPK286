// Shared normalized 80286 bus. Fetch supplies code-cycle metadata; the BIU
// sequences logical data words and arbitrates every physical READY handshake.
// This is functional transaction timing, not native Ts/Tc/Ti timing.
`timescale 1ns/1ps
module spk286_biu (
    input  logic clk, reset, cancel_data,
    input  logic ready,
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
    logic owner_valid_q, owner_data_q, select_data, data_complete;
    assign data_request_ready = !reset && !cancel_data && !data_active_q && !data_response_valid;
    // Data has priority at a free boundary. Once a cycle is visible and waiting,
    // its owner cannot change even if a higher-priority request appears.
    assign select_data = owner_valid_q ? owner_data_q : data_active_q;
    assign bus_valid = !reset && (select_data ? data_active_q : code_valid);
    assign address = !bus_valid ? 24'h000000 : (select_data ? address_q : code_address);
    assign bus_write = bus_valid && select_data && write_q;
    assign bus_bhe_n = !bus_valid ? 1'b1 : (select_data ? second_q : code_bhe_n);
    assign data_out = !bus_write ? 16'h0000 :
                      (address_q[0] ? {write_data_q[7:0], 8'h00} :
                       (second_q ? {8'h00, write_data_q[15:8]} : write_data_q));
    assign data_oe = bus_write;
    assign bus_status = !bus_valid ? 4'hF : (!select_data ? 4'hD : (write_q ? 4'h6 : 4'h5));
    assign code_ready = bus_valid && !select_data && ready;
    assign data_complete = bus_valid && select_data && ready;

    always_ff @(posedge clk) begin
        if (reset) begin
            owner_valid_q <= 1'b0; owner_data_q <= 1'b0;
        end else if (bus_valid) begin
            owner_valid_q <= !ready;
            owner_data_q <= select_data;
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
