# Running on a Mac

There are two ways to run this on a Mac. Docker is the safer choice, because it
uses exactly the tool versions the published results came from (Ubuntu 24.04,
Verilator 5.020, cocotb 1.9.2, pyuvm 3.0.0, Yosys 0.33). Native Homebrew is
faster to iterate with, but Homebrew ships a newer Verilator.

**What was tested.** Every command below was run on Ubuntu 24.04 with those
versions. The Dockerfile installs the same packages on the same base image, but
neither it nor the Homebrew path has been run on a real Mac yet. If something
breaks, the error message and `verilator --version` are what to check first.

## Option A: Docker (recommended)

1. Install a Docker runtime: [Docker Desktop](https://www.docker.com/products/docker-desktop/),
   [OrbStack](https://orbstack.dev) (lighter) or `brew install colima docker && colima start`.
   On Apple Silicon you get a native arm64 image, so there is no emulation.
2. Build the image once (about 3 minutes):

   ```bash
   git clone https://github.com/OmPrajapati2110/hbm3-memory-controller-uvm.git
   cd hbm3-memory-controller-uvm
   docker build -t hbm3-mc .
   ```

3. Run anything from the README inside it. The repo is mounted, so results and
   waveforms land in your Mac folder:

   ```bash
   alias mc='docker run --rm -it -v "$PWD":/work hbm3-mc'
   mc make lint
   mc make test TEST=test_smoke SEED=1      # about 30 s the first time (compiles), then seconds
   mc make test TEST=test_starvation TB_POLICY=1   # watch FR-FCFS starve a client
   mc make regress                          # full seeded regression, several minutes
   mc make mutants                          # bug injection
   mc make synth
   ```

Formal needs SymbiYosys, which is not in the image. Use the
[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build/releases) for
macOS natively (`cd formal && sby -f hbm3_mc.sby`).

## Option B: native Homebrew

```bash
brew install verilator yosys make
python3 -m venv .venv && source .venv/bin/activate
pip install "cocotb==1.9.2" "pyuvm==3.0.0"
make lint && make test TEST=test_smoke
```

Caveats:
- Homebrew's Verilator is newer than 5.020, and cocotb 1.9.2 may not build
  against it. If the build fails inside cocotb's Verilator glue, try
  `pip install "cocotb>=2.0" "pyuvm>=4.0"`. That pairing is untested here, so
  Docker is the fallback if it still fails.
- Apple's `make` is 3.81. Use `gmake` from `brew install make` if a Makefile
  rule misbehaves.
- Run Python from the venv so cocotb finds the right `libpython`.

## Waveforms

```bash
make test TEST=test_hazard SEED=3 WAVES=1      # or mc make ... with Docker
```

This writes `build/sim_clean_waves/dump.vcd`. Open it with
[Surfer](https://surfer-project.org) (`brew install surfer`, native on Apple
Silicon) or GTKWave (`brew install --cask gtkwave`). Signals worth adding first:
`row_cmd`, `col_cmd`, the per-bank state, `q_count` and the client req/rsp
valid/ready pairs.

## The visual model

`demo/index.html` replays real simulation traces. To record your own:

```bash
TB_POLICY=2 TRACE_JSON=$PWD/demo/traces/policy2.json make test TEST=test_demo SEED=4
cd demo && python3 -m http.server 8000      # then open http://localhost:8000
```

Policies are 0 = FCFS, 1 = FR-FCFS, 2 = FR-FCFS with aging.
