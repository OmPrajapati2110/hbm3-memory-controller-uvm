// -----------------------------------------------------------------------------
// hbm3_timing_checker.sv : black-box JEDEC-style protocol and timing checker.
//
// Observes only the HBM command buses, so it is independent of the controller's
// own timers (different implementation: absolute timestamps instead of
// countdown counters). Every rule has an assertion and a "hit exactly at the
// limit" cover, which proves both that the scheduler runs at full speed and
// that a one-cycle-early bug would be caught.
// -----------------------------------------------------------------------------
`include "sva_macros.svh"

module hbm3_timing_checker #(
  parameter int BG_W    = 2,
  parameter int BK_W    = 2,
  parameter int ROW_W   = 14,
  parameter int COL_W   = 5,
  parameter int CYC_W   = 32,
  parameter int T_RCD   = 14,
  parameter int T_RP    = 14,
  parameter int T_RAS   = 28,
  parameter int T_RC    = 42,
  parameter int T_RRD_S = 2,
  parameter int T_RRD_L = 4,
  parameter int T_FAW   = 16,
  parameter int T_CCD_S = 2,
  parameter int T_CCD_L = 4,
  parameter int T_WTR_S = 4,
  parameter int T_WTR_L = 8,
  parameter int T_RTP   = 5,
  parameter int T_WR    = 14,
  parameter int WL      = 6,
  parameter int BURST   = 2,
  parameter int T_RTW   = 15,
  parameter int T_RFC   = 160,
  parameter int T_REFI  = 3900,
  parameter int REF_SLACK = 256,
  localparam int BA_W   = BG_W + BK_W,
  localparam int NB     = 1 << BA_W,
  localparam int NUM_BG = 1 << BG_W
) (
  input logic             clk,
  input logic             rst_n,
  input logic             cfg_refresh_en,
  input logic [1:0]       row_cmd,
  input logic [BA_W-1:0]  row_ba,
  input logic [ROW_W-1:0] row_addr,
  input logic [1:0]       col_cmd,
  input logic [BA_W-1:0]  col_ba,
  input logic [COL_W-1:0] col_addr
);

  localparam int WR2RD_S = WL + BURST + T_WTR_S;
  localparam int WR2RD_L = WL + BURST + T_WTR_L;
  localparam int WR2PRE  = WL + BURST + T_WR;

  // ---------------------------------------------------------------------------
  // History (timestamps + "ever happened" flags)
  // ---------------------------------------------------------------------------
  logic [CYC_W-1:0] cyc;
  logic [CYC_W-1:0] t_act [NB], t_pre [NB], t_rd [NB], t_wr [NB];
  logic [NB-1:0]    s_act, s_pre, s_rd, s_wr, open_b;
  logic [CYC_W-1:0] t_act_bg [NUM_BG], t_col_bg [NUM_BG], t_wr_bg [NUM_BG];
  logic [NUM_BG-1:0] s_act_bg, s_col_bg, s_wr_bg;
  logic [CYC_W-1:0] t_act_any, t_col_any, t_rd_any, t_wr_any, t_pre_any, t_ref, t_refwin;
  logic             s_act_any, s_col_any, s_rd_any, s_wr_any, s_pre_any, s_ref;
  logic [CYC_W-1:0] t_faw [4];
  logic [2:0]       n_act;   // saturates at 4

  wire is_act = (row_cmd == 2'd1);
  wire is_pre = (row_cmd == 2'd2);
  wire is_ref = (row_cmd == 2'd3);
  wire is_rd  = (col_cmd == 2'd1);
  wire is_wr  = (col_cmd == 2'd2);
  wire is_col = is_rd | is_wr;
  wire [BG_W-1:0] row_bg = row_ba[BG_W-1:0];
  wire [BG_W-1:0] col_bg = col_ba[BG_W-1:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cyc <= '0;
      s_act <= '0; s_pre <= '0; s_rd <= '0; s_wr <= '0; open_b <= '0;
      s_act_bg <= '0; s_col_bg <= '0; s_wr_bg <= '0;
      s_act_any <= 1'b0; s_col_any <= 1'b0; s_rd_any <= 1'b0;
      s_wr_any  <= 1'b0; s_pre_any <= 1'b0; s_ref    <= 1'b0;
      n_act <= '0;
      t_refwin <= '0;
    end else begin
      cyc <= cyc + 1'b1;
      if (!cfg_refresh_en) t_refwin <= cyc;
      if (is_act) begin
        t_act[row_ba] <= cyc;  s_act[row_ba] <= 1'b1;  open_b[row_ba] <= 1'b1;
        t_act_bg[row_bg] <= cyc; s_act_bg[row_bg] <= 1'b1;
        t_act_any <= cyc; s_act_any <= 1'b1;
        t_faw[0] <= cyc;
        for (int k = 1; k < 4; k++) t_faw[k] <= t_faw[k-1];
        if (n_act != 3'd4) n_act <= n_act + 3'd1;
      end
      if (is_pre) begin
        t_pre[row_ba] <= cyc; s_pre[row_ba] <= 1'b1; open_b[row_ba] <= 1'b0;
        t_pre_any <= cyc; s_pre_any <= 1'b1;
      end
      if (is_ref) begin
        t_ref <= cyc; s_ref <= 1'b1; t_refwin <= cyc;
      end
      if (is_col) begin
        t_col_any <= cyc; s_col_any <= 1'b1;
        t_col_bg[col_bg] <= cyc; s_col_bg[col_bg] <= 1'b1;
      end
      if (is_rd) begin
        t_rd[col_ba] <= cyc; s_rd[col_ba] <= 1'b1;
        t_rd_any <= cyc; s_rd_any <= 1'b1;
      end
      if (is_wr) begin
        t_wr[col_ba] <= cyc; s_wr[col_ba] <= 1'b1;
        t_wr_any <= cyc; s_wr_any <= 1'b1;
        t_wr_bg[col_bg] <= cyc; s_wr_bg[col_bg] <= 1'b1;
      end
    end
  end

  // Elapsed-cycle helpers ("never happened" counts as infinitely long ago)
  function automatic logic [CYC_W-1:0] since(input logic [CYC_W-1:0] t);
    since = cyc - t;
  endfunction

  // ---------------------------------------------------------------------------
  // Per-rule pass conditions, evaluated for the command on the bus this cycle
  // ---------------------------------------------------------------------------
  logic ok_rcd, ok_rp, ok_ras, ok_rc, ok_rrd_s, ok_rrd_l, ok_faw, ok_rfc_act;
  logic ok_ccd_s, ok_ccd_l, ok_wtr_s, ok_wtr_l, ok_rtw, ok_rtp, ok_wr;
  logic ok_ref_closed, ok_ref_rp, ok_ref_rfc;
  // exact-limit flags for coverage
  logic at_rcd, at_rp, at_ras, at_rc, at_rrd_s, at_rrd_l, at_faw, at_rfc;
  logic at_ccd_s, at_ccd_l, at_wtr_s, at_wtr_l, at_rtw, at_rtp, at_wr;

  always_comb begin
    ok_rcd   = !s_act[col_ba]   || since(t_act[col_ba])   >= CYC_W'(T_RCD);
    ok_rp    = !s_pre[row_ba]   || since(t_pre[row_ba])   >= CYC_W'(T_RP);
    ok_ras   = !s_act[row_ba]   || since(t_act[row_ba])   >= CYC_W'(T_RAS);
    ok_rc    = !s_act[row_ba]   || since(t_act[row_ba])   >= CYC_W'(T_RC);
    ok_rrd_s = !s_act_any       || since(t_act_any)       >= CYC_W'(T_RRD_S);
    ok_rrd_l = !s_act_bg[row_bg]|| since(t_act_bg[row_bg])>= CYC_W'(T_RRD_L);
    ok_faw   = (n_act < 3'd4)   || since(t_faw[3])        >= CYC_W'(T_FAW);
    ok_rfc_act = !s_ref         || since(t_ref)           >= CYC_W'(T_RFC);
    ok_ccd_s = !s_col_any       || since(t_col_any)       >= CYC_W'(T_CCD_S);
    ok_ccd_l = !s_col_bg[col_bg]|| since(t_col_bg[col_bg])>= CYC_W'(T_CCD_L);
    ok_wtr_s = !s_wr_any        || since(t_wr_any)        >= CYC_W'(WR2RD_S);
    ok_wtr_l = !s_wr_bg[col_bg] || since(t_wr_bg[col_bg]) >= CYC_W'(WR2RD_L);
    ok_rtw   = !s_rd_any        || since(t_rd_any)        >= CYC_W'(T_RTW);
    ok_rtp   = !s_rd[row_ba]    || since(t_rd[row_ba])    >= CYC_W'(T_RTP);
    ok_wr    = !s_wr[row_ba]    || since(t_wr[row_ba])    >= CYC_W'(WR2PRE);
    ok_ref_closed = (open_b == '0);
    ok_ref_rp  = !s_pre_any     || since(t_pre_any)       >= CYC_W'(T_RP);
    ok_ref_rfc = !s_ref         || since(t_ref)           >= CYC_W'(T_RFC);

    at_rcd   = s_act[col_ba]    && since(t_act[col_ba])    == CYC_W'(T_RCD);
    at_rp    = s_pre[row_ba]    && since(t_pre[row_ba])    == CYC_W'(T_RP);
    at_ras   = s_act[row_ba]    && since(t_act[row_ba])    == CYC_W'(T_RAS);
    at_rc    = s_act[row_ba]    && since(t_act[row_ba])    == CYC_W'(T_RC);
    at_rrd_s = s_act_any        && since(t_act_any)        == CYC_W'(T_RRD_S);
    at_rrd_l = s_act_bg[row_bg] && since(t_act_bg[row_bg]) == CYC_W'(T_RRD_L);
    at_faw   = (n_act == 3'd4)  && since(t_faw[3])         == CYC_W'(T_FAW);
    at_rfc   = s_ref            && since(t_ref)            == CYC_W'(T_RFC);
    at_ccd_s = s_col_any        && since(t_col_any)        == CYC_W'(T_CCD_S);
    at_ccd_l = s_col_bg[col_bg] && since(t_col_bg[col_bg]) == CYC_W'(T_CCD_L);
    at_wtr_s = s_wr_any         && since(t_wr_any)         == CYC_W'(WR2RD_S);
    at_wtr_l = s_wr_bg[col_bg]  && since(t_wr_bg[col_bg])  == CYC_W'(WR2RD_L);
    at_rtw   = s_rd_any         && since(t_rd_any)         == CYC_W'(T_RTW);
    at_rtp   = s_rd[row_ba]     && since(t_rd[row_ba])     == CYC_W'(T_RTP);
    at_wr    = s_wr[row_ba]     && since(t_wr[row_ba])     == CYC_W'(WR2PRE);
  end

  // ---------------------------------------------------------------------------
  // Assertions
  // ---------------------------------------------------------------------------
  // Bank state legality
  `A_IMPL(a_act_to_closed,  clk, rst_n, is_act, !open_b[row_ba])
  `A_IMPL(a_pre_to_open,    clk, rst_n, is_pre,  open_b[row_ba])
  `A_IMPL(a_col_to_open,    clk, rst_n, is_col,  open_b[col_ba])
  `A_IMPL(a_no_pre_col_same_bank, clk, rst_n, is_pre && is_col, row_ba != col_ba)
  // ACT spacing
  `A_IMPL(a_tRP,    clk, rst_n, is_act, ok_rp)
  `A_IMPL(a_tRC,    clk, rst_n, is_act, ok_rc)
  `A_IMPL(a_tRRD_S, clk, rst_n, is_act, ok_rrd_s)
  `A_IMPL(a_tRRD_L, clk, rst_n, is_act, ok_rrd_l)
  `A_IMPL(a_tFAW,   clk, rst_n, is_act, ok_faw)
  `A_IMPL(a_tRFC,   clk, rst_n, is_act, ok_rfc_act)
  // PRE spacing
  `A_IMPL(a_tRAS,   clk, rst_n, is_pre, ok_ras)
  `A_IMPL(a_tRTP,   clk, rst_n, is_pre, ok_rtp)
  `A_IMPL(a_tWR,    clk, rst_n, is_pre, ok_wr)
  // Column spacing
  `A_IMPL(a_tRCD,   clk, rst_n, is_col, ok_rcd)
  `A_IMPL(a_tCCD_S, clk, rst_n, is_col, ok_ccd_s)
  `A_IMPL(a_tCCD_L, clk, rst_n, is_col, ok_ccd_l)
  `A_IMPL(a_tWTR_S, clk, rst_n, is_rd,  ok_wtr_s)
  `A_IMPL(a_tWTR_L, clk, rst_n, is_rd,  ok_wtr_l)
  `A_IMPL(a_tRTW,   clk, rst_n, is_wr,  ok_rtw)
  // Refresh
  `A_IMPL(a_ref_all_closed, clk, rst_n, is_ref, ok_ref_closed)
  `A_IMPL(a_ref_tRP,        clk, rst_n, is_ref, ok_ref_rp)
  `A_IMPL(a_ref_tRFC,       clk, rst_n, is_ref, ok_ref_rfc)
  `A_IMPL(a_refresh_interval, clk, rst_n, cfg_refresh_en,
          since(t_refwin) <= CYC_W'(T_REFI + REF_SLACK))

  // ---------------------------------------------------------------------------
  // Coverage: every timing rule exercised exactly at its limit
  // ---------------------------------------------------------------------------
  `C_PROP(c_tRCD_min,   clk, rst_n, is_col && at_rcd)
  `C_PROP(c_tRP_min,    clk, rst_n, is_act && at_rp)
  `C_PROP(c_tRAS_min,   clk, rst_n, is_pre && at_ras)
  `C_PROP(c_tRC_min,    clk, rst_n, is_act && at_rc)
  `C_PROP(c_tRRD_S_min, clk, rst_n, is_act && at_rrd_s)
  `C_PROP(c_tRRD_L_min, clk, rst_n, is_act && at_rrd_l)
  `C_PROP(c_tFAW_min,   clk, rst_n, is_act && at_faw)
  `C_PROP(c_tRFC_min,   clk, rst_n, is_act && at_rfc)
  `C_PROP(c_tCCD_S_min, clk, rst_n, is_col && at_ccd_s)
  `C_PROP(c_tCCD_L_min, clk, rst_n, is_col && at_ccd_l)
  `C_PROP(c_tWTR_S_min, clk, rst_n, is_rd  && at_wtr_s)
  `C_PROP(c_tWTR_L_min, clk, rst_n, is_rd  && at_wtr_l)
  `C_PROP(c_tRTW_min,   clk, rst_n, is_wr  && at_rtw)
  `C_PROP(c_tRTP_min,   clk, rst_n, is_pre && at_rtp)
  `C_PROP(c_tWR_min,    clk, rst_n, is_pre && at_wr)
  `C_PROP(c_dual_bus,   clk, rst_n, (is_act || is_pre) && is_col)
  `C_PROP(c_ref,        clk, rst_n, is_ref)

endmodule
