// Instruction byte/prefix lifetime. No architectural storage or bus sequencing.
`timescale 1ns/1ps
module spk286_instruction_context (
    input logic clk, reset, cancel, complete,
    input logic consume, prefix_accept,
    input logic [7:0] byte_data,
    output logic is_prefix, active, segment_override, lock_prefix,
    output logic extended_opcode,
    output logic [1:0] segment_index, repeat_kind,
    output logic [3:0] byte_count
);
    logic extended_q;
    assign extended_opcode = extended_q;
    assign is_prefix = byte_data == 8'h26 || byte_data == 8'h2E || byte_data == 8'h36 || byte_data == 8'h3E ||
                       byte_data == 8'hF0 || byte_data == 8'hF2 || byte_data == 8'hF3 ||
                       (byte_data == 8'h0F && !extended_q);
    always_ff @(posedge clk) begin
        if (reset || cancel || complete) begin
            active <= 0; segment_override <= 0; lock_prefix <= 0; extended_q <= 0;
            segment_index <= 0; repeat_kind <= 0; byte_count <= 0;
        end else if (consume) begin
            active <= 1;
            if (byte_count < 10) byte_count <= byte_count + 4'd1;
            if (prefix_accept) begin
                case (byte_data)
                    8'h26, 8'h2E, 8'h36, 8'h3E: begin
                        segment_override <= 1; segment_index <= byte_data[4:3];
                    end
                    8'hF0: lock_prefix <= 1;
                    8'hF2: repeat_kind <= 1;
                    8'hF3: repeat_kind <= 2;
                    8'h0F: extended_q <= 1'b1;
                    default: begin end
                endcase
            end
        end
    end
endmodule
