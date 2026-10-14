# SPDX-License-Identifier: MIT
# The MiSTer PC/AT integration runs the core on the 50 MHz system clock.
create_clock -name clk -period 20.000 [get_ports clk]
derive_clock_uncertainty
