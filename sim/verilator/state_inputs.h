#ifndef SPK286_STATE_INPUTS_H
#define SPK286_STATE_INPUTS_H

#include "Vspk286.h"

// Drive the normal execution interface inactive before resetting the datapath.
inline void clear_execution_inputs(Vspk286& dut) {
    dut.data_in = 0;
    dut.gpr_read_a_index = 0;
    dut.gpr_read_b_index = 0;
    dut.gpr_read_a_byte = 0;
    dut.gpr_read_b_byte = 0;
    dut.gpr_write_en = 0;
    dut.gpr_write_byte = 0;
    dut.gpr_write_index = 0;
    dut.gpr_write_data = 0;
    dut.ip_write_en = 0;
    dut.ip_write_data = 0;
    dut.flags_write_en = 0;
    dut.flags_write_data = 0;
    dut.flags_write_mask = 0;
    dut.segment_load_en = 0;
    dut.segment_load_index = 0;
    dut.segment_load_selector = 0;
    dut.segment_read_index = 0;
    dut.segment_offset = 0;
    dut.redirect = 0;
    dut.fetch_request = 0;
    dut.fetch_ready = 0;
}

#endif
