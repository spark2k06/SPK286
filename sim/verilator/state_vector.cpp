#include "state_vector.h"
#include "state_inputs.h"

#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>

namespace {
const std::array<std::string, 8> gprs = {"ax", "cx", "dx", "bx", "sp", "bp", "si", "di"};
const std::array<std::string, 4> segments = {"es", "cs", "ss", "ds"};

void tick(Vspk286& dut) {
    dut.clk = 0;
    dut.eval();
    if (dut.control_error) throw std::runtime_error("state adapter issued an invalid commit");
    dut.clk = 1;
    dut.eval();
    dut.clk = 0;
    dut.eval();
}

template <typename T, std::size_t N>
void print_array(const std::array<T, N>& values) {
    std::cout << '[';
    for (std::size_t i = 0; i < N; ++i) {
        if (i) std::cout << ',';
        std::cout << static_cast<std::uint32_t>(values[i]);
    }
    std::cout << ']';
}
}  // namespace

int run_state_vector(const std::string& path) {
    std::ifstream input(path);
    if (!input) throw std::runtime_error("cannot open state vector: " + path);
    std::map<std::string, std::uint16_t> regs;
    std::map<std::uint32_t, std::uint8_t> ram;
    std::string kind;
    while (input >> kind && kind != "END") {
        std::uint64_t value = 0;
        if (kind == "REG") {
            std::string name;
            if (!(input >> name >> value) || value > 0xFFFF || regs.count(name))
                throw std::runtime_error("invalid REG record");
            regs[name] = static_cast<std::uint16_t>(value);
        } else if (kind == "RAM") {
            std::uint64_t address = 0;
            if (!(input >> address >> value) || address > 0xFFFFFF || value > 0xFF)
                throw std::runtime_error("invalid RAM record");
            ram[static_cast<std::uint32_t>(address)] = static_cast<std::uint8_t>(value);
        } else {
            throw std::runtime_error("unknown state vector record: " + kind);
        }
    }
    if (kind != "END" || regs.size() != 14) throw std::runtime_error("incomplete state vector");
    if (input >> kind) throw std::runtime_error("trailing state vector content");

    Vspk286 dut;
    clear_execution_inputs(dut);
    dut.ready = 0;
    dut.reset = 1;
    tick(dut);
    dut.reset = 0;
    // Initialize through datapath commits, never hierarchical state deposits.
    for (std::size_t i = 0; i < gprs.size(); ++i) {
        dut.gpr_write_en = 1;
        dut.gpr_write_index = i;
        dut.gpr_write_data = regs.at(gprs[i]);
        tick(dut);
    }
    dut.gpr_write_en = 0;
    for (std::size_t i = 0; i < segments.size(); ++i) {
        if (i == 1) continue;  // CS must be part of the final redirect transaction.
        dut.segment_load_en = 1;
        dut.segment_load_index = i;
        dut.segment_load_selector = regs.at(segments[i]);
        tick(dut);
    }
    dut.flags_write_en = 1;
    dut.flags_write_mask = 0xFFFF;
    dut.flags_write_data = regs.at("flags");
    dut.segment_load_en = 1;
    dut.segment_load_index = 1;
    dut.segment_load_selector = regs.at("cs");
    dut.ip_write_en = 1;
    dut.ip_write_data = regs.at("ip");
    dut.redirect = 1;
    tick(dut);
    clear_execution_inputs(dut);

    std::uint32_t last_address = 0;
    for (unsigned cycle = 0; !dut.fetch_valid && cycle < 32; ++cycle) {
        dut.ready = dut.bus_valid;
        if (dut.bus_valid) {
            if (dut.bus_status != 0xD || dut.bus_write || dut.data_oe)
                throw std::runtime_error("unexpected bus transaction during state setup");
            last_address = dut.address;
            const std::uint32_t aligned = dut.address & 0xFFFFFEU;
            // The synthetic memory is zero outside the explicitly initialized bytes.
            dut.data_in = ram[aligned] | (static_cast<std::uint16_t>(ram[aligned + 1]) << 8);
        }
        tick(dut);
    }
    if (!dut.fetch_valid) throw std::runtime_error("first fetch timed out");

    std::map<std::string, std::uint16_t> actual_regs;
    std::array<std::uint32_t, 4> bases{};
    std::array<std::uint16_t, 4> limits{};
    std::array<std::uint8_t, 4> access{};
    for (std::size_t i = 0; i < gprs.size(); ++i) {
        dut.gpr_read_a_index = i;
        dut.eval();
        actual_regs[gprs[i]] = dut.gpr_read_a_data;
    }
    for (std::size_t i = 0; i < segments.size(); ++i) {
        dut.segment_read_index = i;
        dut.eval();
        actual_regs[segments[i]] = dut.segment_selector;
        bases[i] = dut.segment_base;
        limits[i] = dut.segment_limit;
        access[i] = dut.segment_access;
    }
    actual_regs["ip"] = dut.debug_ip;
    actual_regs["flags"] = dut.debug_flags;
    std::cout << "{\"regs\":{";
    bool first = true;
    for (const auto& [name, value] : actual_regs) {
        if (!first) std::cout << ',';
        first = false;
        std::cout << '"' << name << "\":" << value;
    }
    std::cout << "},\"bases\":";
    print_array(bases);
    std::cout << ",\"limits\":";
    print_array(limits);
    std::cout << ",\"access\":";
    print_array(access);
    std::cout << ",\"fetch_address\":" << last_address
              << ",\"fetch_ip\":" << dut.fetch_ip
              << ",\"fetch_count\":" << static_cast<unsigned>(dut.fetch_count)
              << ",\"fetch_data\":" << dut.fetch_data
              << ",\"instructions_executed\":0}\n";
    dut.final();
    return 0;
}
