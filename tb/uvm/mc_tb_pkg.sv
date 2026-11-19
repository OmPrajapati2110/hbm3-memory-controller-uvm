// -----------------------------------------------------------------------------
// mc_tb_pkg.sv : UVM verification package for hbm3_mc
// -----------------------------------------------------------------------------
package mc_tb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // DUT geometry (must match tb_top parameters)
  localparam int NC     = 4;
  localparam int ID_W   = 4;
  localparam int DATA_W = 256;
  localparam int OFF_W  = 5;
  localparam int COL_W  = 5;
  localparam int BG_W   = 2;
  localparam int BK_W   = 2;
  localparam int ROW_W  = 14;
  localparam int BA_W   = BG_W + BK_W;
  localparam int NUM_BG = 1 << BG_W;
  localparam int ADDR_W = OFF_W + COL_W + BA_W + ROW_W;
  localparam int QDEPTH = 16;
  localparam int QC_W   = $clog2(QDEPTH + 1);
  localparam int RL     = 17;

  `include "mc_items.svh"
  `include "mc_agents.svh"
  `include "mc_scoreboard.svh"
  `include "mc_coverage.svh"
  `include "mc_env.svh"
  `include "mc_sequences.svh"
  `include "mc_tests.svh"
endpackage
