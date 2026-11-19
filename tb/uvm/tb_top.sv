// -----------------------------------------------------------------------------
// tb_top.sv : SystemVerilog UVM top level
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_top;
  import uvm_pkg::*;
  import mc_tb_pkg::*;
  `include "uvm_macros.svh"

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #0.5 clk = ~clk;                       // 1 GHz controller clock
  initial begin
    repeat (5) @(posedge clk);
    rst_n <= 1'b1;
  end

  mc_client_if #(ADDR_W, DATA_W, ID_W)              cif [NC] (clk, rst_n);
  mc_cmd_if    #(BA_W, ROW_W, COL_W, DATA_W, QC_W)   kif (clk, rst_n);

  // Pack the per-client interfaces onto the harness's flat vectors
  logic [NC-1:0]        req_valid, req_ready, req_we, rsp_valid, rsp_ready, rsp_we;
  logic [NC*ADDR_W-1:0] req_addr;
  logic [NC*DATA_W-1:0] req_wdata, rsp_rdata;
  logic [NC*ID_W-1:0]   req_id, rsp_id;

  for (genvar c = 0; c < NC; c++) begin : g_pack
    assign req_valid[c]                 = cif[c].req_valid;
    assign req_we[c]                    = cif[c].req_we;
    assign req_addr[c*ADDR_W +: ADDR_W] = cif[c].req_addr;
    assign req_wdata[c*DATA_W +: DATA_W]= cif[c].req_wdata;
    assign req_id[c*ID_W +: ID_W]       = cif[c].req_id;
    assign rsp_ready[c]                 = cif[c].rsp_ready;
    assign cif[c].req_ready             = req_ready[c];
    assign cif[c].rsp_valid             = rsp_valid[c];
    assign cif[c].rsp_we                = rsp_we[c];
    assign cif[c].rsp_id                = rsp_id[c*ID_W +: ID_W];
    assign cif[c].rsp_rdata             = rsp_rdata[c*DATA_W +: DATA_W];
  end

  hbm3_mc_harness #(.T_REFI(`ifdef TB_T_REFI `TB_T_REFI `else 900 `endif)) u_h (
    .clk, .rst_n,
    .cfg_policy     (kif.cfg_policy),
    .cfg_refresh_en (kif.cfg_refresh_en),
    .req_valid, .req_ready, .req_we, .req_addr, .req_wdata, .req_id,
    .rsp_valid, .rsp_ready, .rsp_we, .rsp_id, .rsp_rdata,
    .row_cmd  (kif.row_cmd),  .row_ba (kif.row_ba), .row_addr (kif.row_addr),
    .col_cmd  (kif.col_cmd),  .col_ba (kif.col_ba), .col_addr (kif.col_addr),
    .col_wdata(kif.col_wdata),
    .dbg_aging_override (kif.dbg_aging_override),
    .dbg_ref_pending    (kif.dbg_ref_pending),
    .dbg_credit_stall   (kif.dbg_credit_stall),
    .dbg_q_count        (kif.dbg_q_count)
  );

  initial begin
    kif.cfg_policy     = 2'd2;
    kif.cfg_refresh_en = 1'b1;
    uvm_config_db#(cmd_vif_t)::set(null, "uvm_test_top", "cmd_vif", kif);
    uvm_config_db#(client_vif_t)::set(null, "uvm_test_top", "client_vif0", cif[0]);
    uvm_config_db#(client_vif_t)::set(null, "uvm_test_top", "client_vif1", cif[1]);
    uvm_config_db#(client_vif_t)::set(null, "uvm_test_top", "client_vif2", cif[2]);
    uvm_config_db#(client_vif_t)::set(null, "uvm_test_top", "client_vif3", cif[3]);
    run_test("mc_random_test");
  end
endmodule
