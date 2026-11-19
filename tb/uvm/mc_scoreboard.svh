// -----------------------------------------------------------------------------
// mc_scoreboard.svh : reference model + end-to-end scoreboard
//
// The controller may legally reorder requests to different lines and
// interleave racing requests from different clients to the same line, so the
// model does not replay arrival order. It tracks the order in which writes are
// committed on the HBM bus and accepts a read value only if it is legal:
//   floor   : last write committed before the read was accepted
//   order   : the same client's own most recent earlier write to the line
//   ceiling : writes committed before the read's RD could have issued
//             (response cycle - RL - 1)
// Every write must reach the bus exactly once with the right data on the right
// line; every request must receive exactly one response of the right type.
// -----------------------------------------------------------------------------

`uvm_analysis_imp_decl(_req)
`uvm_analysis_imp_decl(_rsp)
`uvm_analysis_imp_decl(_cmd)

typedef struct {
  int unsigned     cyc;
  bit [DATA_W-1:0] data;
  longint unsigned key;
} commit_t;

typedef struct {
  longint unsigned key;
  bit [DATA_W-1:0] data;
} pend_t;

class mc_ref_model extends uvm_object;
  `uvm_object_utils(mc_ref_model)

  bit [ROW_W-1:0]  open_row [bit [BA_W-1:0]];
  commit_t         commits  [line_t][$];
  int              commit_at[longint unsigned];     // write key -> index in commits[line]
  pend_t           pending  [line_t][$];
  longint unsigned last_own_wr[string];            // "client:line" -> write key

  function new(string name = "mc_ref_model");
    super.new(name);
  endfunction

  static function string own_key(int unsigned c, line_t l);
    return $sformatf("%0d:%0h", c, l);
  endfunction

  function void on_row(mc_cmd_item c);
    if (c.row_cmd == 2'd1) open_row[c.row_ba] = c.row_addr;
    else if (c.row_cmd == 2'd2) open_row.delete(c.row_ba);
  endfunction

  function bit col_line(mc_cmd_item c, output line_t l);
    if (!open_row.exists(c.col_ba)) return 0;
    l = {c.col_ba, open_row[c.col_ba], c.col_addr};
    return 1;
  endfunction

  function void add_write(longint unsigned key, int unsigned client, line_t l,
                          bit [DATA_W-1:0] d);
    pend_t p;
    p.key = key;  p.data = d;
    pending[l].push_back(p);
    last_own_wr[own_key(client, l)] = key;
  endfunction

  // Returns 1 when the WR command matches an outstanding client write.
  function bit commit_write(mc_cmd_item c, output string why);
    line_t l;
    if (!col_line(c, l)) begin
      why = $sformatf("WR to closed bank %0d", c.col_ba);
      return 0;
    end
    if (pending.exists(l)) begin
      foreach (pending[l][i]) begin
        if (pending[l][i].data == c.wdata) begin
          commit_t cm;
          cm.cyc = c.cyc;  cm.data = c.wdata;  cm.key = pending[l][i].key;
          commits[l].push_back(cm);
          commit_at[cm.key] = commits[l].size() - 1;
          pending[l].delete(i);
          return 1;
        end
      end
    end
    why = $sformatf("WR @%0d to line %0h carries data no client has outstanding for it",
                    c.cyc, l);
    return 0;
  endfunction

  // Legal read values; returns 0 with a reason on an ordering violation.
  function bit legal_values(line_t l, int unsigned t_acc, int unsigned t_rsp,
                            bit has_must, longint unsigned must_key,
                            ref bit [DATA_W-1:0] vals[$], output string why);
    int base = -1, upper = -1;
    int hi = int'(t_rsp) - RL - 1;
    vals.delete();
    if (commits.exists(l)) begin
      foreach (commits[l][i]) begin
        if (commits[l][i].cyc <= t_acc) base = i;
        if (int'(commits[l][i].cyc) <= hi) upper = i;
      end
    end
    if (has_must) begin
      if (!commit_at.exists(must_key)) begin
        why = "read overtook the same client's earlier write to this line";
        return 0;
      end
      if (commit_at[must_key] > upper) begin
        why = "read returned before the same client's earlier write committed";
        return 0;
      end
      if (commit_at[must_key] > base) base = commit_at[must_key];
    end
    if (base == -1) begin
      vals.push_back('0);
      base = 0;
    end
    for (int i = base; i <= upper; i++) vals.push_back(commits[l][i].data);
    return 1;
  endfunction
endclass


class mc_scoreboard extends uvm_scoreboard;
  `uvm_component_utils(mc_scoreboard)

  uvm_analysis_imp_req #(mc_txn, mc_scoreboard)      req_imp;
  uvm_analysis_imp_rsp #(mc_txn, mc_scoreboard)      rsp_imp;
  uvm_analysis_imp_cmd #(mc_cmd_item, mc_scoreboard) cmd_imp;

  mc_ref_model model;

  typedef struct {
    mc_txn           req;
    longint unsigned key;
    bit              has_must;
    longint unsigned must_key;
  } outst_t;
  outst_t          outstanding[string];     // "client:id"
  longint unsigned seq;
  int unsigned     n_err, n_req, n_rsp, n_rd_cmd, n_wr_cmd, n_act, n_hit;
  int unsigned     lat_max[NC];
  longint unsigned lat_sum[NC], lat_n[NC];
  bit              fresh[bit [BA_W-1:0]];

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    req_imp = new("req_imp", this);
    rsp_imp = new("rsp_imp", this);
    cmd_imp = new("cmd_imp", this);
    model   = mc_ref_model::type_id::create("model");
  endfunction

  function void fail(string msg);
    n_err++;
    `uvm_error("SB", msg)
  endfunction

  static function string okey(int unsigned c, bit [ID_W-1:0] id);
    return $sformatf("%0d:%0d", c, id);
  endfunction

  function int unsigned outstanding_count();
    return outstanding.num();
  endfunction

  // ------------------------------------------------------------------ inputs
  function void write_req(mc_txn t);
    outst_t o;
    line_t  l = addr2line(t.addr);
    if (outstanding.exists(okey(t.client, t.id)))
      fail($sformatf("client %0d reused outstanding id %0d", t.client, t.id));
    seq++;
    o.req = t;  o.key = seq;  o.has_must = 0;
    if (t.we) begin
      model.add_write(seq, t.client, l, t.data);
    end else if (model.last_own_wr.exists(mc_ref_model::own_key(t.client, l))) begin
      o.has_must = 1;
      o.must_key = model.last_own_wr[mc_ref_model::own_key(t.client, l)];
    end
    outstanding[okey(t.client, t.id)] = o;
    n_req++;
  endfunction

  function void write_cmd(mc_cmd_item c);
    string why;
    line_t l;
    if (c.row_cmd != 0) model.on_row(c);
    if (c.row_cmd == 2'd1) begin
      n_act++;
      fresh[c.row_ba] = 1;
    end
    if (c.col_cmd != 0) begin
      if (fresh.exists(c.col_ba)) fresh.delete(c.col_ba);
      else n_hit++;
    end
    if (c.col_cmd == 2'd2) begin
      n_wr_cmd++;
      if (!model.commit_write(c, why)) fail(why);
    end else if (c.col_cmd == 2'd1) begin
      n_rd_cmd++;
      if (!model.col_line(c, l)) fail($sformatf("RD to closed bank %0d", c.col_ba));
    end
  endfunction

  function void write_rsp(mc_txn t);
    outst_t o;
    bit [DATA_W-1:0] vals[$];
    string why;
    int unsigned lat;
    if (!outstanding.exists(okey(t.client, t.id))) begin
      fail($sformatf("client %0d: response id %0d with nothing outstanding", t.client, t.id));
      return;
    end
    o = outstanding[okey(t.client, t.id)];
    outstanding.delete(okey(t.client, t.id));
    n_rsp++;
    lat = t.cyc - o.req.cyc;
    lat_sum[t.client] += lat;  lat_n[t.client]++;
    if (lat > lat_max[t.client]) lat_max[t.client] = lat;
    if (t.we != o.req.we) begin
      fail($sformatf("client %0d id %0d: response type mismatch", t.client, t.id));
      return;
    end
    if (o.req.we) begin
      if (!model.commit_at.exists(o.key))
        fail($sformatf("client %0d id %0d: write acknowledged but never issued", t.client, t.id));
      return;
    end
    if (!model.legal_values(addr2line(o.req.addr), o.req.cyc, t.cyc, o.has_must, o.must_key,
                            vals, why))
      fail($sformatf("client %0d id %0d addr 0x%0h: %s", t.client, t.id, o.req.addr, why));
    else if (!(t.data inside {vals}))
      fail($sformatf("client %0d id %0d addr 0x%0h: read data not among %0d legal value(s)",
                     t.client, t.id, o.req.addr, vals.size()));
  endfunction

  // ------------------------------------------------------------- end of test
  function void check_phase(uvm_phase phase);
    foreach (outstanding[k])
      fail($sformatf("request %s (%s 0x%0h, accepted @%0d) never completed", k,
                     outstanding[k].req.we ? "WR" : "RD", outstanding[k].req.addr,
                     outstanding[k].req.cyc));
    foreach (model.pending[l])
      if (model.pending[l].size())
        fail($sformatf("%0d write(s) to line %0h never reached HBM", model.pending[l].size(), l));
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf("requests=%0d responses=%0d RD=%0d WR=%0d ACT=%0d hit_rate=%0.3f errors=%0d",
              n_req, n_rsp, n_rd_cmd, n_wr_cmd, n_act,
              (n_rd_cmd + n_wr_cmd) ? real'(n_hit) / (n_rd_cmd + n_wr_cmd) : 0.0, n_err), UVM_LOW)
    for (int c = 0; c < NC; c++)
      if (lat_n[c])
        `uvm_info("SB", $sformatf("client %0d: mean latency %0.1f, max %0d cycles", c,
                  real'(lat_sum[c]) / lat_n[c], lat_max[c]), UVM_LOW)
  endfunction
endclass
