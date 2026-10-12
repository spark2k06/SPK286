// SPDX-License-Identifier: MIT
// Six-byte 80286 instruction prefetch storage.
// Fetch address generation and bus transactions remain outside this module.
`timescale 1ns/1ps

module spk286_prefetch_queue (
    input  logic       clk,
    input  logic       reset,
    input  logic       flush,
    input  logic       fill_valid,
    input  logic [15:0] fill_data,
    input  logic [1:0] fill_count,
    output logic       fill_ready,
    output logic       consume_valid,
    output logic [7:0] consume_data,
    input  logic       consume_ready,
    output logic [3:0] count
);
    localparam logic [4:0] CAPACITY = 5'd6;

    logic [7:0] storage_q [0:5];
    logic [2:0] head_q, tail_q;
    logic [3:0] count_q;
    logic do_fill, do_consume;
    logic [2:0] tail_after_first;
    logic [2:0] tail_after_second;

    function automatic [2:0] increment_pointer(input logic [2:0] pointer);
        increment_pointer = (pointer == 3'd5) ? 3'd0 : pointer + 3'd1;
    endfunction

    assign count = count_q;
    assign consume_valid = (count_q != 4'd0);
    // Decode the six legal head positions in parallel, keeping the selection
    // before the byte reduction instead of cascading byte-wide mux stages.
    // The pointer resets to zero and increment_pointer wraps at five.
    (* keep *) logic [5:0] consume_head_select;
    assign consume_head_select = 6'b000001 << head_q;
    assign consume_data = ({8{consume_head_select[0]}} & storage_q[0]) |
                          ({8{consume_head_select[1]}} & storage_q[1]) |
                          ({8{consume_head_select[2]}} & storage_q[2]) |
                          ({8{consume_head_select[3]}} & storage_q[3]) |
                          ({8{consume_head_select[4]}} & storage_q[4]) |
                          ({8{consume_head_select[5]}} & storage_q[5]);
    assign fill_ready = (fill_count != 2'd0) &&
                        ({1'b0, count_q} + {2'b00, fill_count} <= CAPACITY);
    assign do_consume = consume_valid && consume_ready;
    assign do_fill = fill_valid && fill_ready;
    assign tail_after_first = increment_pointer(tail_q);
    assign tail_after_second = increment_pointer(tail_after_first);

    always_ff @(posedge clk) begin
        if (reset || flush) begin
            head_q <= 3'd0;
            tail_q <= 3'd0;
            count_q <= 4'd0;
        end else begin
            if (do_fill) begin
                storage_q[tail_q] <= fill_data[7:0];
                if (fill_count == 2'd2)
                    storage_q[tail_after_first] <= fill_data[15:8];
                tail_q <= (fill_count == 2'd2) ? tail_after_second : tail_after_first;
            end
            if (do_consume)
                head_q <= increment_pointer(head_q);

            case ({do_fill, do_consume})
                2'b10: count_q <= count_q + {2'b00, fill_count};
                2'b01: count_q <= count_q - 4'd1;
                2'b11: count_q <= count_q + {2'b00, fill_count} - 4'd1;
                default: count_q <= count_q;
            endcase
        end
    end
endmodule
