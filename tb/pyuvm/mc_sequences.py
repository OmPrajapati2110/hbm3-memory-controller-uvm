"""Stimulus: per-client sequences, each a constrained-random generator for one
traffic shape. Tests combine them into virtual sequences across the four
client sequencers."""
import random

from pyuvm import uvm_sequence

from mc_agents import MemReqItem
from mc_common import make_addr, NB, NUM_BG, BG_W, ROW_W, COL_W


def ba_split(ba):
    return ba & (NUM_BG - 1), ba >> BG_W


class ClientSeq(uvm_sequence):
    """Base: n requests, each shaped by gen(). Subclasses override gen()."""

    def __init__(self, name="client_seq", n=100, rd_pct=50, idle_max=0, **kw):
        super().__init__(name)
        self.n = n
        self.rd_pct = rd_pct
        self.idle_max = idle_max
        self.kw = kw
        self.i = 0

    def pick_we(self):
        return 0 if random.randrange(100) < self.rd_pct else 1

    def gen(self, it):
        raise NotImplementedError

    async def body(self):
        for self.i in range(self.n):
            it = MemReqItem("req")
            await self.start_item(it)
            it.we = self.pick_we()
            self.gen(it)
            it.idle = random.randint(0, self.idle_max) if self.idle_max else 0
            it.randomize_data()
            await self.finish_item(it)


class RandomSeq(ClientSeq):
    """Uniform over a window of rows: mix of hits, misses and conflicts."""

    def gen(self, it):
        rows = self.kw.get("rows", 8)
        row0 = self.kw.get("row0", 0)
        it.addr = make_addr(random.randrange(NUM_BG), random.randrange(NB // NUM_BG),
                            row0 + random.randrange(rows), random.randrange(1 << COL_W))


class StreamSeq(ClientSeq):
    """Sequential 32B lines: long row-hit runs, row crossings change bank group."""

    def gen(self, it):
        base = self.kw.get("base", 0)
        it.addr = base + (self.i << 5)


class ConflictSeq(ClientSeq):
    """Same bank(s), different rows: worst case PRE/ACT churn (tRAS, tRP, tRC)."""

    def gen(self, it):
        banks = self.kw.get("banks", [0])
        ba = random.choice(banks)
        bg, bk = ba_split(ba)
        it.addr = make_addr(bg, bk, random.randrange(1 << ROW_W), random.randrange(1 << COL_W))


class BankSpreadSeq(ClientSeq):
    """New row in a different bank every request: ACT storm for tRRD_S/L, tFAW."""

    def gen(self, it):
        ba = (self.i * self.kw.get("stride", 5) + self.kw.get("offset", 0)) % NB
        bg, bk = ba_split(ba)
        it.addr = make_addr(bg, bk, random.randrange(1 << ROW_W), random.randrange(1 << COL_W))


class TurnaroundSeq(ClientSeq):
    """Alternating reads and writes over a few open rows, biased to one bank
    group: exercises tCCD_L vs tCCD_S, tWTR_S/L and tRTW."""

    def pick_we(self):
        return self.i % 2 if random.random() < 0.7 else random.getrandbits(1)

    def gen(self, it):
        same_bg = random.random() < self.kw.get("same_bg_pct", 0.5)
        bg = 0 if same_bg else random.randrange(NUM_BG)
        it.addr = make_addr(bg, random.randrange(NB // NUM_BG), self.kw.get("row", 3),
                            random.randrange(1 << COL_W))


class HazardSeq(ClientSeq):
    """Tiny shared address pool: RAW / WAR / WAW races within and across clients."""

    def gen(self, it):
        pool = self.kw["pool"]
        it.addr = random.choice(pool)


class FixedSeq(ClientSeq):
    """Directed list of (we, addr)."""

    def __init__(self, name="fixed_seq", ops=(), **kw):
        super().__init__(name, n=len(ops), **kw)
        self.ops = list(ops)

    def pick_we(self):
        return self.ops[self.i][0]

    def gen(self, it):
        it.addr = self.ops[self.i][1]


class HitStreamSeq(ClientSeq):
    """Aggressor: endless reads to one open row, so FR-FCFS keeps preferring it."""

    def pick_we(self):
        return 0

    def gen(self, it):
        it.addr = make_addr(0, 0, self.kw.get("row", 1), random.randrange(1 << COL_W))
