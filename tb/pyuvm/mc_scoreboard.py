"""Reference model and scoreboard.

The controller is allowed to reorder requests to different lines and to
interleave racing requests from different clients to the same line, so a
"replay in arrival order" model would give false failures. Instead the model
tracks the order in which writes are *committed* (WR commands on the HBM bus)
and checks each read against the set of values it could legally return:

  * mandatory floor : the last write committed before the read was accepted
  * program order   : the client's own most recent earlier write to the line
  * upper bound     : writes committed before the read's RD could have issued
                      (response cycle - RL - 1)

Every write must appear on the bus exactly once, on the right line, with the
right data; every request must get exactly one response.
"""
import collections
import json
import os

from pyuvm import uvm_component, uvm_subscriber, ConfigDB

from mc_common import (line_key, ROW_ACT, ROW_PRE, COL_RD, COL_WR, NC,
                       ROW_NAMES, COL_NAMES)  # noqa: F401


class _Imp(uvm_subscriber):
    """Analysis imp that forwards to a bound method (uvm_analysis_imp_decl)."""

    def __init__(self, name, parent, fn):
        super().__init__(name, parent)
        self._fn = fn

    def write(self, t):
        self._fn(t)


class MemRefModel:
    def __init__(self, rl: int):
        self.rl = rl
        self.open_row = {}
        self.commits = collections.defaultdict(list)       # line -> [(cycle, data, key)]
        self.commit_idx = {}                                # (c,id,seq) -> (line, idx)
        self.pending_wr = collections.defaultdict(list)     # line -> [ (key, data) ]
        self.last_own_wr = {}                               # (client, line) -> key

    def on_cmd_row(self, cmd):
        if cmd.row_cmd == ROW_ACT:
            self.open_row[cmd.row_ba] = cmd.row_addr
        elif cmd.row_cmd == ROW_PRE:
            self.open_row.pop(cmd.row_ba, None)

    def col_line(self, cmd):
        row = self.open_row.get(cmd.col_ba)
        return None if row is None else (cmd.col_ba, row, cmd.col_addr)

    def commit_write(self, cmd):
        """Returns error string or None."""
        line = self.col_line(cmd)
        if line is None:
            return f"WR to closed bank {cmd.col_ba} at cycle {cmd.cycle}"
        for n, (key, data) in enumerate(self.pending_wr[line]):
            if data == cmd.wdata:
                del self.pending_wr[line][n]
                self.commits[line].append((cmd.cycle, data, key))
                self.commit_idx[key] = (line, len(self.commits[line]) - 1)
                return None
        return (f"WR at cycle {cmd.cycle} to line {line} carries data no client "
                f"has outstanding for that line (data corruption or wrong address)")

    def legal_values(self, line, t_acc, t_rsp, must_see_key):
        cl = self.commits.get(line, [])
        hi = t_rsp - self.rl - 1
        base = -1
        upper = -1
        for i, (cyc, _, _) in enumerate(cl):
            if cyc <= t_acc:
                base = i
            if cyc <= hi:
                upper = i
        if must_see_key is not None:
            if must_see_key not in self.commit_idx:
                return None, "read overtook the same client's earlier write to this line"
            _, k = self.commit_idx[must_see_key]
            if k > upper:
                return None, "read returned before the same client's earlier write committed"
            base = max(base, k)
        vals = set()
        if base == -1:
            vals.add(0)
            base = 0
        for i in range(base, upper + 1):
            vals.add(cl[i][1])
        return vals, None


class McScoreboard(uvm_component):
    def build_phase(self):
        self.req_imp = _Imp("req_imp", self, self.write_req)
        self.rsp_imp = _Imp("rsp_imp", self, self.write_rsp)
        self.cmd_imp = _Imp("cmd_imp", self, self.write_cmd)
        self.timing = ConfigDB().get(self, "", "timing")
        self.model = MemRefModel(self.timing.RL)
        self.outstanding = {}           # (client, id) -> (req, seq, must_see)
        self.seq = 0
        self.errors = []
        self.n_req = [0] * NC
        self.n_rsp = [0] * NC
        self.lat = [[] for _ in range(NC)]
        self.n_rd_cmd = 0
        self.n_wr_cmd = 0
        self.n_act = 0
        self.n_pre = 0
        self.n_ref = 0
        self.n_hit = 0
        self.fresh = set()             # banks whose next column access follows an ACT
        self.first_cycle = None
        self.last_cycle = 0

    # ------------------------------------------------------------------ util
    def err(self, msg):
        self.errors.append(msg)
        self.logger.error(msg)

    # ----------------------------------------------------------------- write
    def write_req(self, r):
        key = (r.client, r.id)
        if key in self.outstanding:
            self.err(f"client {r.client} reused outstanding id {r.id}")
        line = line_key(r.addr)
        self.seq += 1
        wkey = (r.client, r.id, self.seq)
        must_see = None
        if r.we:
            self.model.pending_wr[line].append((wkey, r.wdata))
            self.model.last_own_wr[(r.client, line)] = wkey
        else:
            must_see = self.model.last_own_wr.get((r.client, line))
        self.outstanding[key] = (r, wkey, must_see)
        self.n_req[r.client] += 1
        if self.first_cycle is None:
            self.first_cycle = r.cycle

    def write_cmd(self, c):
        if c.row_cmd:
            self.model.on_cmd_row(c)
            self.n_act += c.row_cmd == ROW_ACT
            self.n_pre += c.row_cmd == ROW_PRE
            self.n_ref += c.row_cmd == 3
            if c.row_cmd == ROW_ACT:
                self.fresh.add(c.row_ba)
        if c.col_cmd in (COL_RD, COL_WR):
            if c.col_ba in self.fresh:
                self.fresh.discard(c.col_ba)
            else:
                self.n_hit += 1
        if c.col_cmd == COL_WR:
            self.n_wr_cmd += 1
            e = self.model.commit_write(c)
            if e:
                self.err(e)
        elif c.col_cmd == COL_RD:
            self.n_rd_cmd += 1
            if self.model.col_line(c) is None:
                self.err(f"RD to closed bank {c.col_ba} at cycle {c.cycle}")

    def write_rsp(self, p):
        key = (p.client, p.id)
        if key not in self.outstanding:
            self.err(f"client {p.client}: response for id {p.id} with nothing outstanding")
            return
        req, wkey, must_see = self.outstanding.pop(key)
        self.n_rsp[p.client] += 1
        self.lat[p.client].append(p.cycle - req.cycle)
        self.last_cycle = p.cycle
        if p.we != req.we:
            self.err(f"client {p.client} id {p.id}: response type {p.we} for request type {req.we}")
            return
        line = line_key(req.addr)
        if req.we:
            if wkey not in self.model.commit_idx:
                self.err(f"client {p.client} id {p.id}: write acknowledged but never "
                         f"issued to HBM (line {line})")
            return
        vals, why = self.model.legal_values(line, req.cycle, p.cycle, must_see)
        if vals is None:
            self.err(f"client {p.client} id {p.id} addr 0x{req.addr:x}: {why}")
        elif p.rdata not in vals:
            self.err(f"client {p.client} id {p.id} addr 0x{req.addr:x}: read data "
                     f"0x{p.rdata:x} not among {len(vals)} legal value(s)")

    # ---------------------------------------------------------------- checks
    def check_phase(self):
        for key, (req, _, _) in self.outstanding.items():
            self.err(f"client {key[0]} id {key[1]} ({'WR' if req.we else 'RD'} "
                     f"0x{req.addr:x}, accepted cycle {req.cycle}) never completed")
        for line, lst in self.model.pending_wr.items():
            if lst:
                self.err(f"{len(lst)} write(s) to line {line} never reached HBM")

    def summary(self):
        cycles = max(1, self.last_cycle - (self.first_cycle or 0))
        all_lat = sorted(x for l in self.lat for x in l)
        def pct(p):
            return all_lat[min(len(all_lat) - 1, int(p * len(all_lat)))] if all_lat else 0
        col = self.n_rd_cmd + self.n_wr_cmd
        return {
            "requests": sum(self.n_req),
            "responses": sum(self.n_rsp),
            "errors": len(self.errors),
            "cycles": cycles,
            "col_cmds": col,
            "bus_util": round(col / cycles, 4),
            "act": self.n_act, "pre": self.n_pre, "ref": self.n_ref,
            "row_hit_rate": round(self.n_hit / col, 4) if col else 0,
            "lat_mean": round(sum(all_lat) / len(all_lat), 1) if all_lat else 0,
            "lat_p50": pct(0.5), "lat_p99": pct(0.99),
            "lat_max": all_lat[-1] if all_lat else 0,
            "lat_max_per_client": [max(l) if l else 0 for l in self.lat],
            "lat_mean_per_client": [round(sum(l) / len(l), 1) if l else 0 for l in self.lat],
        }

    def report_phase(self):
        s = self.summary()
        self.logger.info("SCOREBOARD " + json.dumps(s))
        out = os.environ.get("RESULT_JSON")
        if out:
            with open(out, "w") as f:
                json.dump({"summary": s, "errors": self.errors[:50]}, f, indent=1)
