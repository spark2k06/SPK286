// 80286 eight-byte descriptor parser.
// The parser returns a typed candidate and never writes architectural state.
`timescale 1ns/1ps

module spk286_descriptor (
    input  logic [63:0] raw_descriptor,
    output logic [15:0] limit,
    output logic [23:0] base,
    output logic [7:0]  access_rights,
    output logic [3:0]  descriptor_class,
    output logic        descriptor_valid,
    output logic        reserved_form_valid,
    output logic        present,
    output logic        segment,
    output logic        executable,
    output logic        conforming,
    output logic        expand_down,
    output logic        readable,
    output logic        writable,
    output logic        accessed,
    output logic [1:0]  dpl,
    output logic [15:0] gate_target_selector,
    output logic [15:0] gate_offset,
    output logic [4:0]  gate_parameter_count
);
    // Keep the decoder-local encoding explicit.  Yosys supports the package
    // as a simulation/test namespace, but does not support importing package
    // parameters in synthesizable RTL.
    localparam logic [3:0] DESC_INVALID      = 4'd0;
    localparam logic [3:0] DESC_CODE         = 4'd1;
    localparam logic [3:0] DESC_DATA         = 4'd2;
    localparam logic [3:0] DESC_EXPAND_DOWN  = 4'd3;
    localparam logic [3:0] DESC_TSS_AVAIL    = 4'd4;
    localparam logic [3:0] DESC_TSS_BUSY     = 4'd5;
    localparam logic [3:0] DESC_CALL_GATE    = 4'd6;
    localparam logic [3:0] DESC_TASK_GATE    = 4'd7;
    localparam logic [3:0] DESC_INT_GATE     = 4'd8;
    localparam logic [3:0] DESC_TRAP_GATE    = 4'd9;
    localparam logic [3:0] DESC_LDT          = 4'd10;

    logic recognized_class;
    logic [3:0] system_type;

    always_comb begin
        limit = raw_descriptor[15:0];
        base = {raw_descriptor[39:32], raw_descriptor[31:16]};
        access_rights = raw_descriptor[47:40];
        present = raw_descriptor[47];
        dpl = raw_descriptor[46:45];
        segment = raw_descriptor[44];
        executable = raw_descriptor[43];
        conforming = segment && executable && raw_descriptor[42];
        expand_down = segment && !executable && raw_descriptor[42];
        readable = segment && executable && raw_descriptor[41];
        writable = segment && !executable && raw_descriptor[41];
        accessed = raw_descriptor[40];
        gate_target_selector = raw_descriptor[31:16];
        gate_offset = raw_descriptor[15:0];
        gate_parameter_count = raw_descriptor[36:32];
        system_type = raw_descriptor[43:40];

        descriptor_class = DESC_INVALID;
        recognized_class = 1'b0;

        if (segment) begin
            recognized_class = 1'b1;
            descriptor_class = executable ? DESC_CODE :
                               (expand_down ? DESC_EXPAND_DOWN : DESC_DATA);
        end else begin
            case (system_type)
                4'h1: begin descriptor_class = DESC_TSS_AVAIL;  recognized_class = 1'b1; end
                4'h2: begin descriptor_class = DESC_LDT;        recognized_class = 1'b1; end
                4'h3: begin descriptor_class = DESC_TSS_BUSY;   recognized_class = 1'b1; end
                4'h4: begin descriptor_class = DESC_CALL_GATE;  recognized_class = 1'b1; end
                4'h5: begin descriptor_class = DESC_TASK_GATE;  recognized_class = 1'b1; end
                4'h6: begin descriptor_class = DESC_INT_GATE;   recognized_class = 1'b1; end
                4'h7: begin descriptor_class = DESC_TRAP_GATE;  recognized_class = 1'b1; end
                default: begin descriptor_class = DESC_INVALID; recognized_class = 1'b0; end
            endcase
        end

        // Bytes 6-7 are reserved on the 80286. Gate byte 4 is reserved except
        // for the five-bit call-gate parameter count. Base byte 4 remains
        // meaningful for segment, TSS and LDT descriptors.
        reserved_form_valid = raw_descriptor[63:48] == 16'h0000;
        if (!segment && (system_type == 4'h4))
            reserved_form_valid = reserved_form_valid && (raw_descriptor[39:37] == 3'b000);
        else if (!segment && (system_type == 4'h5 || system_type == 4'h6 || system_type == 4'h7))
            reserved_form_valid = reserved_form_valid && (raw_descriptor[39:32] == 8'h00);

        descriptor_valid = recognized_class && reserved_form_valid;
    end
endmodule
