#!/usr/bin/env python3
"""Full elaboration check of the SystemVerilog UVM bench with slang (pyslang).

slang is a standards-strict SystemVerilog compiler front end. This elaborates
the RTL, assertions, harness and UVM bench against the Accellera UVM library
and reports every error, so the UVM code is known to compile before it is run
on a commercial simulator.

  UVM_HOME=/path/to/uvm-core/src python3 scripts/check_uvm_compile.py
"""
import os
import sys

import pyslang

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
UVM = os.environ.get("UVM_HOME")
if not UVM or not os.path.exists(os.path.join(UVM, "uvm_pkg.sv")):
    sys.exit("set UVM_HOME to the uvm-core 'src' directory "
             "(git clone https://github.com/accellera-official/uvm-core)")

files = [os.path.join(UVM, "uvm_pkg.sv")]
files += [os.path.join(ROOT, l.strip()) for l in open(os.path.join(ROOT, "rtl", "files.f")) if l.strip()]
files += [os.path.join(ROOT, p) for p in (
    "tb/sva/hbm3_timing_checker.sv", "tb/sva/hbm3_mc_sva.sv",
    "tb/common/hbm3_dev_model.sv", "tb/common/hbm3_mc_harness.sv",
    "tb/uvm/mc_if.sv", "tb/uvm/mc_tb_pkg.sv", "tb/uvm/tb_top.sv")]

args = ["slang", "--top", "tb_top", "--timescale", "1ns/1ps",
        "-I", UVM, "-I", os.path.join(ROOT, "tb/uvm"), "-I", os.path.join(ROOT, "tb/sva"),
        "--error-limit", "50"] + files
d = pyslang.driver.Driver()
d.addStandardArgs()
if not d.parseCommandLine(" ".join(args), pyslang.driver.CommandLineOptions()):
    sys.exit("bad command line")
if not d.processOptions():
    sys.exit("bad options")
d.parseAllSources()
comp = d.createCompilation()
d.reportCompilation(comp, False)
# Errors anywhere (parse, elaboration, our code or the library) fail the check.
# The UVM library itself emits one benign escape-sequence warning.
n_err = sum(1 for x in comp.getAllDiagnostics() if x.isError())
print(f"ELABORATION {'PASSED' if n_err == 0 else 'FAILED'} ({n_err} errors)")
sys.exit(0 if n_err == 0 else 1)
