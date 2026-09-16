#include "Vspk286.h"
#include "state_inputs.h"
#include "verilated.h"

#include <iostream>

namespace {

void tick(Vspk286& dut) {
    dut.clk = 0;
    dut.eval();
    dut.clk = 1;
    dut.eval();
    dut.clk = 0;
    dut.eval();
}

bool check(bool condition, const char* message) {
    if (!condition) std::cerr << "TIMING_POLICY_INIT FAIL: " << message << '\n';
    return condition;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::randReset(1);

    Vspk286 dut;
    dut.timing_policy_request = 3;
    dut.ready = 1;
    dut.data_in = 0xFFFF;
    clear_execution_inputs(dut);

    dut.reset = 1;
    tick(dut);

    bool pass = true;
    pass &= check(dut.timing_policy_request == 0, "adapter did not select baseline request");
    pass &= check(dut.debug_timing_policy == 0, "active policy is not baseline during reset");
    pass &= check(dut.debug_timing_policy_error == 0, "selector reported an initialization error");

    dut.reset = 0;
    tick(dut);
    pass &= check(dut.debug_timing_policy == 0, "active policy changed after reset");
    pass &= check(dut.debug_timing_policy_error == 0, "selector error appeared after reset");
    pass &= check(dut.debug_timing_policy_locked != 0, "policy selection was not locked after reset");

    dut.final();
    if (pass) {
        std::cout << "TIMING_POLICY_INIT PASS request=0 active=0 error=0 locked=1\n";
        return 0;
    }
    return 1;
}
