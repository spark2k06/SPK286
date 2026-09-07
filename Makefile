SHELL := /usr/bin/env bash

.PHONY: help env bootstrap lint verilator test unit regression iverilog waveform data-smoke state-smoke synth-check quartus-info verify-failure singlestep-fetch singlestep-smoke singlestep-mov singlestep-audit clean microcode microcode-check microcode-test microcode-audit mcl86-fetch mcl86-check mcl86-test phase2.80-check

help:
	@echo "SPK286 development targets:"
	@echo "  make microcode       regenerate committed ROM, constants and source maps"
	@echo "  make microcode-check fail if any generated microcode artifact is stale"
	@echo "  make microcode-test  run independent Python compiler/ROM tests"
	@echo "  make microcode-audit verify Phase 2.75 ROM/entry contract and round-trip"
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
	@echo "  make singlestep-smoke run ten deterministic B8..BF cases per opcode"
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
	python3 tools/fetch_singlestep.py

singlestep-smoke: verilator
	python3 -m tools.run_singlestep --smoke

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
