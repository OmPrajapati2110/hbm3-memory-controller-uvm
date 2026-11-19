// -----------------------------------------------------------------------------
// mc_rr_arb.sv : round-robin arbiter. The grant is combinational; the priority
// pointer only moves when the grant is consumed (advance), so a stalled grant
// is held stable.
// -----------------------------------------------------------------------------
module mc_rr_arb #(
  parameter int N = 4
) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic [N-1:0] req,
  input  logic         advance,
  output logic [N-1:0] gnt
);

  logic [N-1:0] mask;          // requesters strictly after the last winner
  logic [N-1:0] masked_req;

  function automatic logic [N-1:0] lowest(input logic [N-1:0] v);
    lowest = v & (~v + N'(1));
  endfunction

  assign masked_req = req & mask;
  assign gnt        = (|masked_req) ? lowest(masked_req) : lowest(req);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                mask <= '1;
    else if (advance && |gnt)  mask <= ~((gnt << 1) - N'(1));
  end

endmodule
