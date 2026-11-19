# SystemVerilog UVM bench on a commercial simulator.
#   make SIM=questa  TEST=mc_random_test SEED=7 [POLICY=1] [N=500]
#   make SIM=vcs     TEST=mc_hazard_test
#   make SIM=xcelium TEST=mc_backpressure_test PLUSARGS=+NO_STARVE_CHK
# Free option: paste the file list into EDA Playground (Siemens Questa or
# Aldec Riviera-PRO, UVM 1.2), top = tb_top.
# Compile-only check without a simulator: python3 scripts/check_uvm_compile.py
SIM      ?= questa
TEST     ?= mc_random_test
SEED     ?= 1
POLICY   ?=
N        ?=
PLUSARGS ?=
ROOT     := $(abspath ../..)

SRCS := $(shell sed 's|^|$(ROOT)/|' $(ROOT)/rtl/files.f) \
        $(ROOT)/tb/sva/hbm3_timing_checker.sv $(ROOT)/tb/sva/hbm3_mc_sva.sv \
        $(ROOT)/tb/common/hbm3_dev_model.sv $(ROOT)/tb/common/hbm3_mc_harness.sv \
        $(ROOT)/tb/uvm/mc_if.sv $(ROOT)/tb/uvm/mc_tb_pkg.sv $(ROOT)/tb/uvm/tb_top.sv
INCS := +incdir+$(ROOT)/tb/uvm +incdir+$(ROOT)/tb/sva
RUNARGS := +UVM_TESTNAME=$(TEST) $(if $(POLICY),+POLICY=$(POLICY)) $(if $(N),+N=$(N)) $(PLUSARGS)

questa:
	vlib work
	vlog -sv -timescale 1ns/1ps $(INCS) +acc $(SRCS)
	vsim -c tb_top -sv_seed $(SEED) $(RUNARGS) -coverage -assertdebug \
	     -do "coverage save -onexit cov_$(TEST)_$(SEED).ucdb; run -all; quit -f"

vcs:
	vcs -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps $(INCS) -cm line+cond+fsm+assert \
	    -assert enable_diag $(SRCS) -top tb_top -o simv
	./simv +ntb_random_seed=$(SEED) $(RUNARGS) -cm line+cond+fsm+assert

xcelium:
	xrun -sv -uvm -timescale 1ns/1ps $(INCS) -coverage all -top tb_top $(SRCS) \
	     -svseed $(SEED) $(RUNARGS)

run: $(SIM)
.PHONY: questa vcs xcelium run
