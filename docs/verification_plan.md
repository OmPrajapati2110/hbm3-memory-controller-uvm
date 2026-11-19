# Verification plan: `hbm3_mc`

## 1. Scope and strategy

**Design under test:** `rtl/hbm3_mc.sv` and its submodules (see
`docs/architecture.md`).

**Out of scope:** HBM PHY, training, ECC, multiple pseudo-channels and power
states. The HBM device is a behavioural model.

**Approach.** Four independent layers, so that no single checker is trusted
alone:

| Layer | What it proves | Where |
|---|---|---|
| Black-box protocol/timing SVA | Every command on the HBM buses is legal (22 JEDEC-style rules), whatever the controller's internal timers believe | `tb/sva/hbm3_timing_checker.sv` |
| White-box SVA | Internal invariants: age-matrix order, one-hot picks, credit bound, read-return alignment, starvation bound, valid/ready rules | `tb/sva/hbm3_mc_sva.sv` (bound into the DUT) |
| Reference model + scoreboard | End-to-end data integrity and ordering, with legal reordering allowed | `tb/uvm/mc_scoreboard.svh`, `tb/pyuvm/mc_scoreboard.py` |
| Formal (SymbiYosys) | All assertions hold for every input sequence up to 40 cycles on a reduced configuration | `formal/` |

The timing checker uses absolute timestamps while the RTL uses countdown timers.
Because the two are implemented differently, one mistake cannot hide in both.

**Two benches, one environment architecture.**
- `tb/uvm`: SystemVerilog UVM (agents, sequencers, virtual sequencer,
  constrained-random items, scoreboard with analysis imps, covergroups). It
  targets Questa, VCS, Xcelium or Riviera and is elaboration-checked with slang
  against the Accellera UVM library.
- `tb/pyuvm`: the same architecture in pyuvm on cocotb and Verilator, which is
  free to run. This is the bench the regression, coverage and bug-injection
  numbers come from.

Both benches share the DUT harness, the HBM device model and every assertion.

## 2. Reference model

Arrival-order replay is wrong for this design: requests to different lines are
reordered on purpose, and requests from different clients to the same line race
through round-robin admission. The model therefore records the order in which
writes **commit** (WR commands on the bus) and accepts any read value that is
legal:

- **Floor**: the last write to the line committed before the read was accepted.
  An older value means a lost write.
- **Program order**: if the same client wrote the line earlier, the read must see
  that write or a later one.
- **Ceiling**: only writes committed before the read's RD could have issued
  (response cycle − RL − 1).

Every WR on the bus must match exactly one outstanding client write to that line
with identical data. That catches corrupted data, wrong addresses and duplicated
or lost writes. Every request must receive exactly one response of the right
type, and nothing may remain outstanding at the end of the test.

## 3. Requirements, checks and coverage

| ID | Requirement | Check(s) | Coverage | Tests |
|---|---|---|---|---|
| F1 | Reads return the most recent legal write data | SB `legal_values` | `access_outcome_x_kind`, `latency_x_kind` | all |
| F2 | Writes reach the device exactly once, correct line and data | SB `commit_write`, end-of-test pending check | `req_bg_x_kind`, `req_bank` | all |
| F3 | Same-line RAW / WAR / WAW order is kept per client | SB program-order rule | `req_same_line_hazard` (RAW, WAR, WAW, RAR, cross-client RAW) | hazard, random |
| F4 | One response per request, matching ID and type | SB outstanding map, end-of-test check | `response_order` (in order / out of order) | all |
| F5 | Valid/ready: request payload held by the environment, response payload held by the DUT | `m_req_hold`, `m_req_aligned`, `a_rsp_hold` | `c_req_backpressure`, `c_rsp_backpressure` | backpressure |
| F6 | Response FIFOs never overflow; a slow client stalls only itself | `a_credit_bound` | `scheduler_events.credit_stall` | backpressure |
| T1 | ACT only to a closed bank, PRE only to an open bank, RD/WR only to an open bank | `a_act_to_closed`, `a_pre_to_open`, `a_col_to_open`, device model | `dual_bus_issue` | all |
| T2 | Same-bank timing tRCD, tRP, tRAS, tRC, tRTP, tWR | `a_tRCD`, `a_tRP`, `a_tRAS`, `a_tRC`, `a_tRTP`, `a_tWR` | `c_*_min` covers (exactly at the limit) | row_conflict, random |
| T3 | Bank-group timing tRRD_S/L, tFAW | `a_tRRD_S`, `a_tRRD_L`, `a_tFAW` | `c_tRRD_S_min`, `c_tRRD_L_min`, `c_tFAW_min` | bank_parallel |
| T4 | Column timing tCCD_S/L, tWTR_S/L, tRTW | `a_tCCD_S`, `a_tCCD_L`, `a_tWTR_S`, `a_tWTR_L`, `a_tRTW` | `col_to_col` cross (RD/WR x RD/WR x same/diff bank group), `c_*_min` | turnaround, stream |
| T5 | No PRE and column command to the same bank in one cycle | `a_no_pre_col_same_bank` | `c_dual_bus` | all |
| R1 | REF only with every bank closed and tRP met; ACT waits tRFC | `a_ref_all_closed`, `a_ref_tRP`, `a_ref_tRFC`, `a_tRFC` | `scheduler_events.refresh`, `refresh_under_load`, `prea_before_ref` | refresh_idle, all |
| R2 | Refresh interval never exceeds tREFI plus a bounded postponement | `a_refresh_interval` | `c_ref` | all |
| S1 | Scheduler picks at most one valid entry per bus per cycle | `a_col_pick_onehot`, `a_row_pick_onehot`, `a_*_pick_valid` | `c_row_and_col_pick` | all |
| S2 | Age matrix is a strict total order over live entries | `a_age_total_order` | `queue_occupancy` (empty to full) | all |
| S3 | Allocation never overwrites a live entry | `a_alloc_free_slot` | `c_queue_full` | all |
| S4 | Read data returns exactly when the completion pipeline expects it | `a_rd_return_aligned` | | all |
| P1 | With FCFS or FR-FCFS+aging, no request waits longer than a fixed bound | `a_no_starvation`, starvation test latency check | `scheduler_events.aging_override`, `policy_x_outcome` | starvation |
| P2 | All three policies are functionally correct | every check above, per policy | `policy_x_outcome` | policy sweep in regression |

## 4. Stimulus

| Sequence | Shape | Targets |
|---|---|---|
| random | uniform over a window of rows in all banks, random read/write mix and idle gaps | general, all outcomes |
| stream | sequential lines per client | row hits, tCCD, bank-group interleave |
| conflict | random rows in two banks | tRAS, tRP, tRC, PRE/ACT churn |
| bank_spread | new row in a different bank every request | tRRD_S/L, tFAW |
| turnaround | alternating RD/WR, biased to one bank group | tWTR_S/L, tRTW, tCCD_L |
| hazard | eight shared lines, all clients | RAW/WAR/WAW, same-line ordering |
| hit_stream + victim | three clients stream hits, one client needs another row | starvation, aging |
| directed | fixed lists (smoke, unloaded latency probes) | bring-up, latency floor |

Knobs: policy, refresh enable, response-ready probability (backpressure), idle
gaps, requests per client. Every run is reproducible from its seed.

## 5. Coverage closure criteria

- 100% of functional coverage bins, or each remaining hole explained.
- 100% of assertion cover properties, including every timing rule hit exactly
  at its limit (proves both full-speed scheduling and that a one-cycle-early
  bug would be seen).
- Zero failures across the seeded regression and the per-policy sweep.
- Every injected bug detected (section 6).
- Formal BMC passes on the reduced configuration, and every formal mutant fails.

## 6. Checking the checkers (bug injection)

Nine realistic bugs can be compiled into the RTL with `MUT_*` defines. The
testbench is only trusted if it catches every one:

| Mutant | Bug | Expected detector |
|---|---|---|
| MUT_TRCD | column command right after ACT | `a_tRCD` |
| MUT_TCCD_L | same-bank-group column spacing too short | `a_tCCD_L` |
| MUT_TWTR_L | same-bank-group write-to-read too short | `a_tWTR_L` |
| MUT_TFAW | four-activate window ignored | `a_tFAW` |
| MUT_REF_EARLY | REF with banks still open | `a_ref_all_closed`, device model |
| MUT_HAZARD | same-line ordering check removed | scoreboard program-order rule |
| MUT_CREDIT | off-by-one response credit | `a_credit_bound` |
| MUT_WDATA | write data corrupted on one column | scoreboard write match |
| MUT_NO_AGING | aging override removed | `a_no_starvation`, starvation test |

## 7. Sign-off status

See `docs/results.md` for the current numbers. `scripts/regress.py` and
`scripts/run_mutants.py` regenerate them.
