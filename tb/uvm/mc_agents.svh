// -----------------------------------------------------------------------------
// mc_agents.svh : configuration, client agent (active), command agent (passive)
// -----------------------------------------------------------------------------

typedef virtual mc_client_if #(ADDR_W, DATA_W, ID_W) client_vif_t;
typedef virtual mc_cmd_if #(BA_W, ROW_W, COL_W, DATA_W, QC_W) cmd_vif_t;

class mc_env_cfg extends uvm_object;
  client_vif_t client_vif[NC];
  cmd_vif_t    cmd_vif;
  bit [1:0]    policy        = 2;     // FR-FCFS + aging
  bit          refresh_en    = 1;
  int unsigned rsp_ready_pct = 100;
  int unsigned drain_timeout = 200000;
  bit          has_coverage  = 1;
  `uvm_object_utils(mc_env_cfg)
  function new(string name = "mc_env_cfg");
    super.new(name);
  endfunction
endclass


// Transaction IDs: a request may only use an ID with no response pending.
class mc_id_pool extends uvm_object;
  bit busy[1 << ID_W];
  int unsigned n_busy;
  `uvm_object_utils(mc_id_pool)
  function new(string name = "mc_id_pool");
    super.new(name);
  endfunction

  task get(output bit [ID_W-1:0] id);
    int unsigned free_ids[$];
    wait (n_busy < (1 << ID_W));
    foreach (busy[i]) if (!busy[i]) free_ids.push_back(i);
    free_ids.shuffle();
    id = free_ids[0];
    busy[id] = 1'b1;
    n_busy++;
  endtask

  function void put(bit [ID_W-1:0] id);
    if (!busy[id]) `uvm_error("IDPOOL", $sformatf("id %0d freed twice", id))
    busy[id] = 1'b0;
    n_busy--;
  endfunction
endclass


class mc_client_driver extends uvm_driver #(mc_req_item);
  `uvm_component_utils(mc_client_driver)
  client_vif_t vif;
  mc_env_cfg   cfg;
  mc_id_pool   ids;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    vif.drv_cb.req_valid <= 1'b0;
    vif.drv_cb.rsp_ready <= 1'b0;
    wait (vif.rst_n === 1'b1);
    fork
      drive_requests();
      drive_rsp_ready();
    join
  endtask

  // Back-to-back capable valid/ready driver: valid and payload hold until the
  // DUT samples ready high on a clock edge.
  task drive_requests();
    forever begin
      seq_item_port.get_next_item(req);
      repeat (req.idle) @(vif.drv_cb);
      ids.get(req.id);
      vif.drv_cb.req_valid <= 1'b1;
      vif.drv_cb.req_we    <= req.we;
      vif.drv_cb.req_addr  <= req.addr();
      vif.drv_cb.req_wdata <= req.wdata;
      vif.drv_cb.req_id    <= req.id;
      do @(vif.drv_cb); while (vif.drv_cb.req_ready !== 1'b1);
      vif.drv_cb.req_valid <= 1'b0;
      seq_item_port.item_done();
    end
  endtask

  task drive_rsp_ready();
    forever begin
      vif.drv_cb.rsp_ready <= ($urandom_range(99) < cfg.rsp_ready_pct);
      @(vif.drv_cb);
    end
  endtask
endclass


class mc_client_monitor extends uvm_monitor;
  `uvm_component_utils(mc_client_monitor)
  client_vif_t vif;
  int unsigned client;
  mc_id_pool   ids;
  uvm_analysis_port #(mc_txn) req_ap;
  uvm_analysis_port #(mc_txn) rsp_ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    req_ap = new("req_ap", this);
    rsp_ap = new("rsp_ap", this);
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(vif.mon_cb);
      if (vif.rst_n !== 1'b1) continue;
      if (vif.mon_cb.req_valid && vif.mon_cb.req_ready) begin
        mc_txn t = mc_txn::type_id::create("req");
        t.client = client;  t.is_rsp = 0;
        t.we   = vif.mon_cb.req_we;    t.addr = vif.mon_cb.req_addr;
        t.data = vif.mon_cb.req_wdata; t.id   = vif.mon_cb.req_id;
        t.cyc  = vif.mon_cb.cyc;
        req_ap.write(t);
      end
      if (vif.mon_cb.rsp_valid && vif.mon_cb.rsp_ready) begin
        mc_txn t = mc_txn::type_id::create("rsp");
        t.client = client;  t.is_rsp = 1;
        t.we   = vif.mon_cb.rsp_we;    t.data = vif.mon_cb.rsp_rdata;
        t.id   = vif.mon_cb.rsp_id;    t.cyc  = vif.mon_cb.cyc;
        rsp_ap.write(t);
        ids.put(t.id);
      end
    end
  endtask
endclass


class mc_client_agent extends uvm_agent;
  `uvm_component_utils(mc_client_agent)
  int unsigned                  client;
  mc_env_cfg                    cfg;
  mc_id_pool                    ids;
  uvm_sequencer #(mc_req_item)  seqr;
  mc_client_driver              drv;
  mc_client_monitor             mon;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(int unsigned)::get(this, "", "client", client))
      `uvm_fatal("CFG", "client index not set")
    if (!uvm_config_db#(mc_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("CFG", "mc_env_cfg not set")
    ids = mc_id_pool::type_id::create("ids");
    mon = mc_client_monitor::type_id::create("mon", this);
    if (get_is_active() == UVM_ACTIVE) begin
      seqr = uvm_sequencer#(mc_req_item)::type_id::create("seqr", this);
      drv  = mc_client_driver::type_id::create("drv", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    mon.vif = cfg.client_vif[client];
    mon.client = client;
    mon.ids = ids;
    if (get_is_active() == UVM_ACTIVE) begin
      drv.seq_item_port.connect(seqr.seq_item_export);
      drv.vif = cfg.client_vif[client];
      drv.cfg = cfg;
      drv.ids = ids;
    end
  endfunction
endclass


class mc_cmd_monitor extends uvm_monitor;
  `uvm_component_utils(mc_cmd_monitor)
  cmd_vif_t vif;
  uvm_analysis_port #(mc_cmd_item) ap;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(vif.mon_cb);
      if (vif.rst_n !== 1'b1) continue;
      begin
        mc_cmd_item c = mc_cmd_item::type_id::create("cmd");
        c.cyc      = vif.mon_cb.cyc;
        c.row_cmd  = vif.mon_cb.row_cmd;  c.row_ba = vif.mon_cb.row_ba;
        c.row_addr = vif.mon_cb.row_addr;
        c.col_cmd  = vif.mon_cb.col_cmd;  c.col_ba = vif.mon_cb.col_ba;
        c.col_addr = vif.mon_cb.col_addr; c.wdata  = vif.mon_cb.col_wdata;
        c.q_count  = vif.mon_cb.dbg_q_count;
        c.aging    = vif.mon_cb.dbg_aging_override;
        c.ref_pending  = vif.mon_cb.dbg_ref_pending;
        c.credit_stall = vif.mon_cb.dbg_credit_stall;
        c.policy   = vif.mon_cb.cfg_policy;
        ap.write(c);
      end
    end
  endtask
endclass


class mc_cmd_agent extends uvm_agent;
  `uvm_component_utils(mc_cmd_agent)
  mc_cmd_monitor mon;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    mon = mc_cmd_monitor::type_id::create("mon", this);
  endfunction
endclass
