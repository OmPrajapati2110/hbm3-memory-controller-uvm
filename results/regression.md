# Regression report

- Runs: **122**, passed **122**, failed **0**
- Requests checked end to end: **124,295** over 1,218,383 cycles
- Functional coverage: **100.0%** (88/88 bins)
- Assertion cover properties hit: **100.0%** (24/24)
- Wall time: 153.9 s

## Per test

| Test | Runs | Pass | Mean bus util | Mean latency | p99 latency |
|---|---|---|---|---|---|
| test_backpressure | 10 | 10 | 0.177 | 199 | 518 |
| test_bank_parallel | 10 | 10 | 0.153 | 223 | 512 |
| test_hazard | 23 | 23 | 0.104 | 339 | 1272 |
| test_random | 20 | 20 | 0.135 | 378 | 1227 |
| test_refresh_idle | 10 | 10 | 0.125 | 146 | 452 |
| test_row_conflict | 13 | 13 | 0.029 | 1110 | 1664 |
| test_smoke | 5 | 5 | 0.196 | 57 | 86 |
| test_starvation | 5 | 5 | 0.245 | 130 | 234 |
| test_stream | 13 | 13 | 0.284 | 139 | 588 |
| test_turnaround | 13 | 13 | 0.148 | 265 | 1202 |

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
| `u_dut.u_mc_sva.c_aging_override` | 411,456 |
| `u_dut.u_mc_sva.c_credit_stall` | 166 |
| `u_dut.u_mc_sva.c_queue_full` | 1,041,908 |
| `u_dut.u_mc_sva.c_ref_under_load` | 37,353 |
| `u_dut.u_mc_sva.c_row_and_col_pick` | 18,683 |
| `u_dut.u_mc_sva.g_cli__BRA__*__KET__.c_req_backpressure` | 4,350,493 |
| `u_dut.u_mc_sva.g_cli__BRA__*__KET__.c_rsp_backpressure` | 34,760 |
| `u_tchk.c_dual_bus` | 18,683 |
| `u_tchk.c_ref` | 1,253 |
| `u_tchk.c_tCCD_L_min` | 47,629 |
| `u_tchk.c_tCCD_S_min` | 53,281 |
| `u_tchk.c_tFAW_min` | 13,691 |
| `u_tchk.c_tRAS_min` | 9,841 |
| `u_tchk.c_tRCD_min` | 31,967 |
| `u_tchk.c_tRC_min` | 6,501 |
| `u_tchk.c_tRFC_min` | 1,220 |
| `u_tchk.c_tRP_min` | 31,266 |
| `u_tchk.c_tRRD_L_min` | 4,505 |
| `u_tchk.c_tRRD_S_min` | 13,195 |
| `u_tchk.c_tRTP_min` | 6,681 |
| `u_tchk.c_tRTW_min` | 8,435 |
| `u_tchk.c_tWR_min` | 17,196 |
| `u_tchk.c_tWTR_L_min` | 5,887 |
| `u_tchk.c_tWTR_S_min` | 5,702 |
