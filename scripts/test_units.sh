#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -euo pipefail
ulimit -c 0
if (( $# > 2 )); then
    echo "Expected simulator and one unit name; invoke separate commands for multiple units" >&2
    exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${SPK286_BUILD_DIR:-$ROOT_DIR/build}"
cd "$ROOT_DIR"
source scripts/rtl_sources.sh

simulator="${1:-both}"
unit="${2:-all}"
case "$simulator" in verilator|iverilog|both) ;; *) echo "Unknown simulator: $simulator" >&2; exit 2;; esac
tests=(spk286_registers spk286_segments spk286_loadall_service spk286_loadall_protected spk286_protected_foundation spk286_protected_system spk286_protected_event_outer spk286_protected_expand_down spk286_call_stack_precheck spk286_arpl spk286_clts spk286_clts_privilege spk286_protected_retf spk286_tss_service spk286_tss_descriptor_service spk286_task_segment_service spk286_task_switch_service spk286_protected_task spk286_protected_task_fault spk286_protected_task_state_fault spk286_protected_task_gate spk286_protected_task_gate_far spk286_protected_task_gate_fault spk286_protected_task_gate_error spk286_protected_task_privilege spk286_protected_task_privilege_outer spk286_protected_task_gate_privilege spk286_protected_task_gate_privilege_outer spk286_protected_task_gate_event_privilege_outer spk286_protected_task_iret spk286_protected_task_ldt spk286_fetch spk286_core spk286_prefetch_queue
       spk286_protected_ltr
       spk286_microsequencer spk286_microcode_rom spk286_decoder spk286_timing_trace spk286_timing_capture spk286_timing_policy spk286_timing_policy_contract spk286_timing_policy_equivalence spk286_timing_calibration spk286_timing_calibration_extra
       spk286_prefetch_fidelity
       spk286_execution spk286_microcode_execution spk286_modrm spk286_effective_address
       spk286_operand_decode spk286_biu spk286_mov_operands spk286_operand_lifecycle
       spk286_operand_service spk286_alu spk286_alu_instructions spk286_alu_lifecycle spk286_stack_control spk286_stack_lifecycle
       spk286_event_instructions spk286_event_lifecycle spk286_event_streams
       spk286_biu_width_io spk286_operand_byte spk286_alu_byte spk286_byte_scalar spk286_prefix spk286_test_instructions spk286_scalar_direct spk286_shift spk286_shift_instructions spk286_data_instructions spk286_data_lifecycle spk286_unary_instructions spk286_unary_lifecycle spk286_adjust spk286_adjust_instructions spk286_adjust_lifecycle spk286_segment_instructions spk286_segment_lifecycle spk286_stack_range spk286_stack_frame_instructions spk286_stack_frame_lifecycle spk286_far_instructions spk286_far_lifecycle spk286_string_instructions spk286_string_lifecycle spk286_string_boundaries spk286_scalar_io spk286_string_io spk286_string_io_lifecycle spk286_muldiv spk286_muldiv_instructions spk286_muldiv_lifecycle spk286_string_zero_events spk286_string_io_zero_events spk286_biu_hold_lock spk286_xchg_hold_lock spk286_esc_instructions)
tests+=(spk286_loadall_integration)
tests+=(spk286_npx_traps)
tests+=(spk286_esc_boundaries)
tests+=(spk286_double_fault_cpu)
tests+=(spk286_double_fault_events)
tests+=(spk286_protected_entry)
tests+=(spk286_protected_direct_call)
tests+=(spk286_conforming_data_load)
tests+=(spk286_call_gate_accessed)
tests+=(spk286_jmp_call_gate)
tests+=(spk286_hlt_privilege)
tests+=(spk286_event_nt)
tests+=(spk286_return_flags)
tests+=(spk286_gate_target_rpl)
tests+=(spk286_fault_metadata)
tests+=(spk286_fault_precedence)
tests+=(spk286_odd_protected_stack)
tests+=(spk286_system_access)
tests+=(spk286_iopl_access)
tests+=(spk286_protected_return_restart)
tests+=(spk286_protected_pop_segment_restart)
tests+=(spk286_descriptor_inspection)
tests+=(spk286_system_table_range)
tests+=(spk286_outer_return_sp)
tests+=(spk286_register_execution)
tests+=(spk286_task_late_publication)
tests+=(spk286_null_ldtr)
tests+=(spk286_immediate_execution spk286_immediate_throughput)
tests+=(spk286_encoding_preview)
tests+=(spk286_length_boundary)
if [[ "$unit" != all ]]; then tests=("$unit"); fi

for name in "${tests[@]}"; do
    run_args=()
    skip_verilator=0
    if [[ "$name" == spk286_task_late_publication ]]; then
        python3 -m tools.task_late_vectors --output "$BUILD_DIR/task-late-vectors"
        run_args=("+task_vectors=$BUILD_DIR/task-late-vectors/vectors.txt")
    fi
    if [[ "$name" == spk286_null_ldtr ]]; then
        python3 -m tools.null_ldtr_vectors --output "$BUILD_DIR/null-ldtr-vectors"
        run_args=("+ldtr_vectors=$BUILD_DIR/null-ldtr-vectors/vectors.txt")
    fi
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
    if [[ "$name" == spk286_string_io ]]; then
        python3 -m tools.string_io_vectors --output "$BUILD_DIR/string-io-vectors.txt"
        run_args=("+instruction_vectors=$BUILD_DIR/string-io-vectors.txt")
    fi
    if [[ "$name" == spk286_string_instructions ]]; then
        python3 -m tools.string_instruction_vectors --output "$BUILD_DIR/string-instruction-vectors.txt"
        run_args=("+instruction_vectors=$BUILD_DIR/string-instruction-vectors.txt")
    fi
    if [[ "$name" == spk286_far_instructions ]]; then
        python3 -m tools.far_instruction_vectors --output "$BUILD_DIR/far-instruction-vectors.txt"
        run_args=("+instruction_vectors=$BUILD_DIR/far-instruction-vectors.txt")
    fi
    if [[ "$name" == spk286_stack_frame_instructions ]]; then
        python3 -m tools.stack_frame_vectors --output "$BUILD_DIR/stack-frame-vectors.txt"
        run_args=("+instruction_vectors=$BUILD_DIR/stack-frame-vectors.txt")
    fi
    if [[ "$name" == spk286_segment_instructions ]]; then
        python3 -m tools.segment_instruction_vectors --output "$BUILD_DIR/segment-instruction-vectors.txt"
        run_args=("+instruction_vectors=$BUILD_DIR/segment-instruction-vectors.txt")
    fi
    if [[ "$name" == spk286_adjust_instructions ]]; then
        python3 -m tools.adjust_instruction_vectors --output "$BUILD_DIR/adjust-instruction-vectors.txt"
        run_args=("+instruction_vectors=$BUILD_DIR/adjust-instruction-vectors.txt")
    fi
    if [[ "$name" == spk286_muldiv_instructions ]]; then
        python3 -m tools.muldiv_instruction_vectors --output "$BUILD_DIR/muldiv-instruction-vectors.txt"
        run_args=("+instruction_vectors=$BUILD_DIR/muldiv-instruction-vectors.txt")
    fi
    if [[ "$name" == spk286_muldiv ]]; then
        python3 -m tools.muldiv_reference --output "$BUILD_DIR/muldiv-vectors.txt"
        run_args=("+muldiv_vectors=$BUILD_DIR/muldiv-vectors.txt")
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
    if [[ "$name" == spk286_timing_capture ]]; then
        mkdir -p "$BUILD_DIR/timing"
        run_args=("+trace_out=$BUILD_DIR/timing/spk286_timing_capture.csv")
    fi
    if [[ "$name" == spk286_prefetch_fidelity ]]; then
        mkdir -p "$BUILD_DIR/timing"
        run_args=("+prefetch_trace_out=$BUILD_DIR/timing/spk286_prefetch_fidelity.csv")
    fi
    if [[ "$name" == spk286_timing_calibration ]]; then
        mkdir -p "$BUILD_DIR/timing"
        run_args=("+calibration_out=$BUILD_DIR/timing/spk286_timing_calibration.csv")
    fi
    if [[ "$name" == spk286_timing_calibration_extra ]]; then
        mkdir -p "$BUILD_DIR/timing"
        run_args=("+calibration_extra_out=$BUILD_DIR/timing/spk286_timing_calibration_extra.csv")
    fi
    tb="${name}_tb"
    test -f "sim/unit/$tb.sv"
    if [[ "$name" == spk286_protected_expand_down && "${SPK286_EXPAND_DOWN_TERMINATION_SMOKE:-0}" == 1 ]]; then
        run_args=("+termination_smoke")
    fi
    if [[ "$name" == spk286_protected_expand_down && "$simulator" != iverilog && "${SPK286_EXPAND_DOWN_TERMINATION_SMOKE:-0}" != 1 ]]; then
        echo "VERILATOR SKIP: $name full matrix runs in Icarus; protected-system and event banks provide Verilator cross-checks"
        skip_verilator=1
    fi
    if [[ "$simulator" != iverilog && "$skip_verilator" == 0 ]]; then
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
