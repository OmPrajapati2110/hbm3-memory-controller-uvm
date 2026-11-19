# Regression report

- Runs: **122**, passed **122**, failed **0**
- Requests checked end to end: **124,280** over 1,200,726 cycles
- Functional coverage: **100.0%** (88/88 bins)
- Assertion cover properties hit: **100.0%** (24/24)
- Wall time: 152.3 s

## Per test

| Test | Runs | Pass | Mean bus util | Mean latency | p99 latency |
|---|---|---|---|---|---|
| test_backpressure | 10 | 10 | 0.180 | 196 | 679 |
| test_bank_parallel | 10 | 10 | 0.156 | 219 | 491 |
| test_hazard | 23 | 23 | 0.098 | 370 | 1272 |
| test_random | 20 | 20 | 0.137 | 375 | 1227 |
| test_refresh_idle | 10 | 10 | 0.137 | 144 | 437 |
| test_row_conflict | 13 | 13 | 0.032 | 983 | 1664 |
| test_smoke | 5 | 5 | 0.196 | 57 | 86 |
| test_starvation | 5 | 5 | 0.247 | 129 | 187 |
| test_stream | 13 | 13 | 0.288 | 137 | 588 |
| test_turnaround | 13 | 13 | 0.160 | 251 | 1202 |

## Functional coverage by coverpoint

| Coverpoint | Bins hit |
|---|---|
| req_client_x_kind | 8/8 |
| req_bank | 16/16 |
| req_bg_x_kind | 8/8 |
| req_same_line_hazard | 5/5 |
| access_outcome_x_kind | 6/6 |
| policy_x_outcome | 9/9 |
| col_to_col | 8/8 |
| dual_bus_issue | 4/4 |
| queue_occupancy | 5/5 |
| scheduler_events | 5/5 |
| latency_x_kind | 12/12 |
| response_order | 2/2 |

## Assertion cover properties

| Cover | Hits |
|---|---|
| `u_dut.u_mc_sva.c_aging_override` | 441,736 |
| `u_dut.u_mc_sva.c_credit_stall` | 165 |
| `u_dut.u_mc_sva.c_queue_full` | 1,025,005 |
| `u_dut.u_mc_sva.c_ref_under_load` | 37,261 |
| `u_dut.u_mc_sva.c_row_and_col_pick` | 19,276 |
| `u_dut.u_mc_sva.g_cli__BRA__*__KET__.c_req_backpressure` | 4,286,843 |
| `u_dut.u_mc_sva.g_cli__BRA__*__KET__.c_rsp_backpressure` | 34,313 |
| `u_tchk.c_dual_bus` | 19,276 |
| `u_tchk.c_ref` | 1,243 |
| `u_tchk.c_tCCD_L_min` | 47,405 |
| `u_tchk.c_tCCD_S_min` | 52,194 |
| `u_tchk.c_tFAW_min` | 13,825 |
| `u_tchk.c_tRAS_min` | 10,864 |
| `u_tchk.c_tRCD_min` | 34,100 |
| `u_tchk.c_tRC_min` | 7,296 |
| `u_tchk.c_tRFC_min` | 1,207 |
| `u_tchk.c_tRP_min` | 32,724 |
| `u_tchk.c_tRRD_L_min` | 4,506 |
| `u_tchk.c_tRRD_S_min` | 13,440 |
| `u_tchk.c_tRTP_min` | 6,196 |
| `u_tchk.c_tRTW_min` | 8,072 |
| `u_tchk.c_tWR_min` | 18,142 |
| `u_tchk.c_tWTR_L_min` | 5,707 |
| `u_tchk.c_tWTR_S_min` | 5,158 |
