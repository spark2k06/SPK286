// Minimal instruction-form decoder. Destination metadata is independent of ROM.
`timescale 1ns/1ps

module spk286_decoder (
    input  logic [7:0] opcode,
    input logic        extended_opcode,
    output logic supported,
    output logic invalid_opcode,
    output logic [2:0] destination, source_index,
    output logic [spk286_microcode_pkg::MC_ADDR_WIDTH-1:0] entry
);
    logic scalar_io, string_io;
    assign scalar_io = opcode[7:4] == 4'hE && opcode[2];
    assign string_io = opcode[7:2] == 6'b011011;
    logic string_instruction;
    assign string_instruction = opcode[7:2] == 6'b101001 || opcode[7:1] == 7'b1010101 || opcode[7:2] == 6'b101011;
    logic binary_byte, binary_word, stack_control, event_instruction, test_instruction, adjust_instruction, segment_instruction, esc_instruction;
    assign segment_instruction = opcode == 8'h06 || opcode == 8'h07 || opcode == 8'h0E || opcode == 8'h16 || opcode == 8'h17 || opcode == 8'h1E || opcode == 8'h1F || opcode == 8'h8C || opcode == 8'h8E;
    assign adjust_instruction = opcode == 8'h27 || opcode == 8'h2F || opcode == 8'h37 || opcode == 8'h3F || opcode == 8'hD4 || opcode == 8'hD5;
    // Phase 8 no-coprocessor profile: ESC syntax is consumed by a terminal
    // passthrough microprogram; this core does not emulate an 80287.
    assign esc_instruction = opcode[7:3] == 5'b11011;
    assign test_instruction = opcode == 8'h84 || opcode == 8'h85 || opcode == 8'hA8 || opcode == 8'hA9 || opcode == 8'hF6 || opcode == 8'hF7;
    assign event_instruction = opcode == 8'h9C || opcode == 8'h9D ||
                               opcode[7:2] == 6'b110011 || opcode == 8'hF4 || opcode == 8'hFA || opcode == 8'hFB;
    assign stack_control = opcode[7:4] == 4'h5 || opcode[7:4] == 4'h7 ||
                           opcode == 8'h68 || opcode == 8'h6A || opcode == 8'h8F || opcode == 8'hFF ||
                           opcode == 8'hC2 || opcode == 8'hC3 || opcode[7:2] == 6'b111000 ||
                           opcode == 8'hE8 || opcode == 8'hE9 || opcode == 8'hEB;
    assign binary_byte = opcode[7:6] == 2'b00 && (opcode[2:0] == 3'd0 || opcode[2:0] == 3'd2 || opcode[2:0] == 3'd4);
    assign binary_word = opcode[7:6] == 2'b00 &&
                         (opcode[2:0] == 3'd1 || opcode[2:0] == 3'd3 || opcode[2:0] == 3'd5);
    // The 80286 has no 386 operand/address-size prefixes: 64h..67h are
    // invalid first bytes.  0F05 is the undocumented 286 LOADALL opcode;
    // it is implemented by the dedicated fixed-image LOADALL service.
    // The remaining 0Fxx values outside the 286 system set are invalid.
    assign invalid_opcode = extended_opcode ?
                            !(opcode == 8'h00 || opcode == 8'h01 || opcode == 8'h02 ||
                              opcode == 8'h03 || opcode == 8'h05 || opcode == 8'h06) :
                            (opcode >= 8'h64 && opcode <= 8'h67);
    assign supported = extended_opcode ? (opcode == 8'h00 || opcode == 8'h01 || opcode == 8'h02 || opcode == 8'h03 || opcode == 8'h05 || opcode == 8'h06) : opcode == 8'h63 || opcode == 8'h69 || opcode == 8'h6B || scalar_io || string_io || string_instruction || opcode == 8'hC4 || opcode == 8'hC5 || opcode == 8'h9A || opcode == 8'hEA || opcode == 8'hCA || opcode == 8'hCB || opcode == 8'h60 || opcode == 8'h61 || opcode == 8'h62 || opcode == 8'hC8 || opcode == 8'hC9 || segment_instruction || adjust_instruction || esc_instruction || opcode == 8'hFE || opcode == 8'h86 || opcode == 8'h87 || opcode == 8'h8D || opcode[7:3] == 5'b10010 || opcode[7:2] == 6'b101000 || opcode == 8'hD7 || opcode == 8'hC0 || opcode == 8'hC1 || opcode[7:2] == 6'b110100 || opcode[7:4] == 4'h4 || opcode == 8'h98 || opcode == 8'h99 || opcode == 8'h9E || opcode == 8'h9F || opcode == 8'hF5 || opcode == 8'hF8 || opcode == 8'hF9 || opcode == 8'hFC || opcode == 8'hFD || test_instruction || binary_byte || opcode[7:3] == 5'b10110 || opcode == 8'h88 || opcode == 8'h8A || opcode == 8'h80 || opcode == 8'hC6 || opcode == 8'hC7 || event_instruction || stack_control || opcode[7:3] == 5'b10111 || opcode == 8'h89 || opcode == 8'h8B ||
                       binary_word || opcode == 8'h81 || opcode == 8'h83 || opcode == 8'hD6;
    assign source_index = opcode == 8'h63 || opcode[7:3] == 5'b10010 || opcode == 8'h98 || opcode == 8'h99 ? 3'd0 : destination;
    assign destination = opcode == 8'h63 ? 3'd0 : scalar_io ? 3'd0 : adjust_instruction ? 3'd0 : esc_instruction ? 3'd0 : opcode[7:2] == 6'b101000 || opcode == 8'hD6 || opcode == 8'hD7 ? 3'd0 : opcode == 8'h9F ? 3'd4 : opcode == 8'h98 ? 3'd0 : opcode == 8'h99 ? 3'd2 : binary_word || binary_byte || test_instruction ? 3'd0 : opcode[2:0];
    // Instruction direction is expressed by the generated entry, not the sequencer.
    assign entry = extended_opcode && opcode == 8'h05 ? spk286_microcode_pkg::MC_ENTRY_LOADALL :
                   extended_opcode && opcode == 8'h00 ? spk286_microcode_pkg::MC_ENTRY_SYSTEM_GROUP_0F00 :
                   extended_opcode && opcode == 8'h01 ? spk286_microcode_pkg::MC_ENTRY_SYSTEM_GROUP_0F01 :
                   extended_opcode && opcode == 8'h02 ? spk286_microcode_pkg::MC_ENTRY_SYSTEM_LOAD_ACCESS :
                   extended_opcode && opcode == 8'h03 ? spk286_microcode_pkg::MC_ENTRY_SYSTEM_LOAD_LIMIT :
                   opcode == 8'h63 ? spk286_microcode_pkg::MC_ENTRY_SYSTEM_ARPL :
                   extended_opcode && opcode == 8'h06 ? spk286_microcode_pkg::MC_ENTRY_SYSTEM_CLTS :
                   opcode == 8'h69 ? spk286_microcode_pkg::MC_ENTRY_IMUL_R16_RM16_IMM16 :
                   opcode == 8'h6B ? spk286_microcode_pkg::MC_ENTRY_IMUL_R16_RM16_IMM8S : scalar_io ? (opcode[1] ? (opcode[0] ? spk286_microcode_pkg::MC_ENTRY_OUT_PORT_AX : spk286_microcode_pkg::MC_ENTRY_OUT_PORT_AL) :
                                            (opcode[0] ? spk286_microcode_pkg::MC_ENTRY_IN_AX_PORT : spk286_microcode_pkg::MC_ENTRY_IN_AL_PORT)) :
                   string_io ? (opcode[1] ? (opcode[0] ? spk286_microcode_pkg::MC_ENTRY_STRING_OUTPUT_WORD : spk286_microcode_pkg::MC_ENTRY_STRING_OUTPUT_BYTE) :
                                            (opcode[0] ? spk286_microcode_pkg::MC_ENTRY_STRING_INPUT_WORD : spk286_microcode_pkg::MC_ENTRY_STRING_INPUT_BYTE)) :
                   opcode[7:1] == 7'b1010010 ? spk286_microcode_pkg::MC_ENTRY_STRING_MOVE :
                   opcode[7:1] == 7'b1010011 ? spk286_microcode_pkg::MC_ENTRY_STRING_COMPARE :
                   opcode[7:1] == 7'b1010101 ? spk286_microcode_pkg::MC_ENTRY_STRING_STORE :
                   opcode[7:1] == 7'b1010110 ? spk286_microcode_pkg::MC_ENTRY_STRING_LOAD :
                   opcode[7:1] == 7'b1010111 ? spk286_microcode_pkg::MC_ENTRY_STRING_SCAN :
                   opcode == 8'hC4 || opcode == 8'hC5 ? spk286_microcode_pkg::MC_ENTRY_LOAD_POINTER :
                   opcode == 8'h9A ? spk286_microcode_pkg::MC_ENTRY_CALL_FAR_IMM :
                   opcode == 8'hEA ? spk286_microcode_pkg::MC_ENTRY_JMP_FAR_IMM :
                   opcode == 8'hCA ? spk286_microcode_pkg::MC_ENTRY_RET_FAR_IMM :
                   opcode == 8'hCB ? spk286_microcode_pkg::MC_ENTRY_RET_FAR :
                   opcode == 8'h60 ? spk286_microcode_pkg::MC_ENTRY_PUSH_ALL :
                   opcode == 8'h61 ? spk286_microcode_pkg::MC_ENTRY_POP_ALL :
                   opcode == 8'h62 ? spk286_microcode_pkg::MC_ENTRY_CHECK_BOUNDS :
                   opcode == 8'hC8 ? spk286_microcode_pkg::MC_ENTRY_ENTER_FRAME :
                   opcode == 8'hC9 ? spk286_microcode_pkg::MC_ENTRY_LEAVE_FRAME :
                   segment_instruction ? (opcode == 8'h8C ? spk286_microcode_pkg::MC_ENTRY_MOV_RM16_SEG : opcode == 8'h8E ? spk286_microcode_pkg::MC_ENTRY_MOV_SEG_RM16 : opcode[0] ? spk286_microcode_pkg::MC_ENTRY_POP_SEG : spk286_microcode_pkg::MC_ENTRY_PUSH_SEG) : adjust_instruction ? ((opcode == 8'hD4 || opcode == 8'hD5) ? spk286_microcode_pkg::MC_ENTRY_ADJUST_RADIX : spk286_microcode_pkg::MC_ENTRY_ADJUST_DIRECT) :
                   opcode == 8'hFE ? spk286_microcode_pkg::MC_ENTRY_INC_DEC_RM8 :
                   opcode == 8'h86 ? spk286_microcode_pkg::MC_ENTRY_EXCHANGE_RM8_R8 :
                   opcode == 8'h87 ? spk286_microcode_pkg::MC_ENTRY_EXCHANGE_RM16_R16 :
                   opcode == 8'h8D ? spk286_microcode_pkg::MC_ENTRY_LEA_R16_M :
                   opcode[7:3] == 5'b10010 ? spk286_microcode_pkg::MC_ENTRY_EXCHANGE_SOURCE_TARGET16 :
                   opcode == 8'hA0 ? spk286_microcode_pkg::MC_ENTRY_LOAD_DIRECT8 :
                   opcode == 8'hA1 ? spk286_microcode_pkg::MC_ENTRY_LOAD_DIRECT16 :
                   opcode == 8'hA2 ? spk286_microcode_pkg::MC_ENTRY_STORE_DIRECT8 :
                   opcode == 8'hA3 ? spk286_microcode_pkg::MC_ENTRY_STORE_DIRECT16 :
                   opcode == 8'hD6 ? spk286_microcode_pkg::MC_ENTRY_LOAD_CARRY_BYTE :
                   opcode == 8'hD7 ? spk286_microcode_pkg::MC_ENTRY_LOAD_BASE_INDEX8 :
                   esc_instruction ? spk286_microcode_pkg::MC_ENTRY_ESC_NO_COPROCESSOR :
                   opcode == 8'hC0 ? spk286_microcode_pkg::MC_ENTRY_SHIFT_RM8_IMM8 :
                   opcode == 8'hC1 ? spk286_microcode_pkg::MC_ENTRY_SHIFT_RM16_IMM8 :
                   opcode == 8'hD0 ? spk286_microcode_pkg::MC_ENTRY_SHIFT_RM8_ONE :
                   opcode == 8'hD1 ? spk286_microcode_pkg::MC_ENTRY_SHIFT_RM16_ONE :
                   opcode == 8'hD2 ? spk286_microcode_pkg::MC_ENTRY_SHIFT_RM8_CL :
                   opcode == 8'hD3 ? spk286_microcode_pkg::MC_ENTRY_SHIFT_RM16_CL :
                   opcode[7:4] == 4'h4 ? spk286_microcode_pkg::MC_ENTRY_INC_DEC_R16 :
                   opcode == 8'h98 ? spk286_microcode_pkg::MC_ENTRY_EXTEND_BYTE :
                   opcode == 8'h99 ? spk286_microcode_pkg::MC_ENTRY_EXTEND_WORD :
                   opcode == 8'h9F ? spk286_microcode_pkg::MC_ENTRY_LOAD_FLAGS_BYTE :
                   opcode == 8'h9E || opcode == 8'hF5 || opcode == 8'hF8 || opcode == 8'hF9 || opcode == 8'hFC || opcode == 8'hFD ? spk286_microcode_pkg::MC_ENTRY_CONTROL_FLAGS :
                   opcode == 8'h84 ? spk286_microcode_pkg::MC_ENTRY_ALU_RM8_R8 :
                   opcode == 8'h85 ? spk286_microcode_pkg::MC_ENTRY_ALU_RM16_R16 :
                   opcode == 8'hA8 ? spk286_microcode_pkg::MC_ENTRY_ALU_AL_IMM8 :
                   opcode == 8'hA9 ? spk286_microcode_pkg::MC_ENTRY_ALU_AX_IMM16 :
                   opcode == 8'hF6 ? spk286_microcode_pkg::MC_ENTRY_GROUP3_DISPATCH :
                   opcode == 8'hF7 ? spk286_microcode_pkg::MC_ENTRY_GROUP3_DISPATCH :
                   opcode[7:3] == 5'b10110 ? spk286_microcode_pkg::MC_ENTRY_MOV_R8_IMM8 :
                   opcode == 8'h88 ? spk286_microcode_pkg::MC_ENTRY_MOV_RM8_R8 :
                   opcode == 8'h8A ? spk286_microcode_pkg::MC_ENTRY_MOV_R8_RM8 :
                   opcode == 8'hC6 ? spk286_microcode_pkg::MC_ENTRY_MOV_RM8_IMM8 :
                   opcode == 8'hC7 ? spk286_microcode_pkg::MC_ENTRY_MOV_RM16_IMM16 :
                   opcode == 8'h80 ? spk286_microcode_pkg::MC_ENTRY_ALU_RM8_IMM8 :
                   binary_byte ? (opcode[2:0] == 3'd0 ? spk286_microcode_pkg::MC_ENTRY_ALU_RM8_R8 :
                                  opcode[2:0] == 3'd2 ? spk286_microcode_pkg::MC_ENTRY_ALU_R8_RM8 :
                                                       spk286_microcode_pkg::MC_ENTRY_ALU_AL_IMM8) : opcode == 8'h9C ? spk286_microcode_pkg::MC_ENTRY_PUSH_FLAGS :
                   opcode == 8'h9D ? spk286_microcode_pkg::MC_ENTRY_POP_FLAGS :
                   opcode == 8'hFA || opcode == 8'hFB ? spk286_microcode_pkg::MC_ENTRY_CONTROL_IF :
                   opcode == 8'hF4 ? spk286_microcode_pkg::MC_ENTRY_HALT_CPU :
                   opcode == 8'hCC || opcode == 8'hCE ? spk286_microcode_pkg::MC_ENTRY_SOFTWARE_EVENT :
                   opcode == 8'hCD ? spk286_microcode_pkg::MC_ENTRY_SOFTWARE_EVENT_IMM8 :
                   opcode == 8'hCF ? spk286_microcode_pkg::MC_ENTRY_INTERRUPT_RETURN :
                   opcode[7:3] == 5'b01010 ? spk286_microcode_pkg::MC_ENTRY_PUSH_R16 :
                   opcode[7:3] == 5'b01011 ? spk286_microcode_pkg::MC_ENTRY_POP_R16 :
                   opcode == 8'h68 ? spk286_microcode_pkg::MC_ENTRY_PUSH_IMM16 :
                   opcode == 8'h6A ? spk286_microcode_pkg::MC_ENTRY_PUSH_IMM8S :
                   opcode == 8'h8F ? spk286_microcode_pkg::MC_ENTRY_POP_RM16 :
                   opcode == 8'hFF ? spk286_microcode_pkg::MC_ENTRY_GROUP5_DISPATCH :
                   opcode == 8'hE8 ? spk286_microcode_pkg::MC_ENTRY_CALL_REL16 :
                   opcode == 8'hE9 ? spk286_microcode_pkg::MC_ENTRY_JMP_REL16 :
                   opcode == 8'hEB || opcode[7:4] == 4'h7 ? spk286_microcode_pkg::MC_ENTRY_BRANCH_REL8 :
                   opcode[7:2] == 6'b111000 ? spk286_microcode_pkg::MC_ENTRY_LOOP_REL8 :
                   opcode == 8'hC2 ? spk286_microcode_pkg::MC_ENTRY_RET_IMM16 :
                   opcode == 8'hC3 ? spk286_microcode_pkg::MC_ENTRY_RET_NEAR :
                   opcode == 8'h81 ? spk286_microcode_pkg::MC_ENTRY_ALU_RM16_IMM16 :
                   opcode == 8'h83 ? spk286_microcode_pkg::MC_ENTRY_ALU_RM16_IMM8S :
                   binary_word ? (opcode[2:0] == 3'd1 ? spk286_microcode_pkg::MC_ENTRY_ALU_RM16_R16 :
                                  opcode[2:0] == 3'd3 ? spk286_microcode_pkg::MC_ENTRY_ALU_R16_RM16 :
                                                       spk286_microcode_pkg::MC_ENTRY_ALU_AX_IMM16) :
                   opcode == 8'h89 ? spk286_microcode_pkg::MC_ENTRY_MOV_RM16_R16 :
                   (opcode == 8'h8B ? spk286_microcode_pkg::MC_ENTRY_MOV_R16_RM16 :
                    spk286_microcode_pkg::MC_ENTRY_MOV_R16_IMM16);
endmodule
