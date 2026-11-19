// -----------------------------------------------------------------------------
// mc_coverage.svh : functional coverage model (mirrors tb/pyuvm/mc_coverage.py)
// -----------------------------------------------------------------------------

typedef enum bit [1:0] {OUT_HIT, OUT_MISS, OUT_CONFLICT} outcome_e;
typedef enum bit [2:0] {HZ_NONE, HZ_RAW, HZ_WAR, HZ_WAW, HZ_RAR} hazard_e;

class mc_coverage extends uvm_component;
  `uvm_component_utils(mc_coverage)

  uvm_analysis_imp_req #(mc_txn, mc_coverage)      req_imp;
  uvm_analysis_imp_rsp #(mc_txn, mc_coverage)      rsp_imp;
  uvm_analysis_imp_cmd #(mc_cmd_item, mc_coverage) cmd_imp;

  // ---- request stream ------------------------------------------------------
  covergroup cg_req with function sample(int unsigned client, bit we,
                                         bit [BG_W-1:0] bg, bit [BA_W-1:0] ba,
                                         hazard_e hz, bit cross_client);
    cp_client : coverpoint client { bins c[] = {[0:NC-1]}; }
    cp_kind   : coverpoint we     { bins rd = {0}; bins wr = {1}; }
    cp_bg     : coverpoint bg;
    cp_bank   : coverpoint ba;
    cp_hazard : coverpoint hz     { bins raw = {HZ_RAW}; bins war = {HZ_WAR};
                                    bins waw = {HZ_WAW}; bins rar = {HZ_RAR}; }
    cp_hz_xc  : coverpoint cross_client iff (hz == HZ_RAW) { bins raw_cross_client = {1}; }
    x_client_kind : cross cp_client, cp_kind;
    x_bg_kind     : cross cp_bg, cp_kind;
  endgroup

  // ---- command stream -------------------------------------------------------
  covergroup cg_col with function sample(outcome_e oc, bit we, bit [1:0] policy,
                                         bit prev_we, bit same_bg, bit has_prev);
    cp_outcome : coverpoint oc;
    cp_kind    : coverpoint we { bins rd = {0}; bins wr = {1}; }
    cp_policy  : coverpoint policy { bins fcfs = {0}; bins frfcfs = {1}; bins aging = {2}; }
    cp_prev    : coverpoint prev_we iff (has_prev) { bins rd = {0}; bins wr = {1}; }
    cp_same_bg : coverpoint same_bg iff (has_prev);
    x_outcome_kind   : cross cp_outcome, cp_kind;
    x_policy_outcome : cross cp_policy, cp_outcome;
    // RD->RD, RD->WR, WR->RD, WR->WR, each within / across bank groups
    x_turnaround     : cross cp_prev, cp_kind, cp_same_bg;
  endgroup

  covergroup cg_cycle with function sample(int unsigned q, bit aging, bit credit_stall,
                                           bit ref_pending, bit [1:0] row_cmd, bit [1:0] col_cmd);
    cp_occupancy : coverpoint q { bins empty = {0}; bins low = {[1:4]}; bins mid = {[5:8]};
                                  bins high = {[9:QDEPTH-1]}; bins full = {QDEPTH}; }
    cp_aging     : coverpoint aging        { bins on = {1}; }
    cp_credit    : coverpoint credit_stall { bins on = {1}; }
    cp_refresh   : coverpoint row_cmd iff (row_cmd == 2'd3) { bins ref_issued = {3}; }
    cp_ref_load  : coverpoint (row_cmd == 2'd3 && q != 0) { bins ref_under_load = {1}; }
    cp_dual      : coverpoint {row_cmd, col_cmd} {
                     bins act_rd = {4'b01_01}; bins act_wr = {4'b01_10};
                     bins pre_rd = {4'b10_01}; bins pre_wr = {4'b10_10}; }
  endgroup

  covergroup cg_rsp with function sample(int unsigned lat, bit we, bit ooo);
    cp_lat  : coverpoint lat { bins lt30 = {[0:29]}; bins b30 = {[30:59]}; bins b60 = {[60:119]};
                               bins b120 = {[120:249]}; bins b250 = {[250:499]};
                               bins ge500 = {[500:$]}; }
    cp_kind : coverpoint we { bins rd = {0}; bins wr = {1}; }
    cp_order: coverpoint ooo { bins in_order = {0}; bins out_of_order = {1}; }
    x_lat_kind : cross cp_lat, cp_kind;
  endgroup

  // ---- state for derived events -----------------------------------------------
  bit [ROW_W-1:0] open_row[bit [BA_W-1:0]];
  bit             fresh[bit [BA_W-1:0]];
  bit             conflict[bit [BA_W-1:0]];
  bit             have_prev, prev_we;
  bit [BG_W-1:0]  prev_bg;
  typedef struct { line_t l; bit we; int unsigned c; } recent_t;
  recent_t        recent[$];
  typedef struct { longint unsigned seq; int unsigned cyc; bit we; } ent_t;
  ent_t           outst[string];
  longint unsigned req_seq, last_rsp_seq[NC];

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_req = new();
    cg_col = new();
    cg_cycle = new();
    cg_rsp = new();
  endfunction

  function void build_phase(uvm_phase phase);
    req_imp = new("req_imp", this);
    rsp_imp = new("rsp_imp", this);
    cmd_imp = new("cmd_imp", this);
  endfunction

  function void write_req(mc_txn t);
    line_t   l  = addr2line(t.addr);
    hazard_e hz = HZ_NONE;
    bit      xc = 0;
    foreach (recent[i]) begin
      if (recent[i].l == l) begin
        case ({recent[i].we, t.we})
          2'b10: hz = HZ_RAW;
          2'b01: hz = HZ_WAR;
          2'b11: hz = HZ_WAW;
          default: hz = HZ_RAR;
        endcase
        xc = (recent[i].c != t.client);
        break;
      end
    end
    recent.push_front('{l, t.we, t.client});
    if (recent.size() > 64) void'(recent.pop_back());
    cg_req.sample(t.client, t.we, l[ROW_W+COL_W +: BG_W],
                  l[ROW_W+COL_W +: BA_W], hz, xc);
    req_seq++;
    outst[$sformatf("%0d:%0d", t.client, t.id)] = '{req_seq, t.cyc, t.we};
  endfunction

  function void write_rsp(mc_txn t);
    string k = $sformatf("%0d:%0d", t.client, t.id);
    ent_t  e;
    if (!outst.exists(k)) return;
    e = outst[k];
    outst.delete(k);
    cg_rsp.sample(t.cyc - e.cyc, e.we, e.seq < last_rsp_seq[t.client]);
    if (e.seq > last_rsp_seq[t.client]) last_rsp_seq[t.client] = e.seq;
  endfunction

  function void write_cmd(mc_cmd_item c);
    outcome_e oc;
    cg_cycle.sample(c.q_count, c.aging, c.credit_stall, c.ref_pending, c.row_cmd, c.col_cmd);
    if (c.row_cmd == 2'd1) begin
      open_row[c.row_ba] = c.row_addr;
      fresh[c.row_ba] = 1;
    end else if (c.row_cmd == 2'd2) begin
      open_row.delete(c.row_ba);
      if (!c.ref_pending) conflict[c.row_ba] = 1;
    end
    if (c.col_cmd != 0) begin
      if (fresh.exists(c.col_ba)) begin
        oc = conflict.exists(c.col_ba) ? OUT_CONFLICT : OUT_MISS;
        fresh.delete(c.col_ba);
        conflict.delete(c.col_ba);
      end else oc = OUT_HIT;
      cg_col.sample(oc, c.col_cmd == 2'd2, c.policy, prev_we,
                    prev_bg == c.col_ba[BG_W-1:0], have_prev);
      have_prev = 1;
      prev_we   = (c.col_cmd == 2'd2);
      prev_bg   = c.col_ba[BG_W-1:0];
    end
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("req %0.1f%%  col %0.1f%%  cycle %0.1f%%  rsp %0.1f%%",
              cg_req.get_inst_coverage(), cg_col.get_inst_coverage(),
              cg_cycle.get_inst_coverage(), cg_rsp.get_inst_coverage()), UVM_LOW)
  endfunction
endclass
