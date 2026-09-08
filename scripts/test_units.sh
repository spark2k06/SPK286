#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build}"
cd "$ROOT_DIR"
source scripts/rtl_sources.sh

simulator="${1:-both}"
unit="${2:-all}"
case "$simulator" in verilator|iverilog|both) ;; *) echo "Unknown simulator: $simulator" >&2; exit 2;; esac
tests=(spk286_registers spk286_segments spk286_fetch spk286_core spk286_prefetch_queue
       spk286_microsequencer spk286_microcode_rom spk286_decoder
       spk286_execution spk286_microcode_execution spk286_modrm spk286_effective_address
       spk286_operand_decode spk286_biu spk286_mov_operands spk286_operand_lifecycle
       spk286_operand_service spk286_alu spk286_alu_instructions spk286_alu_lifecycle spk286_stack_control spk286_stack_lifecycle
       spk286_event_instructions spk286_event_lifecycle spk286_event_streams
       spk286_biu_width_io spk286_operand_byte spk286_alu_byte spk286_byte_scalar spk286_prefix spk286_test_instructions spk286_scalar_direct spk286_shift spk286_shift_instructions spk286_data_instructions spk286_data_lifecycle spk286_unary_instructions spk286_unary_lifecycle spk286_adjust spk286_adjust_instructions spk286_adjust_lifecycle)
if [[ "$unit" != all ]]; then tests=("$unit"); fi

for name in "${tests[@]}"; do
    run_args=()
    if [[ "$name" == spk286_test_instructions ]]; then
        python3 -m tools.test_instruction_vectors --output "$BUILD_DIR/test-vectors.txt"
        run_args=("+instruction_vectors=$BUILD_DIR/test-vectors.txt")
    fi
    if [[ "$name" == spk286_scalar_direct ]]; then
        python3 -m tools.scalar_direct_vectors --output "$BUILD_DIR/scalar-direct-vectors.txt"
        run_args=("+instruction_vectors=$BUILD_DIR/scalar-direct-vectors.txt")
    fi
    if [[ "$name" == spk286_unary_instructions ]]; then
        python3 -m tools.unary_instruction_vectors --output "$BUILD_DIR/unary-instruction-vectors.txt"
        run_args=("+instruction_vectors=$BUILD_DIR/unary-instruction-vectors.txt")
    fi
    if [[ "$name" == spk286_data_instructions ]]; then
        python3 -m tools.data_instruction_vectors --output "$BUILD_DIR/data-instruction-vectors.txt"
        run_args=("+instruction_vectors=$BUILD_DIR/data-instruction-vectors.txt")
    fi
    if [[ "$name" == spk286_adjust_instructions ]]; then
        python3 -m tools.adjust_instruction_vectors --output "$BUILD_DIR/adjust-instruction-vectors.txt"
        run_args=("+instruction_vectors=$BUILD_DIR/adjust-instruction-vectors.txt")
    fi
    if [[ "$name" == spk286_adjust ]]; then
        python3 -m tools.adjust_reference --output "$BUILD_DIR/adjust-vectors.txt"
        run_args=("+adjust_vectors=$BUILD_DIR/adjust-vectors.txt")
    fi
    if [[ "$name" == spk286_shift ]]; then
        python3 -m tools.shift_reference --output "$BUILD_DIR/shift-vectors.txt"
        run_args=("+shift_vectors=$BUILD_DIR/shift-vectors.txt")
    fi
    if [[ "$name" == spk286_shift_instructions ]]; then
        python3 -m tools.shift_instruction_vectors --output "$BUILD_DIR/shift-instruction-vectors.txt"
        run_args=("+instruction_vectors=$BUILD_DIR/shift-instruction-vectors.txt")
    fi
    if [[ "$name" == spk286_alu_byte ]]; then
        python3 -m tools.byte_alu_vectors --output "$BUILD_DIR/byte-alu-vectors.txt"
        run_args=("+vectors=$BUILD_DIR/byte-alu-vectors.txt")
    fi
    if [[ "$name" == spk286_byte_scalar ]]; then
        python3 -m tools.byte_scalar_vectors --output "$BUILD_DIR/byte-scalar-vectors.txt"
        run_args=("+instruction_vectors=$BUILD_DIR/byte-scalar-vectors.txt")
    fi
    if [[ "$name" == spk286_alu ]]; then
        python3 -m tools.alu_reference --output "$BUILD_DIR/alu-vectors.txt"
        run_args=("+alu_vectors=$BUILD_DIR/alu-vectors.txt")
    fi
    if [[ "$name" == spk286_alu_instructions ]]; then
        python3 -m tools.alu_instruction_vectors --output "$BUILD_DIR/alu-instructions.txt"
        run_args=("+instruction_vectors=$BUILD_DIR/alu-instructions.txt")
    fi
    if [[ "$name" == spk286_stack_control ]]; then
        python3 -m tools.stack_control_vectors --output "$BUILD_DIR/stack-control.txt"
        run_args=("+instruction_vectors=$BUILD_DIR/stack-control.txt")
    fi
    if [[ "$name" == spk286_event_instructions ]]; then
        python3 -m tools.event_vectors --output "$BUILD_DIR/event-instructions.txt"
        run_args=("+event_vectors=$BUILD_DIR/event-instructions.txt")
    fi
    if [[ "$name" == spk286_event_streams ]]; then
        python3 -m tools.event_streams --output "$BUILD_DIR/event-streams.txt"
        run_args=("+stream_vectors=$BUILD_DIR/event-streams.txt")
    fi
    tb="${name}_tb"
    test -f "sim/unit/$tb.sv"
    if [[ "$simulator" != iverilog ]]; then
        obj="$BUILD_DIR/verilator/$tb"
        mkdir -p "$obj"
        verilator --binary --build-jobs "${SPK286_BUILD_JOBS:-1}" --timing --assert --language 1800-2012 \
            --top-module "$tb" --Mdir "$obj" -Irtl -Isim/unit \
            -o "$tb" "${rtl_sources[@]}" "sim/unit/$tb.sv" >"$obj/build.log" 2>&1 || {
                cat "$obj/build.log"; exit 1;
            }
        cat "$obj/build.log"
        "$obj/$tb" "${run_args[@]}"
    fi
    if [[ "$simulator" != verilator ]]; then
        obj="$BUILD_DIR/iverilog/$tb"
        mkdir -p "$obj"
        iverilog -g2012 -Wall -Irtl -Isim/unit -s "$tb" -o "$obj/$tb.vvp" "${rtl_sources[@]}" "sim/unit/$tb.sv"
        vvp "$obj/$tb.vvp" "${run_args[@]}"
    fi
done
