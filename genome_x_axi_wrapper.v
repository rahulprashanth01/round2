// ============================================================================
// GENOME-X AXI-Lite Peripheral Wrapper  (PROVIDED — DO NOT MODIFY)
// ============================================================================
// Memory-mapped AXI4-Lite slave that bridges the Zynq PS (ARM) to the
// GENOME-X pipeline modules running in PL (FPGA fabric).
//
// Register Map (32-bit word-addressed from base address):
//   Offset  Name              R/W   Description
//   0x00    GENOME_LO         W     genome[31:0]
//   0x04    GENOME_HI         W     genome[63:32]
//   0x08    GUIDE             W     guide[15:0] in lower 16 bits
//   0x0C    REPLACEMENT       W     replacement[7:0] in lower 8 bits
//   0x10    THRESHOLD         W     threshold[1:0] in lower 2 bits
//   0x14    COMMAND           W     Write command opcode + auto-start
//   0x18    STATUS            R     {16'b0, single_status[7:0], flags[7:0]}
//                                   flags: [0]=single_done [1]=multi_done
//                                          [2]=single_pass [3]=multi_pass [7:4]=0
//   0x1C    RESULT_GENOME_LO  R     single_edited_genome[31:0]
//   0x20    RESULT_GENOME_HI  R     single_edited_genome[63:32]
//   0x24    RESULT_INFO       R     {target_found, target_position[4:0], ...}
//   0x28    MULTI_GENOME_LO   R     multi_final_genome[31:0]
//   0x2C    MULTI_GENOME_HI   R     multi_final_genome[63:32]
//   0x30    MULTI_COUNTS      R     {edits_verified, edits_applied, targets_found}
//   0x34    MULTI_STATUS      R     {30'b0, multi_pass, multi_done}
//   0x38    LATENCY           R     Clock cycle count of last operation
//   0x3C    HEARTBEAT         R     Free-running counter (design alive check)
//
// Command opcodes written to COMMAND register:
//   0x01 = SINGLE_EDIT   → pulses single_start
//   0x02 = MULTI_EDIT    → pulses multi_start
//   0x03 = SEARCH_ONLY   → pulses single_start (host interprets status)
//
// AXI4-Lite interface parameters:
//   Data width: 32 bits
//   Address width: 6 bits (16 registers × 4 bytes = 64 bytes address space)
// ============================================================================

module genome_x_axi_wrapper #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 6
)(
    // ── AXI4-Lite Slave Interface ──────────────────────────────────────
    input  wire                                S_AXI_ACLK,
    input  wire                                S_AXI_ARESETN,
    // Write address channel
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       S_AXI_AWADDR,
    input  wire [2:0]                          S_AXI_AWPROT,
    input  wire                                S_AXI_AWVALID,
    output wire                                S_AXI_AWREADY,
    // Write data channel
    input  wire [C_S_AXI_DATA_WIDTH-1:0]       S_AXI_WDATA,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0]   S_AXI_WSTRB,
    input  wire                                S_AXI_WVALID,
    output wire                                S_AXI_WREADY,
    // Write response channel
    output wire [1:0]                          S_AXI_BRESP,
    output wire                                S_AXI_BVALID,
    input  wire                                S_AXI_BREADY,
    // Read address channel
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]       S_AXI_ARADDR,
    input  wire [2:0]                          S_AXI_ARPROT,
    input  wire                                S_AXI_ARVALID,
    output wire                                S_AXI_ARREADY,
    // Read data channel
    output wire [C_S_AXI_DATA_WIDTH-1:0]       S_AXI_RDATA,
    output wire [1:0]                          S_AXI_RRESP,
    output wire                                S_AXI_RVALID,
    input  wire                                S_AXI_RREADY,

    // ── Pipeline Interface (directly connect your modules here) ────────
    // Pipeline data outputs (wrapper → your modules)
    output wire [63:0] pipe_genome,
    output wire [15:0] pipe_guide,
    output wire [7:0]  pipe_replacement,
    output wire [1:0]  pipe_threshold,
    output wire [7:0]  pipe_command,
    output reg         single_start,
    output reg         multi_start,

    // Single pipeline results (your modules → wrapper)
    input  wire [63:0] single_edited_genome,
    input  wire        single_done,
    input  wire        single_pass,
    input  wire [4:0]  single_target_position,
    input  wire        single_target_found,
    input  wire [7:0]  single_status,

    // Multi pipeline results (your modules → wrapper)
    input  wire [63:0] multi_final_genome,
    input  wire [4:0]  multi_targets_found,
    input  wire [4:0]  multi_edits_applied,
    input  wire [4:0]  multi_edits_verified,
    input  wire        multi_done,
    input  wire        multi_pass,

    // Pipeline reset (active-high)
    output wire        pipe_reset,

    // LED outputs
    output wire        led_busy,
    output wire        led_pass,
    output wire        led_fail
);

    // ====================================================================
    // AXI4-Lite internal signals
    // ====================================================================
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr;
    reg        axi_awready;
    reg        axi_wready;
    reg [1:0]  axi_bresp;
    reg        axi_bvalid;
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr;
    reg        axi_arready;
    reg [C_S_AXI_DATA_WIDTH-1:0] axi_rdata;
    reg [1:0]  axi_rresp;
    reg        axi_rvalid;

    // ====================================================================
    // Register file (writable by ARM)
    // ====================================================================
    reg [31:0] reg_genome_lo;     // 0x00
    reg [31:0] reg_genome_hi;     // 0x04
    reg [31:0] reg_guide;         // 0x08
    reg [31:0] reg_replacement;   // 0x0C
    reg [31:0] reg_threshold;     // 0x10
    reg [31:0] reg_command;       // 0x14

    // ====================================================================
    // Pipeline data mapping
    // ====================================================================
    assign pipe_genome      = {reg_genome_hi, reg_genome_lo};
    assign pipe_guide       = reg_guide[15:0];
    assign pipe_replacement = reg_replacement[7:0];
    assign pipe_threshold   = reg_threshold[1:0];
    assign pipe_command     = reg_command[7:0];
    assign pipe_reset       = ~S_AXI_ARESETN;

    // ====================================================================
    // Latency counter
    // ====================================================================
    reg [31:0] latency_counter;
    reg        latency_running;
    reg [31:0] latency_result;

    always @(posedge S_AXI_ACLK) begin
        if (~S_AXI_ARESETN) begin
            latency_counter <= 32'd0;
            latency_running <= 1'b0;
            latency_result  <= 32'd0;
        end else begin
            if (single_start || multi_start) begin
                latency_counter <= 32'd0;
                latency_running <= 1'b1;
            end else if (latency_running) begin
                latency_counter <= latency_counter + 32'd1;
                if (single_done || multi_done) begin
                    latency_running <= 1'b0;
                    latency_result  <= latency_counter + 32'd1;
                end
            end
        end
    end

    // ====================================================================
    // Heartbeat (free-running 32-bit counter)
    // ====================================================================
    reg [31:0] heartbeat;
    always @(posedge S_AXI_ACLK) begin
        if (~S_AXI_ARESETN)
            heartbeat <= 32'd0;
        else
            heartbeat <= heartbeat + 32'd1;
    end

    // ====================================================================
    // Result capture registers (latched on done)
    // ====================================================================
    reg [63:0] cap_single_genome;
    reg [7:0]  cap_single_status;
    reg [4:0]  cap_single_target_pos;
    reg        cap_single_target_found;
    reg        cap_single_pass;
    reg        cap_single_done;

    reg [63:0] cap_multi_genome;
    reg [4:0]  cap_multi_targets_found;
    reg [4:0]  cap_multi_edits_applied;
    reg [4:0]  cap_multi_edits_verified;
    reg        cap_multi_pass;
    reg        cap_multi_done;

    always @(posedge S_AXI_ACLK) begin
        if (~S_AXI_ARESETN) begin
            cap_single_genome       <= 64'd0;
            cap_single_status       <= 8'd0;
            cap_single_target_pos   <= 5'd0;
            cap_single_target_found <= 1'b0;
            cap_single_pass         <= 1'b0;
            cap_single_done         <= 1'b0;
            cap_multi_genome        <= 64'd0;
            cap_multi_targets_found <= 5'd0;
            cap_multi_edits_applied <= 5'd0;
            cap_multi_edits_verified<= 5'd0;
            cap_multi_pass          <= 1'b0;
            cap_multi_done          <= 1'b0;
        end else begin
            if (single_done) begin
                cap_single_genome       <= single_edited_genome;
                cap_single_status       <= single_status;
                cap_single_target_pos   <= single_target_position;
                cap_single_target_found <= single_target_found;
                cap_single_pass         <= single_pass;
                cap_single_done         <= 1'b1;
            end
            if (multi_done) begin
                cap_multi_genome        <= multi_final_genome;
                cap_multi_targets_found <= multi_targets_found;
                cap_multi_edits_applied <= multi_edits_applied;
                cap_multi_edits_verified<= multi_edits_verified;
                cap_multi_pass          <= multi_pass;
                cap_multi_done          <= 1'b1;
            end
            // Clear done flags when a new command is issued
            if (single_start) cap_single_done <= 1'b0;
            if (multi_start)  cap_multi_done  <= 1'b0;
        end
    end

    // ====================================================================
    // LED outputs
    // ====================================================================
    assign led_busy = latency_running;
    assign led_pass = cap_single_pass | cap_multi_pass;
    assign led_fail = (cap_single_done & ~cap_single_pass) |
                      (cap_multi_done  & ~cap_multi_pass);

    // ====================================================================
    // AXI4-Lite Write Logic
    // ====================================================================
    wire aw_handshake = S_AXI_AWVALID & axi_awready;
    wire w_handshake  = S_AXI_WVALID  & axi_wready;

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = axi_bresp;
    assign S_AXI_BVALID  = axi_bvalid;

    // AW channel
    always @(posedge S_AXI_ACLK) begin
        if (~S_AXI_ARESETN) begin
            axi_awready <= 1'b0;
            axi_awaddr  <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else begin
            if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID) begin
                axi_awready <= 1'b1;
                axi_awaddr  <= S_AXI_AWADDR;
            end else begin
                axi_awready <= 1'b0;
            end
        end
    end

    // W channel
    always @(posedge S_AXI_ACLK) begin
        if (~S_AXI_ARESETN)
            axi_wready <= 1'b0;
        else if (~axi_wready && S_AXI_WVALID && S_AXI_AWVALID)
            axi_wready <= 1'b1;
        else
            axi_wready <= 1'b0;
    end

    // B channel
    always @(posedge S_AXI_ACLK) begin
        if (~S_AXI_ARESETN) begin
            axi_bvalid <= 1'b0;
            axi_bresp  <= 2'b00;
        end else begin
            if (aw_handshake && w_handshake && ~axi_bvalid) begin
                axi_bvalid <= 1'b1;
                axi_bresp  <= 2'b00; // OKAY
            end else if (S_AXI_BREADY && axi_bvalid) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    // Register write logic + command start pulse generation
    always @(posedge S_AXI_ACLK) begin
        if (~S_AXI_ARESETN) begin
            reg_genome_lo   <= 32'd0;
            reg_genome_hi   <= 32'd0;
            reg_guide       <= 32'd0;
            reg_replacement <= 32'd0;
            reg_threshold   <= 32'd0;
            reg_command     <= 32'd0;
            single_start    <= 1'b0;
            multi_start     <= 1'b0;
        end else begin
            // Default: deassert start pulses
            single_start <= 1'b0;
            multi_start  <= 1'b0;

            if (aw_handshake && w_handshake) begin
                case (axi_awaddr[5:2]) // Word address
                    4'h0: reg_genome_lo   <= S_AXI_WDATA;
                    4'h1: reg_genome_hi   <= S_AXI_WDATA;
                    4'h2: reg_guide       <= S_AXI_WDATA;
                    4'h3: reg_replacement <= S_AXI_WDATA;
                    4'h4: reg_threshold   <= S_AXI_WDATA;
                    4'h5: begin
                        reg_command <= S_AXI_WDATA;
                        // Auto-generate start pulse based on command
                        case (S_AXI_WDATA[7:0])
                            8'h01: single_start <= 1'b1; // SINGLE_EDIT
                            8'h02: multi_start  <= 1'b1; // MULTI_EDIT
                            8'h03: single_start <= 1'b1; // SEARCH_ONLY
                            default: ;
                        endcase
                    end
                    default: ;
                endcase
            end
        end
    end

    // ====================================================================
    // AXI4-Lite Read Logic
    // ====================================================================
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RDATA   = axi_rdata;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RVALID  = axi_rvalid;

    // AR channel
    always @(posedge S_AXI_ACLK) begin
        if (~S_AXI_ARESETN) begin
            axi_arready <= 1'b0;
            axi_araddr  <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else begin
            if (~axi_arready && S_AXI_ARVALID) begin
                axi_arready <= 1'b1;
                axi_araddr  <= S_AXI_ARADDR;
            end else begin
                axi_arready <= 1'b0;
            end
        end
    end

    // R channel
    always @(posedge S_AXI_ACLK) begin
        if (~S_AXI_ARESETN) begin
            axi_rvalid <= 1'b0;
            axi_rresp  <= 2'b00;
        end else begin
            if (axi_arready && S_AXI_ARVALID && ~axi_rvalid) begin
                axi_rvalid <= 1'b1;
                axi_rresp  <= 2'b00; // OKAY
            end else if (axi_rvalid && S_AXI_RREADY) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

    // Read data mux
    always @(posedge S_AXI_ACLK) begin
        if (~S_AXI_ARESETN) begin
            axi_rdata <= 32'd0;
        end else if (axi_arready && S_AXI_ARVALID && ~axi_rvalid) begin
            case (axi_araddr[5:2])
                // Writable registers (read-back)
                4'h0: axi_rdata <= reg_genome_lo;
                4'h1: axi_rdata <= reg_genome_hi;
                4'h2: axi_rdata <= reg_guide;
                4'h3: axi_rdata <= reg_replacement;
                4'h4: axi_rdata <= reg_threshold;
                4'h5: axi_rdata <= reg_command;
                // Status
                // STATUS flags (matches pynq_host.py): [0]=single_done [1]=multi_done
                //                                      [2]=single_pass [3]=multi_pass
                4'h6: axi_rdata <= {16'd0, cap_single_status,
                                    4'd0, cap_multi_pass, cap_single_pass,
                                    cap_multi_done, cap_single_done};
                // Single pipeline results
                4'h7: axi_rdata <= cap_single_genome[31:0];
                4'h8: axi_rdata <= cap_single_genome[63:32];
                4'h9: axi_rdata <= {24'd0, cap_single_target_found,
                                    2'd0, cap_single_target_pos};
                // Multi pipeline results
                4'hA: axi_rdata <= cap_multi_genome[31:0];
                4'hB: axi_rdata <= cap_multi_genome[63:32];
                4'hC: axi_rdata <= {17'd0,
                                    cap_multi_edits_verified,
                                    cap_multi_edits_applied,
                                    cap_multi_targets_found};
                4'hD: axi_rdata <= {30'd0, cap_multi_pass, cap_multi_done};
                // Latency
                4'hE: axi_rdata <= latency_result;
                // Heartbeat
                4'hF: axi_rdata <= heartbeat;
                default: axi_rdata <= 32'd0;
            endcase
        end
    end

endmodule
