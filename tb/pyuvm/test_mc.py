"""Environment and tests for the HBM3 memory controller (pyuvm on cocotb).

Run one test:   make -C tb/pyuvm TESTCASE=test_random RANDOM_SEED=7
Regression:     python3 scripts/regress.py
"""
import os
import random

import cocotb
from cocotb.triggers import ClockCycles
from pyuvm import uvm_env, uvm_test, ConfigDB, uvm_root

from mc_agents import ClientAgent, BusAgent
from mc_bfm import HarnessBfm
from mc_common import (NC, TestKnobs, Timing, make_addr, NB, NUM_BG, POLICY_NAMES,
                       POL_FCFS, POL_FRFCFS, POL_FRFCFS_A)
from mc_coverage import McCoverage
from mc_scoreboard import McScoreboard
from mc_trace import McTrace
import mc_sequences as S


def env_int(name, default):
    v = os.environ.get(name)
    return int(v) if v not in (None, "") else default


# =============================================================================
# Environment
# =============================================================================
class McEnv(uvm_env):
    def build_phase(self):
        self.agents = []
        for c in range(NC):
            ConfigDB().set(self, f"client{c}*", "client", c)
            self.agents.append(ClientAgent(f"client{c}", self))
        self.bus = BusAgent("bus", self)
        self.sb = McScoreboard("sb", self)
        self.cov = McCoverage("cov", self)
        self.trace = McTrace("trace", self) if os.environ.get("TRACE_JSON") else None

    def connect_phase(self):
        mon = self.bus.monitor
        mon.req_ap.connect(self.sb.req_imp.analysis_export)
        mon.rsp_ap.connect(self.sb.rsp_imp.analysis_export)
        mon.cmd_ap.connect(self.sb.cmd_imp.analysis_export)
        mon.req_ap.connect(self.cov.req_imp.analysis_export)
        mon.rsp_ap.connect(self.cov.rsp_imp.analysis_export)
        mon.cmd_ap.connect(self.cov.cmd_imp.analysis_export)
        if self.trace:
            mon.req_ap.connect(self.trace.req_imp.analysis_export)
            mon.rsp_ap.connect(self.trace.rsp_imp.analysis_export)
            mon.cmd_ap.connect(self.trace.cmd_imp.analysis_export)

    @property
    def seqrs(self):
        return [a.seqr for a in self.agents]


# =============================================================================
# Base test
# =============================================================================
class BaseTest(uvm_test):
    default_policy = POL_FRFCFS_A
    n = 300

    def build_phase(self):
        t = Timing()
        t.T_REFI = env_int("TB_T_REFI", t.T_REFI)
        ConfigDB().set(None, "*", "timing", t)
        self.knobs = TestKnobs(policy=env_int("TB_POLICY", self.default_policy))
        self.n = env_int("TB_N", self.n)
        self.configure(self.knobs)
        self.env = McEnv("env", self)

    def configure(self, knobs):
        pass

    async def stimulus(self, seqrs):
        raise NotImplementedError

    async def run_phase(self):
        self.raise_objection()
        bfm = HarnessBfm()
        await bfm.start(self.knobs)
        self.logger.info(f"seed={cocotb.RANDOM_SEED} policy={POLICY_NAMES[self.knobs.policy]} "
                         f"n/client={self.n}")
        await self.stimulus(self.env.seqrs)
        # drain: every accepted request must complete
        sb = self.env.sb
        waited = 0
        while sb.outstanding and waited < self.knobs.drain_timeout:
            await ClockCycles(bfm.dut.clk, 100)
            waited += 100
        await ClockCycles(bfm.dut.clk, 50)
        self.drop_objection()

    def final_phase(self):
        sb = self.env.sb
        if sb.errors:
            raise AssertionError(f"{len(sb.errors)} scoreboard error(s); first: {sb.errors[0]}")
        if sum(sb.n_req) == 0:
            raise AssertionError("no traffic was generated")


def mc_test(cls):
    """Register a uvm_test class as a cocotb test under the class's own name
    (so `make TESTCASE=<name>` works)."""
    async def _run(dut):
        await uvm_root().run_test(cls)
    _run.__name__ = _run.__qualname__ = cls.__name__
    _run.__doc__ = cls.__doc__
    return cocotb.test()(_run)


async def run_parallel(pairs):
    """Start (sequence, sequencer) pairs concurrently and wait for all."""
    tasks = [cocotb.start_soon(seq.start(seqr)) for seq, seqr in pairs]
    for t in tasks:
        await t


# =============================================================================
# Tests
# =============================================================================
@mc_test
class test_smoke(BaseTest):
    """Directed: write 64 lines across two rows, read them back, then overwrite."""
    default_policy = POL_FRFCFS

    async def stimulus(self, seqrs):
        lines = [make_addr(bg, 0, r, col) for r in (5, 6) for bg in (0, 1) for col in range(16)]
        ops = [(1, a) for a in lines] + [(0, a) for a in lines] + \
              [(1, a) for a in lines[:8]] + [(0, a) for a in lines[:8]]
        await S.FixedSeq("smoke", ops=ops).start(seqrs[0])
        # unloaded latency probes: one miss, then hits to the now-open row
        clk = HarnessBfm().dut.clk
        for we, col in ((0, 20), (0, 21), (1, 22), (0, 22)):
            await ClockCycles(clk, 60)
            await S.FixedSeq("probe", ops=[(we, make_addr(3, 2, 9, col))]).start(seqrs[0])


@mc_test
class test_random(BaseTest):
    """All four clients, random reads/writes over a window of rows in every bank."""

    def configure(self, k):
        if "TB_POLICY" not in os.environ:
            k.policy = random.choice([POL_FCFS, POL_FRFCFS, POL_FRFCFS_A])

    async def stimulus(self, seqrs):
        await run_parallel([(S.RandomSeq(f"rand{c}", n=self.n, rd_pct=random.randint(30, 70),
                                         idle_max=random.choice([0, 0, 3, 10]),
                                         rows=random.choice([2, 4, 16])), seqrs[c])
                            for c in range(NC)])


@mc_test
class test_stream(BaseTest):
    """Sequential streams per client: row-hit heavy, bandwidth at tCCD."""

    async def stimulus(self, seqrs):
        await run_parallel([(S.StreamSeq(f"stream{c}", n=self.n, rd_pct=60,
                                         base=make_addr(c % 4, 0, 100 + 7 * c, 0)), seqrs[c])
                            for c in range(NC)])


@mc_test
class test_row_conflict(BaseTest):
    """Every client hammers two banks with random rows: PRE/ACT churn."""

    async def stimulus(self, seqrs):
        await run_parallel([(S.ConflictSeq(f"conf{c}", n=self.n // 2, banks=[0, 5]), seqrs[c])
                            for c in range(NC)])


@mc_test
class test_bank_parallel(BaseTest):
    """ACT storm over all 16 banks: tRRD_S/L and the four-activate window."""

    async def stimulus(self, seqrs):
        await run_parallel([(S.BankSpreadSeq(f"spread{c}", n=self.n, offset=4 * c,
                                             stride=random.choice([1, 3, 5])), seqrs[c])
                            for c in range(NC)])


@mc_test
class test_turnaround(BaseTest):
    """Read/write interleaving within and across bank groups."""

    async def stimulus(self, seqrs):
        await run_parallel([(S.TurnaroundSeq(f"ta{c}", n=self.n, row=3 + (c & 1),
                                             same_bg_pct=0.7), seqrs[c])
                            for c in range(NC)])


@mc_test
class test_hazard(BaseTest):
    """Eight shared lines in two banks, all clients: RAW/WAR/WAW ordering races."""

    async def stimulus(self, seqrs):
        pool = [make_addr(bg, 1, row, col) for bg in (0, 2) for row in (7, 8) for col in (0, 1)]
        await run_parallel([(S.HazardSeq(f"haz{c}", n=self.n, rd_pct=50, pool=pool,
                                         idle_max=random.choice([0, 2])), seqrs[c])
                            for c in range(NC)])


@mc_test
class test_backpressure(BaseTest):
    """Clients rarely accept responses: credit stalls, full queues, full FIFOs.
    Run with +NO_STARVE_CHK (stalled clients can block requests indefinitely)."""

    def configure(self, k):
        k.rsp_ready_pct = 15

    async def stimulus(self, seqrs):
        await run_parallel([(S.RandomSeq(f"bp{c}", n=self.n // 2, rd_pct=70, rows=4), seqrs[c])
                            for c in range(NC)])


@mc_test
class test_starvation(BaseTest):
    """Clients 0-2 stream reads to bank 0 row 1; client 3 needs bank 0 row 2.
    With aging the victim must finish within the bound asserted in the RTL SVA
    (and checked here). Run with TB_POLICY=1 to see FR-FCFS starve it."""

    def configure(self, k):
        # refresh off: otherwise each refresh closes the hot row and rescues
        # the victim every tREFI, hiding true starvation under FR-FCFS
        k.refresh_en = 0

    async def stimulus(self, seqrs):
        # the victim needs another row of the hot bank, and also writes to an
        # idle bank (a write competing with a read stream for the data bus)
        victim = S.FixedSeq("victim", ops=[(1, make_addr(1, 1, 3, c)) for c in range(2)] +
                            [(0, make_addr(0, 0, 2, c)) for c in range(4)] +
                            [(1, make_addr(0, 0, 2, 5))],
                            idle_max=0)
        aggressors = [(S.HitStreamSeq(f"aggr{c}", n=self.n * 2, row=1), seqrs[c]) for c in range(3)]
        tasks = [cocotb.start_soon(s.start(q)) for s, q in aggressors]
        await ClockCycles(HarnessBfm().dut.clk, 200)
        await victim.start(seqrs[3])
        for t in tasks:
            await t

    def check_phase(self):
        lat = self.env.sb.lat[3]
        self.logger.info(f"victim latencies: {lat}")
        bound = 256 + 200   # AGE_THRESH + time to close the row and serve the victim
        if self.knobs.policy != POL_FRFCFS and lat and max(lat) > bound:
            raise AssertionError(f"victim waited {max(lat)} cycles under aging policy")


@mc_test
class test_refresh_idle(BaseTest):
    """Bursts separated by idle gaps longer than tREFI: refresh with closed and
    open banks, plus refresh arriving mid-burst."""

    async def stimulus(self, seqrs):
        bfm = HarnessBfm()
        for burst in range(4):
            await run_parallel([(S.RandomSeq(f"rb{burst}_{c}", n=self.n // 8, rows=2), seqrs[c])
                                for c in range(NC)])
            await ClockCycles(bfm.dut.clk, random.randint(200, 1500))


@mc_test
class test_demo(BaseTest):
    """Short mixed workload used for the visual model in demo/: three clients
    streaming row hits to bank 0 row 1, and a fourth client that needs row 2
    of the same bank (the starvation victim) and then mixes traffic across
    other banks."""

    def configure(self, k):
        k.policy = env_int("TB_POLICY", POL_FRFCFS_A)

    async def stimulus(self, seqrs):
        clk = HarnessBfm().dut.clk
        hot = [(S.HitStreamSeq(f"hot{c}", n=120, row=1), seqrs[c]) for c in range(3)]
        tasks = [cocotb.start_soon(s.start(q)) for s, q in hot]
        await ClockCycles(clk, 60)
        victim = S.FixedSeq("victim", ops=[(0, make_addr(0, 0, 2, c)) for c in range(2)] +
                            [(1, make_addr(0, 0, 2, 9))])
        await victim.start(seqrs[3])
        await S.ConflictSeq("mix3", n=20, banks=[5, 6, 10], rd_pct=60).start(seqrs[3])
        for t in tasks:
            await t
