// -----------------------------------------------------------------------------
// hbm3_mc_pkg.sv
// Shared encodings for the HBM3-style memory controller and its verification
// collateral. Timing values live as module parameters (see hbm3_mc.sv) so that
// simulation, formal and synthesis can each pick a profile.
// -----------------------------------------------------------------------------
package hbm3_mc_pkg;

  // Row command bus (ACT / PRE / REF travel on the row bus in HBM)
  localparam logic [1:0] ROW_NOP = 2'd0;
  localparam logic [1:0] ROW_ACT = 2'd1;
  localparam logic [1:0] ROW_PRE = 2'd2;
  localparam logic [1:0] ROW_REF = 2'd3;

  // Column command bus (RD / WR travel on the column bus in HBM)
  localparam logic [1:0] COL_NOP = 2'd0;
  localparam logic [1:0] COL_RD  = 2'd1;
  localparam logic [1:0] COL_WR  = 2'd2;

  // Scheduling policies (cfg_policy)
  localparam logic [1:0] POL_FCFS     = 2'd0;  // strict oldest-first
  localparam logic [1:0] POL_FRFCFS   = 2'd1;  // row-hit first, then oldest
  localparam logic [1:0] POL_FRFCFS_A = 2'd2;  // FR-FCFS with an aging cap

endpackage
