// -----------------------------------------------------------------------------
// mc_if.sv : interfaces for the SystemVerilog UVM bench.
// -----------------------------------------------------------------------------

// One client port of the controller (request + response channels)
interface mc_client_if #(
  parameter int ADDR_W = 28,
  parameter int DATA_W = 256,
  parameter int ID_W   = 4
) (input logic clk, input logic rst_n);

  logic              req_valid;
  logic              req_ready;
  logic              req_we;
  logic [ADDR_W-1:0] req_addr;
  logic [DATA_W-1:0] req_wdata;
  logic [ID_W-1:0]   req_id;
  logic              rsp_valid;
  logic              rsp_ready;
  logic              rsp_we;
  logic [ID_W-1:0]   rsp_id;
  logic [DATA_W-1:0] rsp_rdata;

  // Free-running cycle stamp shared by all monitors (same clock and reset)
  int unsigned cyc;
  always @(posedge clk) cyc <= rst_n ? cyc + 1 : 0;

  clocking drv_cb @(posedge clk);
    default input #1step output #0;
    output req_valid, req_we, req_addr, req_wdata, req_id, rsp_ready;
    input  req_ready, rsp_valid;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input req_valid, req_ready, req_we, req_addr, req_wdata, req_id;
    input rsp_valid, rsp_ready, rsp_we, rsp_id, rsp_rdata, cyc;
  endclocking

  modport drv (clocking drv_cb, input clk, input rst_n);
  modport mon (clocking mon_cb, input clk, input rst_n);

endinterface


// HBM command buses plus controller configuration / observability
interface mc_cmd_if #(
  parameter int BA_W   = 4,
  parameter int ROW_W  = 14,
  parameter int COL_W  = 5,
  parameter int DATA_W = 256,
  parameter int QC_W   = 5
) (input logic clk, input logic rst_n);

  logic [1:0]        row_cmd;
  logic [BA_W-1:0]   row_ba;
  logic [ROW_W-1:0]  row_addr;
  logic [1:0]        col_cmd;
  logic [BA_W-1:0]   col_ba;
  logic [COL_W-1:0]  col_addr;
  logic [DATA_W-1:0] col_wdata;
  logic              dbg_aging_override;
  logic              dbg_ref_pending;
  logic              dbg_credit_stall;
  logic [QC_W-1:0]   dbg_q_count;
  // configuration, driven by the test before reset is released
  logic [1:0]        cfg_policy;
  logic              cfg_refresh_en;

  int unsigned cyc;
  always @(posedge clk) cyc <= rst_n ? cyc + 1 : 0;

  clocking mon_cb @(posedge clk);
    default input #1step;
    input row_cmd, row_ba, row_addr, col_cmd, col_ba, col_addr, col_wdata;
    input dbg_aging_override, dbg_ref_pending, dbg_credit_stall, dbg_q_count;
    input cfg_policy, cyc;
  endclocking

endinterface
