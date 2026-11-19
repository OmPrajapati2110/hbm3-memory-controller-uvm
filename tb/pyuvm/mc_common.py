"""Shared configuration, address map and transaction types for the pyuvm bench.

Timing values mirror the HDL parameters. The Makefile passes the same values to
Verilator with -G, and the bench reads them back from the DUT at start-up so
the two can never drift apart.
"""
from dataclasses import dataclass, field
import random

# ---- geometry (must match hbm3_mc parameters) -------------------------------
NC = 4
ID_W = 4
DATA_W = 256
OFF_W = 5
COL_W = 5
BG_W = 2
BK_W = 2
ROW_W = 14
BA_W = BG_W + BK_W
NB = 1 << BA_W
NUM_BG = 1 << BG_W
ADDR_W = OFF_W + COL_W + BG_W + BK_W + ROW_W
QDEPTH = 16
RSP_DEPTH = 8

ROW_NOP, ROW_ACT, ROW_PRE, ROW_REF = 0, 1, 2, 3
COL_NOP, COL_RD, COL_WR = 0, 1, 2
ROW_NAMES = {ROW_NOP: "NOP", ROW_ACT: "ACT", ROW_PRE: "PRE", ROW_REF: "REF"}
COL_NAMES = {COL_NOP: "NOP", COL_RD: "RD", COL_WR: "WR"}

POL_FCFS, POL_FRFCFS, POL_FRFCFS_A = 0, 1, 2
POLICY_NAMES = {0: "FCFS", 1: "FR-FCFS", 2: "FR-FCFS+aging"}


@dataclass
class Timing:
    """Timing profile in controller clocks; filled from DUT parameters."""
    RL: int = 17
    WL: int = 6
    BURST: int = 2
    T_RCD: int = 14
    T_RP: int = 14
    T_RAS: int = 28
    T_RC: int = 42
    T_REFI: int = 3900
    T_RFC: int = 160


def make_addr(bg: int, bank: int, row: int, col: int) -> int:
    return (((((row << BK_W) | bank) << BG_W | bg) << COL_W) | col) << OFF_W


def decode(addr: int):
    """Return (ba, row, col) with ba = {bank, bg} as on the command bus."""
    col = (addr >> OFF_W) & ((1 << COL_W) - 1)
    ba = (addr >> (OFF_W + COL_W)) & ((1 << BA_W) - 1)
    row = (addr >> (OFF_W + COL_W + BA_W)) & ((1 << ROW_W) - 1)
    return ba, row, col


def line_key(addr: int):
    return decode(addr)


def bg_of(ba: int) -> int:
    return ba & (NUM_BG - 1)


def rand_data() -> int:
    return random.getrandbits(DATA_W)


@dataclass
class ReqObs:
    """A request accepted by the DUT (observed on the client interface)."""
    client: int
    we: int
    addr: int
    wdata: int
    id: int
    cycle: int


@dataclass
class RspObs:
    """A response delivered to a client."""
    client: int
    we: int
    id: int
    rdata: int
    cycle: int


@dataclass
class CmdObs:
    """One cycle of activity on the HBM row and/or column command bus."""
    cycle: int
    row_cmd: int = ROW_NOP
    row_ba: int = 0
    row_addr: int = 0
    col_cmd: int = COL_NOP
    col_ba: int = 0
    col_addr: int = 0
    wdata: int = 0
    q_count: int = 0
    aging: int = 0
    ref_pending: int = 0
    credit_stall: int = 0
    policy: int = 0


@dataclass
class TestKnobs:
    """Runtime knobs a test sets in the ConfigDB."""
    policy: int = POL_FRFCFS_A
    refresh_en: int = 1
    rsp_ready_pct: int = 100          # chance a client accepts a response
    idle_pct: list = field(default_factory=lambda: [0] * NC)
    drain_timeout: int = 200_000
