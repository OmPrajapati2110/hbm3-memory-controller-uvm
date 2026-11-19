# HBM3-style memory controller: RTL and full verification environment

A 4-client HBM3-style pseudo-channel memory controller in SystemVerilog, with a
verification environment built the way a GPU or memory DV team would build one:
a UVM testbench with a reference-model scoreboard, constrained-random stimulus,
functional coverage, SVA for every JEDEC-style timing rule, formal proofs, a
seeded regression, and a bug-injection campaign that shows the testbench
catches real bugs.

**Headline results** (all reproducible with the commands below):

<!-- RESULTS:BEGIN -->
| Metric | Result |
|---|---|
| Seeded regression | 122/122 runs pass, 124,295 requests checked end to end |
| Functional coverage | 100.0% (88/88 bins) |
| Assertion cover properties | 100.0% (24/24), every timing rule hit exactly at its limit |
| Bug injection | 9/9 injected bugs caught |
| Formal (SymbiYosys BMC, depth 40) | all 43 assertions proven; 4/4 formal mutants caught |
| SV UVM bench | elaborates with 0 errors against Accellera UVM 2020 (slang) |
| Synthesis (Yosys, generic gates) | 68,889 cells, 19,292 flip-flops |
| Starvation (victim worst latency) | FR-FCFS 7,066 cycles vs aging 345 cycles |
<!-- RESULTS:END -->

**See it run:** [interactive cycle-by-cycle model](https://claude.ai/artifact/Wzp1zgnqYeVc8C6ZQTAeCc)
(source in `demo/`). It replays real Verilator traces of this RTL and compares
FCFS, FR-FCFS and aging on the same traffic. Building it uncovered a real
starvation bug, which is now fixed (bug 4 in [docs/results.md](docs/results.md)).

## What the design does

- 4 clients, valid/ready request and response channels, 4-bit transaction IDs,
  out-of-order completion
- 16 banks in 4 bank groups, separate row (ACT/PRE/REF) and column (RD/WR)
  command buses, as on HBM
- 16-entry shared command queue with an age matrix and same-address hazard
  tracking (RAW/WAR/WAW order kept, everything else may reorder)
- Three scheduling policies: FCFS, FR-FCFS, and FR-FCFS with a per-bank aging
  reservation that bounds starvation without giving up bandwidth
- 22 timing rules: tRCD, tRP, tRAS, tRC, tRRD_S/L, tFAW, tCCD_S/L, tWTR_S/L,
  tRTP, tWR, tRTW, tRFC, tREFI, plus bank-state legality
- All-bank refresh with precharge sequencing; credit-based response flow control

Details: [docs/architecture.md](docs/architecture.md), timing values and their
rationale: [docs/timing.md](docs/timing.md).

## Verification environment

```
                 +------------------------- env --------------------------+
  vseq --------> | client agent x4 (seqr, driver, monitor, ID pool)       |
  (per test)     |   |  req/rsp                                           |
                 |   v                                                    |
                 |  DUT harness: hbm3_mc + HBM device model               |
                 |   |  row/col command bus      + bound SVA (white box)  |
                 |   v                           + timing checker (bus)   |
                 | cmd agent (passive monitor)                            |
                 |   |                                                    |
                 |   +--> scoreboard + reference model (legal-value sets) |
                 |   +--> functional coverage                             |
                 +--------------------------------------------------------+
```

| Piece | File(s) |
|---|---|
| SystemVerilog UVM bench (Questa / VCS / Xcelium / Riviera) | `tb/uvm/` |
| Same environment in pyuvm (runs free on Verilator) | `tb/pyuvm/` |
| Black-box JEDEC timing checker, 22 assertions + at-limit covers | `tb/sva/hbm3_timing_checker.sv` |
| White-box assertions bound into the DUT | `tb/sva/hbm3_mc_sva.sv` |
| HBM device model | `tb/common/hbm3_dev_model.sv` |
| Formal harness and SymbiYosys script | `formal/` |
| Regression, bug injection, policy sweep | `scripts/` |
| Verification plan (requirements to checks to coverage) | [docs/verification_plan.md](docs/verification_plan.md) |
| Results and bugs found | [docs/results.md](docs/results.md) |

The scoreboard is the interesting part: the controller reorders on purpose, so
a replay-in-order model would give false failures. The reference model tracks
the order in which writes commit on the HBM bus and accepts a read only if its
data is a legal value (floor, program order, ceiling). See section 2 of the
verification plan.

## Quick start

Tools: Verilator 5.x, Python 3.10+, `pip install cocotb==1.9.2 pyuvm==3.0.0`,
Yosys, and SymbiYosys for formal. The OSS CAD Suite has everything except the
Python packages.

```bash
make lint                          # RTL lint, warnings are errors
make test TEST=test_hazard SEED=3  # one test (pyuvm on Verilator)
make regress                       # seeded regression + merged coverage
make mutants                       # bug injection: every mutant must be caught
make sweep                         # FCFS vs FR-FCFS vs aging, same traffic
make formal                        # bounded proof + formal mutants
make synth                         # generic gate-level synthesis
UVM_HOME=<uvm-core>/src make uvm-check   # elaborate the SV UVM bench with slang
```

On a Mac, use the Dockerfile (same tool versions as the results) or Homebrew:
see [docs/macos.md](docs/macos.md).

SystemVerilog UVM on a commercial simulator:

```bash
cd tb/uvm && make SIM=questa TEST=mc_random_test SEED=7
```

Tests: `smoke`, `random`, `stream`, `row_conflict`, `bank_parallel`,
`turnaround`, `hazard`, `backpressure`, `starvation`, `refresh_idle`, `demo` (prefix
`test_` in pyuvm, `mc_..._test` in SV UVM). Add `TB_POLICY=0|1|2` (pyuvm) or
`+POLICY=` (UVM) to force a policy, and `WAVES=1` to dump waveforms, or
`TRACE_JSON=<abs path>` to record a trace for the demo.

## Repository layout

```
rtl/        controller RTL (files.f lists compile order)
tb/common/  DUT harness + HBM device model (shared by both benches)
tb/sva/     assertion modules and macros
tb/uvm/     SystemVerilog UVM bench
tb/pyuvm/   pyuvm/cocotb bench (Verilator)
formal/     SymbiYosys harness
scripts/    regression, mutants, policy sweep, UVM elaboration check
syn/        Yosys synthesis script and stats
docs/       architecture, timing, verification plan, results, macOS setup
demo/       interactive trace viewer and recorded traces
results/    generated reports
```

## Honest limitations

- The SystemVerilog UVM bench is elaboration-checked (slang, Accellera UVM
  2020) but was not simulated here, because no UVM-capable simulator was
  available. The regression numbers come from the pyuvm bench, which has the
  same architecture, checks and coverage model and runs against the same DUT
  harness and assertions.
- Formal is bounded (40 cycles) on a reduced configuration, not a full
  unbounded proof.
- Timing values are HBM3-representative, not from a vendor datasheet (see
  `docs/timing.md`). The HBM model is behavioural and covers no PHY, training,
  ECC or multiple pseudo-channels.
