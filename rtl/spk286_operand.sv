// One logical word-operand service, shared by reads/writes of REG and RM.
// Register access completes locally; memory completes through the BIU response.
`timescale 1ns/1ps
module spk286_operand (
    input  logic clk, reset, cancel,
    input  logic request_valid, request_write, select_rm,
    input  logic [15:0] write_data,
    output logic done,
    output logic [15:0] read_data,
    input  logic [127:0] register_state,
    input  logic [2:0] reg_index, rm_index,
    input  logic register_direct,
    input  logic [23:0] physical_address,
    input  logic [15:0] offset, segment_limit,
    output logic blocked,
    output logic gpr_write_en,
    output logic [2:0] gpr_write_index,
    output logic [15:0] gpr_write_data,
    output logic memory_request,
    input  logic memory_request_ready,
    output logic memory_write,
    output logic [23:0] memory_address,
    output logic [15:0] memory_write_data,
    input  logic memory_response_valid,
    output logic memory_response_ready,
    input  logic [15:0] memory_read_data
);
    logic pending_q, is_memory, allowed, within_limit;
    logic [2:0] register_index;
    assign register_index = select_rm ? rm_index : reg_index;
    assign is_memory = select_rm && !register_direct;
    assign within_limit = ({1'b0, offset} + 17'd1) <= {1'b0, segment_limit};
    assign allowed = request_valid && !reset && !cancel && !blocked;
    assign memory_request = allowed && is_memory && !pending_q && within_limit;
    assign memory_write = request_write;
    assign memory_address = physical_address;
    assign memory_write_data = write_data;
    assign memory_response_ready = allowed && pending_q;
    assign done = allowed && ((!is_memory && !pending_q) || (pending_q && memory_response_valid));
    assign read_data = is_memory ? memory_read_data : register_state[register_index * 16 +: 16];
    assign gpr_write_en = done && request_write && !is_memory;
    assign gpr_write_index = register_index;
    assign gpr_write_data = write_data;
    always_ff @(posedge clk) begin
        if (reset || cancel) begin
            pending_q <= 1'b0;
            blocked <= 1'b0;
        end else begin
            if (allowed && is_memory && !within_limit) blocked <= 1'b1;
            if (memory_request && memory_request_ready) pending_q <= 1'b1;
            if (memory_response_ready && memory_response_valid) pending_q <= 1'b0;
        end
    end
endmodule
