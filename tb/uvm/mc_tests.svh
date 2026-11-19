// -----------------------------------------------------------------------------
// mc_tests.svh : test library. Same scenarios as the pyuvm bench.
//   +UVM_TESTNAME=<test> +POLICY=<0|1|2> +N=<requests per client>
// -----------------------------------------------------------------------------

class mc_base_test extends uvm_test;
  `uvm_component_utils(mc_base_test)
  mc_env       env;
  mc_env_cfg   cfg;
  int unsigned n = 300;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Tests override to adjust knobs
  virtual function void configure(mc_env_cfg c);
  endfunction

  virtual function mc_vseq_base make_vseq();
    mc_vseq_base v = mc_vseq_base::type_id::create("vseq");
    v.n = n;
    return v;
  endfunction

  function void build_phase(uvm_phase phase);
    int unsigned p;
    cfg = mc_env_cfg::type_id::create("cfg");
    for (int c = 0; c < NC; c++)
      if (!uvm_config_db#(client_vif_t)::get(this, "", $sformatf("client_vif%0d", c),
                                              cfg.client_vif[c]))
        `uvm_fatal("VIF", "client vif missing")
    if (!uvm_config_db#(cmd_vif_t)::get(this, "", "cmd_vif", cfg.cmd_vif))
      `uvm_fatal("VIF", "cmd vif missing")
    void'($value$plusargs("N=%d", n));
    configure(cfg);
    if ($value$plusargs("POLICY=%d", p)) cfg.policy = p[1:0];
    uvm_config_db#(mc_env_cfg)::set(this, "env", "cfg", cfg);
    env = mc_env::type_id::create("env", this);
  endfunction

  task run_phase(uvm_phase phase);
    mc_vseq_base v;
    int unsigned waited;
    phase.raise_objection(this);
    // configuration is static while the controller runs
    cfg.cmd_vif.cfg_policy     <= cfg.policy;
    cfg.cmd_vif.cfg_refresh_en <= cfg.refresh_en;
    wait (cfg.cmd_vif.rst_n === 1'b1);
    `uvm_info("TEST", $sformatf("policy=%0d refresh=%0d n/client=%0d", cfg.policy,
              cfg.refresh_en, n), UVM_LOW)
    v = make_vseq();
    v.start(env.vseqr);
    // drain: every accepted request must complete
    while (env.sb.outstanding_count() > 0 && waited < cfg.drain_timeout) begin
      repeat (100) @(posedge cfg.cmd_vif.clk);
      waited += 100;
    end
    repeat (50) @(posedge cfg.cmd_vif.clk);
    phase.drop_objection(this);
  endtask

  function void report_phase(uvm_phase phase);
    uvm_report_server rs = uvm_report_server::get_server();
    if (rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL) == 0)
      `uvm_info("RESULT", "*** TEST PASSED ***", UVM_NONE)
    else
      `uvm_info("RESULT", "*** TEST FAILED ***", UVM_NONE)
  endfunction
endclass


// ----------------------------------------------------------------------------
class mc_smoke_vseq extends mc_vseq_base;
  `uvm_object_utils(mc_smoke_vseq)
  function new(string name = "mc_smoke_vseq"); super.new(name); endfunction
  task body();
    mc_directed_seq d = mc_directed_seq::type_id::create("d");
    bit [ADDR_W-1:0] lines[$];
    for (int r = 5; r <= 6; r++)
      for (int bg = 0; bg <= 1; bg++)
        for (int col = 0; col < 16; col++) lines.push_back(make_addr(bg, 0, r, col));
    foreach (lines[k]) d.add(1, lines[k]);
    foreach (lines[k]) d.add(0, lines[k]);
    for (int k = 0; k < 8; k++) d.add(1, lines[k]);
    for (int k = 0; k < 8; k++) d.add(0, lines[k]);
    d.start(p_sequencer.client_seqr[0]);
  endtask
endclass

class mc_smoke_test extends mc_base_test;
  `uvm_component_utils(mc_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure(mc_env_cfg c); c.policy = 1; endfunction
  virtual function mc_vseq_base make_vseq();
    return mc_smoke_vseq::type_id::create("vseq");
  endfunction
endclass


// ----------------------------------------------------------------------------
class mc_random_vseq extends mc_vseq_base;
  `uvm_object_utils(mc_random_vseq)
  function new(string name = "mc_random_vseq"); super.new(name); endfunction
  virtual function mc_base_seq make(int unsigned c);
    mc_random_seq s = mc_random_seq::type_id::create($sformatf("rand%0d", c));
    s.n = n;
    s.rd_pct = $urandom_range(70, 30);
    s.max_idle = $urandom_range(1) ? 0 : 10;
    s.row_hi = $urandom_range(15, 1);
    return s;
  endfunction
endclass

class mc_random_test extends mc_base_test;
  `uvm_component_utils(mc_random_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure(mc_env_cfg c); c.policy = $urandom_range(2); endfunction
  virtual function mc_vseq_base make_vseq();
    mc_random_vseq v = mc_random_vseq::type_id::create("vseq");
    v.n = n;
    return v;
  endfunction
endclass


// ----------------------------------------------------------------------------
class mc_stream_vseq extends mc_vseq_base;
  `uvm_object_utils(mc_stream_vseq)
  function new(string name = "mc_stream_vseq"); super.new(name); endfunction
  virtual function mc_base_seq make(int unsigned c);
    mc_stream_seq s = mc_stream_seq::type_id::create($sformatf("stream%0d", c));
    s.n = n;  s.rd_pct = 60;
    s.base = make_addr(c % NUM_BG, 0, 100 + 7 * c, 0);
    return s;
  endfunction
endclass

class mc_stream_test extends mc_base_test;
  `uvm_component_utils(mc_stream_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function mc_vseq_base make_vseq();
    mc_stream_vseq v = mc_stream_vseq::type_id::create("vseq");
    v.n = n;
    return v;
  endfunction
endclass


// ----------------------------------------------------------------------------
class mc_conflict_vseq extends mc_vseq_base;
  `uvm_object_utils(mc_conflict_vseq)
  function new(string name = "mc_conflict_vseq"); super.new(name); endfunction
  virtual function mc_base_seq make(int unsigned c);
    mc_conflict_seq s = mc_conflict_seq::type_id::create($sformatf("conf%0d", c));
    s.n = n / 2;
    return s;
  endfunction
endclass

class mc_row_conflict_test extends mc_base_test;
  `uvm_component_utils(mc_row_conflict_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function mc_vseq_base make_vseq();
    mc_conflict_vseq v = mc_conflict_vseq::type_id::create("vseq");
    v.n = n;
    return v;
  endfunction
endclass


// ----------------------------------------------------------------------------
class mc_spread_vseq extends mc_vseq_base;
  `uvm_object_utils(mc_spread_vseq)
  function new(string name = "mc_spread_vseq"); super.new(name); endfunction
  virtual function mc_base_seq make(int unsigned c);
    mc_bank_spread_seq s = mc_bank_spread_seq::type_id::create($sformatf("spread%0d", c));
    int unsigned strides[3] = '{1, 3, 5};
    s.n = n;  s.offset = 4 * c;  s.stride = strides[$urandom_range(2)];
    return s;
  endfunction
endclass

class mc_bank_parallel_test extends mc_base_test;
  `uvm_component_utils(mc_bank_parallel_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function mc_vseq_base make_vseq();
    mc_spread_vseq v = mc_spread_vseq::type_id::create("vseq");
    v.n = n;
    return v;
  endfunction
endclass


// ----------------------------------------------------------------------------
class mc_turnaround_vseq extends mc_vseq_base;
  `uvm_object_utils(mc_turnaround_vseq)
  function new(string name = "mc_turnaround_vseq"); super.new(name); endfunction
  virtual function mc_base_seq make(int unsigned c);
    mc_turnaround_seq s = mc_turnaround_seq::type_id::create($sformatf("ta%0d", c));
    s.n = n;  s.the_row = 3 + (c & 1);
    return s;
  endfunction
endclass

class mc_turnaround_test extends mc_base_test;
  `uvm_component_utils(mc_turnaround_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function mc_vseq_base make_vseq();
    mc_turnaround_vseq v = mc_turnaround_vseq::type_id::create("vseq");
    v.n = n;
    return v;
  endfunction
endclass


// ----------------------------------------------------------------------------
class mc_hazard_vseq extends mc_vseq_base;
  `uvm_object_utils(mc_hazard_vseq)
  function new(string name = "mc_hazard_vseq"); super.new(name); endfunction
  virtual function mc_base_seq make(int unsigned c);
    mc_hazard_seq s = mc_hazard_seq::type_id::create($sformatf("haz%0d", c));
    s.n = n;  s.max_idle = $urandom_range(1) ? 0 : 2;
    return s;
  endfunction
endclass

class mc_hazard_test extends mc_base_test;
  `uvm_component_utils(mc_hazard_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function mc_vseq_base make_vseq();
    mc_hazard_vseq v = mc_hazard_vseq::type_id::create("vseq");
    v.n = n;
    return v;
  endfunction
endclass


// ----------------------------------------------------------------------------
// Run with +NO_STARVE_CHK: clients that stop draining responses can block
// any request indefinitely by design.
class mc_backpressure_test extends mc_random_test;
  `uvm_component_utils(mc_backpressure_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure(mc_env_cfg c);
    c.policy = $urandom_range(2);
    c.rsp_ready_pct = 15;
    n = n / 2;
  endfunction
endclass


// ----------------------------------------------------------------------------
class mc_starvation_vseq extends mc_vseq_base;
  `uvm_object_utils(mc_starvation_vseq)
  function new(string name = "mc_starvation_vseq"); super.new(name); endfunction
  task body();
    mc_hit_stream_seq aggr[3];
    mc_directed_seq   victim = mc_directed_seq::type_id::create("victim");
    for (int c = 0; c < 4; c++) victim.add(0, make_addr(0, 0, 2, c));
    for (int c = 0; c < 3; c++) begin
      automatic int cc = c;
      aggr[cc] = mc_hit_stream_seq::type_id::create($sformatf("aggr%0d", cc));
      aggr[cc].n = 2 * n;
      fork aggr[cc].start(p_sequencer.client_seqr[cc]); join_none
    end
    repeat (200) @(posedge p_sequencer.cfg.cmd_vif.clk);
    victim.start(p_sequencer.client_seqr[3]);
    wait fork;
  endtask
endclass

class mc_starvation_test extends mc_base_test;
  `uvm_component_utils(mc_starvation_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function void configure(mc_env_cfg c);
    c.refresh_en = 0;   // refresh would periodically rescue the victim
  endfunction
  virtual function mc_vseq_base make_vseq();
    mc_starvation_vseq v = mc_starvation_vseq::type_id::create("vseq");
    v.n = n;
    return v;
  endfunction
  function void check_phase(uvm_phase phase);
    if (cfg.policy != 1 && env.sb.lat_max[3] > 256 + 200)
      `uvm_error("STARVE", $sformatf("victim waited %0d cycles under policy %0d",
                 env.sb.lat_max[3], cfg.policy))
  endfunction
endclass


// ----------------------------------------------------------------------------
class mc_refresh_idle_vseq extends mc_vseq_base;
  `uvm_object_utils(mc_refresh_idle_vseq)
  function new(string name = "mc_refresh_idle_vseq"); super.new(name); endfunction
  task body();
    for (int b = 0; b < 4; b++) begin
      for (int c = 0; c < NC; c++) begin
        automatic int cc = c;
        automatic mc_random_seq s = mc_random_seq::type_id::create($sformatf("rb%0d_%0d", b, c));
        s.n = n / 8;  s.row_hi = 1;
        fork s.start(p_sequencer.client_seqr[cc]); join_none
      end
      wait fork;
      repeat ($urandom_range(1500, 200)) @(posedge p_sequencer.cfg.cmd_vif.clk);
    end
  endtask
endclass

class mc_refresh_idle_test extends mc_base_test;
  `uvm_component_utils(mc_refresh_idle_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  virtual function mc_vseq_base make_vseq();
    mc_refresh_idle_vseq v = mc_refresh_idle_vseq::type_id::create("vseq");
    v.n = n;
    return v;
  endfunction
endclass
