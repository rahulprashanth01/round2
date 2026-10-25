// ============================================================================
// PROVIDED -- DO NOT MODIFY.
// GENOME-X AXI top: AXI-Lite wrapper + single-target pipeline + multi-target
// controller. Add this as ONE module in the Vivado block design (Add Module)
// and name the cell  genome_x_axi_0  (pynq_host.py uses ol.genome_x_axi_0).
// ============================================================================
module genome_x_axi_top (
    // ── AXI4-Lite slave (connects to the Zynq PS through AXI Interconnect) ──
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET S_AXI_ARESETN" *)
    input  wire        S_AXI_ACLK,
    input  wire        S_AXI_ARESETN,
    input  wire [5:0]  S_AXI_AWADDR,
    input  wire [2:0]  S_AXI_AWPROT,
    input  wire        S_AXI_AWVALID,
    output wire        S_AXI_AWREADY,
    input  wire [31:0] S_AXI_WDATA,
    input  wire [3:0]  S_AXI_WSTRB,
    input  wire        S_AXI_WVALID,
    output wire        S_AXI_WREADY,
    output wire [1:0]  S_AXI_BRESP,
    output wire        S_AXI_BVALID,
    input  wire        S_AXI_BREADY,
    input  wire [5:0]  S_AXI_ARADDR,
    input  wire [2:0]  S_AXI_ARPROT,
    input  wire        S_AXI_ARVALID,
    output wire        S_AXI_ARREADY,
    output wire [31:0] S_AXI_RDATA,
    output wire [1:0]  S_AXI_RRESP,
    output wire        S_AXI_RVALID,
    input  wire        S_AXI_RREADY,

    // ── Optional status LEDs (can be left unconnected in the block design) ──
    output wire        led_busy,
    output wire        led_pass,
    output wire        led_fail
);

    // ── Wires between wrapper and pipelines ────────────────────────────────
    wire [63:0] pipe_genome;
    wire [15:0] pipe_guide;
    wire [7:0]  pipe_replacement;
    wire [1:0]  pipe_threshold;
    wire [7:0]  pipe_command;
    wire        pipe_reset;          // active-high, = ~S_AXI_ARESETN

    wire        single_start;
    wire [63:0] single_edited_genome;
    wire        single_done;
    wire        single_pass;
    wire [4:0]  single_target_position;
    wire        single_target_found;
    wire [7:0]  single_status;

    wire        multi_start;
    wire [63:0] multi_final_genome;
    wire [4:0]  multi_targets_found;
    wire [4:0]  multi_edits_applied;
    wire [4:0]  multi_edits_verified;
    wire        multi_done;
    wire        multi_pass;

    wire clk = S_AXI_ACLK;
    wire rst = pipe_reset;

    // ── AXI-Lite register wrapper (provided, unmodified) ───────────────────
    genome_x_axi_wrapper #(
        .C_S_AXI_DATA_WIDTH (32),
        .C_S_AXI_ADDR_WIDTH (6)
    ) u_axi (
        .S_AXI_ACLK      (S_AXI_ACLK),
        .S_AXI_ARESETN   (S_AXI_ARESETN),
        .S_AXI_AWADDR    (S_AXI_AWADDR),
        .S_AXI_AWPROT    (S_AXI_AWPROT),
        .S_AXI_AWVALID   (S_AXI_AWVALID),
        .S_AXI_AWREADY   (S_AXI_AWREADY),
        .S_AXI_WDATA     (S_AXI_WDATA),
        .S_AXI_WSTRB     (S_AXI_WSTRB),
        .S_AXI_WVALID    (S_AXI_WVALID),
        .S_AXI_WREADY    (S_AXI_WREADY),
        .S_AXI_BRESP     (S_AXI_BRESP),
        .S_AXI_BVALID    (S_AXI_BVALID),
        .S_AXI_BREADY    (S_AXI_BREADY),
        .S_AXI_ARADDR    (S_AXI_ARADDR),
        .S_AXI_ARPROT    (S_AXI_ARPROT),
        .S_AXI_ARVALID   (S_AXI_ARVALID),
        .S_AXI_ARREADY   (S_AXI_ARREADY),
        .S_AXI_RDATA     (S_AXI_RDATA),
        .S_AXI_RRESP     (S_AXI_RRESP),
        .S_AXI_RVALID    (S_AXI_RVALID),
        .S_AXI_RREADY    (S_AXI_RREADY),

        .pipe_genome            (pipe_genome),
        .pipe_guide             (pipe_guide),
        .pipe_replacement       (pipe_replacement),
        .pipe_threshold         (pipe_threshold),
        .pipe_command           (pipe_command),
        .single_start           (single_start),
        .multi_start            (multi_start),

        .single_edited_genome   (single_edited_genome),
        .single_done            (single_done),
        .single_pass            (single_pass),
        .single_target_position (single_target_position),
        .single_target_found    (single_target_found),
        .single_status          (single_status),

        .multi_final_genome     (multi_final_genome),
        .multi_targets_found    (multi_targets_found),
        .multi_edits_applied    (multi_edits_applied),
        .multi_edits_verified   (multi_edits_verified),
        .multi_done             (multi_done),
        .multi_pass             (multi_pass),

        .pipe_reset             (pipe_reset),
        .led_busy               (led_busy),
        .led_pass               (led_pass),
        .led_fail               (led_fail)
    );

    // ── GENOME-X Top Module (Task 1) — single-target pipeline ──────────────
    T01_genome_x_top u_pipeline (
        .clk             (clk),
        .rst             (rst),
        .start           (single_start),
        .genome          (pipe_genome),
        .guide           (pipe_guide),
        .replacement     (pipe_replacement),
        .threshold       (pipe_threshold),
        .edited_genome   (single_edited_genome),
        .pipeline_done   (single_done),
        .pipeline_pass   (single_pass),
        .target_position (single_target_position),
        .target_found    (single_target_found),
        .status          (single_status)
    );

    // ── Multi-Target Edit Controller (Task 2) ──────────────────────────────
    T01_multi_target_controller u_multi (
        .clk             (clk),
        .rst             (rst),
        .start           (multi_start),
        .genome          (pipe_genome),
        .guide           (pipe_guide),
        .replacement     (pipe_replacement),
        .threshold       (pipe_threshold),
        .final_genome    (multi_final_genome),
        .targets_found   (multi_targets_found),
        .edits_applied   (multi_edits_applied),
        .edits_verified  (multi_edits_verified),
        .all_done        (multi_done),
        .all_pass        (multi_pass)
    );

endmodule
