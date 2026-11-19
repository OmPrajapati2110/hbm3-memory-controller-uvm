# cocotb + pyuvm bench on Verilator.
#   make TESTCASE=test_random RANDOM_SEED=1
#   make TESTCASE=test_hazard MUTANT=MUT_HAZARD     (bug-injection build)
SIM            ?= verilator
TOPLEVEL_LANG  ?= verilog
TB_DIR         := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT           := $(abspath $(TB_DIR)/../..)
export PYTHONPATH := $(TB_DIR):$(PYTHONPATH)
TOPLEVEL       := hbm3_mc_harness
MODULE         := test_mc

# Accelerated refresh interval so refresh-under-load happens in every test
TB_T_REFI      ?= 900
export TB_T_REFI

VERILOG_SOURCES := $(ROOT)/rtl/hbm3_mc_pkg.sv $(ROOT)/rtl/mc_fifo.sv \
                   $(ROOT)/rtl/mc_rr_arb.sv $(ROOT)/rtl/mc_bank.sv \
                   $(ROOT)/rtl/mc_rank_timer.sv $(ROOT)/rtl/mc_refresh.sv \
                   $(ROOT)/rtl/hbm3_mc.sv \
                   $(ROOT)/tb/sva/hbm3_timing_checker.sv $(ROOT)/tb/sva/hbm3_mc_sva.sv \
                   $(ROOT)/tb/common/hbm3_dev_model.sv $(ROOT)/tb/common/hbm3_mc_harness.sv

MUTANT         ?=
WAVES          ?= 0
ifeq ($(WAVES),1)
  # dump.vcd is written to the run directory
  VERILATOR_TRACE := 1
endif
SIM_BUILD      ?= $(ROOT)/build/sim_$(if $(MUTANT),$(MUTANT),clean)$(if $(filter 1,$(WAVES)),_waves,)
COMPILE_ARGS   += --assert --coverage-user -Wno-fatal -Wno-lint -Wno-style \
                  -I$(ROOT)/tb/sva $(ROOT)/rtl/lint_waivers.vlt \
                  -GT_REFI=$(TB_T_REFI) -O2 \
                  $(if $(MUTANT),+define+$(MUTANT),)

include $(shell cocotb-config --makefiles)/Makefile.sim
