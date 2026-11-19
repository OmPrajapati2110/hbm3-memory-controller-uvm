// -----------------------------------------------------------------------------
// hbm3_mc_harness.sv : DUT + HBM device model + black-box timing checker.
// Shared by the SystemVerilog UVM bench (tb/uvm/tb_top.sv) and the Python
// pyuvm/cocotb bench (tb/pyuvm), so both run against identical checkers.
// -----------------------------------------------------------------------------
module hbm3_mc_harness #(
  parameter int NC        = 4,
  parameter int ID_W      = 4,
  parameter int DATA_W    = 256,
  parameter int COL_W     = 5,
  parameter int BG_W      = 2,
  parameter int BK_W      = 2,
  parameter int ROW_W     = 14,
  parameter int QDEPTH    = 16,
  parameter int CF_DEPTH  = 4,
  parameter int RSP_DEPTH = 8,
  parameter int AGE_THRESH = 256,
  parameter int T_RCD  = 14,
  parameter int T_RP   = 14,
  parameter int T_RAS  = 28,
  parameter int T_RC   = 42,
  parameter int T_RRD_S = 2,
  parameter int T_RRD_L = 4,
  parameter int T_FAW  = 16,
  parameter int T_CCD_S = 2,
  parameter int T_CCD_L = 4,
  parameter int T_WTR_S = 4,
  parameter int T_WTR_L = 8,
  parameter int T_RTP  = 5,
  parameter int T_WR   = 14,
  parameter int RL     = 17,
  parameter int WL     = 6,
  parameter int BURST  = 2,
  parameter int T_RTW  = 15,
  parameter int T_RFC  = 160,
  parameter int T_REFI = 3900,
  localparam int OFF_W  = $clog2(DATA_W / 8),
  localparam int ADDR_W = OFF_W + COL_W + BG_W + BK_W + ROW_W,
  localparam int BA_W   = BG_W + BK_W
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic [1:0]           cfg_policy,
  input  logic                 cfg_refresh_en,
  input  logic [NC-1:0]        req_valid,
  output logic [NC-1:0]        req_ready,
  input  logic [NC-1:0]        req_we,
  input  logic [NC*ADDR_W-1:0] req_addr,
  input  logic [NC*DATA_W-1:0] req_wdata,
  input  logic [NC*ID_W-1:0]   req_id,
  output logic [NC-1:0]        rsp_valid,
  input  logic [NC-1:0]        rsp_ready,
  output logic [NC-1:0]        rsp_we,
  output logic [NC*ID_W-1:0]   rsp_id,
  output logic [NC*DATA_W-1:0] rsp_rdata,
  // command bus, exposed for passive monitoring
  output logic [1:0]           row_cmd,
  output logic [BA_W-1:0]      row_ba,
  output logic [ROW_W-1:0]     row_addr,
  output logic [1:0]           col_cmd,
  output logic [BA_W-1:0]      col_ba,
  output logic [COL_W-1:0]     col_addr,
  output logic [DATA_W-1:0]    col_wdata,
  output logic                 dbg_aging_override,
  output logic                 dbg_ref_pending,
  output logic                 dbg_credit_stall,
  output logic [$clog2(QDEPTH+1)-1:0] dbg_q_count
);

  logic              rd_valid;
  logic [DATA_W-1:0] rd_data;

  hbm3_mc #(
    .NC(NC), .ID_W(ID_W), .DATA_W(DATA_W), .COL_W(COL_W), .BG_W(BG_W),
    .BK_W(BK_W), .ROW_W(ROW_W), .QDEPTH(QDEPTH), .CF_DEPTH(CF_DEPTH),
    .RSP_DEPTH(RSP_DEPTH), .AGE_THRESH(AGE_THRESH),
    .T_RCD(T_RCD), .T_RP(T_RP), .T_RAS(T_RAS), .T_RC(T_RC),
    .T_RRD_S(T_RRD_S), .T_RRD_L(T_RRD_L), .T_FAW(T_FAW),
    .T_CCD_S(T_CCD_S), .T_CCD_L(T_CCD_L), .T_WTR_S(T_WTR_S), .T_WTR_L(T_WTR_L),
    .T_RTP(T_RTP), .T_WR(T_WR), .RL(RL), .WL(WL), .BURST(BURST),
    .T_RTW(T_RTW), .T_RFC(T_RFC), .T_REFI(T_REFI)
  ) u_dut (.*);

  hbm3_dev_model #(
    .DATA_W(DATA_W), .BA_W(BA_W), .ROW_W(ROW_W), .COL_W(COL_W), .RL(RL)
  ) u_dev (.*);

  hbm3_timing_checker #(
    .BG_W(BG_W), .BK_W(BK_W), .ROW_W(ROW_W), .COL_W(COL_W),
    .T_RCD(T_RCD), .T_RP(T_RP), .T_RAS(T_RAS), .T_RC(T_RC),
    .T_RRD_S(T_RRD_S), .T_RRD_L(T_RRD_L), .T_FAW(T_FAW),
    .T_CCD_S(T_CCD_S), .T_CCD_L(T_CCD_L), .T_WTR_S(T_WTR_S), .T_WTR_L(T_WTR_L),
    .T_RTP(T_RTP), .T_WR(T_WR), .WL(WL), .BURST(BURST), .T_RTW(T_RTW),
    .T_RFC(T_RFC), .T_REFI(T_REFI)
  ) u_tchk (
    .clk, .rst_n, .cfg_refresh_en,
    .row_cmd, .row_ba, .row_addr, .col_cmd, .col_ba, .col_addr
  );

endmodule
