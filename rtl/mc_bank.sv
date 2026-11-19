// -----------------------------------------------------------------------------
// mc_bank.sv : per-bank state machine and timers.
//
// Each timer holds "cycles until the command is legal". A command issued in
// cycle t that requires spacing N loads N-1, so the dependent command becomes
// legal in cycle t+N. Timers take the max of their current value and any new
// load, which lets several constraints share one counter.
// -----------------------------------------------------------------------------
module mc_bank #(
  parameter int ROW_W = 14,
  parameter int CNT_W = 9,
  parameter int T_RCD = 14,
  parameter int T_RP  = 14,
  parameter int T_RAS = 28,
  parameter int T_RC  = 42,
  parameter int T_RTP = 5,
  parameter int T_WRP = 22,   // WL + BURST + tWR : write to precharge
  parameter int T_RFC = 160
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             do_act,
  input  logic             do_pre,
  input  logic             do_rd,
  input  logic             do_wr,
  input  logic             do_ref,
  input  logic [ROW_W-1:0] act_row,
  output logic             is_open,
  output logic [ROW_W-1:0] open_row,
  output logic             act_ok,
  output logic             pre_ok,
  output logic             col_ok
);

  logic [CNT_W-1:0] act_w, pre_w, col_w;

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

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      is_open  <= 1'b0;
      open_row <= '0;
      act_w    <= '0;
      pre_w    <= '0;
      col_w    <= '0;
    end else begin
      if (do_act) begin
        is_open  <= 1'b1;
        open_row <= act_row;
      end else if (do_pre) begin
        is_open  <= 1'b0;
      end
      act_w <= max2(max2(dec(act_w), ld(do_act, T_RC)),
                    max2(ld(do_pre, T_RP), ld(do_ref, T_RFC)));
      pre_w <= max2(max2(dec(pre_w), ld(do_act, T_RAS)),
                    max2(ld(do_rd, T_RTP), ld(do_wr, T_WRP)));
      col_w <= max2(dec(col_w), ld(do_act, T_RCD));
    end
  end

  assign act_ok = ~is_open & (act_w == '0);
  assign pre_ok =  is_open & (pre_w == '0);
  assign col_ok =  is_open & (col_w == '0);

endmodule
