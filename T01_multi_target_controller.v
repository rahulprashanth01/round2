// ============================================================================
// T01_multi_target_controller  --  TEMPLATE (fill in)
// Multi-target edit controller (Task 2). The port list is FIXED: the provided
// genome_x_axi_top.v instantiates this module by name. Do not rename the
// module or change any port.
//
//  start     : one-cycle pulse, inputs are stable when it arrives
//  all_done  : pulse (>= 1 cycle) when results are valid
// ============================================================================
module T01_multi_target_controller (
    input  wire        clk,
    input  wire        rst,            // active-high, synchronous
    input  wire        start,
    input  wire [63:0] genome,
    input  wire [15:0] guide,
    input  wire [7:0]  replacement,
    input  wire [1:0]  threshold,
    output reg  [63:0] final_genome,
    output reg  [4:0]  targets_found,
    output reg  [4:0]  edits_applied,
    output reg  [4:0]  edits_verified,
    output reg         all_done,
    output reg         all_pass
);

    // TODO: implement the multi-target scan / edit / verify loop here.

    always @(posedge clk) begin
        if (rst) begin
            final_genome   <= 64'd0;
            targets_found  <= 5'd0;
            edits_applied  <= 5'd0;
            edits_verified <= 5'd0;
            all_done       <= 1'b0;
            all_pass       <= 1'b0;
        end
    end

endmodule
