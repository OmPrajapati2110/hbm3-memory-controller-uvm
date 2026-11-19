# Bug-injection results

**9/9 injected bugs detected.**

| Mutant | Injected bug | Detected by | Tests failing | First failure message |
|---|---|---|---|---|
| `MUT_TRCD` | Column command allowed right after ACT (tRCD ignored) | SVA | 10 | SVA FAIL hbm3_mc_harness.u_tchk.a_tRCD |
| `MUT_TCCD_L` | Same-bank-group column spacing uses tCCD_S instead of tCCD_L | SVA | 9 | SVA FAIL hbm3_mc_harness.u_tchk.a_tCCD_L |
| `MUT_TWTR_L` | Same-bank-group write-to-read turnaround (tWTR_L) ignored | SVA | 8 | SVA FAIL hbm3_mc_harness.u_tchk.a_tWTR_L |
| `MUT_TFAW` | Four-activate window (tFAW) not enforced | SVA | 6 | SVA FAIL hbm3_mc_harness.u_tchk.a_tFAW |
| `MUT_REF_EARLY` | REF issued before every bank is precharged | SVA | 8 | SVA FAIL hbm3_mc_harness.u_tchk.a_ref_tRP |
| `MUT_HAZARD` | Same-address ordering check removed (younger request may pass older) | scoreboard | 3 | ERROR ..c/tb/pyuvm/mc_scoreboard.py(123) [uvm_test_top.env.sb]: client 1 id 6 addr 0x1d800: read overtook the same client's earlier write to this line |
| `MUT_CREDIT` | Response credit check off by one (can overflow response FIFO) | SVA | 1 | SVA FAIL hbm3_mc_harness.u_dut.u_mc_sva.g_cli[0].a_credit_bound |
| `MUT_WDATA` | Write data bit flipped on the last column of a row | scoreboard | 7 | ERROR ..c/tb/pyuvm/mc_scoreboard.py(123) [uvm_test_top.env.sb]: WR at cycle 131 to line (15, 2, 31) carries data no client has outstanding for that line (data corruption or wrong address) |
| `MUT_NO_AGING` | Aging override removed from FR-FCFS+aging policy | SVA | 1 | SVA FAIL hbm3_mc_harness.u_dut.u_mc_sva.g_age_i[15].a_no_starvation |
