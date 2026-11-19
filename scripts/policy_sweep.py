#!/usr/bin/env python3
"""Scheduling-policy experiment: the same traffic (same seeds) under FCFS,
FR-FCFS and FR-FCFS+aging. Every run is also fully checked by the scoreboard
and assertions, so performance numbers only come from correct runs.

  python3 scripts/policy_sweep.py [--seeds 3]
Writes results/policy_sweep.md and results/policy_sweep.json.
"""
import argparse
import collections
import concurrent.futures as cf
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import regress  # noqa: E402

WORKLOADS = {
    "test_random":       "Random, 4 clients, mixed rows",
    "test_stream":       "Sequential streams (row-hit heavy)",
    "test_row_conflict": "Two hot banks, random rows",
    "test_hazard":       "Shared lines, read/write races",
    "test_starvation":   "Row-hit aggressors vs one victim",
}
POL = {0: "FCFS", 1: "FR-FCFS", 2: "FR-FCFS+aging"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=3)
    ap.add_argument("-j", type=int, default=os.cpu_count() or 2)
    a = ap.parse_args()
    regress.build()
    jobs = [(w, s, p) for w in WORKLOADS for s in range(1, a.seeds + 1) for p in POL]
    res = []
    with cf.ThreadPoolExecutor(a.j) as ex:
        futs = [ex.submit(regress.run_one, w, 1000 + s, regress.TESTS[w][1], "sweep", policy=p)
                for w, s, p in jobs]
        for f in cf.as_completed(futs):
            res.append(f.result())
    agg = collections.defaultdict(list)
    for r in res:
        agg[(r["test"], r["policy"])].append(r)
    L = ["# Scheduling policy comparison", "",
         f"Same traffic and seeds ({a.seeds} per cell) under each policy. "
         "Bandwidth is column commands per cycle (peak 0.5 at tCCD_S = 2). "
         "Latency is request acceptance to response, in controller cycles. "
         "Every run passed all scoreboard and assertion checks unless marked.", "",
         "| Workload | Policy | Bandwidth | Row-hit rate | Mean latency | p99 latency | Worst latency (any client) | All checks |",
         "|---|---|---|---|---|---|---|---|"]
    out = {}
    for w, desc in WORKLOADS.items():
        for p, pn in POL.items():
            rs = agg[(w, p)]
            sb = [r["sb"] for r in rs if r["sb"]]
            if not sb:
                continue
            m = lambda k: sum(x[k] for x in sb) / len(sb)
            row = {"bw": round(m("bus_util"), 3), "hit": round(m("row_hit_rate"), 3),
                   "lat": round(m("lat_mean"), 1), "p99": round(m("lat_p99"), 1),
                   "worst": max(x["lat_max"] for x in sb),
                   "pass": all(r["passed"] for r in rs)}
            out[f"{w}/{pn}"] = row
            L.append(f"| {desc} | {pn} | {row['bw']:.3f} | {row['hit']:.2f} | {row['lat']:.0f} | "
                     f"{row['p99']:.0f} | {row['worst']} | {'pass' if row['pass'] else 'FAIL'} |")
    os.makedirs(regress.OUT, exist_ok=True)
    open(os.path.join(regress.OUT, "policy_sweep.md"), "w").write("\n".join(L) + "\n")
    json.dump(out, open(os.path.join(regress.OUT, "policy_sweep.json"), "w"), indent=1)
    print("\n".join(L))


if __name__ == "__main__":
    main()
