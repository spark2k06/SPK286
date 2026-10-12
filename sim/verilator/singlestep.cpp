// SPDX-License-Identifier: MIT
#include "singlestep.h"

#include "Vspk286.h"
#include "state_inputs.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <array>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

constexpr std::array<const char*, 14> REG_NAMES = {
    "AX", "BX", "CX", "DX", "CS", "SS", "DS", "ES",
    "SP", "BP", "SI", "DI", "IP", "FLAGS",
};

using PortCycle = std::array<std::uint32_t, 4>; // write, physical address, BHE#, selected data

struct BatchCase {
    std::uint32_t index = 0;
    std::string name;
    std::string hash;
    std::vector<std::uint8_t> instruction_bytes;
    std::array<std::uint16_t, 14> initial_regs{};
    std::array<std::uint16_t, 14> expected_regs{};
    std::array<std::uint16_t, 14> expected_masks{};
    std::map<std::uint32_t, std::uint8_t> initial_ram;
    std::map<std::uint32_t, std::uint8_t> expected_ram;
    std::map<std::uint32_t, std::uint8_t> expected_ram_masks;
    std::uint16_t expected_event = 256;
    std::uint8_t expected_retired = 1;
    std::vector<PortCycle> expected_io;
};

class BatchReader {
public:
    explicit BatchReader(const std::string& path) : input_(path, std::ios::binary) {
        if (!input_) throw std::runtime_error("cannot open SingleStep batch: " + path);
    }

    std::vector<BatchCase> read_all() {
        const std::array<char, 8> expected_magic = {'S', 'P', 'K', '2', '8', '6', 'S', 'S'};
        for (char value : expected_magic) {
            if (read_u8() != static_cast<std::uint8_t>(value))
                throw std::runtime_error("invalid SingleStep batch magic");
        }
        version_ = read_u32();
        if (version_ < 2 || version_ > 5) throw std::runtime_error("unsupported SingleStep batch version");
        const std::uint32_t count = read_u32();
        if (count > 1000000U) throw std::runtime_error("unreasonable SingleStep batch size");
        std::vector<BatchCase> cases;
        cases.reserve(count);
        for (std::uint32_t i = 0; i < count; ++i) cases.push_back(read_case());
        if (input_.peek() != std::ifstream::traits_type::eof())
            throw std::runtime_error("trailing SingleStep batch data");
        return cases;
    }

private:
    std::ifstream input_;
    std::uint32_t version_ = 0;

    std::uint8_t read_u8() {
        char value = 0;
        if (!input_.get(value)) throw std::runtime_error("truncated SingleStep batch");
        return static_cast<std::uint8_t>(value);
    }

    std::uint16_t read_u16() {
        const std::uint16_t low = read_u8();
        return static_cast<std::uint16_t>(low | (static_cast<std::uint16_t>(read_u8()) << 8));
    }

    std::uint32_t read_u32() {
        std::uint32_t value = 0;
        for (unsigned shift = 0; shift < 32; shift += 8)
            value |= static_cast<std::uint32_t>(read_u8()) << shift;
        return value;
    }

    std::string read_string(std::uint32_t length, const char* label) {
        if (length > 1000000U) throw std::runtime_error(std::string("unreasonable ") + label);
        std::string value(length, '\0');
        if (length != 0 && !input_.read(value.data(), static_cast<std::streamsize>(length)))
            throw std::runtime_error(std::string("truncated ") + label);
        return value;
    }

    std::map<std::uint32_t, std::uint8_t> read_memory(const char* label) {
        const std::uint32_t count = read_u32();
        if (count > 100000U) throw std::runtime_error(std::string("unreasonable ") + label);
        std::map<std::uint32_t, std::uint8_t> values;
        for (std::uint32_t i = 0; i < count; ++i) {
            const std::uint32_t address = read_u32();
            const std::uint8_t value = read_u8();
            const auto [it, inserted] = values.emplace(address, value);
            if (!inserted && it->second != value)
                throw std::runtime_error(std::string("conflicting ") + label + " entry");
        }
        return values;
    }

    BatchCase read_case() {
        BatchCase result;
        result.index = read_u32();
        result.name = read_string(read_u32(), "case name");
        result.hash = read_string(read_u32(), "case hash");
        const std::uint32_t byte_count = read_u32();
        if (byte_count == 0 || byte_count > 32) throw std::runtime_error("invalid instruction length");
        result.instruction_bytes.resize(byte_count);
        for (auto& value : result.instruction_bytes) value = read_u8();
        for (auto& value : result.initial_regs) value = read_u16();
        result.initial_ram = read_memory("initial RAM");
        for (auto& value : result.expected_regs) value = read_u16();
        for (auto& value : result.expected_masks) value = read_u16();
        result.expected_ram = read_memory("expected RAM");
        if (version_ == 3 || version_ == 5) {
            result.expected_ram_masks = read_memory("expected RAM masks");
            for (const auto& [address, mask] : result.expected_ram_masks) {
                if (result.expected_ram.count(address) == 0 || mask == 255)
                    throw std::runtime_error("invalid expected RAM mask address/value");
            }
        }
        result.expected_event = read_u16();
        result.expected_retired = read_u8();
        if (result.expected_event > 256 || result.expected_retired > 1)
            throw std::runtime_error("invalid completion expectation");
        if (version_ == 4 || version_ == 5) {
            const auto count = read_u32();
            if (count > 131070U) throw std::runtime_error("unreasonable I/O expectation count");
            for (std::uint32_t i = 0; i < count; ++i) {
                const auto write = read_u8();
                const auto address = read_u32();
                const auto bhe = read_u8();
                const auto data = read_u16();
                if (write > 1 || address > 0x10000 || bhe > 1 || ((address & 1U) && bhe))
                    throw std::runtime_error("invalid I/O expectation");
                result.expected_io.push_back({write, address, bhe, data});
            }
        }
        return result;
    }
};

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

std::uint8_t memory_read(const std::map<std::uint32_t, std::uint8_t>& memory,
                         std::uint32_t address) {
    const auto it = memory.find(address & 0xFFFFFFU);
    return it == memory.end() ? 0 : it->second;
}

std::uint16_t read_bus_word(const std::map<std::uint32_t, std::uint8_t>& memory,
                            std::uint32_t address) {
    const std::uint32_t aligned = address & 0xFFFFFEU;
    return static_cast<std::uint16_t>(memory_read(memory, aligned) |
                                      (static_cast<std::uint16_t>(memory_read(memory, aligned + 1)) << 8));
}

void apply_bus_write(Vspk286& dut, std::map<std::uint32_t, std::uint8_t>& memory) {
    if (!dut.bus_valid || dut.bus_status != 6 || !dut.bus_write || !dut.ready) return;
    const std::uint32_t address = dut.address & 0xFFFFFFU;
    if ((address & 1U) != 0U) {
        memory[address] = static_cast<std::uint8_t>((dut.data_out >> 8) & 0xFFU);
    } else if (dut.bus_bhe_n == 0) {
        memory[address] = static_cast<std::uint8_t>(dut.data_out & 0xFFU);
        memory[(address + 1) & 0xFFFFFFU] = static_cast<std::uint8_t>((dut.data_out >> 8) & 0xFFU);
    } else {
        memory[address] = static_cast<std::uint8_t>(dut.data_out & 0xFFU);
    }
}

void initialize_case(Vspk286& dut, const BatchCase& test) {
    clear_execution_inputs(dut);
    dut.ready = 0;
    dut.reset = 1;
    std::uint64_t time = 0;
    tick(dut, nullptr, time);
    dut.reset = 0;

    constexpr std::array<unsigned, 8> gpr_moo_indices = {0, 2, 3, 1, 8, 9, 10, 11};
    for (unsigned rtl_index = 0; rtl_index < gpr_moo_indices.size(); ++rtl_index) {
        dut.gpr_write_en = 1;
        dut.gpr_write_index = rtl_index;
        dut.gpr_write_data = test.initial_regs[gpr_moo_indices[rtl_index]];
        tick(dut, nullptr, time);
    }
    dut.gpr_write_en = 0;

    // The MOO state is real mode, so ordinary segment loads derive selector*16
    // hidden bases.  CS and IP are committed together as the stream restart.
    constexpr std::array<unsigned, 3> ordinary_segments = {7, 5, 6}; // ES, SS, DS
    for (unsigned moo_index : ordinary_segments) {
        dut.segment_load_en = 1;
        dut.segment_load_index = moo_index == 7 ? 0 : (moo_index == 5 ? 2 : 3);
        dut.segment_load_selector = test.initial_regs[moo_index];
        tick(dut, nullptr, time);
    }
    dut.flags_write_en = 1;
    dut.flags_write_mask = 0xFFFF;
    dut.flags_write_data = test.initial_regs[13];
    dut.segment_load_en = 1;
    dut.segment_load_index = 1;
    dut.segment_load_selector = test.initial_regs[4];
    dut.ip_write_en = 1;
    dut.ip_write_data = test.initial_regs[12];
    dut.redirect = 1;
    tick(dut, nullptr, time);

    clear_execution_inputs(dut);
    dut.reset = 0;
    dut.execute_enable = 1;
}

std::array<std::uint16_t, 14> read_registers(Vspk286& dut) {
    std::array<std::uint16_t, 14> values{};
    constexpr std::array<unsigned, 8> moo_indices = {0, 1, 2, 3, 8, 9, 10, 11};
    constexpr std::array<unsigned, 8> rtl_indices = {0, 3, 1, 2, 4, 5, 6, 7};
    for (unsigned gpr = 0; gpr < moo_indices.size(); ++gpr) {
        dut.gpr_read_a_index = rtl_indices[gpr];
        dut.eval();
        values[moo_indices[gpr]] = dut.gpr_read_a_data;
    }
    values[4] = dut.debug_cs;
    values[5] = static_cast<std::uint16_t>((dut.debug_segment_selectors >> 32) & 0xFFFFU);
    values[6] = static_cast<std::uint16_t>((dut.debug_segment_selectors >> 48) & 0xFFFFU);
    values[7] = static_cast<std::uint16_t>(dut.debug_segment_selectors & 0xFFFFU);
    values[12] = dut.debug_ip;
    values[13] = dut.debug_flags;
    return values;
}

std::string hex16(std::uint16_t value) {
    std::ostringstream output;
    output << "0x" << std::uppercase << std::hex << std::setw(4) << std::setfill('0') << value;
    return output.str();
}

void print_failure(const BatchCase& test, const std::array<std::uint16_t, 14>& actual,
                   const std::string& reason) {
    std::cout << "SINGLESTEP FAIL opcode=" << std::uppercase << std::hex
              << static_cast<unsigned>(test.instruction_bytes.front()) << std::dec
              << " index=" << test.index << " hash=" << test.hash
              << " instruction=\"" << test.name << "\"\n";
    if (!reason.empty()) std::cout << "  reason: " << reason << "\n";
    std::cout << "  initial:";
    for (unsigned i = 0; i < REG_NAMES.size(); ++i)
        std::cout << ' ' << REG_NAMES[i] << '=' << hex16(test.initial_regs[i]);
    std::cout << "\n  expected:";
    for (unsigned i = 0; i < REG_NAMES.size(); ++i)
        std::cout << ' ' << REG_NAMES[i] << '=' << hex16(test.expected_regs[i]);
    std::cout << "\n  actual:";
    for (unsigned i = 0; i < REG_NAMES.size(); ++i) std::cout << ' ' << REG_NAMES[i] << '=' << hex16(actual[i]);
    std::cout << "\n  differences:";
    bool any = false;
    for (unsigned i = 0; i < REG_NAMES.size(); ++i) {
        if ((actual[i] & test.expected_masks[i]) != (test.expected_regs[i] & test.expected_masks[i])) {
            std::cout << ' ' << REG_NAMES[i] << " expected " << hex16(test.expected_regs[i])
                      << " got " << hex16(actual[i]);
            any = true;
        }
    }
    if (!any) std::cout << " none";
    std::cout << '\n';
}

// A scalar retirement budget is insufficient for a counted string. This is
// a finite execution watchdog, separate from the architectural comparison and
// from historical timing. READY is asserted by this runner at every bus cycle.
unsigned execution_budget(const BatchCase& test) {
    bool repeat = false;
    for (const auto byte : test.instruction_bytes) {
        if (byte == 0xF2 || byte == 0xF3) { repeat = true; continue; }
        if (byte == 0x26 || byte == 0x2E || byte == 0x36 || byte == 0x3E || byte == 0xF0) continue;
        const bool string = (byte >= 0x6C && byte <= 0x6F) || (byte >= 0xA4 && byte <= 0xA7) || (byte >= 0xAA && byte <= 0xAF);
        return 512U + (repeat && string ? 64U * test.initial_regs[2] : 0U);
    }
    return 512U;
}

bool run_case(const BatchCase& test, const std::string& trace_path, unsigned ordinal,
              bool report_failure, std::uint64_t& total_cycles) {
    Vspk286 dut;
    VerilatedVcdC* trace = nullptr;
    std::uint64_t time = 0;
    if (!trace_path.empty()) {
        if (ordinal != 0) throw std::runtime_error("a trace requires a single selected case");
        Verilated::traceEverOn(true);
        trace = new VerilatedVcdC;
        dut.trace(trace, 99);
        trace->open(trace_path.c_str());
    }

    initialize_case(dut, test);
    std::map<std::uint32_t, std::uint8_t> memory = test.initial_ram;
    std::vector<PortCycle> observed_io;
    bool retired = false;
    bool failed = false;
    std::string reason;
    const unsigned max_cycles = execution_budget(test);
    unsigned cycles = 0;
    for (; cycles < max_cycles; ++cycles) {
        if (dut.bus_valid) {
            dut.ready = 1;
            // Pinned Arduino capture methodology: IN/INS always reads FF.
            // Expected port records below are comparisons, never stimulus.
            dut.data_in = dut.bus_status == 9 ? 0xFFFF : read_bus_word(memory, dut.address);
            // Code prefetch may run past the sparse initialized stream. Data
            // reads must have every selected byte supplied by the hardware case.
            if (dut.bus_status == 5 &&
                (((dut.address & 1U) == 0 && memory.count(dut.address) == 0) ||
                 (dut.bus_bhe_n == 0 && memory.count(dut.address | 1U) == 0))) {
                failed = true;
                reason = "data read from unspecified sparse RAM";
                break;
            }
        } else {
            dut.ready = 0;
            dut.data_in = 0;
        }
        if (dut.bus_valid && dut.ready && (dut.bus_status == 9 || dut.bus_status == 10)) {
            const std::uint32_t mask = (dut.address & 1U) ? 0xFF00 : (dut.bus_bhe_n ? 0xFF : 0xFFFF);
            const std::uint32_t data = (dut.bus_write ? dut.data_out : dut.data_in) & mask;
            observed_io.push_back({dut.bus_write, dut.address, dut.bus_bhe_n, data});
        }
        apply_bus_write(dut, memory);
        tick(dut, trace, time);
        if (dut.shutdown || dut.microcode_fault) {
            failed = true;
            reason = dut.shutdown ? "CPU shutdown before target completion" : "microcode fault";
            break;
        }
        if (dut.unsupported_opcode) {
            failed = true;
            reason = "unsupported opcode observed before target retirement";
            break;
        }
        if (dut.instruction_retired || dut.event_completed) {
            retired = true;
            // Oracle metadata never drives event delivery. Observe either CPU
            // completion independently, then check its identity and retirement.
            if (dut.instruction_retired != test.expected_retired ||
                bool(dut.event_completed) != (test.expected_event != 256) ||
                (dut.event_completed && dut.debug_event_vector != test.expected_event)) {
                failed = true;
                reason = "architectural completion mismatch";
            }
            break;
        }
    }
    total_cycles += cycles + (retired || failed ? 1 : 0);

    if (!retired && !failed) {
        failed = true;
        reason = "instruction retirement timeout";
    }
    const auto actual = read_registers(dut);
    if (retired && !failed) {
        for (unsigned i = 0; i < actual.size(); ++i) {
            if ((actual[i] & test.expected_masks[i]) != (test.expected_regs[i] & test.expected_masks[i])) {
                failed = true;
                reason = "architectural register mismatch";
                break;
            }
        }
        if (!failed && observed_io != test.expected_io) {
            failed = true;
            reason = "I/O transaction mismatch";
        }
        if (!failed) {
            if (memory.size() != test.expected_ram.size()) {
                failed = true;
                reason = "memory address set mismatch";
            }
            for (const auto& [address, value] : memory) {
                const auto expected = test.expected_ram.find(address);
                const auto masked = test.expected_ram_masks.find(address);
                const std::uint8_t mask = masked == test.expected_ram_masks.end() ? 255 : masked->second;
                if (expected == test.expected_ram.end() || ((expected->second ^ value) & mask) != 0) {
                    failed = true;
                    std::ostringstream detail;
                    detail << "memory state mismatch at 0x" << std::hex << address << " actual=" << unsigned(value);
                    if (expected != test.expected_ram.end()) detail << " expected=" << unsigned(expected->second);
                    detail << " mask=" << unsigned(mask);
                    reason = detail.str();
                    break;
                }
            }
        }
    }
    if (failed && report_failure) {
        print_failure(test, actual, reason);
        std::cout << "  microstate: micro_pc=" << hex16(dut.debug_micro_pc)
                  << " micro_entry=" << hex16(dut.debug_micro_entry)
                  << " micro_instruction=" << static_cast<unsigned>(dut.debug_micro_instruction)
                  << " active=" << static_cast<unsigned>(dut.debug_micro_active)
                  << " fault=" << static_cast<unsigned>(dut.microcode_fault)
                  << " queue_count=" << static_cast<unsigned>(dut.debug_prefetch_count) << '\n';
        std::cout << "  operand: modrm=" << hex16(dut.debug_modrm)
                  << " displacement=" << hex16(dut.debug_displacement)
                  << " offset=" << hex16(dut.debug_effective_offset)
                  << " segment=" << unsigned(dut.debug_operand_segment)
                  << " blocked=" << unsigned(dut.operand_blocked)
                  << " bus_status=" << unsigned(dut.bus_status)
                  << " bus_address=" << std::hex << dut.address << std::dec << '\n';
    }

    if (trace != nullptr) {
        trace->flush();
        trace->close();
        delete trace;
    }
    dut.final();
    return !failed;
}

}  // namespace

int run_singlestep_batch(const std::string& path, const std::string& trace_path) {
    try {
        const auto tests = BatchReader(path).read_all();
        std::uint64_t total_cycles = 0;
        std::uint32_t passed = 0;
        std::uint32_t failures = 0;
        constexpr std::uint32_t max_reported_failures = 20;
        for (unsigned i = 0; i < tests.size(); ++i) {
            const bool report_failure = failures < max_reported_failures;
            const bool pass = run_case(tests[i], trace_path, i, report_failure, total_cycles);
            if (pass) {
                ++passed;
            } else {
                ++failures;
                if (failures == max_reported_failures && tests.size() > i + 1)
                    std::cout << "SINGLESTEP: further failure diagnostics suppressed\n";
            }
        }
        std::cout << "SINGLESTEP_RESULT executed=" << tests.size()
                  << " passed=" << passed << " failed=" << failures
                  << " cycles=" << total_cycles << '\n';
        return failures == 0 ? 0 : 1;
    } catch (const std::exception& error) {
        std::cerr << "SINGLESTEP ERROR: " << error.what() << '\n';
        return 2;
    }
}
