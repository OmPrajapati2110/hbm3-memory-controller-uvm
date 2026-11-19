// -----------------------------------------------------------------------------
// mc_refresh.sv : all-bank refresh request generator.
// A free-running interval counter raises ref_pending every T_REFI cycles. The
// controller then stops new ACT/column traffic, precharges every open bank and
// issues REF; ref_done clears the request.
// -----------------------------------------------------------------------------
module mc_refresh #(
  parameter int T_REFI = 3900,
  parameter int REF_W  = 16
) (
  input  logic clk,
  input  logic rst_n,
  input  logic enable,
  input  logic ref_done,
  output logic ref_pending
);

  logic [REF_W-1:0] cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cnt         <= '0;
      ref_pending <= 1'b0;
    end else begin
      if (!enable) begin
        cnt         <= '0;
        ref_pending <= 1'b0;
      end else begin
        cnt <= (cnt == REF_W'(T_REFI - 1)) ? '0 : cnt + REF_W'(1);
        if (cnt == REF_W'(T_REFI - 1)) ref_pending <= 1'b1;
        else if (ref_done)             ref_pending <= 1'b0;
      end
    end
  end

endmodule
