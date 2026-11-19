"""Bus functional model for the hbm3_mc_harness top level.

The harness exposes the four client ports as packed vectors, so one BFM owns
all pin wiggling (like a virtual interface in SV UVM). Agents talk to it via
queues:

  * drive  : ClientDriver -> send_req()   (returns when the DUT accepts)
  * observe: BFM -> req/rsp/cmd queues -> monitors -> analysis ports

Timing discipline: inputs are written just after the rising edge, everything is
sampled at the falling edge, when all outputs have settled for the cycle.
A valid&ready seen at the falling edge of cycle N is the transfer that
completes at the rising edge that ends cycle N.
"""
import random

import cocotb
from cocotb.clock import Clock
from cocotb.queue import Queue
from cocotb.triggers import FallingEdge, RisingEdge, Event, ClockCycles

from mc_common import (NC, ID_W, DATA_W, ADDR_W, ReqObs, RspObs, CmdObs,
                       ROW_NOP, COL_NOP, TestKnobs, Timing)


def _get_slice(val: int, idx: int, width: int) -> int:
    return (val >> (idx * width)) & ((1 << width) - 1)


class _ClientSlot:
    def __init__(self):
        self.item = None          # (we, addr, wdata, id)
        self.event = None
        self.idle = 0


class HarnessBfm:
    _inst = None

    def __new__(cls, *a, **k):
        if cls._inst is None:
            cls._inst = super().__new__(cls)
            cls._inst._init_done = False
        return cls._inst

    def __init__(self, dut=None):
        if self._init_done:
            return
        self._init_done = True
        self.dut = dut if dut is not None else cocotb.top
        self.cycle = 0
        self.knobs = TestKnobs()
        self.timing = Timing()
        self.slots = [_ClientSlot() for _ in range(NC)]
        self.req_q = [Queue() for _ in range(NC)]      # driver -> bfm
        # One ordered stream of observations ("req" | "rsp" | "cmd", obj) so
        # subscribers see events in exact cycle order.
        self.mon_q = Queue()
        self.free_ids = [list(range(1 << ID_W)) for _ in range(NC)]
        self.id_event = [Event() for _ in range(NC)]
        self.rsp_ready = [1] * NC
        self.started = False

    # ------------------------------------------------------------------ setup
    def read_timing(self):
        d = self.dut
        t = self.timing
        for name in ("RL", "WL", "BURST", "T_RCD", "T_RP", "T_RAS", "T_RC",
                     "T_REFI", "T_RFC"):
            h = getattr(d, name, None)
            if h is not None:
                try:
                    setattr(t, name, int(h.value))
                except Exception:  # parameter not visible on this simulator
                    pass

    async def start(self, knobs: TestKnobs):
        self.knobs = knobs
        d = self.dut
        cocotb.start_soon(Clock(d.clk, 1, units="ns").start())
        d.rst_n.value = 0
        d.cfg_policy.value = knobs.policy
        d.cfg_refresh_en.value = knobs.refresh_en
        d.req_valid.value = 0
        d.req_we.value = 0
        d.req_addr.value = 0
        d.req_wdata.value = 0
        d.req_id.value = 0
        d.rsp_ready.value = 0
        await ClockCycles(d.clk, 5)
        await RisingEdge(d.clk)
        d.rst_n.value = 1
        self.read_timing()
        self.started = True
        cocotb.start_soon(self._loop())

    # --------------------------------------------------------------- driving
    async def alloc_id(self, c: int) -> int:
        while not self.free_ids[c]:
            self.id_event[c].clear()
            await self.id_event[c].wait()
        return self.free_ids[c].pop(random.randrange(len(self.free_ids[c])))

    def release_id(self, c: int, i: int):
        self.free_ids[c].append(i)
        self.id_event[c].set()

    async def send_req(self, c: int, we: int, addr: int, wdata: int, rid: int,
                       idle: int = 0):
        ev = Event()
        await self.req_q[c].put((we, addr, wdata, rid, idle, ev))
        await ev.wait()

    # ------------------------------------------------------------ main loop
    async def _loop(self):
        d = self.dut
        knobs = self.knobs
        while True:
            # ---------------- drive (just after the rising edge) ----------
            v = we = addr = wdata = rid = 0
            for c, s in enumerate(self.slots):
                if s.item is None and s.idle == 0 and not self.req_q[c].empty():
                    we_, a_, wd_, id_, idle_, ev_ = self.req_q[c].get_nowait()
                    if idle_ > 0:
                        s.idle = idle_
                        s.pending = (we_, a_, wd_, id_, ev_)
                    else:
                        s.item, s.event = (we_, a_, wd_, id_), ev_
                elif s.item is None and s.idle > 0:
                    s.idle -= 1
                    if s.idle == 0:
                        we_, a_, wd_, id_, ev_ = s.pending
                        s.item, s.event = (we_, a_, wd_, id_), ev_
                if s.item is not None:
                    i_we, i_addr, i_wd, i_id = s.item
                    v |= 1 << c
                    we |= i_we << c
                    addr |= i_addr << (c * ADDR_W)
                    wdata |= i_wd << (c * DATA_W)
                    rid |= i_id << (c * ID_W)
                self.rsp_ready[c] = 1 if random.randrange(100) < knobs.rsp_ready_pct else 0
            d.req_valid.value = v
            d.req_we.value = we
            d.req_addr.value = addr
            d.req_wdata.value = wdata
            d.req_id.value = rid
            d.rsp_ready.value = sum(r << c for c, r in enumerate(self.rsp_ready))

            # ---------------- sample (falling edge) ------------------------
            await FallingEdge(d.clk)
            self.cycle += 1
            cyc = self.cycle
            rdy = int(d.req_ready.value)
            for c, s in enumerate(self.slots):
                if s.item is not None and (rdy >> c) & 1:
                    i_we, i_addr, i_wd, i_id = s.item
                    self.mon_q.put_nowait(("req", ReqObs(c, i_we, i_addr, i_wd, i_id, cyc)))
                    s.event.set()
                    s.item = None
            rv = int(d.rsp_valid.value)
            if rv:
                rwe = int(d.rsp_we.value)
                rids = int(d.rsp_id.value)
                rdata = int(d.rsp_rdata.value)
                for c in range(NC):
                    if (rv >> c) & 1 and self.rsp_ready[c]:
                        self.mon_q.put_nowait(("rsp", RspObs(
                            c, (rwe >> c) & 1, _get_slice(rids, c, ID_W),
                            _get_slice(rdata, c, DATA_W), cyc)))
            rc = int(d.row_cmd.value)
            cc = int(d.col_cmd.value)
            self.mon_q.put_nowait(("cmd", CmdObs(
                cycle=cyc, row_cmd=rc,
                row_ba=int(d.row_ba.value) if rc != ROW_NOP else 0,
                row_addr=int(d.row_addr.value) if rc != ROW_NOP else 0,
                col_cmd=cc,
                col_ba=int(d.col_ba.value) if cc != COL_NOP else 0,
                col_addr=int(d.col_addr.value) if cc != COL_NOP else 0,
                wdata=int(d.col_wdata.value) if cc == 2 else 0,
                q_count=int(d.dbg_q_count.value),
                aging=int(d.dbg_aging_override.value),
                ref_pending=int(d.dbg_ref_pending.value),
                credit_stall=int(d.dbg_credit_stall.value),
                policy=knobs.policy)))
            await RisingEdge(d.clk)
