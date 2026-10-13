# SPK286 native bus contract

Status: stage 1 is implemented in `rtl/native/spk286_native.sv` and checked by
`sim/unit/spk286_native_tb.sv`. Rules labeled V (section 2) are still open.

This document defines how SPK286 presents itself at the pins of an 80286 when
the core runs in its own device, for example a dedicated FPGA on a board where
other devices implement the rest of the machine. It covers the CPU side of the
boundary only. Board design and the system-side logic (clock generator, bus
controller, chipset) belong to the projects that use the core; they appear
here only as the expectations the CPU places on them.

## 1. Layers

```text
 CPU device                                        system device(s)
+-------------------------------------------+     +----------------------+
| spk286 --normalized bus--> spk286_native  | pins| clock/reset/READY    |
|        (rtl/spk286.sv)     (pin adapter)  |<--->| bus controller       |
+-------------------------------------------+     | memory, I/O, chipset |
                                                  +----------------------+
```

- `spk286` keeps its normalized transaction bus ([SPK286.md, section 3](SPK286.md#3-external-interface-and-biu)).
  The core is not changed to produce pin timing.
- `spk286_native` converts each normalized transaction into an 80286 bus
  cycle: pin polarities, the T-state sequence, READY# sampling, HOLD/HLDA
  floating, reset and the halt/shutdown cycle.
- A board-specific top level for the CPU device instantiates `spk286_native`,
  turns each value/enable pair into a three-state pin and assigns pins. It
  lives with the board project.

## 2. Evidence labels

Every rule below carries one label:

| Label | Meaning |
| --- | --- |
| **I** | Intel 80286 documentation (data sheet, Hardware Reference Manual 210760-002). |
| **C** | Behavior of the current core RTL, already verified. |
| **P** | Project decision for `spk286_native`; may be revised. |
| **V** | Not yet confirmed; must be checked against Intel timing figures and, where possible, logic-analyzer captures of a physical 80286 before it is relied on. |

Items labeled **V** are collected in section 11.

## 3. Pins

Active-low signals carry a `#` suffix. Output and bidirectional pins are
three-state where noted.

| Pin | Dir | Function | Core connection | Label |
| --- | --- | --- | --- | --- |
| CLK | in | System clock, twice the processor clock. | Clock of `spk286` and `spk286_native` (section 4). | I, P |
| RESET | in | Active-high reset; sets the processor clock phase. | `reset` | I |
| A23-A0 | out, 3-state | Physical address. I/O cycles drive A15-A0 with A23-A16 low. | `address` | I, C |
| D15-D0 | in/out, 3-state | Data bus. | `data_in`, `data_out`, `data_oe` | I |
| BHE# | out, 3-state | Upper byte enable. | `bus_bhe_n` | I, C |
| S1#, S0# | out, 3-state | Bus cycle status; a cycle starts when either goes low. | `bus_status[1:0]` | I, C |
| M/IO# | out, 3-state | Memory (high) or I/O (low). | `bus_status[2]` | I, C |
| COD/INTA# | out, 3-state | Code (high) or interrupt acknowledge (low). | `bus_status[3]` | I, C |
| LOCK# | out | Bus lock. | `bus_lock` | I, C |
| READY# | in | Ends the current bus cycle. | Qualifies `ready` (section 6) | I |
| HOLD | in | Bus hold request. | `hold_request` | I |
| HLDA | out | Hold acknowledge. | From `hlda` (section 8) | I |
| INTR | in | Maskable interrupt, level sensitive. | `intr` | I, C |
| NMI | in | Non-maskable interrupt, rising edge. | `nmi` | I, C |
| PEREQ | in | Processor extension operand request. | Ignored | P |
| PEACK# | out | Processor extension acknowledge. | Driven high (inactive) | P |
| BUSY# | in | Processor extension busy. | Ignored | P |
| ERROR# | in | Processor extension error. | Ignored | P |

### Module ports

`spk286_native` exposes the pins as plain inputs and outputs, so the board top
level owns the I/O buffers:

| Pins | Ports |
| --- | --- |
| A23-A0, BHE#, S1#, S0#, M/IO#, COD/INTA# | `a`, `bhe_n`, `s1_n`, `s0_n`, `m_io`, `cod_inta_n`; driven while `bus_oe` is high |
| D15-D0 | `d_in`; `d_out` driven while `d_oe` is high |
| Other pins | `clk`, `reset`, `lock_n`, `ready_n`, `hold`, `hlda`, `intr`, `nmi`, `pereq`, `peack_n`, `busy_n`, `error_n` |
| Not 80286 pins | `timing_policy` strap; `halted` and `shutdown` status for the board |

The core has no processor extension interface; ESC and WAIT follow the MSW
no-NPX rules (C). The four processor extension pins are reserved so that a
board can route them now and a later revision can use them.

Core inputs not listed are tied by `spk286_native`: `execute_enable` high,
setup ports inactive, `redirect` low. `timing_policy_request` comes from a
parameter or strap input (P). The `debug_*` outputs may be routed to a debug
connector by the board top level; they are not part of this contract.

### Status encoding

`bus_status` already uses the 80286 status encoding
`{COD/INTA#, M/IO#, S1#, S0#}` (I, C). The adapter drives these four bits
unchanged during Ts and drives S1#/S0# high (passive) otherwise.

| `bus_status` | COD/INTA# M/IO# S1# S0# | Cycle | Core use |
| --- | --- | --- | --- |
| `0` | 0 0 0 0 | Interrupt acknowledge | INTA pair |
| `4` | 0 1 0 0 | Halt if A1 = 1, shutdown if A1 = 0 | Halt/shutdown (section 9) |
| `5` | 0 1 0 1 | Memory data read | Data |
| `6` | 0 1 1 0 | Memory data write | Data |
| `9` | 1 0 0 1 | I/O read | Data |
| `A` | 1 0 1 0 | I/O write | Data |
| `D` | 1 1 0 1 | Memory instruction read | Code fetch |
| `F` | 1 1 1 1 | No cycle | Passive |

The other encodings are reserved or passive (I) and are never produced.

### Byte lanes

| BHE# | A0 | Transfer | Label |
| --- | --- | --- | --- |
| 0 | 0 | Word on D15-D0 | I |
| 0 | 1 | Upper byte (odd address) on D15-D8 | I |
| 1 | 0 | Lower byte (even address) on D7-D0 | I |
| 1 | 1 | Not used | I |

The core already splits an odd word into two ordered byte cycles and returns
a single byte on D15-D8 for an odd code fetch (C). The adapter does not split
or merge transfers.

## 4. Clocking

- CLK is the board clock and the only clock of the CPU device. The processor
  clock is CLK divided by two; each processor clock has two phases, phase 1
  and phase 2, of one CLK period each (I).
- `spk286` and `spk286_native` both run on CLK. The core therefore completes
  internal work at twice the processor clock rate; bus cycles are paced by the
  adapter in processor clocks (P).
- The core must close timing at the CLK frequency of the board (for example
  16 MHz for an 8 MHz part, 32 MHz for 16 MHz). This has to be confirmed per
  device family (V).
- The falling edge of RESET defines the phase relationship (I). RESET is
  registered; the first processor clock starts, in phase 1, on the first CLK
  edge after RESET falls (P; exact edge V).
- All inputs are synchronous to CLK because the system side generates CLK
  and drives READY#, HOLD, INTR and NMI from it (P). RESET, HOLD, INTR and NMI
  are registered once on entry; READY# and D15-D0 are sampled directly at the
  end of Tc. An asynchronous source must be synchronized on the system side.
- Every pin output is registered and changes only where a processor clock
  begins (P).

## 5. Bus states

| State | Length | Meaning | Label |
| --- | --- | --- | --- |
| Ti | 1 processor clock | Idle; S1#/S0# passive. | I |
| Ts | 1 processor clock | Status: S1#/S0# active, cycle type valid. | I |
| Tc | 1 processor clock, repeated | Command; READY# sampled at its end. Each extra Tc is a wait state. | I |
| Th | while HOLD | Bus floated, HLDA high. | I |

A cycle with no wait states lasts Ts + Tc, two processor clocks or four CLK
periods (I).

On an 80286 the address and BHE# of a cycle are valid before its Ts: during
the preceding Ti, or during the last Tc of the preceding cycle when cycles run
back to back (pipelined addressing, I). The exact phase at which they change
is V.

### Stage 1: address-setup Ti

The normalized bus offers one transaction at a time and only shows the next
one after the current one completes. Stage 1 of the adapter therefore always
inserts one Ti before Ts, with address, BHE# and M/IO#/COD/INTA# already
valid, and hands the result to the core in the Ti after the cycle (P):

```text
processor clock | Ti(addr) |   Ts   |   Tc   | Tc(wait) |    Ti     | Ti(addr) |   Ts   |
A23-A0, BHE#    |<============== cycle N ===================>|<======= cycle N+1 ====...
S1#, S0#        | passive  | active | passive| passive  | passive   | passive  | active |
READY# sampled  |          |        |  high  |   low    |           |          |        |
core            |          |        |        |          | READY,    |          |        |
                |          |        |        |          | offers N+1|          |        |
```

Back-to-back cycles take two processor clocks more than on a pipelined 80286:
four instead of two without wait states. In return the address is valid for
a full processor clock before Ts, which should be at least as early as an
80286 drives it (V). A system device that
latches the address from status, as the 82288 ALE does, sees a valid address.

### Stage 2: pipelined addressing

Overlapping the next address with the current Tc needs the next transaction
before the current one completes. That requires a separate address-accept
handshake on the normalized bus. It is left for a later revision once stage 1
is verified on hardware (P).

## 6. Bus cycle sequence and READY#

For each transaction (P unless noted):

1. At the end of a Ti, when `bus_valid` is high, the adapter latches
   `address`, `bus_bhe_n`, `bus_status`, `bus_write` and `data_out`. The next
   processor clock is the address-setup Ti.
2. Ts: S1#/S0# active with the latched status.
3. Tc: READY# is sampled at the end of each Tc (I; exact CLK edge V). While
   READY# is high, Tc repeats.
4. At the end of the Tc that samples READY# low, the adapter captures
   D15-D0. In phase 1 of the following Ti it drives `ready` high for one CLK
   with `data_in` set to the captured value, and the core accepts the
   transfer (C).
5. At the end of that Ti the adapter may latch the next `bus_valid`.

The core never sees `ready` before step 4. The adapter relies on two
properties of the core (C):

- an offered transaction is not withdrawn or changed until `ready`, except by
  reset;
- data and code arbitration is decided by the core; the adapter serves
  whatever `bus_valid` presents.

The bench asserts both properties at the adapter boundary.

## 7. Data bus

- Writes: D15-D0 are driven with the latched write data during every Tc of
  the cycle and float from the next processor clock (P; the exact enable and
  float points of an 80286 are V). The byte lanes
  follow `data_out`; the core already places a byte on the lane selected by
  BHE#/A0 (C).
- Reads and INTA: D15-D0 are inputs throughout and sampled with READY# (I).
- D15-D0 float in Ti, Ts, Th and during reset (P).
- Direction control for buffers (DEN, DT/R#) is generated by the system-side
  bus controller from status, as with the 82288 (I). The CPU device has no
  DEN or DT/R# pin.

## 8. HOLD and HLDA

- HOLD goes to `hold_request` after the input register (P).
- The core grants HOLD only at a free boundary and never splits an odd word,
  a locked read-modify-write or the INTA chain (C).
- When the core raises `hlda` and the adapter is in Ti, the adapter floats
  A23-A0, D15-D0, BHE#, S1#, S0#, M/IO# and COD/INTA#, then raises HLDA on
  the next processor clock (P; float set and ordering V). LOCK# stays driven
  (P; whether an 80286 floats it is V).
- When HOLD falls, the core drops `hlda`. The adapter lowers HLDA while the
  bus is still floated, drives the bus passive on the next processor clock,
  and only then may start a cycle (P; V against the Intel release timing).
- Pins that float need board pull-ups so the system side sees passive status
  (S1#, S0#, BHE#).

## 9. Interrupt acknowledge, halt and shutdown

- INTA is a pair of status-0 cycles, both READY-qualified, with the vector
  taken from D7-D0 of the second (C). LOCK# links both cycles and the first
  stack push (C). The adapter runs each as a normal cycle, so stage 1 timing
  separates them by two Ti. The number of idle processor clocks an 80286
  inserts between the two INTA cycles is V.
- LOCK# follows the core lock at the start of each processor clock: it is
  active from the address-setup Ti of the first locked cycle and released at
  the start of the processor clock after the core accepts the last one (P).
- The core shows halt and shutdown as a steady level: `bus_status` 4 with
  address 2 (halt) or 0 (shutdown), without a bus transaction (C). On entering
  either state the adapter runs one status-4 cycle with A1 set for halt and
  clear for shutdown and BHE# high, then stays in Ti until the core leaves the
  state (P).
- Whether the halt/shutdown cycle waits for READY# like other cycles is V.
  Until confirmed the adapter waits for READY#, so the system side must
  return READY# for status-4 cycles.

## 10. Reset

- RESET is active high and must stay high for at least 16 CLK periods (I).
- While RESET is high the adapter holds S1#/S0#, BHE#, LOCK# and PEACK# high,
  floats D15-D0, drives HLDA low and drives A23-A0, M/IO# and COD/INTA# high
  (P; must match the Intel pin-state table, V).
- After RESET falls, the core fetches from FFFFF0 (C). The delay from RESET
  falling to the first Ts on an 80286 is V; the adapter may start earlier
  until the historical value is known.

## 11. Open validation items

Each V item must be resolved from Intel timing figures, and preferably
confirmed on a physical 80286 with a logic analyzer, before the matching
adapter behavior is treated as final:

1. CLK edge at which the phase bit starts after RESET falls.
2. Phase at which the address and BHE# change, including pipelined timing.
3. Phases at which S1#/S0# assert and return passive.
4. CLK edge at which READY# and read data are sampled.
5. Start and end of the write data drive window.
6. Pins floated during hold, including LOCK#, and the HLDA assert and
   release ordering.
7. Idle clocks between the two INTA cycles.
8. Whether halt and shutdown cycles wait for READY#.
9. Pin states during reset and the delay to the first Ts.
10. Core timing closure at the board CLK frequency for each target device.

## 12. Verification

Implemented:

- `sim/unit/spk286_native_tb.sv`, part of `make unit` in Verilator and
  Icarus. A program runs through the pins against a memory and I/O model:
  far jump from the reset vector, word and odd-word writes, a word read,
  OUT and IN, STI and HLT, and an INTR handler that ends in a second HLT.
  Every cycle gets 0 to 2 random wait states and one HOLD is requested
  mid-program. An independent processor-clock monitor checks that pins change
  only where a processor clock begins, the address-setup Ti before every Ts,
  status and BHE#/A0 encodings, Tc holding, the write data window, READY#
  waits, LOCK# across the INTA chain, the HOLD/HLDA float order, one halt
  cycle per HLT and the reset pin states. The program results are then
  checked in memory, including the interrupt frame.
- The same bench asserts the core properties of section 6.
- `tools/audit_native.py`, part of `make mutation-audit`, injects ten adapter
  faults and requires the intended assertion of the bench to reject each.

Planned:

- A co-simulation with a minimal system model (clock and READY# generator,
  82288-style status decode, memory) that runs the existing directed programs
  through the pins, so functional results can be compared with the
  normalized-bus benches.
- Captures from a physical 80286 to close the V items, used as references in
  the same way as the SingleStepTests/80286 corpus is used for functional
  behavior.
