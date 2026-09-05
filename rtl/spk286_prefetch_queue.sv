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
    assign consume_data = storage_q[head_q];
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
