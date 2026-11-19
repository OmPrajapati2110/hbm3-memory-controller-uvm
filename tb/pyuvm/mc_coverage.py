"""Functional coverage.

A small covergroup library (coverpoints with named bins, crosses) plus the
coverage model for the controller. Each test writes its hit counts to JSON;
scripts/regress.py merges them across the regression and reports holes.
The same model is written as SystemVerilog covergroups in
tb/uvm/mc_coverage.svh.
"""
import collections
import json
import os

from pyuvm import uvm_component

from mc_common import (NC, NB, NUM_BG, QDEPTH, line_key, bg_of, ROW_ACT,
                       ROW_PRE, ROW_REF, COL_RD, COL_WR)
from mc_scoreboard import _Imp


class Coverpoint:
    def __init__(self, name, bins):
        self.name = name
        self.bins = list(bins)
        self.hits = collections.Counter()

    def sample(self, b):
        if b in self.bins:
            self.hits[b] += 1

    def covered(self):
        return sum(1 for b in self.bins if self.hits[b] > 0)

    def to_dict(self):
        return {str(b): self.hits[b] for b in self.bins}


class Cross(Coverpoint):
    def __init__(self, name, *axes):
        import itertools
        super().__init__(name, itertools.product(*axes))


class CoverageModel:
    def __init__(self):
        self.points = {}

    def add(self, cp):
        self.points[cp.name] = cp
        return cp

    def report(self):
        tot = sum(len(p.bins) for p in self.points.values())
        hit = sum(p.covered() for p in self.points.values())
        return hit, tot

    def to_dict(self):
        return {n: p.to_dict() for n, p in self.points.items()}


def _occ_bin(n):
    if n == 0:
        return "empty"
    if n <= 4:
        return "1-4"
    if n <= 8:
        return "5-8"
    if n < QDEPTH:
        return "9-15"
    return "full"


def _lat_bin(l):
    for lim, name in ((30, "<30"), (60, "30-59"), (120, "60-119"), (250, "120-249"),
                      (500, "250-499")):
        if l < lim:
            return name
    return ">=500"


class McCoverage(uvm_component):
    def build_phase(self):
        self.req_imp = _Imp("req_imp", self, self.write_req)
        self.rsp_imp = _Imp("rsp_imp", self, self.write_rsp)
        self.cmd_imp = _Imp("cmd_imp", self, self.write_cmd)
        m = self.m = CoverageModel()
        kinds = ("RD", "WR")
        self.cp_client_kind = m.add(Cross("req_client_x_kind", range(NC), kinds))
        self.cp_bank = m.add(Coverpoint("req_bank", range(NB)))
        self.cp_bg_kind = m.add(Cross("req_bg_x_kind", range(NUM_BG), kinds))
        self.cp_hazard = m.add(Coverpoint("req_same_line_hazard",
                                          ("RAW", "WAR", "WAW", "RAR", "RAW_cross_client")))
        self.cp_outcome = m.add(Cross("access_outcome_x_kind",
                                      ("hit", "miss", "conflict"), kinds))
        self.cp_policy_outcome = m.add(Cross("policy_x_outcome", (0, 1, 2),
                                             ("hit", "miss", "conflict")))
        self.cp_col_seq = m.add(Cross("col_to_col", ("RD", "WR"), ("RD", "WR"),
                                      ("same_bg", "diff_bg")))
        self.cp_dual = m.add(Coverpoint("dual_bus_issue", ("ACT+RD", "ACT+WR", "PRE+RD", "PRE+WR")))
        self.cp_occ = m.add(Coverpoint("queue_occupancy", ("empty", "1-4", "5-8", "9-15", "full")))
        self.cp_events = m.add(Coverpoint("scheduler_events",
                                          ("refresh", "refresh_under_load", "aging_override",
                                           "credit_stall", "prea_before_ref")))
        self.cp_lat = m.add(Cross("latency_x_kind",
                                  ("<30", "30-59", "60-119", "120-249", "250-499", ">=500"), kinds))
        self.cp_ooo = m.add(Coverpoint("response_order", ("in_order", "out_of_order")))
        # state
        self.open_row = {}
        self.first_col_after_act = set()
        self.prev_col = None
        self.recent = collections.deque(maxlen=64)     # (line, we, client)
        self.outstanding = {}
        self.last_rsp_seq = [-1] * NC
        self.req_seq = 0
        self.prev_ref_pending = 0
        self.conflict_bank = set()

    # ------------------------------------------------------------------ req
    def write_req(self, r):
        k = "WR" if r.we else "RD"
        self.cp_client_kind.sample((r.client, k))
        ba, _, _ = line_key(r.addr)
        self.cp_bank.sample(ba)
        self.cp_bg_kind.sample((bg_of(ba), k))
        line = line_key(r.addr)
        for (l2, we2, c2) in self.recent:
            if l2 == line:
                pair = ("W" if we2 else "R") + "A" + ("W" if r.we else "R")
                name = {"WAR": "RAW", "RAW": "WAR", "WAW": "WAW", "RAR": "RAR"}[pair]
                self.cp_hazard.sample(name)
                if name == "RAW" and c2 != r.client:
                    self.cp_hazard.sample("RAW_cross_client")
                break
        self.recent.appendleft((line, r.we, r.client))
        self.req_seq += 1
        self.outstanding[(r.client, r.id)] = (self.req_seq, r.cycle, r.we)

    def write_rsp(self, p):
        ent = self.outstanding.pop((p.client, p.id), None)
        if ent is None:
            return
        seq, t0, we = ent
        self.sample_latency(p.cycle - t0, we)
        self.cp_ooo.sample("in_order" if seq > self.last_rsp_seq[p.client] else "out_of_order")
        self.last_rsp_seq[p.client] = max(seq, self.last_rsp_seq[p.client])

    # ------------------------------------------------------------------ cmd
    def write_cmd(self, c):
        self.cp_occ.sample(_occ_bin(c.q_count))
        if c.aging:
            self.cp_events.sample("aging_override")
        if c.credit_stall:
            self.cp_events.sample("credit_stall")
        if c.ref_pending and c.row_cmd == ROW_PRE:
            self.cp_events.sample("prea_before_ref")
        if c.row_cmd == ROW_REF:
            self.cp_events.sample("refresh")
            if c.q_count:
                self.cp_events.sample("refresh_under_load")
        if c.row_cmd == ROW_ACT:
            self.open_row[c.row_ba] = c.row_addr
            self.first_col_after_act.add(c.row_ba)
        elif c.row_cmd == ROW_PRE:
            self.open_row.pop(c.row_ba, None)
            if not c.ref_pending:
                self.conflict_bank.add(c.row_ba)
        if c.col_cmd in (COL_RD, COL_WR):
            k = "RD" if c.col_cmd == COL_RD else "WR"
            if c.col_ba in self.first_col_after_act:
                self.first_col_after_act.discard(c.col_ba)
                outcome = "conflict" if c.col_ba in self.conflict_bank else "miss"
                self.conflict_bank.discard(c.col_ba)
            else:
                outcome = "hit"
            self.cp_outcome.sample((outcome, k))
            self.cp_policy_outcome.sample((c.policy, outcome))
            if self.prev_col is not None:
                pk, pbg = self.prev_col
                self.cp_col_seq.sample((pk, k, "same_bg" if pbg == bg_of(c.col_ba) else "diff_bg"))
            self.prev_col = (k, bg_of(c.col_ba))
            if c.row_cmd in (ROW_ACT, ROW_PRE):
                self.cp_dual.sample(("ACT" if c.row_cmd == ROW_ACT else "PRE") + "+" + k)

    def sample_latency(self, lat, we):
        self.cp_lat.sample((_lat_bin(lat), "WR" if we else "RD"))

    def report_phase(self):
        hit, tot = self.m.report()
        self.logger.info(f"FUNCTIONAL COVERAGE {hit}/{tot} bins = {100.0 * hit / tot:.1f}%")
        out = os.environ.get("COV_JSON")
        if out:
            with open(out, "w") as f:
                json.dump(self.m.to_dict(), f)
