SHELL := /usr/bin/env bash

.PHONY: help env bootstrap lint verilator test regression iverilog waveform data-smoke synth-check quartus-info verify-failure clean

help:
	@echo "SPK286 development targets:"
	@echo "  make env          check the WSL toolchain"
	@echo "  make bootstrap    install missing WSL packages when permitted"
	@echo "  make lint         run Verilator lint"
	@echo "  make verilator    build the Verilator smoke executable"
	@echo "  make iverilog     run the Icarus smoke test"
	@echo "  make test         run fast dual-simulator and Python tests"
	@echo "  make regression   run test plus Yosys synthesis sanity check"
	@echo "  make waveform     run Verilator smoke with a VCD trace"
	@echo "  make data-smoke   validate the JSON/MOO data loader"
	@echo "  make verify-failure prove negative simulator status propagation"
	@echo "  make synth-check  run the portable RTL through Yosys"
	@echo "  make quartus-info inspect the local Quartus Docker image"
	@echo "  make clean        remove generated build output"

env:
	./scripts/env_check.sh

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

regression:
	./scripts/test.sh
	./scripts/synth_check.sh
	@echo "REGRESSION PASS"

waveform:
	./scripts/test_verilator.sh --trace

data-smoke:
	python3 tools/run_tests.py --smoke

verify-failure:
	./scripts/verify_failure_path.sh

synth-check:
	./scripts/synth_check.sh

quartus-info:
	./scripts/quartus_info.sh

clean:
	rm -rf build
