"""Cycle-level trace recorder (enabled with TRACE_JSON=<file>).

Writes every accepted request, response and command-bus cycle to JSON so the
run can be replayed visually (see demo/)."""
import json
import os

from pyuvm import uvm_component

from mc_common import decode
from mc_scoreboard import _Imp


class McTrace(uvm_component):
    def build_phase(self):
        self.req_imp = _Imp("req_imp", self, self.on_req)
        self.rsp_imp = _Imp("rsp_imp", self, self.on_rsp)
        self.cmd_imp = _Imp("cmd_imp", self, self.on_cmd)
        self.ev = []
        self.max_cycle = int(os.environ.get("TRACE_MAX_CYCLES", "3000"))

    def on_req(self, r):
        if r.cycle <= self.max_cycle:
            ba, row, col = decode(r.addr)
            self.ev.append(["q", r.cycle, r.client, r.id, r.we, ba, row, col])

    def on_rsp(self, p):
        if p.cycle <= self.max_cycle:
            self.ev.append(["r", p.cycle, p.client, p.id, p.we])

    def on_cmd(self, c):
        if c.cycle > self.max_cycle:
            return
        if c.row_cmd or c.col_cmd:
            self.ev.append(["c", c.cycle, c.row_cmd, c.row_ba, c.row_addr,
                            c.col_cmd, c.col_ba, c.col_addr])
        self.ev.append(["s", c.cycle, c.q_count, c.aging, c.ref_pending, c.credit_stall])

    def report_phase(self):
        out = os.environ.get("TRACE_JSON")
        if out:
            with open(out, "w") as f:
                json.dump(self.ev, f, separators=(",", ":"))
