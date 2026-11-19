// -----------------------------------------------------------------------------
// hbm3_mc_sva.sv : white-box assertions bound into hbm3_mc.
// Covers the interface contracts (valid/ready), structural invariants of the
// scheduler (age matrix, one-hot picks, credits) and the anti-starvation
// guarantee of the aging policy.
// -----------------------------------------------------------------------------
`include "sva_macros.svh"

module hbm3_mc_sva #(
  parameter int NC         = 4,
  parameter int ID_W       = 4,
  parameter int DATA_W     = 256,
  parameter int ADDR_W     = 28,
  parameter int OFF_W      = 5,
  parameter int QDEPTH     = 16,
  parameter int RSP_DEPTH  = 8,
  parameter int RC_W       = 4,
  parameter int AGE_W      = 10,
  parameter int PIPE_N     = 18,
  parameter int STARVE_BOUND = 1023
) (
  input logic                     clk,
  input logic                     rst_n,
  input logic [1:0]               cfg_policy,
  // client side
  input logic [NC-1:0]            req_valid,
  input logic [NC-1:0]            req_ready,
  input logic [NC-1:0]            req_we,
  input logic [NC*ADDR_W-1:0]     req_addr,
  input logic [NC*DATA_W-1:0]     req_wdata,
  input logic [NC*ID_W-1:0]       req_id,
  input logic [NC-1:0]            rsp_valid,
  input logic [NC-1:0]            rsp_ready,
  input logic [NC-1:0]            rsp_we,
  input logic [NC*ID_W-1:0]       rsp_id,
  input logic [NC*DATA_W-1:0]     rsp_rdata,
  // internals
  input logic [QDEPTH-1:0]        e_valid,
  input logic [QDEPTH*QDEPTH-1:0] older,
  input logic [QDEPTH-1:0]        col_pick,
  input logic [QDEPTH-1:0]        row_pick,
  input logic                     alloc,
  input logic [$clog2(QDEPTH > 1 ? QDEPTH : 2)-1:0] free_idx,
  input logic [NC*RC_W-1:0]       rsp_cnt_flat,
  input logic [NC*RC_W-1:0]       inflight_flat,
  input logic [PIPE_N-1:0]        tp_v,
  input logic                     tp_out_we,
  input logic                     rd_valid,
  input logic [QDEPTH*AGE_W-1:0]  e_wait_flat,
  input logic                     dbg_aging_override,
  input logic                     dbg_ref_pending,
  input logic                     dbg_credit_stall
);

  // Starvation checking is disabled for tests that deliberately stop draining
  // responses (backpressure can block any entry indefinitely by design).
  bit starve_chk_en;
`ifndef FORMAL
  initial starve_chk_en = !$test$plusargs("NO_STARVE_CHK");
`else
  initial starve_chk_en = 1'b1;
`endif

  // ---------------------------------------------------------------------------
  // Client interface contracts
  // ---------------------------------------------------------------------------
  for (genvar c = 0; c < NC; c++) begin : g_cli
    // environment rules (assumed in formal, checked in simulation)
    `ASSUME_NEXT(m_req_hold, clk, rst_n, req_valid[c] && !req_ready[c],
                 req_valid[c] && $stable(req_we[c]) &&
                 $stable(req_addr[c*ADDR_W +: ADDR_W]) &&
                 $stable(req_wdata[c*DATA_W +: DATA_W]) &&
                 $stable(req_id[c*ID_W +: ID_W]))
    `ASSUME_IMPL(m_req_aligned, clk, rst_n, req_valid[c],
                 req_addr[c*ADDR_W +: OFF_W] == '0)
    // DUT obligations
    `A_NEXT(a_rsp_hold, clk, rst_n, rsp_valid[c] && !rsp_ready[c],
            rsp_valid[c] && $stable(rsp_we[c]) &&
            $stable(rsp_id[c*ID_W +: ID_W]) &&
            $stable(rsp_rdata[c*DATA_W +: DATA_W]))
    `A_IMPL(a_credit_bound, clk, rst_n, 1'b1,
            ({1'b0, rsp_cnt_flat[c*RC_W +: RC_W]} + {1'b0, inflight_flat[c*RC_W +: RC_W]})
              <= (RC_W+1)'(RSP_DEPTH))
    `C_PROP(c_rsp_backpressure, clk, rst_n, rsp_valid[c] && !rsp_ready[c])
    `C_PROP(c_req_backpressure, clk, rst_n, req_valid[c] && !req_ready[c])
  end

  // ---------------------------------------------------------------------------
  // Scheduler invariants
  // ---------------------------------------------------------------------------
  `A_IMPL(a_col_pick_onehot, clk, rst_n, 1'b1, $onehot0(col_pick))
  `A_IMPL(a_row_pick_onehot, clk, rst_n, 1'b1, $onehot0(row_pick))
  `A_IMPL(a_col_pick_valid,  clk, rst_n, 1'b1, (col_pick & ~e_valid) == '0)
  `A_IMPL(a_row_pick_valid,  clk, rst_n, 1'b1, (row_pick & ~e_valid) == '0)
  `A_IMPL(a_alloc_free_slot, clk, rst_n, alloc, !e_valid[free_idx])

  // Age matrix: any two live entries are strictly ordered
  for (genvar i = 0; i < QDEPTH; i++) begin : g_age_i
    for (genvar j = i + 1; j < QDEPTH; j++) begin : g_age_j
      `A_IMPL(a_age_total_order, clk, rst_n, e_valid[i] && e_valid[j],
              older[i*QDEPTH+j] != older[j*QDEPTH+i])
    end
    // Anti-starvation: with FCFS or aging, no request waits without bound
    `A_IMPL(a_no_starvation, clk, rst_n,
            starve_chk_en && e_valid[i] && cfg_policy != 2'd1,
            e_wait_flat[i*AGE_W +: AGE_W] < STARVE_BOUND)
  end

  // Read data returns exactly when the completion pipeline expects it
  `A_IMPL(a_rd_return_aligned, clk, rst_n, 1'b1,
          rd_valid == (tp_v[PIPE_N-1] && !tp_out_we))

  // ---------------------------------------------------------------------------
  // Scenario coverage
  // ---------------------------------------------------------------------------
  `C_PROP(c_queue_full,       clk, rst_n, &e_valid)
  `C_PROP(c_aging_override,   clk, rst_n, dbg_aging_override)
  `C_PROP(c_credit_stall,     clk, rst_n, dbg_credit_stall)
  `C_PROP(c_ref_under_load,   clk, rst_n, dbg_ref_pending && (e_valid != '0))
  `C_PROP(c_row_and_col_pick, clk, rst_n, (col_pick != '0) && (row_pick != '0))

endmodule

// Formal instantiates the checker inside hbm3_mc directly (`ifdef FORMAL),
// and newer Yosys rejects bind, so the bind is for simulation only.
`ifndef FORMAL
// Bind into every hbm3_mc instance. Unpacked arrays are flattened here so the
// checker stays portable across simulators and the open-source formal flow.
bind hbm3_mc hbm3_mc_sva #(
  .NC(NC), .ID_W(ID_W), .DATA_W(DATA_W), .ADDR_W(ADDR_W), .OFF_W(OFF_W),
  .QDEPTH(QDEPTH), .RSP_DEPTH(RSP_DEPTH), .RC_W(RC_W), .AGE_W(AGE_W),
  .PIPE_N(PIPE_N),
  .STARVE_BOUND(AGE_THRESH + QDEPTH * (T_RAS + T_RP + T_RCD + T_RTW + T_WTR_L + WL + BURST) + T_RFC + T_RAS + 64)
) u_mc_sva (
  .clk, .rst_n, .cfg_policy,
  .req_valid, .req_ready, .req_we, .req_addr, .req_wdata, .req_id,
  .rsp_valid, .rsp_ready, .rsp_we, .rsp_id, .rsp_rdata,
  .e_valid, .older, .col_pick, .row_pick, .alloc, .free_idx,
  .rsp_cnt_flat  (dbg_rsp_cnt_flat),
  .inflight_flat (dbg_inflight_flat),
  .tp_v, .tp_out_we (tp_we[PIPE_N-1]), .rd_valid,
  .e_wait_flat   (dbg_e_wait_flat),
  .dbg_aging_override, .dbg_ref_pending, .dbg_credit_stall
);
`endif
