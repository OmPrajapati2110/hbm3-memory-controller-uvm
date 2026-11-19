# Timing profile

All values are in controller clock cycles and are module parameters, so the
simulation, formal and synthesis flows can each choose a profile.

The defaults are **HBM3-representative**. They keep the relationships that drive
scheduling decisions (for example tCCD_L > tCCD_S, tRRD_L > tRRD_S,
tRC = tRAS + tRP, and tFAW binding over 4 x tRRD_S). They are rounded and
normalised to a single controller clock. They are **not** copied from a specific
vendor datasheet: real HBM3 values depend on speed bin and vendor and should be
taken from the JEDEC JESD238 standard and the device datasheet before any claim
about a specific part.

| Parameter | Default | Meaning | Checked by |
|---|---|---|---|
| T_RCD | 14 | ACT to RD/WR, same bank | `a_tRCD` |
| T_RP | 14 | PRE to ACT, same bank | `a_tRP`, `a_ref_tRP` |
| T_RAS | 28 | ACT to PRE, same bank | `a_tRAS` |
| T_RC | 42 | ACT to ACT, same bank | `a_tRC` |
| T_RRD_S | 2 | ACT to ACT, different bank group | `a_tRRD_S` |
| T_RRD_L | 4 | ACT to ACT, same bank group | `a_tRRD_L` |
| T_FAW | 16 | window holding at most four ACTs | `a_tFAW` |
| T_CCD_S | 2 | column to column, different bank group | `a_tCCD_S` |
| T_CCD_L | 4 | column to column, same bank group | `a_tCCD_L` |
| T_WTR_S | 4 | end of write data to RD, different bank group | `a_tWTR_S` |
| T_WTR_L | 8 | end of write data to RD, same bank group | `a_tWTR_L` |
| T_RTP | 5 | RD to PRE | `a_tRTP` |
| T_WR | 14 | end of write data to PRE | `a_tWR` |
| RL / WL | 17 / 6 | read / write latency | `a_rd_return_aligned` |
| BURST | 2 | data-bus cycles per burst | (used in tWTR, tWR) |
| T_RTW | 15 | RD to WR bus turnaround | `a_tRTW` |
| T_RFC | 160 | REF to ACT | `a_tRFC`, `a_ref_tRFC` |
| T_REFI | 3900 | refresh interval (900 in regression) | `a_refresh_interval` |

Write-to-read and write-to-precharge are measured from the end of write data,
so the controller and checker use `WL + BURST + tWTR` and `WL + BURST + tWR`.

## Why tRRD_S is 2, not 4

The first profile used tRRD_S = 4 and tFAW = 16. Then four ACTs at tRRD_S
spacing already span 16 cycles, so tFAW can never be the binding constraint.
The bug-injection campaign found this: removing the tFAW check entirely
(`MUT_TFAW`) passed every test. With tRRD_S = 2, four ACTs fit in 8 cycles and
tFAW really limits ACT bursts, which is also how real HBM3 behaves. The mutant
is now caught by `a_tFAW` in 6 of 10 tests and by formal in 10 cycles.
