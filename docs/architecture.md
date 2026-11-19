# Microarchitecture: `hbm3_mc`

An HBM3-style pseudo-channel memory controller. Four clients issue 32-byte reads
and writes; the controller schedules them onto HBM's separate row and column
command buses while obeying JEDEC-style timing, keeps same-address ordering,
refreshes the device, and returns responses with flow control.

```
           client 0..3 (valid/ready, 4-bit transaction IDs)
                 |  |  |  |
          +------v--v--v--v-------+
          | request FIFOs (x4)    |  depth CF_DEPTH
          +----------+------------+
                     | round-robin admission (1 request / cycle)
          +----------v------------+      +---------------------+
          | command queue (16)    |<---->| age matrix (16x16)  |
          | ba,row,col,we,id,data |      | oldest-first select |
          | wait counter          |      +---------------------+
          +--+----------------+---+
             | hit / miss /   | same-line hazard check
             | conflict       |
   +---------v----+    +------v-------+    +-------------------+
   | column picker|    | row picker   |<---| refresh sequencer |
   | RD / WR      |    | ACT / PRE    |    | PRE all, REF      |
   +------+-------+    +------+-------+    +-------------------+
          |   per-bank timers (16) + rank timers (tRRD, tFAW, tCCD, tWTR, tRTW)
          v                   v
     column bus           row bus          ---> HBM pseudo-channel
          |
   +------v---------------------+
   | completion pipeline (RL+1) |<--- read data (RL cycles after RD)
   +------+---------------------+
          v
   response FIFOs (x4, depth RSP_DEPTH) ---> clients
```

## Interfaces

| Port group | Signals | Notes |
|---|---|---|
| Config | `cfg_policy[1:0]`, `cfg_refresh_en` | Static while traffic runs |
| Client request (x4) | `req_valid/ready/we/addr/wdata/id` | Valid must hold, payload stable, until ready. Address 32B aligned |
| Client response (x4) | `rsp_valid/ready/we/id/rdata` | Write ack (`rsp_we=1`) or read data. Held stable under backpressure |
| Row bus | `row_cmd` (NOP/ACT/PRE/REF), `row_ba`, `row_addr` | Registered outputs |
| Column bus | `col_cmd` (NOP/RD/WR), `col_ba`, `col_addr`, `col_wdata` | Registered outputs |
| Read return | `rd_valid`, `rd_data` | Exactly RL cycles after RD |
| Debug | `dbg_q_count`, `dbg_aging_override`, `dbg_ref_pending`, `dbg_credit_stall` | For coverage and waveforms |

Clients are flattened into packed vectors (client `c` uses bits `[c*W +: W]`).
That keeps the top level portable across Verilator, Yosys and commercial tools.

## Address map

```
 27        14 13  12 11  10 9      5 4      0
+------------+------+------+--------+--------+
|    row     | bank |  bg  |  col   | offset |
+------------+------+------+--------+--------+
```

One request moves one 32B burst (BL8 on a 32-bit pseudo-channel). Consecutive
lines stay in one 1 KB row, which gives long streams of row hits. The next row's
worth of addresses moves to the next bank group, so a sequential stream
alternates bank groups at row boundaries (tCCD_S instead of tCCD_L). On the bus,
`ba = {bank, bg}`.

## Command queue and age matrix

- 16 entries. Each holds bank, row, column, read/write, client, ID, write data,
  and a saturating wait counter.
- Allocation takes the lowest free slot. Ordering comes from an **age matrix**:
  `older[i][j] = 1` when entry `i` arrived before `j`. On allocation of `k`,
  `older[*][k]` copies the valid vector and `older[k][*]` clears. "Oldest among a
  request set" is one level of AND/OR logic (an entry wins if no older requester
  exists), so there is no priority encoder chain or timestamp comparator.
- **Same-line hazard**: an entry is blocked while an older entry targets the same
  bank, row and column. This one rule preserves RAW, WAR and WAW order for every
  client. Different lines may be freely reordered.

## Scheduler

Each cycle the scheduler may issue one column command and one row command, like
the split command buses of HBM.

Per entry, the bank state gives one of three outcomes:

| Outcome | Bank state | Next command |
|---|---|---|
| hit | open, same row | RD / WR |
| miss | closed | ACT |
| conflict | open, other row | PRE |

**Column pick**: oldest eligible hit whose bank has passed tRCD, whose bank group
and rank timers allow the RD or WR (tCCD_S/L, tWTR_S/L, tRTW), and whose client
has a free response credit.

**Row pick**: oldest eligible ACT (tRP, tRC, tRRD_S/L, tFAW, tRFC satisfied) or
PRE (tRAS, tRTP, tWR satisfied). A PRE is held back while other queued requests
still hit the open row, so FR-FCFS does not throw away row locality. The row bus
never precharges the bank the column bus is using in the same cycle.

**Policies** (`cfg_policy`):

| Value | Policy | Behaviour |
|---|---|---|
| 0 | FCFS | Only the oldest request may issue anything. Baseline. |
| 1 | FR-FCFS | Any ready request, row hits first, oldest first. Highest bandwidth, can starve a request behind a stream of hits. |
| 2 | FR-FCFS + aging | FR-FCFS, but once the oldest request has waited `AGE_THRESH` cycles its bank is reserved for it: younger hits to that bank are held and its PRE ignores hit protection. Other banks keep running at full rate. |

The first aging design forced FCFS whenever the oldest request crossed the
threshold. The regression showed this collapsed bandwidth under heavy load,
because the oldest request is almost always "old" when the queue is full. It
was replaced by the per-bank reservation above, which raised bandwidth on the
bank-parallel test from 0.036 to 0.150 column commands per cycle (about 4x)
with the same seed. See `docs/results.md`.

## Timers

All timers count down "cycles until legal". A command at cycle *t* that needs
spacing *N* loads *N-1*, and a timer keeps the max of its current value and any
new load, so several constraints share one counter.

| Block | Timer | Loaded by | Gates |
|---|---|---|---|
| `mc_bank` (x16) | act_w | PRE (tRP), ACT (tRC), REF (tRFC) | ACT |
| | pre_w | ACT (tRAS), RD (tRTP), WR (WL+BURST+tWR) | PRE |
| | col_w | ACT (tRCD) | RD/WR |
| `mc_rank_timer` | act_any / act_bg[4] | ACT (tRRD_S / tRRD_L) | ACT |
| | faw[4] | shift register of the last four ACTs | ACT |
| | col_any / col_bg[4] | RD/WR (tCCD_S / tCCD_L) | RD/WR |
| | wtr_any / wtr_bg[4] | WR (WL+BURST+tWTR_S/L) | RD |
| | rtw | RD (tRTW) | WR |

## Refresh

`mc_refresh` raises `ref_pending` every `T_REFI` cycles. The controller then
stops new ACT and column traffic, precharges every open bank as soon as its
tRAS/tRTP/tWR allow, and issues an all-bank REF once all banks are closed and
tRP has passed. Every bank then waits tRFC before the next ACT.

## Completion path and credits

Every RD or WR pushes `{client, id, we}` into an RL+1 deep shift pipeline. Read
data arrives exactly when the read's tag reaches the end (an assertion checks
this), and a write's acknowledgement travels the same pipeline. Because the
column bus issues at most one command per cycle, at most one completion arrives
per cycle and each response FIFO needs only one write port.

A column command is only issued if
`response FIFO occupancy + completions in flight < RSP_DEPTH` for its client. A
client that stops accepting responses therefore stalls only its own traffic and
can never overflow a FIFO or lose data.

## Bug-injection hooks

`ifdef MUT_*` blocks reproduce realistic design mistakes (wrong timing rule,
missing hazard check, off-by-one credit, data corruption, early refresh, missing
aging). They are never enabled in a normal build. `scripts/run_mutants.py`
builds each one and shows which check catches it.
