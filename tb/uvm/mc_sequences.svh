// -----------------------------------------------------------------------------
// mc_sequences.svh : per-client traffic shapes (constrained random) and the
// virtual sequences that combine them across the four clients.
// -----------------------------------------------------------------------------

class mc_base_seq extends uvm_sequence #(mc_req_item);
  `uvm_object_utils(mc_base_seq)
  int unsigned n        = 100;
  int unsigned rd_pct   = 50;
  int unsigned max_idle = 0;
  int unsigned i;

  function new(string name = "mc_base_seq");
    super.new(name);
  endfunction

  // Subclasses constrain the address here
  virtual function bit shape(mc_req_item it);
    return it.randomize();
  endfunction

  task body();
    for (i = 0; i < n; i++) begin
      mc_req_item it = mc_req_item::type_id::create("it");
      start_item(it);
      it.rd_pct   = rd_pct;
      it.max_idle = max_idle;
      if (!shape(it)) `uvm_fatal("RAND", "randomization failed")
      finish_item(it);
    end
  endtask
endclass


// Uniform over a small window of rows in every bank: hits, misses, conflicts
class mc_random_seq extends mc_base_seq;
  `uvm_object_utils(mc_random_seq)
  int unsigned row_lo = 0, row_hi = 7;
  function new(string name = "mc_random_seq"); super.new(name); endfunction
  virtual function bit shape(mc_req_item it);
    return it.randomize() with { row inside {[row_lo:row_hi]}; };
  endfunction
endclass


// Sequential 32B lines from a base address: long row-hit runs
class mc_stream_seq extends mc_base_seq;
  `uvm_object_utils(mc_stream_seq)
  bit [ADDR_W-1:0] base;
  function new(string name = "mc_stream_seq"); super.new(name); endfunction
  virtual function bit shape(mc_req_item it);
    bit [ADDR_W-1:0] a = base + (ADDR_W'(i) << OFF_W);
    return it.randomize() with {
      col == a[OFF_W +: COL_W];
      bg  == a[OFF_W + COL_W +: BG_W];
      bk  == a[OFF_W + COL_W + BG_W +: BK_W];
      row == a[OFF_W + COL_W + BA_W +: ROW_W]; };
  endfunction
endclass


// Same bank(s), random rows: PRE/ACT churn (tRAS, tRP, tRC)
class mc_conflict_seq extends mc_base_seq;
  `uvm_object_utils(mc_conflict_seq)
  bit [BA_W-1:0] banks[$] = '{0, 5};
  function new(string name = "mc_conflict_seq"); super.new(name); endfunction
  virtual function bit shape(mc_req_item it);
    bit [BA_W-1:0] ba = banks[$urandom_range(banks.size() - 1)];
    return it.randomize() with { bg == ba[BG_W-1:0]; bk == ba[BA_W-1:BG_W]; };
  endfunction
endclass


// A new row in a different bank each request: ACT storm (tRRD_S/L, tFAW)
class mc_bank_spread_seq extends mc_base_seq;
  `uvm_object_utils(mc_bank_spread_seq)
  int unsigned stride = 5, offset = 0;
  function new(string name = "mc_bank_spread_seq"); super.new(name); endfunction
  virtual function bit shape(mc_req_item it);
    bit [BA_W-1:0] ba = BA_W'(i * stride + offset);
    return it.randomize() with { bg == ba[BG_W-1:0]; bk == ba[BA_W-1:BG_W]; };
  endfunction
endclass


// Alternating reads and writes, biased to one bank group (tCCD_L, tWTR, tRTW)
class mc_turnaround_seq extends mc_base_seq;
  `uvm_object_utils(mc_turnaround_seq)
  int unsigned the_row = 3;
  int unsigned same_bg_pct = 70;
  function new(string name = "mc_turnaround_seq"); super.new(name); endfunction
  virtual function bit shape(mc_req_item it);
    bit want_we = ($urandom_range(99) < 70) ? i[0] : $urandom_range(1);
    bit same    = ($urandom_range(99) < same_bg_pct);
    it.c_we.constraint_mode(0);
    return it.randomize() with { we == want_we; row == the_row; same -> bg == 0; };
  endfunction
endclass


// Tiny shared pool of lines: RAW / WAR / WAW races within and across clients
class mc_hazard_seq extends mc_base_seq;
  `uvm_object_utils(mc_hazard_seq)
  function new(string name = "mc_hazard_seq"); super.new(name); endfunction
  virtual function bit shape(mc_req_item it);
    return it.randomize() with { bg inside {0, 2}; bk == 1; row inside {7, 8}; col inside {0, 1}; };
  endfunction
endclass


// Reads that all hit one row of bank 0 (starvation aggressor)
class mc_hit_stream_seq extends mc_base_seq;
  `uvm_object_utils(mc_hit_stream_seq)
  int unsigned the_row = 1;
  function new(string name = "mc_hit_stream_seq"); super.new(name); endfunction
  virtual function bit shape(mc_req_item it);
    it.c_we.constraint_mode(0);
    return it.randomize() with { we == 0; bg == 0; bk == 0; row == the_row; };
  endfunction
endclass


// Directed list of operations
class mc_directed_seq extends mc_base_seq;
  `uvm_object_utils(mc_directed_seq)
  bit              op_we[$];
  bit [ADDR_W-1:0] op_addr[$];
  function new(string name = "mc_directed_seq"); super.new(name); endfunction
  function void add(bit we, bit [ADDR_W-1:0] a);
    op_we.push_back(we);  op_addr.push_back(a);  n = op_we.size();
  endfunction
  virtual function bit shape(mc_req_item it);
    bit [ADDR_W-1:0] a = op_addr[i];
    it.c_we.constraint_mode(0);
    it.c_idle.constraint_mode(0);
    return it.randomize() with {
      we == op_we[i]; idle == 0;
      col == a[OFF_W +: COL_W];
      bg  == a[OFF_W + COL_W +: BG_W];
      bk  == a[OFF_W + COL_W + BG_W +: BK_W];
      row == a[OFF_W + COL_W + BA_W +: ROW_W]; };
  endfunction
endclass


// -----------------------------------------------------------------------------
// Virtual sequence base: runs one child sequence per client in parallel
// -----------------------------------------------------------------------------
class mc_vseq_base extends uvm_sequence;
  `uvm_object_utils(mc_vseq_base)
  `uvm_declare_p_sequencer(mc_vseqr)
  int unsigned n = 300;

  function new(string name = "mc_vseq_base");
    super.new(name);
  endfunction

  virtual function mc_base_seq make(int unsigned c);
    mc_random_seq s = mc_random_seq::type_id::create($sformatf("rand%0d", c));
    s.n = n;
    return s;
  endfunction

  task body();
    mc_base_seq s[NC];
    for (int c = 0; c < NC; c++) s[c] = make(c);
    for (int c = 0; c < NC; c++) begin
      automatic int cc = c;
      fork
        s[cc].start(p_sequencer.client_seqr[cc]);
      join_none
    end
    wait fork;
  endtask
endclass
