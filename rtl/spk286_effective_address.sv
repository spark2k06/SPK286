// The single 16-bit EA table. Displacement arrives as a sign-extended word.
// Offset arithmetic wraps at 16 bits; segment translation is a separate stage.
`timescale 1ns/1ps

module spk286_effective_address (
    input  logic [1:0] mode,
    input  logic [2:0] rm_index,
    input  logic [15:0] displacement,
    input  logic [15:0] bx, bp, si, di,
    output logic [15:0] offset,
    output logic [1:0] segment_index,
    output logic memory_operand
);
    logic [15:0] base_offset;
    logic uses_bp;
    always_comb begin
        base_offset = 16'h0000;
        uses_bp = 1'b0;
        case (rm_index)
            3'd0: base_offset = bx + si;
            3'd1: base_offset = bx + di;
            3'd2: begin base_offset = bp + si; uses_bp = 1'b1; end
            3'd3: begin base_offset = bp + di; uses_bp = 1'b1; end
            3'd4: base_offset = si;
            3'd5: base_offset = di;
            3'd6: begin
                base_offset = mode == 2'b00 ? 16'h0000 : bp;
                uses_bp = mode != 2'b00;
            end
            3'd7: base_offset = bx;
            default: base_offset = 16'h0000;
        endcase
    end
    assign memory_operand = mode != 2'b11;
    assign offset = memory_operand ? base_offset + displacement : 16'h0000;
    assign segment_index = uses_bp ? 2'd2 : 2'd3; // SS / DS, including direct DS:[disp16].
endmodule
