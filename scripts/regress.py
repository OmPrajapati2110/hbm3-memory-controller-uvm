#!/usr/bin/env python3
"""Seeded regression for the HBM3 memory controller (cocotb + pyuvm, Verilator).

  python3 scripts/regress.py                 # full regression (default seeds)
  python3 scripts/regress.py --seeds 3 -j 4  # quicker
  python3 scripts/regress.py --tests test_hazard --seeds 20

Each run gets its own results file, scoreboard JSON, functional coverage JSON
and Verilator assertion-coverage file. At the end the script merges coverage,
lists coverage holes, and writes results/regression.json and
results/regression.md. Failing runs print the exact command to reproduce.
"""
import argparse
import collections
import concurrent.futures as cf
import json
import os
import re
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
TB = os.path.join(ROOT, "tb", "pyuvm")
OUT = os.path.join(ROOT, "results")

# test -> (relative seed weight, extra env)
TESTS = {
    "test_smoke":         (1, {}),
    "test_random":        (4, {}),
    "test_stream":        (2, {}),
    "test_row_conflict":  (2, {}),
    "test_bank_parallel": (2, {}),
    "test_turnaround":    (2, {}),
    "test_hazard":        (4, {}),
    "test_backpressure":  (2, {"PLUSARGS": "+NO_STARVE_CHK"}),
    "test_starvation":    (1, {}),
    "test_refresh_idle":  (2, {}),
}
POLICIES = {"test_random": None}   # test_random picks a policy per seed itself


def build(mutant=None):
    env = dict(os.environ)
    args = ["make", "-s", "-C", TB, os.path.join(ROOT, "build",
            f"sim_{mutant or 'clean'}", "Vtop")]
    if mutant:
        args.append(f"MUTANT={mutant}")
    r = subprocess.run(args, env=env, capture_output=True, text=True)
    if r.returncode:
        print(r.stdout[-3000:], r.stderr[-3000:])
        raise SystemExit(f"build failed ({mutant or 'clean'})")


def run_one(test, seed, extra_env, tag, mutant=None, policy=None, n=None):
    d = os.path.join(OUT, "runs", tag)
    os.makedirs(d, exist_ok=True)
    stem = f"{test}_s{seed}" + (f"_p{policy}" if policy is not None else "")
    env = dict(os.environ)
    env.update(extra_env)
    env["RESULT_JSON"] = os.path.join(d, stem + ".sb.json")
    env["COV_JSON"] = os.path.join(d, stem + ".cov.json")
    env["COCOTB_RESULTS_FILE"] = os.path.join(d, stem + ".xml")
    if policy is not None:
        env["TB_POLICY"] = str(policy)
    if n is not None:
        env["TB_N"] = str(n)
    # each simulation runs in its own directory (Verilator writes coverage.dat to cwd)
    wd = os.path.join(d, stem)
    os.makedirs(wd, exist_ok=True)
    plus = env.get("PLUSARGS", "") + f" +verilator+seed+{seed}"
    cmd = ["make", "-s", "-f", os.path.join(TB, "Makefile"), f"TESTCASE={test}",
           f"RANDOM_SEED={seed}", f"PLUSARGS={plus.strip()}"]
    if mutant:
        cmd.append(f"MUTANT={mutant}")
    t0 = time.time()
    r = subprocess.run(cmd, env=env, cwd=wd, capture_output=True, text=True, timeout=1800)
    log = r.stdout + r.stderr
    with open(os.path.join(d, stem + ".log"), "w") as f:
        f.write(log)
    xml = env["COCOTB_RESULTS_FILE"]
    passed = os.path.exists(xml) and "<failure" not in open(xml).read() and r.returncode == 0
    reason = ""
    if not passed:
        m = re.search(r"(SVA FAIL[^\n]*|\[DEV\][^\n]*|AssertionError: [^\n]*|"
                      r"scoreboard error[^\n]*|ERROR[^\n]*sb\]: [^\n]*)", log)
        reason = m.group(1).strip() if m else "simulation failed (see log)"
        reason = re.sub(r"\s+", " ", reason)[:240]
    sb = {}
    if os.path.exists(env["RESULT_JSON"]):
        sb = json.load(open(env["RESULT_JSON"]))["summary"]
    repro = (f"make -C tb/pyuvm TESTCASE={test} RANDOM_SEED={seed}"
             + (f" TB_POLICY={policy}" if policy is not None else "")
             + (f" MUTANT={mutant}" if mutant else "")
             + (f" PLUSARGS={extra_env['PLUSARGS']}" if "PLUSARGS" in extra_env else ""))
    return {"test": test, "seed": seed, "policy": policy, "passed": passed,
            "reason": reason, "secs": round(time.time() - t0, 1), "sb": sb,
            "cov": env["COV_JSON"], "dat": os.path.join(wd, "coverage.dat"), "repro": repro}


def merge_func_cov(paths):
    merged = collections.defaultdict(lambda: collections.Counter())
    for p in paths:
        if not os.path.exists(p):
            continue
        for cp, bins in json.load(open(p)).items():
            for b, n in bins.items():
                merged[cp][b] += n
    return merged


def merge_sva_cov(paths):
    hits = collections.Counter()
    pat = re.compile(r"\x01o\x02([^\x01]+).*?\x01h\x02([^']+)' (\d+)")
    for p in paths:
        if not os.path.exists(p):
            continue
        for line in open(p, encoding="latin-1"):
            m = pat.search(line)
            if m:
                hier = m.group(2).replace(".hbm3_mc_harness.", "")
                hits[hier] += int(m.group(3))
    return hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=5, help="base seeds per weight unit")
    ap.add_argument("-j", type=int, default=os.cpu_count() or 2)
    ap.add_argument("--tests", nargs="*")
    ap.add_argument("--seed0", type=int, default=1)
    args = ap.parse_args()

    tests = args.tests or list(TESTS)
    os.makedirs(OUT, exist_ok=True)
    print("building ...", flush=True)
    build()
    jobs = []
    for t in tests:
        weight, extra = TESTS[t]
        for k in range(weight * args.seeds):
            jobs.append((t, args.seed0 + k, extra))
    # policy sweep for the directed traffic shapes (each policy must be correct)
    for t in ("test_stream", "test_row_conflict", "test_hazard", "test_turnaround"):
        if t in tests:
            for pol in (0, 1, 2):
                jobs.append((t, 100 + pol, TESTS[t][1], pol))

    print(f"running {len(jobs)} simulations on {args.j} workers ...", flush=True)
    results = []
    t0 = time.time()
    with cf.ThreadPoolExecutor(args.j) as ex:
        futs = [ex.submit(run_one, j[0], j[1], j[2], "regress",
                          policy=(j[3] if len(j) > 3 else None)) for j in jobs]
        for f in cf.as_completed(futs):
            r = f.result()
            results.append(r)
            mark = "PASS" if r["passed"] else "FAIL"
            pol = f" pol={r['policy']}" if r["policy"] is not None else ""
            print(f"  {mark} {r['test']:20s} seed={r['seed']:<4d}{pol} {r['secs']:6.1f}s "
                  f"{r['reason']}", flush=True)
    wall = time.time() - t0

    func = merge_func_cov([r["cov"] for r in results])
    sva = merge_sva_cov([r["dat"] for r in results])
    tot_bins = sum(len(b) for b in func.values())
    hit_bins = sum(1 for b in func.values() for n in b.values() if n)
    holes = {cp: [k for k, n in b.items() if not n] for cp, b in func.items()}
    holes = {k: v for k, v in holes.items() if v}
    sva_tot = len(sva)
    sva_hit = sum(1 for n in sva.values() if n)
    n_pass = sum(r["passed"] for r in results)
    reqs = sum(r["sb"].get("requests", 0) for r in results)
    cycles = sum(r["sb"].get("cycles", 0) for r in results)

    summary = {
        "runs": len(results), "passed": n_pass, "failed": len(results) - n_pass,
        "requests_checked": reqs, "cycles_simulated": cycles, "wall_s": round(wall, 1),
        "functional_coverage": {"hit": hit_bins, "total": tot_bins,
                                "pct": round(100.0 * hit_bins / max(1, tot_bins), 1)},
        "assertion_coverage": {"hit": sva_hit, "total": sva_tot,
                               "pct": round(100.0 * sva_hit / max(1, sva_tot), 1)},
        "holes": holes,
        "sva_cover_unhit": sorted(k for k, n in sva.items() if not n),
        "failures": [{"test": r["test"], "seed": r["seed"], "reason": r["reason"],
                      "repro": r["repro"]} for r in results if not r["passed"]],
    }
    json.dump({"summary": summary, "func_cov": func, "sva_cov": sva,
               "runs": [{k: r[k] for k in ("test", "seed", "policy", "passed", "reason",
                                             "secs", "sb")} for r in results]},
              open(os.path.join(OUT, "regression.json"), "w"), indent=1)
    write_md(summary, results, func, sva)
    print(json.dumps({k: summary[k] for k in ("runs", "passed", "failed", "requests_checked",
                                              "functional_coverage", "assertion_coverage")}))
    if holes:
        print("coverage holes:", json.dumps(holes))
    sys.exit(0 if n_pass == len(results) else 1)


def write_md(s, results, func, sva):
    L = ["# Regression report", "",
         f"- Runs: **{s['runs']}**, passed **{s['passed']}**, failed **{s['failed']}**",
         f"- Requests checked end to end: **{s['requests_checked']:,}** over "
         f"{s['cycles_simulated']:,} cycles",
         f"- Functional coverage: **{s['functional_coverage']['pct']}%** "
         f"({s['functional_coverage']['hit']}/{s['functional_coverage']['total']} bins)",
         f"- Assertion cover properties hit: **{s['assertion_coverage']['pct']}%** "
         f"({s['assertion_coverage']['hit']}/{s['assertion_coverage']['total']})",
         f"- Wall time: {s['wall_s']} s", ""]
    L += ["## Per test", "", "| Test | Runs | Pass | Mean bus util | Mean latency | p99 latency |",
          "|---|---|---|---|---|---|"]
    by = collections.defaultdict(list)
    for r in results:
        by[r["test"]].append(r)
    for t, rs in sorted(by.items()):
        sb = [r["sb"] for r in rs if r["sb"]]
        mu = sum(x["bus_util"] for x in sb) / max(1, len(sb))
        ml = sum(x["lat_mean"] for x in sb) / max(1, len(sb))
        p99 = max((x["lat_p99"] for x in sb), default=0)
        L.append(f"| {t} | {len(rs)} | {sum(r['passed'] for r in rs)} | {mu:.3f} | {ml:.0f} | {p99} |")
    L += ["", "## Functional coverage by coverpoint", "", "| Coverpoint | Bins hit |", "|---|---|"]
    for cp, b in func.items():
        L.append(f"| {cp} | {sum(1 for n in b.values() if n)}/{len(b)} |")
    if s["holes"]:
        L += ["", "### Holes", ""]
        for cp, hs in s["holes"].items():
            L.append(f"- {cp}: {', '.join(hs)}")
    L += ["", "## Assertion cover properties", "", "| Cover | Hits |", "|---|---|"]
    for k, n in sorted(sva.items()):
        L.append(f"| `{k}` | {n:,} |")
    if s["failures"]:
        L += ["", "## Failures", ""]
        for f in s["failures"]:
            L.append(f"- {f['test']} seed {f['seed']}: {f['reason']}  \n  `{f['repro']}`")
    open(os.path.join(OUT, "regression.md"), "w").write("\n".join(L) + "\n")


if __name__ == "__main__":
    main()
