// -----------------------------------------------------------------------------
// mc_rank_timer.sv : constraints that span banks within a pseudo-channel.
//   tRRD_S / tRRD_L  ACT to ACT, different / same bank group
//   tFAW             at most four ACTs in any tFAW window
//   tCCD_S / tCCD_L  column to column, different / same bank group
//   tWTR_S / tWTR_L  end of write data to RD, different / same bank group
//   tRTW             RD to WR bus turnaround
// -----------------------------------------------------------------------------
module mc_rank_timer #(
  parameter int NUM_BG  = 4,
  parameter int BG_W    = 2,
  parameter int CNT_W   = 9,
  parameter int T_RRD_S = 2,
  parameter int T_RRD_L = 4,
  parameter int T_FAW   = 16,
  parameter int T_CCD_S = 2,
  parameter int T_CCD_L = 4,
  parameter int T_WTR_S = 12,  // WL + BURST + tWTR_S
  parameter int T_WTR_L = 16,  // WL + BURST + tWTR_L
  parameter int T_RTW   = 15
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              do_act,
  input  logic [BG_W-1:0]   act_bg,
  input  logic              do_rd,
  input  logic              do_wr,
  input  logic [BG_W-1:0]   col_bg,
  output logic [NUM_BG-1:0] act_ok_bg,
  output logic [NUM_BG-1:0] rd_ok_bg,
  output logic [NUM_BG-1:0] wr_ok_bg
);

  logic [CNT_W-1:0] act_any_w, col_any_w, wtr_any_w, rtw_w;
  logic [CNT_W-1:0] act_bg_w [NUM_BG];
  logic [CNT_W-1:0] col_bg_w [NUM_BG];
  logic [CNT_W-1:0] wtr_bg_w [NUM_BG];
  logic [CNT_W-1:0] faw_w    [4];      // [0] = most recent ACT

  function automatic logic [CNT_W-1:0] dec(input logic [CNT_W-1:0] c);
    dec = (c != '0) ? c - CNT_W'(1) : '0;
  endfunction

  function automatic logic [CNT_W-1:0] ld(input logic en, input int val);
    ld = (en && val > 0) ? CNT_W'(val - 1) : '0;
  endfunction

  function automatic logic [CNT_W-1:0] max2(input logic [CNT_W-1:0] a,
                                            input logic [CNT_W-1:0] b);
    max2 = (a > b) ? a : b;
  endfunction

  wire do_col = do_rd | do_wr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      act_any_w <= '0;
      col_any_w <= '0;
      wtr_any_w <= '0;
      rtw_w     <= '0;
      for (int g = 0; g < NUM_BG; g++) begin
        act_bg_w[g] <= '0;
        col_bg_w[g] <= '0;
        wtr_bg_w[g] <= '0;
      end
      for (int k = 0; k < 4; k++) faw_w[k] <= '0;
    end else begin
      act_any_w <= max2(dec(act_any_w), ld(do_act, T_RRD_S));
      col_any_w <= max2(dec(col_any_w), ld(do_col, T_CCD_S));
      wtr_any_w <= max2(dec(wtr_any_w), ld(do_wr,  T_WTR_S));
      rtw_w     <= max2(dec(rtw_w),     ld(do_rd,  T_RTW));
      for (int g = 0; g < NUM_BG; g++) begin
        act_bg_w[g] <= max2(dec(act_bg_w[g]), ld(do_act && act_bg == BG_W'(g), T_RRD_L));
        col_bg_w[g] <= max2(dec(col_bg_w[g]), ld(do_col && col_bg == BG_W'(g), T_CCD_L));
        wtr_bg_w[g] <= max2(dec(wtr_bg_w[g]), ld(do_wr  && col_bg == BG_W'(g), T_WTR_L));
      end
      if (do_act) begin
        faw_w[0] <= ld(1'b1, T_FAW);
        for (int k = 1; k < 4; k++) faw_w[k] <= dec(faw_w[k-1]);
      end else begin
        for (int k = 0; k < 4; k++) faw_w[k] <= dec(faw_w[k]);
      end
    end
  end

  always_comb begin
    for (int g = 0; g < NUM_BG; g++) begin
`ifdef MUT_TFAW
      // MUTANT: four-activate window ignored
      act_ok_bg[g] = (act_any_w == '0) && (act_bg_w[g] == '0);
`else
      act_ok_bg[g] = (act_any_w == '0) && (act_bg_w[g] == '0) && (faw_w[3] == '0);
`endif
`ifdef MUT_TCCD_L
      // MUTANT: same-bank-group column spacing uses tCCD_S
      rd_ok_bg[g]  = (col_any_w == '0) && (wtr_any_w == '0) && (wtr_bg_w[g] == '0);
      wr_ok_bg[g]  = (col_any_w == '0) && (rtw_w == '0);
`elsif MUT_TWTR_L
      // MUTANT: same-bank-group write-to-read turnaround ignored
      rd_ok_bg[g]  = (col_any_w == '0) && (col_bg_w[g] == '0) && (wtr_any_w == '0);
      wr_ok_bg[g]  = (col_any_w == '0) && (col_bg_w[g] == '0) && (rtw_w == '0);
`else
      rd_ok_bg[g]  = (col_any_w == '0) && (col_bg_w[g] == '0) &&
                     (wtr_any_w == '0) && (wtr_bg_w[g] == '0);
      wr_ok_bg[g]  = (col_any_w == '0) && (col_bg_w[g] == '0) && (rtw_w == '0);
`endif
    end
  end

endmodule
