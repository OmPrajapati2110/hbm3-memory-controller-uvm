// -----------------------------------------------------------------------------
// mc_env.svh : environment and virtual sequencer
// -----------------------------------------------------------------------------

class mc_vseqr extends uvm_sequencer;
  `uvm_component_utils(mc_vseqr)
  uvm_sequencer #(mc_req_item) client_seqr[NC];
  mc_env_cfg cfg;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
endclass


class mc_env extends uvm_env;
  `uvm_component_utils(mc_env)

  mc_env_cfg      cfg;
  mc_client_agent client[NC];
  mc_cmd_agent    cmd;
  mc_scoreboard   sb;
  mc_coverage     cov;
  mc_vseqr        vseqr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(mc_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("CFG", "mc_env_cfg not set")
    for (int c = 0; c < NC; c++) begin
      uvm_config_db#(int unsigned)::set(this, $sformatf("client%0d", c), "client", c);
      uvm_config_db#(mc_env_cfg)::set(this, $sformatf("client%0d", c), "cfg", cfg);
      client[c] = mc_client_agent::type_id::create($sformatf("client%0d", c), this);
    end
    cmd   = mc_cmd_agent::type_id::create("cmd", this);
    sb    = mc_scoreboard::type_id::create("sb", this);
    if (cfg.has_coverage) cov = mc_coverage::type_id::create("cov", this);
    vseqr = mc_vseqr::type_id::create("vseqr", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    cmd.mon.vif = cfg.cmd_vif;
    cmd.mon.ap.connect(sb.cmd_imp);
    if (cov != null) cmd.mon.ap.connect(cov.cmd_imp);
    for (int c = 0; c < NC; c++) begin
      client[c].mon.req_ap.connect(sb.req_imp);
      client[c].mon.rsp_ap.connect(sb.rsp_imp);
      if (cov != null) begin
        client[c].mon.req_ap.connect(cov.req_imp);
        client[c].mon.rsp_ap.connect(cov.rsp_imp);
      end
      vseqr.client_seqr[c] = client[c].seqr;
    end
    vseqr.cfg = cfg;
  endfunction
endclass
