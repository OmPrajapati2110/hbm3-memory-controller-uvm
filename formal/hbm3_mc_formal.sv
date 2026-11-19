// -----------------------------------------------------------------------------
// hbm3_mc_formal.sv : formal harness (SymbiYosys).
//
// A scaled-down configuration (2 clients, 4 banks in 2 bank groups, 4-entry
// queue, short timings) so bounded model checking explores every input
// sequence of the given depth. Clients are completely unconstrained apart from
// the valid/ready protocol rules, so the solver tries every interleaving of
// requests, addresses, data and response backpressure, every policy and
// refresh setting.
//
// Proven (bounded): every JEDEC timing / bank-state assertion in
// hbm3_timing_checker, plus the white-box invariants in hbm3_mc_sva (age-matrix
// total order, one-hot picks, credit bound, response hold, read-return
// alignment, starvation bound).
// -----------------------------------------------------------------------------
module hbm3_mc_formal (input logic clk);

  localparam int NC = 2, ID_W = 2, DATA_W = 16, COL_W = 1, BG_W = 1, BK_W = 1, ROW_W = 2;
  localparam int OFF_W  = 1;
  localparam int ADDR_W = OFF_W + COL_W + BG_W + BK_W + ROW_W;
  localparam int BA_W   = BG_W + BK_W;
  localparam int RL = 2, WL = 1, BURST = 1;
  localparam int T_RCD = 2, T_RP = 2, T_RAS = 3, T_RC = 5, T_RRD_S = 1, T_RRD_L = 2;
  localparam int T_FAW = 6, T_CCD_S = 1, T_CCD_L = 2, T_WTR_S = 1, T_WTR_L = 2;
  localparam int T_RTP = 1, T_WR = 2, T_RTW = 3, T_RFC = 4, T_REFI = 24;

  // ---- reset: low in the first cycle, high afterwards ----------------------
  logic init = 1'b1;
  (* anyseq *) logic rst_n;
  always @(posedge clk) init <= 1'b0;
  always @(*) assume (rst_n == !init);

  // ---- unconstrained environment ------------------------------------------
  (* anyseq *) logic [1:0]           cfg_policy;
  (* anyseq *) logic                 cfg_refresh_en;
  (* anyseq *) logic [NC-1:0]        req_valid, req_we, rsp_ready;
  (* anyseq *) logic [NC*ADDR_W-1:0] req_addr;
  (* anyseq *) logic [NC*DATA_W-1:0] req_wdata;
  (* anyseq *) logic [NC*ID_W-1:0]   req_id;
  (* anyseq *) logic [DATA_W-1:0]    rd_data;

  // configuration is static after reset
  always @(posedge clk) if (!init) begin
    assume (cfg_policy != 2'd3);
    assume ($stable(cfg_policy));
    assume ($stable(cfg_refresh_en));
  end

  logic [NC-1:0]        req_ready, rsp_valid, rsp_we;
  logic [NC*ID_W-1:0]   rsp_id;
  logic [NC*DATA_W-1:0] rsp_rdata;
  logic [1:0]           row_cmd, col_cmd;
  logic [BA_W-1:0]      row_ba, col_ba;
  logic [ROW_W-1:0]     row_addr;
  logic [COL_W-1:0]     col_addr;
  logic [DATA_W-1:0]    col_wdata;
  logic                 rd_valid;
  logic                 dbg_aging_override, dbg_ref_pending, dbg_credit_stall;
  logic [2:0]           dbg_q_count;

  hbm3_mc #(
    .NC(NC), .ID_W(ID_W), .DATA_W(DATA_W), .COL_W(COL_W), .BG_W(BG_W), .BK_W(BK_W),
    .ROW_W(ROW_W), .QDEPTH(4), .CF_DEPTH(2), .RSP_DEPTH(2), .AGE_W(8), .AGE_THRESH(8),
    .CNT_W(4),
    .T_RCD(T_RCD), .T_RP(T_RP), .T_RAS(T_RAS), .T_RC(T_RC), .T_RRD_S(T_RRD_S),
    .T_RRD_L(T_RRD_L), .T_FAW(T_FAW), .T_CCD_S(T_CCD_S), .T_CCD_L(T_CCD_L),
    .T_WTR_S(T_WTR_S), .T_WTR_L(T_WTR_L), .T_RTP(T_RTP), .T_WR(T_WR), .RL(RL), .WL(WL),
    .BURST(BURST), .T_RTW(T_RTW), .T_RFC(T_RFC), .T_REFI(T_REFI)
  ) dut (.*);

  // ---- minimal HBM: read data valid exactly RL cycles after RD -------------
  logic [RL-1:0] rd_pipe;
  always @(posedge clk) rd_pipe <= rst_n ? {rd_pipe[RL-2:0], col_cmd == 2'd1} : '0;
  assign rd_valid = rd_pipe[RL-1];

  hbm3_timing_checker #(
    .BG_W(BG_W), .BK_W(BK_W), .ROW_W(ROW_W), .COL_W(COL_W), .CYC_W(8),
    .T_RCD(T_RCD), .T_RP(T_RP), .T_RAS(T_RAS), .T_RC(T_RC), .T_RRD_S(T_RRD_S),
    .T_RRD_L(T_RRD_L), .T_FAW(T_FAW), .T_CCD_S(T_CCD_S), .T_CCD_L(T_CCD_L),
    .T_WTR_S(T_WTR_S), .T_WTR_L(T_WTR_L), .T_RTP(T_RTP), .T_WR(T_WR), .WL(WL),
    .BURST(BURST), .T_RTW(T_RTW), .T_RFC(T_RFC), .T_REFI(T_REFI), .REF_SLACK(32)
  ) u_tchk (.*);

endmodule
