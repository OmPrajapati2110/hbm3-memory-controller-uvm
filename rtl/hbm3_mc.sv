// -----------------------------------------------------------------------------
// hbm3_mc.sv : HBM3-style pseudo-channel memory controller
//
//   clients --> per-client request FIFOs --> round-robin admission
//           --> shared command queue (age matrix, same-line hazard tracking)
//           --> scheduler: one column command (RD/WR) and one row command
//               (ACT/PRE/REF) per cycle, as on HBM's split command buses
//           --> per-bank + rank timers enforce JEDEC-style spacing
//           --> RL-deep completion pipeline --> per-client response FIFOs
//
// Address map (byte address, one 32B access per request):
//   [4:0] offset (must be 0) | col | bank group | bank | row
// Consecutive 32B lines stay in one row (streaming row hits); the next row's
// worth of addresses moves to another bank group, then another bank.
//
// Mutation hooks: `MUT_* defines inject known bugs so the regression can show
// that the testbench catches them (see scripts/run_mutants.py). They are never
// set in a normal build.
// -----------------------------------------------------------------------------
module hbm3_mc #(
  parameter int NC        = 4,     // clients
  parameter int ID_W      = 4,
  parameter int DATA_W    = 256,   // one 32B burst (BL8 x 32 bit pseudo-channel)
  parameter int COL_W     = 5,
  parameter int BG_W      = 2,
  parameter int BK_W      = 2,
  parameter int ROW_W     = 14,
  parameter int QDEPTH    = 16,
  parameter int CF_DEPTH  = 4,     // client request FIFO depth
  parameter int RSP_DEPTH = 8,     // client response FIFO depth
  parameter int AGE_W     = 12,
  parameter int AGE_THRESH = 256,
  parameter int CNT_W     = 9,
  // Timing, in controller clocks (HBM3-representative, see docs/timing.md)
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
  // Derived
  localparam int OFF_W  = $clog2(DATA_W / 8),
  localparam int ADDR_W = OFF_W + COL_W + BG_W + BK_W + ROW_W,
  localparam int BA_W   = BG_W + BK_W,
  localparam int NB     = 1 << BA_W,
  localparam int NUM_BG = 1 << BG_W,
  localparam int CL_W   = (NC > 1) ? $clog2(NC) : 1,
  localparam int QI_W   = (QDEPTH > 1) ? $clog2(QDEPTH) : 1,
  localparam int QC_W   = $clog2(QDEPTH + 1),
  localparam int RC_W   = $clog2(RSP_DEPTH + 1),
  localparam int PIPE_N = RL + 1
) (
  input  logic                 clk,
  input  logic                 rst_n,
  // configuration
  input  logic [1:0]           cfg_policy,
  input  logic                 cfg_refresh_en,
  // client request channels
  input  logic [NC-1:0]        req_valid,
  output logic [NC-1:0]        req_ready,
  input  logic [NC-1:0]        req_we,
  input  logic [NC*ADDR_W-1:0] req_addr,
  input  logic [NC*DATA_W-1:0] req_wdata,
  input  logic [NC*ID_W-1:0]   req_id,
  // client response channels (write ack or read data)
  output logic [NC-1:0]        rsp_valid,
  input  logic [NC-1:0]        rsp_ready,
  output logic [NC-1:0]        rsp_we,
  output logic [NC*ID_W-1:0]   rsp_id,
  output logic [NC*DATA_W-1:0] rsp_rdata,
  // HBM command/data interface (registered outputs)
  output logic [1:0]           row_cmd,
  output logic [BA_W-1:0]      row_ba,
  output logic [ROW_W-1:0]     row_addr,
  output logic [1:0]           col_cmd,
  output logic [BA_W-1:0]      col_ba,
  output logic [COL_W-1:0]     col_addr,
  output logic [DATA_W-1:0]    col_wdata,
  input  logic                 rd_valid,
  input  logic [DATA_W-1:0]    rd_data,
  // observability
  output logic                 dbg_aging_override,
  output logic                 dbg_ref_pending,
  output logic [QC_W-1:0]      dbg_q_count,
  output logic                 dbg_credit_stall
);

  // ---------------------------------------------------------------------------
  // 1. Client request FIFOs and round-robin admission
  // ---------------------------------------------------------------------------
  localparam int REQ_W = 1 + ADDR_W + DATA_W + ID_W;

  logic [NC-1:0]        cf_empty, cf_full, cf_pop;
  logic [REQ_W-1:0]     cf_dout [NC];
  logic [NC-1:0]        arb_gnt;
  logic                 q_has_free;
  logic [QI_W-1:0]      free_idx;
  wire  [31:0]          fi32 = {{(32-QI_W){1'b0}}, free_idx};

  for (genvar c = 0; c < NC; c++) begin : g_cf
    mc_fifo #(.W(REQ_W), .DEPTH(CF_DEPTH)) u_cf (
      .clk, .rst_n,
      .push  (req_valid[c] & req_ready[c]),
      .din   ({req_we[c], req_addr[c*ADDR_W +: ADDR_W],
               req_wdata[c*DATA_W +: DATA_W], req_id[c*ID_W +: ID_W]}),
      .pop   (cf_pop[c]),
      .dout  (cf_dout[c]),
      .empty (cf_empty[c]),
      .full  (cf_full[c]),
      .count ()
    );
    assign req_ready[c] = ~cf_full[c];
  end

  mc_rr_arb #(.N(NC)) u_arb (
    .clk, .rst_n,
    .req     (~cf_empty & {NC{q_has_free}}),
    .advance (q_has_free),
    .gnt     (arb_gnt)
  );

  assign cf_pop = arb_gnt & {NC{q_has_free}};
  wire   alloc  = |cf_pop;

  // Selected request (one-hot mux)
  logic [REQ_W-1:0] sel_req;
  logic [CL_W-1:0]  sel_cli;
  always_comb begin
    sel_req = '0;
    sel_cli = '0;
    for (int c = 0; c < NC; c++) begin
      if (arb_gnt[c]) begin
        sel_req = cf_dout[c];
        sel_cli = CL_W'(c);
      end
    end
  end

  wire                 sel_we    = sel_req[REQ_W-1];
  wire [ADDR_W-1:0]    sel_addr  = sel_req[DATA_W+ID_W +: ADDR_W];
  wire [DATA_W-1:0]    sel_wdata = sel_req[ID_W +: DATA_W];
  wire [ID_W-1:0]      sel_id    = sel_req[0 +: ID_W];
  wire [COL_W-1:0]     sel_col   = sel_addr[OFF_W +: COL_W];
  wire [BA_W-1:0]      sel_ba    = sel_addr[OFF_W + COL_W +: BA_W];  // {bank, bg}
  wire [ROW_W-1:0]     sel_row   = sel_addr[OFF_W + COL_W + BA_W +: ROW_W];

  // ---------------------------------------------------------------------------
  // 2. Command queue
  //    Bank address encoding: ba = {bank, bg}; bg = ba[BG_W-1:0]
  // ---------------------------------------------------------------------------
  logic [QDEPTH-1:0] e_valid;
  logic              e_we    [QDEPTH];
  logic [CL_W-1:0]   e_cli   [QDEPTH];
  logic [ID_W-1:0]   e_id    [QDEPTH];
  logic [BA_W-1:0]   e_ba    [QDEPTH];
  logic [ROW_W-1:0]  e_row   [QDEPTH];
  logic [COL_W-1:0]  e_col   [QDEPTH];
  logic [DATA_W-1:0] e_wdata [QDEPTH];
  logic [AGE_W-1:0]  e_wait  [QDEPTH];
  // older[i*QDEPTH+j] == 1 : entry i was admitted before entry j
  logic [QDEPTH*QDEPTH-1:0] older;

  always_comb begin
    q_has_free = ~&e_valid;
    free_idx   = '0;
    for (int i = QDEPTH - 1; i >= 0; i--) begin
      if (!e_valid[i]) free_idx = QI_W'(i);
    end
  end

  // Oldest requester in a vector, using the age matrix
  function automatic logic [QDEPTH-1:0] oldest(input logic [QDEPTH-1:0] req,
                                               input logic [QDEPTH*QDEPTH-1:0] om);
    logic [QDEPTH-1:0] r;
    logic              beaten;
    r = '0;
    for (int i = 0; i < QDEPTH; i++) begin
      beaten = 1'b0;
      for (int j = 0; j < QDEPTH; j++) begin
        if (j != i && req[j] && om[j*QDEPTH+i]) beaten = 1'b1;
      end
      r[i] = req[i] & ~beaten;
    end
    oldest = r;
  endfunction

  // ---------------------------------------------------------------------------
  // 3. Bank state, rank timers, refresh
  // ---------------------------------------------------------------------------
  logic [NB-1:0]     bk_open, bk_act_ok, bk_pre_ok, bk_col_ok;
  logic [ROW_W-1:0]  bk_row [NB];
  logic [NB-1:0]     bk_do_act, bk_do_pre, bk_do_rd, bk_do_wr;
  logic              do_ref;
  logic [ROW_W-1:0]  act_row_sel;

  for (genvar b = 0; b < NB; b++) begin : g_bank
    mc_bank #(
      .ROW_W(ROW_W), .CNT_W(CNT_W),
      .T_RCD(T_RCD), .T_RP(T_RP), .T_RAS(T_RAS), .T_RC(T_RC),
      .T_RTP(T_RTP), .T_WRP(WL + BURST + T_WR), .T_RFC(T_RFC)
    ) u_bank (
      .clk, .rst_n,
      .do_act  (bk_do_act[b]),
      .do_pre  (bk_do_pre[b]),
      .do_rd   (bk_do_rd[b]),
      .do_wr   (bk_do_wr[b]),
      .do_ref  (do_ref),
      .act_row (act_row_sel),
      .is_open (bk_open[b]),
      .open_row(bk_row[b]),
      .act_ok  (bk_act_ok[b]),
      .pre_ok  (bk_pre_ok[b]),
`ifdef MUT_TRCD
      .col_ok  ()
`else
      .col_ok  (bk_col_ok[b])
`endif
    );
`ifdef MUT_TRCD
    // MUTANT: ignore tRCD, column commands may follow ACT immediately
    assign bk_col_ok[b] = bk_open[b];
`endif
  end

  logic [NUM_BG-1:0] act_ok_bg, rd_ok_bg, wr_ok_bg;
  logic              rk_do_act, rk_do_rd, rk_do_wr;
  logic [BG_W-1:0]   rk_act_bg, rk_col_bg;

  mc_rank_timer #(
    .NUM_BG(NUM_BG), .BG_W(BG_W), .CNT_W(CNT_W),
    .T_RRD_S(T_RRD_S), .T_RRD_L(T_RRD_L), .T_FAW(T_FAW),
    .T_CCD_S(T_CCD_S), .T_CCD_L(T_CCD_L),
    .T_WTR_S(WL + BURST + T_WTR_S), .T_WTR_L(WL + BURST + T_WTR_L),
    .T_RTW(T_RTW)
  ) u_rank (
    .clk, .rst_n,
    .do_act (rk_do_act), .act_bg (rk_act_bg),
    .do_rd  (rk_do_rd),  .do_wr  (rk_do_wr), .col_bg (rk_col_bg),
    .act_ok_bg, .rd_ok_bg, .wr_ok_bg
  );

  logic ref_pending;
  mc_refresh #(.T_REFI(T_REFI)) u_ref (
    .clk, .rst_n,
    .enable      (cfg_refresh_en),
    .ref_done    (do_ref),
    .ref_pending (ref_pending)
  );

  // ---------------------------------------------------------------------------
  // 4. Completion pipeline and response credits
  // ---------------------------------------------------------------------------
  logic [PIPE_N-1:0] tp_v;
  logic              tp_we  [PIPE_N];
  logic [CL_W-1:0]   tp_cli [PIPE_N];
  logic [ID_W-1:0]   tp_id  [PIPE_N];

  logic [RC_W-1:0]   rsp_cnt  [NC];
  logic [RC_W-1:0]   inflight [NC];
  logic [NC-1:0]     credit_ok;

  always_comb begin
    for (int c = 0; c < NC; c++) begin
      inflight[c] = '0;
      for (int k = 0; k < PIPE_N; k++) begin
        if (tp_v[k] && tp_cli[k] == CL_W'(c)) inflight[c] = inflight[c] + RC_W'(1);
      end
`ifdef MUT_CREDIT
      // MUTANT: off-by-one, lets one more completion in than the FIFO holds
      credit_ok[c] = (rsp_cnt[c] + inflight[c]) <= RC_W'(RSP_DEPTH);
`else
      credit_ok[c] = (rsp_cnt[c] + inflight[c]) <  RC_W'(RSP_DEPTH);
`endif
    end
  end

  // ---------------------------------------------------------------------------
  // 5. Scheduler
  // ---------------------------------------------------------------------------
  logic [QDEPTH-1:0] hit, miss, conf, blocked;
  logic [NB-1:0]     hit_pending;
  logic [QDEPTH-1:0] oldest_oh, elig, col_req, act_req, pre_req, col_pick, row_pick;
  logic              fcfs, starve;
  logic [BA_W-1:0]   starve_ba;
  logic              col_go, row_go;
  logic [QI_W-1:0]   col_idx, row_idx;

  always_comb begin
    hit_pending = '0;
    for (int i = 0; i < QDEPTH; i++) begin
      hit[i]  = e_valid[i] &  bk_open[e_ba[i]] & (bk_row[e_ba[i]] == e_row[i]);
      miss[i] = e_valid[i] & ~bk_open[e_ba[i]];
      conf[i] = e_valid[i] &  bk_open[e_ba[i]] & (bk_row[e_ba[i]] != e_row[i]);
      if (hit[i]) hit_pending[e_ba[i]] = 1'b1;
      blocked[i] = 1'b0;
`ifndef MUT_HAZARD
      for (int j = 0; j < QDEPTH; j++) begin
        if (j != i && e_valid[j] && older[j*QDEPTH+i] &&
            e_ba[j] == e_ba[i] && e_row[j] == e_row[i] && e_col[j] == e_col[i])
          blocked[i] = 1'b1;
      end
`endif
    end

    // Policy:
    //   FCFS          only the oldest request may issue anything
    //   FR-FCFS       any ready request; column hits first, oldest first
    //   FR-FCFS+aging as FR-FCFS, but once the oldest request has waited
    //                 AGE_THRESH cycles its bank is reserved for it: younger
    //                 hits to that bank are held so its row can be closed.
    //                 Other banks keep running at full rate.
    oldest_oh = oldest(e_valid, older);
    fcfs      = (cfg_policy == hbm3_mc_pkg::POL_FCFS);
    starve    = 1'b0;
    starve_ba = '0;
    for (int i = 0; i < QDEPTH; i++) begin
      if (oldest_oh[i]) starve_ba = e_ba[i];
`ifndef MUT_NO_AGING
      if (cfg_policy == hbm3_mc_pkg::POL_FRFCFS_A && oldest_oh[i] &&
          e_wait[i] >= AGE_W'(AGE_THRESH))
        starve = 1'b1;
`endif
    end
    elig = fcfs ? oldest_oh : e_valid;

    // Column bus candidates
    for (int i = 0; i < QDEPTH; i++) begin
      col_req[i] = elig[i] & hit[i] & ~blocked[i] & ~ref_pending &
                   bk_col_ok[e_ba[i]] & credit_ok[e_cli[i]] &
                   (e_we[i] ? wr_ok_bg[e_ba[i][BG_W-1:0]] : rd_ok_bg[e_ba[i][BG_W-1:0]]) &
                   ~(starve && e_ba[i] == starve_ba && !oldest_oh[i]);
    end
    col_pick = oldest(col_req, older);
    col_go   = |col_pick;
    col_idx  = '0;
    for (int i = 0; i < QDEPTH; i++) if (col_pick[i]) col_idx = QI_W'(i);

    // Row bus candidates (never PRE the bank the column bus is using this cycle).
    // A PRE that would close a row other requests still hit is held back,
    // except for the oldest request under FCFS or aging.
    for (int i = 0; i < QDEPTH; i++) begin
      act_req[i] = elig[i] & miss[i] & ~blocked[i] & ~ref_pending &
                   bk_act_ok[e_ba[i]] & act_ok_bg[e_ba[i][BG_W-1:0]];
      pre_req[i] = elig[i] & conf[i] & ~blocked[i] & ~ref_pending &
                   bk_pre_ok[e_ba[i]] &
                   (fcfs | (starve & oldest_oh[i]) | ~hit_pending[e_ba[i]]) &
                   ~(col_go && e_ba[col_idx] == e_ba[i]);
    end
    row_pick = oldest(act_req | pre_req, older);
    row_go   = |row_pick;
    row_idx  = '0;
    for (int i = 0; i < QDEPTH; i++) if (row_pick[i]) row_idx = QI_W'(i);
  end

  // Refresh sequencing: close every open bank, then REF once tRP/tRC are met
  logic          ref_pre_go;
  logic [BA_W-1:0] ref_pre_ba;
  always_comb begin
    ref_pre_go = 1'b0;
    ref_pre_ba = '0;
    for (int b = NB - 1; b >= 0; b--) begin
      if (bk_pre_ok[b]) begin
        ref_pre_go = 1'b1;
        ref_pre_ba = BA_W'(b);
      end
    end
`ifdef MUT_REF_EARLY
    // MUTANT: issue REF without waiting for every bank to close
    do_ref = ref_pending & ~ref_pre_go;
`else
    do_ref = ref_pending & ~|bk_open & &bk_act_ok;
`endif
  end

  // Final command decode for this cycle
  logic [1:0]       nxt_row_cmd, nxt_col_cmd;
  logic [BA_W-1:0]  nxt_row_ba,  nxt_col_ba;
  logic [ROW_W-1:0] nxt_row_addr;
  logic [COL_W-1:0] nxt_col_addr;
  logic [DATA_W-1:0] nxt_wdata;

  always_comb begin
    nxt_col_cmd  = hbm3_mc_pkg::COL_NOP;
    nxt_col_ba   = e_ba[col_idx];
    nxt_col_addr = e_col[col_idx];
    nxt_wdata    = e_wdata[col_idx];
`ifdef MUT_WDATA
    // MUTANT: data-path corruption on the last column of a row
    if (e_col[col_idx] == '1) nxt_wdata[0] = ~nxt_wdata[0];
`endif
    if (col_go) nxt_col_cmd = e_we[col_idx] ? hbm3_mc_pkg::COL_WR : hbm3_mc_pkg::COL_RD;

    nxt_row_cmd  = hbm3_mc_pkg::ROW_NOP;
    nxt_row_ba   = e_ba[row_idx];
    nxt_row_addr = e_row[row_idx];
    if (ref_pending) begin
      if (do_ref) begin
        nxt_row_cmd = hbm3_mc_pkg::ROW_REF;
      end else if (ref_pre_go && bk_open[ref_pre_ba]) begin
        nxt_row_cmd = hbm3_mc_pkg::ROW_PRE;
        nxt_row_ba  = ref_pre_ba;
      end
    end else if (row_go) begin
      nxt_row_cmd = miss[row_idx] ? hbm3_mc_pkg::ROW_ACT : hbm3_mc_pkg::ROW_PRE;
    end

    for (int b = 0; b < NB; b++) begin
      bk_do_act[b] = (nxt_row_cmd == hbm3_mc_pkg::ROW_ACT) && nxt_row_ba == BA_W'(b);
      bk_do_pre[b] = (nxt_row_cmd == hbm3_mc_pkg::ROW_PRE) && nxt_row_ba == BA_W'(b);
      bk_do_rd[b]  = (nxt_col_cmd == hbm3_mc_pkg::COL_RD)  && nxt_col_ba == BA_W'(b);
      bk_do_wr[b]  = (nxt_col_cmd == hbm3_mc_pkg::COL_WR)  && nxt_col_ba == BA_W'(b);
    end
    act_row_sel = nxt_row_addr;
    rk_do_act   = (nxt_row_cmd == hbm3_mc_pkg::ROW_ACT);
    rk_act_bg   = nxt_row_ba[BG_W-1:0];
    rk_do_rd    = (nxt_col_cmd == hbm3_mc_pkg::COL_RD);
    rk_do_wr    = (nxt_col_cmd == hbm3_mc_pkg::COL_WR);
    rk_col_bg   = nxt_col_ba[BG_W-1:0];
  end

  // ---------------------------------------------------------------------------
  // 6. Sequential state
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      e_valid <= '0;
      older <= '0;
      for (int i = 0; i < QDEPTH; i++) e_wait[i] <= '0;
      tp_v      <= '0;
      row_cmd   <= hbm3_mc_pkg::ROW_NOP;
      col_cmd   <= hbm3_mc_pkg::COL_NOP;
      row_ba    <= '0;
      row_addr  <= '0;
      col_ba    <= '0;
      col_addr  <= '0;
    end else begin
      // Ages
      for (int i = 0; i < QDEPTH; i++) begin
        if (e_valid[i] && e_wait[i] != '1) e_wait[i] <= e_wait[i] + AGE_W'(1);
      end
      // Retire on column issue
      if (col_go) e_valid[col_idx] <= 1'b0;
      // Admit
      if (alloc) begin
        e_valid[free_idx] <= 1'b1;
        e_wait[free_idx]  <= '0;
        for (int j = 0; j < QDEPTH; j++) begin
          older[fi32*QDEPTH + j] <= 1'b0;
          older[j*QDEPTH + fi32]   <= e_valid[j];
        end
      end
      // Completion pipeline
      tp_v <= {tp_v[PIPE_N-2:0], col_go};
      // Command bus
      row_cmd  <= nxt_row_cmd;
      row_ba   <= nxt_row_ba;
      row_addr <= nxt_row_addr;
      col_cmd  <= nxt_col_cmd;
      col_ba   <= nxt_col_ba;
      col_addr <= nxt_col_addr;
    end
  end

  // Payload storage without reset (datapath)
  always_ff @(posedge clk) begin
    if (alloc) begin
      e_we[free_idx]    <= sel_we;
      e_cli[free_idx]   <= sel_cli;
      e_id[free_idx]    <= sel_id;
      e_ba[free_idx]    <= sel_ba;
      e_row[free_idx]   <= sel_row;
      e_col[free_idx]   <= sel_col;
      e_wdata[free_idx] <= sel_wdata;
    end
    tp_we[0]  <= e_we[col_idx];
    tp_cli[0] <= e_cli[col_idx];
    tp_id[0]  <= e_id[col_idx];
    for (int k = 1; k < PIPE_N; k++) begin
      tp_we[k]  <= tp_we[k-1];
      tp_cli[k] <= tp_cli[k-1];
      tp_id[k]  <= tp_id[k-1];
    end
    col_wdata <= nxt_wdata;
  end

  // ---------------------------------------------------------------------------
  // 7. Response FIFOs
  // ---------------------------------------------------------------------------
  localparam int RSP_W = 1 + ID_W + DATA_W;
  wire tp_out_v = tp_v[PIPE_N-1];

  for (genvar c = 0; c < NC; c++) begin : g_rsp
    logic [RSP_W-1:0] rdout;
    logic             rempty;
    mc_fifo #(.W(RSP_W), .DEPTH(RSP_DEPTH)) u_rsp (
      .clk, .rst_n,
      .push  (tp_out_v && tp_cli[PIPE_N-1] == CL_W'(c)),
      .din   ({tp_we[PIPE_N-1], tp_id[PIPE_N-1],
               tp_we[PIPE_N-1] ? {DATA_W{1'b0}} : rd_data}),
      .pop   (rsp_valid[c] & rsp_ready[c]),
      .dout  (rdout),
      .empty (rempty),
      .full  (),
      .count (rsp_cnt[c])
    );
    assign rsp_valid[c]                   = ~rempty;
    assign rsp_we[c]                      = rdout[RSP_W-1];
    assign rsp_id[c*ID_W +: ID_W]         = rdout[DATA_W +: ID_W];
    assign rsp_rdata[c*DATA_W +: DATA_W]  = rdout[DATA_W-1:0];
  end

  // ---------------------------------------------------------------------------
  // 8. Observability
  // ---------------------------------------------------------------------------
  always_comb begin
    dbg_q_count = '0;
    for (int i = 0; i < QDEPTH; i++) dbg_q_count = dbg_q_count + QC_W'(e_valid[i]);
    dbg_credit_stall = 1'b0;
    for (int i = 0; i < QDEPTH; i++) begin
      if (elig[i] && hit[i] && !credit_ok[e_cli[i]]) dbg_credit_stall = 1'b1;
    end
  end
  // Flattened views of internal arrays for the bound assertion module
  logic [NC*RC_W-1:0]      dbg_rsp_cnt_flat, dbg_inflight_flat;
  logic [QDEPTH*AGE_W-1:0] dbg_e_wait_flat;
  always_comb begin
    for (int c = 0; c < NC; c++) begin
      dbg_rsp_cnt_flat [c*RC_W +: RC_W] = rsp_cnt[c];
      dbg_inflight_flat[c*RC_W +: RC_W] = inflight[c];
    end
    for (int i = 0; i < QDEPTH; i++) dbg_e_wait_flat[i*AGE_W +: AGE_W] = e_wait[i];
  end

  assign dbg_aging_override = starve;

`ifdef FORMAL
  // Open-source formal (Yosys) does not support `bind`, so the white-box
  // assertion module is instantiated directly in formal builds only.
  hbm3_mc_sva #(
    .NC(NC), .ID_W(ID_W), .DATA_W(DATA_W), .ADDR_W(ADDR_W), .OFF_W(OFF_W),
    .QDEPTH(QDEPTH), .RSP_DEPTH(RSP_DEPTH), .RC_W(RC_W), .AGE_W(AGE_W),
    .PIPE_N(PIPE_N),
    .STARVE_BOUND(AGE_THRESH + QDEPTH * (T_RAS + T_RP + T_RCD + T_RTW + T_WTR_L + WL + BURST) + T_RFC + T_RAS + 64)
  ) u_mc_sva_f (
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
  assign dbg_ref_pending    = ref_pending;

endmodule
