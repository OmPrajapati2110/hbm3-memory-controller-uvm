// -----------------------------------------------------------------------------
// mc_fifo.sv : synchronous FIFO, any depth >= 1, registered count.
// Push when full and pop when empty are ignored (and flagged by SVA).
// -----------------------------------------------------------------------------
module mc_fifo #(
  parameter int W     = 8,
  parameter int DEPTH = 4,
  localparam int AW   = (DEPTH > 1) ? $clog2(DEPTH) : 1,
  localparam int CW   = $clog2(DEPTH + 1)
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic          push,
  input  logic [W-1:0]  din,
  input  logic          pop,
  output logic [W-1:0]  dout,
  output logic          empty,
  output logic          full,
  output logic [CW-1:0] count
);

  logic [W-1:0]  mem [DEPTH];
  logic [AW-1:0] wp, rp;

  wire do_push = push & ~full;
  wire do_pop  = pop  & ~empty;

  function automatic logic [AW-1:0] incr(input logic [AW-1:0] p);
    incr = (p == AW'(DEPTH - 1)) ? '0 : p + AW'(1);
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wp    <= '0;
      rp    <= '0;
      count <= '0;
    end else begin
      if (do_push) wp <= incr(wp);
      if (do_pop)  rp <= incr(rp);
      case ({do_push, do_pop})
        2'b10:   count <= count + CW'(1);
        2'b01:   count <= count - CW'(1);
        default: count <= count;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (do_push) mem[wp] <= din;
  end

  assign dout  = mem[rp];
  assign empty = (count == '0);
  assign full  = (count == CW'(DEPTH));

endmodule
