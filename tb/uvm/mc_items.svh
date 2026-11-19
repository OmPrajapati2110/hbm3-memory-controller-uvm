// -----------------------------------------------------------------------------
// mc_items.svh : transactions
// -----------------------------------------------------------------------------

typedef bit [BA_W+ROW_W+COL_W-1:0] line_t;

function automatic line_t addr2line(bit [ADDR_W-1:0] a);
  // {ba, row, col} with ba = {bank, bg}, matching the command bus
  bit [COL_W-1:0] col = a[OFF_W +: COL_W];
  bit [BA_W-1:0]  ba  = a[OFF_W + COL_W +: BA_W];
  bit [ROW_W-1:0] row = a[OFF_W + COL_W + BA_W +: ROW_W];
  return {ba, row, col};
endfunction

function automatic bit [ADDR_W-1:0] make_addr(int unsigned bg, int unsigned bk,
                                              int unsigned row, int unsigned col);
  bit [ADDR_W-1:0] a;
  a = '0;
  a[OFF_W +: COL_W]                       = col[COL_W-1:0];
  a[OFF_W + COL_W +: BG_W]                = bg[BG_W-1:0];
  a[OFF_W + COL_W + BG_W +: BK_W]         = bk[BK_W-1:0];
  a[OFF_W + COL_W + BA_W +: ROW_W]        = row[ROW_W-1:0];
  return a;
endfunction


// Client request: address fields are randomized separately so sequences can
// constrain bank group, bank, row and column independently.
class mc_req_item extends uvm_sequence_item;
  rand bit              we;
  rand bit [BG_W-1:0]   bg;
  rand bit [BK_W-1:0]   bk;
  rand bit [ROW_W-1:0]  row;
  rand bit [COL_W-1:0]  col;
  rand bit [DATA_W-1:0] wdata;
  rand int unsigned     idle;
  bit [ID_W-1:0]        id;      // assigned by the driver from its ID pool

  // knobs (set by the sequence before randomize)
  int unsigned rd_pct  = 50;
  int unsigned max_idle = 0;

  constraint c_we   { we dist {1'b0 := rd_pct, 1'b1 := 100 - rd_pct}; }
  constraint c_idle { idle <= max_idle;
                      idle dist {0 :/ 70, [1:3] :/ 20, [4:20] :/ 10}; }
  constraint c_data { !we -> wdata == '0; }

  `uvm_object_utils_begin(mc_req_item)
    `uvm_field_int(we,    UVM_ALL_ON)
    `uvm_field_int(bg,    UVM_ALL_ON)
    `uvm_field_int(bk,    UVM_ALL_ON)
    `uvm_field_int(row,   UVM_ALL_ON)
    `uvm_field_int(col,   UVM_ALL_ON)
    `uvm_field_int(id,    UVM_ALL_ON)
    `uvm_field_int(idle,  UVM_ALL_ON | UVM_NOCOMPARE)
  `uvm_object_utils_end

  function new(string name = "mc_req_item");
    super.new(name);
  endfunction

  function bit [ADDR_W-1:0] addr();
    return make_addr(bg, bk, row, col);
  endfunction

  function string convert2string();
    return $sformatf("%s bg=%0d bk=%0d row=%0d col=%0d id=%0d", we ? "WR" : "RD",
                     bg, bk, row, col, id);
  endfunction
endclass


// Observed request / response on a client port
class mc_txn extends uvm_sequence_item;
  int unsigned     client;
  bit              is_rsp;
  bit              we;
  bit [ADDR_W-1:0] addr;
  bit [DATA_W-1:0] data;    // wdata for requests, rdata for responses
  bit [ID_W-1:0]   id;
  int unsigned     cyc;

  `uvm_object_utils(mc_txn)
  function new(string name = "mc_txn");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("c%0d %s %s id=%0d addr=0x%0h @%0d", client, is_rsp ? "RSP" : "REQ",
                     we ? "WR" : "RD", id, addr, cyc);
  endfunction
endclass


// One cycle of HBM command bus activity plus controller status
class mc_cmd_item extends uvm_sequence_item;
  int unsigned      cyc;
  bit [1:0]         row_cmd, col_cmd;
  bit [BA_W-1:0]    row_ba, col_ba;
  bit [ROW_W-1:0]   row_addr;
  bit [COL_W-1:0]   col_addr;
  bit [DATA_W-1:0]  wdata;
  int unsigned      q_count;
  bit               aging, ref_pending, credit_stall;
  bit [1:0]         policy;

  `uvm_object_utils(mc_cmd_item)
  function new(string name = "mc_cmd_item");
    super.new(name);
  endfunction
endclass
