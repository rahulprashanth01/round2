// ============================================================================
// T01_genome_x_top  --  TEMPLATE (fill in)
// Single-target pipeline: locate guide in genome -> edit -> verify.
// The port list is FIXED: the provided genome_x_axi_top.v instantiates this
// module by name. Do not rename the module or change any port.
//
//  start            : one-cycle pulse, inputs are stable when it arrives
//  pipeline_done    : pulse (>= 1 cycle) when results are valid
//  status           : per the Round 2 spec
// ============================================================================
module T01_genome_x_top (
    input  wire        clk,
    input  wire        rst,            // active-high, synchronous
    input  wire        start,
    input  wire [63:0] genome,
    input  wire [15:0] guide,
    input  wire [7:0]  replacement,
    input  wire [1:0]  threshold,
    output reg  [63:0] edited_genome,
    output reg         pipeline_done,
    output reg         pipeline_pass,
    output reg  [4:0]  target_position,
    output reg         target_found,
    output reg  [7:0]  status
);

    // TODO: instantiate your Round 1 modules and add the control FSM here.

    always @(posedge clk) begin
        if (rst) begin
            edited_genome   <= 64'd0;
            pipeline_done   <= 1'b0;
            pipeline_pass   <= 1'b0;
            target_position <= 5'd0;
            target_found    <= 1'b0;
            status          <= 8'd0;
        end
    end

endmodule
