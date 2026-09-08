SHELL := /usr/bin/env bash

.PHONY: help env bootstrap lint verilator test unit regression iverilog waveform data-smoke state-smoke synth-check quartus-info verify-failure singlestep-fetch singlestep-smoke singlestep-mov singlestep-audit clean microcode microcode-check microcode-test microcode-audit mcl86-fetch mcl86-check mcl86-test phase2.80-check

help:
	@echo "SPK286 development targets:"
	@echo "  make microcode       regenerate committed ROM, constants and source maps"
	@echo "  make microcode-check fail if any generated microcode artifact is stale"
	@echo "  make microcode-test  run independent Python compiler/ROM tests"
	@echo "  make microcode-audit verify the active phase ROM/entry contract and round-trip"
	@echo "  make mcl86-fetch     fetch hash-pinned public references into .cache"
	@echo "  make mcl86-check     reconstruct and compare both public MCL86 ROMs"
	@echo "  make mcl86-test      run isolated offline MCL86 toolchain tests"
	@echo "  make phase2.80-check run all mandatory phase gates (requires references/corpus)"
	@echo "  make env          check the WSL toolchain"
	@echo "  make bootstrap    install missing WSL packages when permitted"
	@echo "  make lint         run Verilator lint"
	@echo "  make verilator    build the Verilator smoke executable"
	@echo "  make iverilog     run the Icarus smoke test"
	@echo "  make test         run fast dual-simulator and Python tests"
	@echo "  make unit         run directed RTL tests in both simulators"
	@echo "  make regression   run test plus Yosys synthesis sanity check"
	@echo "  make waveform     run Verilator smoke with a VCD trace"
	@echo "  make data-smoke   validate the JSON/MOO data loader"
	@echo "  make state-smoke  initialize RTL and verify first fetch from JSON state"
	@echo "  make singlestep-fetch acquire the pinned external 80286 MOO working set"
	@echo "  make singlestep-smoke run ten supported cases per opcode, B8..BF and 89/8B"
	@echo "  make singlestep-operands run the complete supported 89/8B corpus"
	@echo "  make phase3-check run mandatory Phase 3 gates with the pinned external corpus"
	@echo "  make phase5-check run all inherited and stack/control-flow release gates"
	@echo "  make phase6-check run the complete event release gate in a fresh build directory"
	@echo "  make phase6-exec-check run all executable checks with explicit provisional evidence status"
	@echo "  make singlestep-phase6 run all 474049 admitted Phase 6 hardware cases"
	@echo "  make event-audit reject isolated event/arbitration/INTA RTL mutations"
	@echo "  make stack-control-audit reject twelve isolated stack/control RTL mutants"
	@echo "  make singlestep-stack-control run all 47 Phase 5 hardware forms"
	@echo "  make phase4-check run all inherited and word ALU release gates"
	@echo "  make singlestep-alu run all admitted Phase 4 hardware forms"
	@echo "  make alu-audit reject eight isolated ALU/datapath mutants"
	@echo "  make phase3-boundary-audit prove operand/BIU boundary assertions reject RTL faults"
	@echo "  make singlestep-mov   run all non-revoked B8..BF cases"
	@echo "  make singlestep-audit cross-check upstream parsing and inject comparison faults"
	@echo "  make verify-failure prove negative simulator status propagation"
	@echo "  make synth-check  run the portable RTL through Yosys"
	@echo "  make quartus-info inspect the local Quartus Docker image"
	@echo "  make clean        remove generated build output"

env:
	./scripts/env_check.sh

microcode:
	python3 -m tools.microcode.compile_microcode

microcode-check:
	python3 -m tools.microcode.compile_microcode --check

microcode-test: microcode-check
	python3 -m unittest discover -s tests -p 'test_microcode*.py' -v

microcode-audit: microcode-check
	python3 -m tools.microcode.audit_microcode --output "$${SPK286_BUILD_DIR:-build}/microcode-audit"

mcl86-fetch:
	python3 -m research.mcl86.fetch_references

mcl86-check:
	python3 -m research.mcl86.mcl86_uccheck --output "$${SPK286_BUILD_DIR:-build}/mcl86"

mcl86-test:
	python3 -m unittest discover -s research/mcl86/tests -v

phase2.80-check:
	bash scripts/validate_phase2_80.sh

bootstrap:
	./scripts/bootstrap.sh

lint:
	./scripts/lint.sh

verilator:
	./scripts/build_verilator.sh

iverilog:
	./scripts/test_iverilog.sh

test:
	./scripts/test.sh

unit:
	bash ./scripts/test_units.sh

regression:
	./scripts/test.sh
	./scripts/synth_check.sh
	@echo "REGRESSION PASS"

waveform:
	./scripts/test_verilator.sh --trace

data-smoke:
	python3 tools/run_tests.py --smoke

state-smoke: verilator
	python3 -m tools.state_vectors
	python3 -m tools.state_vectors --source tests/fixtures/state_vectors.json

verify-failure:
	./scripts/verify_failure_path.sh

singlestep-fetch:
	python3 -m tools.fetch_singlestep

singlestep-smoke: verilator
	python3 -m tools.run_singlestep --smoke
	python3 -m tools.run_singlestep --opcode 89 --opcode 8B --smoke

.PHONY: singlestep-operands phase3-check
.PHONY: singlestep-alu singlestep-alu-smoke
.PHONY: phase4-check alu-audit
phase4-check:
	bash scripts/validate_phase4.sh

alu-audit:
	python3 -m tools.audit_alu

singlestep-alu: verilator
	python3 -m tools.run_singlestep --alu --full

singlestep-alu-smoke: verilator
	python3 -m tools.run_singlestep --alu --smoke

singlestep-operands: verilator
	python3 -m tools.run_singlestep --opcode 89 --opcode 8B --full

phase3-check:
	bash scripts/validate_phase3.sh

.PHONY: phase3-boundary-audit
phase3-boundary-audit:
	python3 -m tools.audit_phase3_boundaries

singlestep-mov: verilator
	python3 -m tools.run_singlestep --full

singlestep-audit: verilator
	python3 -m tools.audit_singlestep

synth-check:
	./scripts/synth_check.sh

quartus-info:
	./scripts/quartus_info.sh

clean:
	rm -rf build

.PHONY: phase5-check stack-control-audit singlestep-stack-control singlestep-stack-control-smoke
phase5-check:
	bash scripts/validate_phase5.sh

stack-control-audit:
	python3 -m tools.audit_stack_control

singlestep-stack-control: verilator
	python3 -m tools.run_singlestep --stack-control --full

singlestep-stack-control-smoke: verilator
	python3 -m tools.run_singlestep --stack-control --smoke

.PHONY: phase6-check phase6-exec-check event-audit singlestep-events-smoke singlestep-phase6
phase6-check:
	bash scripts/validate_phase6.sh

phase6-exec-check:
	bash scripts/validate_phase6.sh executable

event-audit:
	python3 -m tools.audit_events

singlestep-events-smoke: verilator
	python3 -m tools.run_singlestep --events --smoke

singlestep-phase6: verilator
	python3 -m tools.run_singlestep --phase6 --full
