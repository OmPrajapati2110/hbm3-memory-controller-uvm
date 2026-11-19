# Top-level shortcuts. See README.md.
SBY ?= sby
.PHONY: lint test regress mutants sweep formal synth uvm-check clean

lint:        ## Verilator lint of the RTL (warnings are errors)
	verilator --lint-only -Wall rtl/lint_waivers.vlt -f rtl/files.f --top-module hbm3_mc

test:        ## One test: make test TEST=test_hazard SEED=3
	$(MAKE) -C tb/pyuvm TESTCASE=$(or $(TEST),test_random) RANDOM_SEED=$(or $(SEED),1)

regress:     ## Seeded regression with coverage merge -> results/regression.md
	python3 scripts/regress.py

mutants:     ## Bug-injection campaign -> results/mutants.md
	python3 scripts/run_mutants.py

sweep:       ## Scheduling-policy comparison -> results/policy_sweep.md
	python3 scripts/policy_sweep.py

formal:      ## SymbiYosys bounded proof + formal mutants
	cd formal && $(SBY) -f hbm3_mc.sby

synth:       ## Generic Yosys synthesis -> syn/stat.txt
	yosys -q syn/synth.ys

uvm-check:   ## Elaborate the SV UVM bench with slang (needs UVM_HOME)
	python3 scripts/check_uvm_compile.py

clean:
	rm -rf build results/runs formal/hbm3_mc_*/ tb/pyuvm/__pycache__ tb/pyuvm/results.xml
