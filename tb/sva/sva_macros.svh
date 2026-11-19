// -----------------------------------------------------------------------------
// sva_macros.svh : one source of truth for properties used in simulation
// (concurrent SVA) and in open-source formal (Yosys/SBY, which only reads
// immediate assertions in clocked blocks without a commercial front end).
// -----------------------------------------------------------------------------
`ifndef SVA_MACROS_SVH
`define SVA_MACROS_SVH

`ifdef FORMAL
  // Labels are dropped here: Yosys does not scope labels inside generate
  // loops, and reports failures by source line instead.
  // A |-> B, same cycle
  `define A_IMPL(name, clk, rst_n, A, B) \
    always @(posedge clk) if ((rst_n) && (A)) assert (B);
  // A |=> B, next cycle
  `define A_NEXT(name, clk, rst_n, A, B) \
    always @(posedge clk) if ((rst_n) && $past(rst_n) && $past(A)) assert (B);
  `define ASSUME_NEXT(name, clk, rst_n, A, B) \
    always @(posedge clk) if ((rst_n) && $past(rst_n) && $past(A)) assume (B);
  `define ASSUME_IMPL(name, clk, rst_n, A, B) \
    always @(posedge clk) if ((rst_n) && (A)) assume (B);
  `define C_PROP(name, clk, rst_n, A) \
    always @(posedge clk) if (rst_n) cover (A);
`else
  `define A_IMPL(name, clk, rst_n, A, B) \
    name: assert property (@(posedge clk) disable iff (!(rst_n)) (A) |-> (B)) \
      else $error("SVA FAIL %m");
  `define A_NEXT(name, clk, rst_n, A, B) \
    name: assert property (@(posedge clk) disable iff (!(rst_n)) (A) |=> (B)) \
      else $error("SVA FAIL %m");
  // In simulation the environment is checked, not assumed.
  `define ASSUME_NEXT(name, clk, rst_n, A, B) `A_NEXT(name, clk, rst_n, A, B)
  `define ASSUME_IMPL(name, clk, rst_n, A, B) `A_IMPL(name, clk, rst_n, A, B)
  `define C_PROP(name, clk, rst_n, A) \
    name: cover property (@(posedge clk) disable iff (!(rst_n)) (A));
`endif

`endif
