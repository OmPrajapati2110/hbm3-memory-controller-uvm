// -----------------------------------------------------------------------------
// hbm3_dev_model.sv : behavioural HBM pseudo-channel used by every testbench.
//   - tracks open rows per bank (RD/WR carry only bank + column, like real HBM)
//   - sparse storage, unwritten lines read back as zero
//   - read data returns exactly RL cycles after the RD command
// Timing legality is deliberately NOT checked here: that is the job of the
// independent SVA checker (tb/sva/hbm3_timing_checker.sv). This model only
// flags commands that make no sense for storage (column access to a closed
// bank, ACT to an open bank).
// -----------------------------------------------------------------------------
module hbm3_dev_model #(
  parameter int DATA_W = 256,
  parameter int BA_W   = 4,
  parameter int ROW_W  = 14,
  parameter int COL_W  = 5,
  parameter int RL     = 17
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic [1:0]        row_cmd,
  input  logic [BA_W-1:0]   row_ba,
  input  logic [ROW_W-1:0]  row_addr,
  input  logic [1:0]        col_cmd,
  input  logic [BA_W-1:0]   col_ba,
  input  logic [COL_W-1:0]  col_addr,
  input  logic [DATA_W-1:0] col_wdata,
  output logic              rd_valid,
  output logic [DATA_W-1:0] rd_data
);

  localparam int NB    = 1 << BA_W;
  localparam int KEY_W = BA_W + ROW_W + COL_W;

  logic [DATA_W-1:0] mem [bit [KEY_W-1:0]];
  logic [NB-1:0]     open_q;
  logic [ROW_W-1:0]  row_q [NB];

  logic [RL-1:0]     pv;
  logic [DATA_W-1:0] pd [RL];

  int unsigned n_err;

  function automatic logic [KEY_W-1:0] key(input logic [BA_W-1:0] ba,
                                           input logic [ROW_W-1:0] r,
                                           input logic [COL_W-1:0] c);
    return {ba, r, c};
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      open_q <= '0;
      pv     <= '0;
      n_err  <= 0;
    end else begin
      // Row bus
      case (row_cmd)
        2'd1: begin // ACT
          if (open_q[row_ba]) begin
            $error("[DEV] ACT to open bank %0d", row_ba);
            n_err <= n_err + 1;
          end
          open_q[row_ba] <= 1'b1;
          row_q[row_ba]  <= row_addr;
        end
        2'd2: open_q[row_ba] <= 1'b0; // PRE
        2'd3: begin // REF
          if (open_q != '0) begin
            $error("[DEV] REF with open banks %b", open_q);
            n_err <= n_err + 1;
          end
        end
        default: ;
      endcase

      // Column bus
      pv[0] <= 1'b0;
      if (col_cmd != 2'd0 && !open_q[col_ba]) begin
        $error("[DEV] column command to closed bank %0d", col_ba);
        n_err <= n_err + 1;
      end
      if (col_cmd == 2'd2) begin
        mem[key(col_ba, row_q[col_ba], col_addr)] = col_wdata;
      end
      if (col_cmd == 2'd1) begin
        pv[0] <= 1'b1;
        pd[0] <= mem.exists(key(col_ba, row_q[col_ba], col_addr)) ?
                 mem[key(col_ba, row_q[col_ba], col_addr)] : '0;
      end
      for (int k = 1; k < RL; k++) begin
        pv[k] <= pv[k-1];
        pd[k] <= pd[k-1];
      end
    end
  end

  assign rd_valid = pv[RL-1];
  assign rd_data  = pv[RL-1] ? pd[RL-1] : '0;

endmodule
