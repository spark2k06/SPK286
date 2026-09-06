#include "Vspk286.h"
#include "state_inputs.h"
#include "state_vector.h"
#include "singlestep.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>

namespace {

struct Options {
    std::uint32_t expected_fetch = 0xFFFFF0U;
    std::string trace_path;
    std::string state_vector;
    std::string singlestep_batch;
};

std::uint32_t parse_hex(const std::string& text) {
    std::size_t consumed = 0;
    const auto value = std::stoul(text, &consumed, 0);
    if (consumed != text.size() || value > 0xFFFFFFU) {
        throw std::invalid_argument("invalid 24-bit hexadecimal value: " + text);
    }
    return static_cast<std::uint32_t>(value);
}

Options parse_options(int argc, char** argv) {
    Options options;
    for (int index = 1; index < argc; ++index) {
        const std::string argument(argv[index]);
        if (argument == "--expected-fetch" && index + 1 < argc) {
            options.expected_fetch = parse_hex(argv[++index]);
        } else if (argument == "--state-vector" && index + 1 < argc) {
            options.state_vector = argv[++index];
        } else if (argument == "--singlestep-batch" && index + 1 < argc) {
            options.singlestep_batch = argv[++index];
        } else if (argument == "--trace" && index + 1 < argc) {
            options.trace_path = argv[++index];
        } else if (argument == "--help") {
            std::cout << "Usage: spk286_smoke [--expected-fetch VALUE] [--trace PATH] | --state-vector PATH | --singlestep-batch PATH\n";
            std::exit(0);
        } else {
            throw std::invalid_argument("unknown or incomplete argument: " + argument);
        }
    }
    return options;
}

void tick(Vspk286& dut, VerilatedVcdC* trace, std::uint64_t& time) {
    dut.clk = 0;
    dut.eval();
    if (trace != nullptr) trace->dump(time++);
    dut.clk = 1;
    dut.eval();
    if (trace != nullptr) trace->dump(time++);
    dut.clk = 0;
    dut.eval();
    if (trace != nullptr) trace->dump(time++);
}

bool check(bool condition, const std::string& message) {
    if (!condition) std::cerr << "RESET_SMOKE FAIL: " << message << "\n";
    return condition;
}

}  // namespace

int main(int argc, char** argv) {
    try {
        const Options options = parse_options(argc, argv);
        Verilated::commandArgs(argc, argv);
        if (!options.state_vector.empty()) return run_state_vector(options.state_vector);
        if (!options.singlestep_batch.empty())
            return run_singlestep_batch(options.singlestep_batch, options.trace_path);
        Verilated::traceEverOn(!options.trace_path.empty());

        Vspk286 dut;
        clear_execution_inputs(dut);
        VerilatedVcdC* trace = nullptr;
        if (!options.trace_path.empty()) {
            trace = new VerilatedVcdC;
            dut.trace(trace, 99);
            trace->open(options.trace_path.c_str());
        }

        std::uint64_t time = 0;
        dut.reset = 1;
        dut.ready = 0;
        tick(dut, trace, time);
        tick(dut, trace, time);

        bool pass = true;
        pass &= check(dut.debug_cs == 0xF000U, "reset CS mismatch");
        pass &= check(dut.debug_cs_base == 0xFF0000U, "hidden CS base mismatch");
        pass &= check(dut.debug_ip == 0xFFF0U, "reset IP mismatch");
        pass &= check(dut.debug_flags == 0x0002U, "reset FLAGS mismatch");
        pass &= check(dut.bus_valid == 0, "bus active during reset");

        dut.reset = 0;
        tick(dut, trace, time);
        pass &= check(dut.bus_valid != 0, "no first code-fetch request observed");
        pass &= check(dut.bus_write == 0, "first fetch unexpectedly writes");
        pass &= check(dut.bus_status == 0xDU, "first fetch bus status mismatch");
        pass &= check(dut.bus_bhe_n == 0, "first fetch did not select the upper lane");
        pass &= check(dut.debug_bus_state == 0x1U, "debug bus state mismatch");
        pass &= check(dut.debug_micro_pc == 0U, "debug micro-PC mismatch");
        {
            std::ostringstream message;
            message << "first fetch address got 0x" << std::hex << dut.address
                    << " expected 0x" << options.expected_fetch;
            pass &= check(dut.address == options.expected_fetch, message.str());
        }

        dut.ready = 1;
        tick(dut, trace, time);
        pass &= check(dut.bus_valid == 0, "fetch did not complete after READY");

        if (trace != nullptr) {
            trace->close();
            delete trace;
        }
        dut.final();

        if (pass) {
            std::cout << "RESET_SMOKE PASS CS=0x" << std::hex << dut.debug_cs
                      << " CS_BASE=0x" << dut.debug_cs_base << " IP=0x" << dut.debug_ip
                      << " FETCH=0xFFFFF0\n";
            return 0;
        }
        return 1;
    } catch (const std::exception& error) {
        std::cerr << "RESET_SMOKE FAIL: " << error.what() << "\n";
        return 2;
    }
}
