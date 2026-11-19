#!/usr/bin/env python3
"""Bug injection ("mutation") campaign: proves the testbench catches real bugs.

Each mutant is an `ifdef MUT_*` in the RTL that reproduces a realistic design
mistake. For every mutant the script builds the DUT, runs the whole test list
with one seed, and records which tests failed and which checker fired first.
A mutant that no test catches is a verification hole.

  python3 scripts/run_mutants.py [-j 4]
"""
import argparse
import collections
import concurrent.futures as cf
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import regress  # noqa: E402

MUTANTS = {
    "MUT_TRCD":      "Column command allowed right after ACT (tRCD ignored)",
    "MUT_TCCD_L":    "Same-bank-group column spacing uses tCCD_S instead of tCCD_L",
    "MUT_TWTR_L":    "Same-bank-group write-to-read turnaround (tWTR_L) ignored",
    "MUT_TFAW":      "Four-activate window (tFAW) not enforced",
    "MUT_REF_EARLY": "REF issued before every bank is precharged",
    "MUT_HAZARD":    "Same-address ordering check removed (younger request may pass older)",
    "MUT_CREDIT":    "Response credit check off by one (can overflow response FIFO)",
    "MUT_WDATA":     "Write data bit flipped on the last column of a row",
    "MUT_NO_AGING":  "Aging override removed from FR-FCFS+aging policy",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-j", type=int, default=os.cpu_count() or 2)
    ap.add_argument("--mutants", nargs="*")
    args = ap.parse_args()
    mutants = args.mutants or list(MUTANTS)

    print("building mutants ...", flush=True)
    with cf.ThreadPoolExecutor(min(args.j, 4)) as ex:
        list(ex.map(regress.build, mutants))

    jobs = [(m, t) for m in mutants for t in regress.TESTS]
    print(f"running {len(jobs)} simulations ...", flush=True)
    res = collections.defaultdict(list)
    with cf.ThreadPoolExecutor(args.j) as ex:
        futs = {ex.submit(regress.run_one, t, 1, regress.TESTS[t][1], f"mut_{m}", mutant=m): (m, t)
                for m, t in jobs}
        for f in cf.as_completed(futs):
            m, t = futs[f]
            r = f.result()
            res[m].append(r)

    rows = []
    killed = 0
    for m in mutants:
        fails = sorted((r for r in res[m] if not r["passed"]), key=lambda r: r["test"])
        ok = bool(fails)
        killed += ok
        rows.append({"mutant": m, "bug": MUTANTS[m], "killed": ok,
                     "failing_tests": [r["test"] for r in fails],
                     "first_detection": fails[0]["reason"] if fails else "",
                     "repro": fails[0]["repro"] if fails else ""})
        print(f"{'KILLED ' if ok else 'SURVIVED'} {m:14s} {len(fails):2d}/{len(res[m])} tests fail  "
              f"{fails[0]['reason'][:110] if fails else ''}", flush=True)

    os.makedirs(regress.OUT, exist_ok=True)
    json.dump(rows, open(os.path.join(regress.OUT, "mutants.json"), "w"), indent=1)
    L = ["# Bug-injection results", "",
         f"**{killed}/{len(mutants)} injected bugs detected.**", "",
         "| Mutant | Injected bug | Detected by | Tests failing | First failure message |",
         "|---|---|---|---|---|"]
    for r in rows:
        det = "scoreboard" if "SVA" not in r["first_detection"] and r["killed"] else "SVA"
        if "[DEV]" in r["first_detection"]:
            det = "device model"
        if "AssertionError" in r["first_detection"] and "victim" in r["first_detection"]:
            det = "test check"
        L.append(f"| `{r['mutant']}` | {r['bug']} | {det if r['killed'] else '**MISSED**'} | "
                 f"{len(r['failing_tests'])} | {r['first_detection'].replace('|', '/')} |")
    open(os.path.join(regress.OUT, "mutants.md"), "w").write("\n".join(L) + "\n")
    sys.exit(0 if killed == len(mutants) else 1)


if __name__ == "__main__":
    main()
