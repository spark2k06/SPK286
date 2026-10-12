# SPDX-License-Identifier: MIT
SHELL := /usr/bin/env bash

BUILD_DIR := $(or $(SPK286_BUILD_DIR),build)
SINGLESTEP_ROOT := $(or $(SPK286_SINGLESTEP_ROOT),.cache/singlestep-80286)

.PHONY: help env bootstrap microcode microcode-check microcode-test microcode-audit \
        lint verilator iverilog waveform unit test synth-check regression verify-failure \
        data-smoke state-smoke singlestep-fetch singlestep-smoke singlestep singlestep-audit \
        mutation-audit timing-trace timing-calibration profiled profiled-check full-check resource-report \
        quartus-info clean

help:
	@echo "SPK286 targets:"
	@echo "  make env               check the local toolchain"
	@echo "  make bootstrap         install missing Ubuntu/WSL packages"
	@echo "  make microcode         regenerate the committed microcode artifacts"
	@echo "  make microcode-check   fail if any generated microcode artifact is stale"
	@echo "  make microcode-test    run the microcode compiler tests"
	@echo "  make microcode-audit   verify the ROM entry contract and round-trip"
	@echo "  make lint              run Verilator lint"
	@echo "  make verilator         build the Verilator smoke/SingleStep executable"
	@echo "  make iverilog          run the Icarus reset smoke test"
	@echo "  make waveform          run the Verilator smoke test with a VCD trace"
	@echo "  make unit              run every directed testbench in both simulators"
	@echo "  make test              microcode, lint, unit benches, Python tests and smokes"
	@echo "  make synth-check       run the RTL through Yosys"
	@echo "  make regression        test + synth-check"
	@echo "  make singlestep-fetch  fetch the pinned SingleStepTests/80286 working set"
	@echo "  make singlestep-smoke  run ten cases of every supported opcode file"
	@echo "  make singlestep        run every case of every supported opcode file"
	@echo "  make singlestep-audit  cross-check SingleStep parsing and comparators"
	@echo "  make mutation-audit    require the testbenches to reject injected RTL faults"
	@echo "  make profiled          regenerate the profiled timing variant in rtl/timed"
	@echo "  make profiled-check    check rtl/timed is current and run its testbenches"
	@echo "  make timing-trace      capture and validate a timing observation trace"
	@echo "  make timing-calibration capture the instruction timing calibration suite"
	@echo "  make full-check        regression, SingleStep, audits and profiled variant"
	@echo "  make resource-report   estimate Cyclone V resources per module with Yosys"
	@echo "  make clean             remove build output"

env:
	./scripts/env_check.sh

bootstrap:
	./scripts/bootstrap.sh

microcode:
	python3 -m tools.microcode.compile_microcode

microcode-check:
	python3 -m tools.microcode.compile_microcode --check

microcode-test: microcode-check
	python3 -m unittest discover -s tests -p 'test_microcode*.py' -v

microcode-audit: microcode-check
	python3 -m tools.microcode.audit_microcode --output "$(BUILD_DIR)/microcode-audit"

lint:
	./scripts/lint.sh

verilator:
	./scripts/build_verilator.sh

iverilog:
	./scripts/test_iverilog.sh

waveform:
	./scripts/test_verilator.sh --trace

unit:
	bash ./scripts/test_units.sh

test:
	./scripts/test.sh

synth-check:
	./scripts/synth_check.sh

regression:
	./scripts/test.sh
	./scripts/synth_check.sh
	@echo "REGRESSION PASS"

verify-failure:
	./scripts/verify_failure_path.sh

data-smoke:
	python3 tools/run_tests.py --smoke

state-smoke: verilator
	python3 -m tools.state_vectors
	python3 -m tools.state_vectors --source tests/fixtures/state_vectors.json

singlestep-fetch:
	python3 -m tools.fetch_singlestep

singlestep-smoke: verilator
	python3 -m tools.run_singlestep --all --smoke

singlestep: verilator
	rm -rf "$(BUILD_DIR)/singlestep-all"
	python3 -m tools.run_singlestep_all --repo "$(SINGLESTEP_ROOT)" \
	    --executable "$(BUILD_DIR)/verilator/obj_dir/spk286_smoke" --build-dir "$(BUILD_DIR)/singlestep-all"

singlestep-audit: verilator
	./scripts/run_singlestep_audits.sh

mutation-audit:
	./scripts/run_mutation_audits.sh

profiled:
	python3 scripts/build_profiled_cpu.py

profiled-check:
	python3 scripts/check_profiled_cpu.py

timing-trace:
	python3 -m tools.capture_timing_trace

timing-calibration:
	python3 -m tools.capture_timing_calibration --simulator both

full-check: regression verify-failure data-smoke singlestep singlestep-audit mutation-audit profiled-check
	@echo "FULL CHECK PASS"

resource-report:
	python3 scripts/resource_report.py --top spk286 --view modules
	python3 scripts/resource_report.py --top spk286 --view integrated

quartus-info:
	./scripts/quartus_info.sh

clean:
	rm -rf build
