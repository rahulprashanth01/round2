`timescale 1ns/1ps
// ============================================================================
// Self-checking testbench for genome_x_axi_top. Drives the AXI-Lite registers
// exactly the way pynq_host.py does (same register order, same STATUS polling:
// single_done = STATUS[0], single_pass = STATUS[2], multi via 0x34), and checks
// results against a reference model. Prints PASS/FAIL per test and a final score.
// ============================================================================
module tb_genome_x_axi;
    reg clk = 0, rstn = 0;
    always #5 clk = ~clk;

    reg  [5:0]  awaddr, araddr;
    reg         awvalid = 0, wvalid = 0, arvalid = 0;
    reg  [31:0] wdata;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [31:0] rdata;

    genome_x_axi_top dut (
        .S_AXI_ACLK(clk), .S_AXI_ARESETN(rstn),
        .S_AXI_AWADDR(awaddr), .S_AXI_AWPROT(3'b0), .S_AXI_AWVALID(awvalid), .S_AXI_AWREADY(awready),
        .S_AXI_WDATA(wdata), .S_AXI_WSTRB(4'hF), .S_AXI_WVALID(wvalid), .S_AXI_WREADY(wready),
        .S_AXI_BRESP(), .S_AXI_BVALID(bvalid), .S_AXI_BREADY(1'b1),
        .S_AXI_ARADDR(araddr), .S_AXI_ARPROT(3'b0), .S_AXI_ARVALID(arvalid), .S_AXI_ARREADY(arready),
        .S_AXI_RDATA(rdata), .S_AXI_RRESP(), .S_AXI_RVALID(rvalid), .S_AXI_RREADY(1'b1),
        .led_busy(), .led_pass(), .led_fail());

    task wr(input [5:0] a, input [31:0] d); begin
        @(posedge clk); awaddr <= a; wdata <= d; awvalid <= 1; wvalid <= 1;
        wait (awready && wready); @(posedge clk); awvalid <= 0; wvalid <= 0;
        wait (bvalid); @(posedge clk);
    end endtask

    reg [31:0] r;
    task rd(input [5:0] a); begin
        @(posedge clk); araddr <= a; arvalid <= 1; wait (arready); @(posedge clk);
        arvalid <= 0; wait (rvalid); r = rdata; @(posedge clk);
    end endtask

    integer passed = 0, failed = 0, polls;
    reg ok;
    reg [31:0] st, info, cnt;
    reg [63:0] res;

    task load(input [63:0] g, input [15:0] gd, input [7:0] rp, input [1:0] th, input [7:0] cmd); begin
        wr(6'h00, g[31:0]); wr(6'h04, g[63:32]); wr(6'h08, {16'b0, gd});
        wr(6'h0C, {24'b0, rp}); wr(6'h10, {30'b0, th}); wr(6'h14, {24'b0, cmd});
    end endtask

    task run_single(input integer n, input [63:0] g, input [15:0] gd, input [7:0] rp, input [1:0] th,
                    input exp_found, input [4:0] exp_pos, input [63:0] exp_genome);
        reg done; begin
        ok = 1; done = 0;
        load(g, gd, rp, th, 8'h01);
        for (polls = 0; polls < 400 && !done; polls = polls + 1) begin rd(6'h18); st = r; done = st[0]; end
        if (!done) begin $display("  [FAIL] single %0d: TIMEOUT (STATUS=0x%08h)", n, st); ok = 0; end
        else begin
            rd(6'h1C); res[31:0] = r; rd(6'h20); res[63:32] = r; rd(6'h24); info = r;
            if (info[7] !== exp_found) begin $display("  [FAIL] single %0d: found=%0d exp %0d", n, info[7], exp_found); ok = 0; end
            if (exp_found && info[4:0] !== exp_pos) begin $display("  [FAIL] single %0d: pos=%0d exp %0d", n, info[4:0], exp_pos); ok = 0; end
            if (st[2] !== exp_found) begin $display("  [FAIL] single %0d: pass=%0d exp %0d", n, st[2], exp_found); ok = 0; end
            if (res !== exp_genome) begin $display("  [FAIL] single %0d: genome=%016h exp %016h", n, res, exp_genome); ok = 0; end
        end
        if (ok) begin $display("  [PASS] single %0d", n); passed = passed + 1; end else failed = failed + 1;
    end endtask

    task run_multi(input integer n, input [63:0] g, input [15:0] gd, input [7:0] rp, input [1:0] th,
                   input integer exp_t, input integer min_t, input exp_pass, input chk_genome, input [63:0] exp_genome);
        reg done; begin
        ok = 1; done = 0;
        load(g, gd, rp, th, 8'h02);
        for (polls = 0; polls < 400 && !done; polls = polls + 1) begin rd(6'h34); st = r; done = st[0]; end
        if (!done) begin $display("  [FAIL] multi %0d: TIMEOUT", n); ok = 0; end
        else begin
            rd(6'h28); res[31:0] = r; rd(6'h2C); res[63:32] = r; rd(6'h30); cnt = r;
            if (exp_t >= 0 && cnt[4:0] !== exp_t[4:0]) begin $display("  [FAIL] multi %0d: targets=%0d exp %0d", n, cnt[4:0], exp_t); ok = 0; end
            if (cnt[4:0] < min_t) begin $display("  [FAIL] multi %0d: targets=%0d < %0d", n, cnt[4:0], min_t); ok = 0; end
            if (cnt[9:5] !== cnt[4:0] || cnt[14:10] !== cnt[4:0]) begin $display("  [FAIL] multi %0d: applied/verified (%0d/%0d) != targets %0d", n, cnt[9:5], cnt[14:10], cnt[4:0]); ok = 0; end
            if (st[1] !== exp_pass) begin $display("  [FAIL] multi %0d: all_pass=%0d exp %0d", n, st[1], exp_pass); ok = 0; end
            if (chk_genome && res !== exp_genome) begin $display("  [FAIL] multi %0d: genome=%016h exp %016h", n, res, exp_genome); ok = 0; end
        end
        if (ok) begin $display("  [PASS] multi %0d (targets=%0d)", n, cnt[4:0]); passed = passed + 1; end else failed = failed + 1;
    end endtask

    initial begin
        #50 rstn = 1; #50;
        rd(6'h3C);
        $display("== SINGLE-TARGET TESTS ==");
    run_single(1, 64'h1b1b1b1b1b1b1b1b, 16'h1b1b, 8'hff, 2'd0, 1, 5'd0, 64'hff1b1b1b1b1b1b1b);
    run_single(2, 64'hff1b1bffffffffff, 16'h1b1b, 8'h55, 2'd0, 1, 5'd4, 64'hff551bffffffffff);
    run_single(3, 64'h9b1b1b1b1b1b1b1b, 16'h1b1b, 8'h00, 2'd1, 1, 5'd0, 64'h001b1b1b1b1b1b1b);
    run_single(4, 64'h000000000000000f, 16'h5555, 8'haa, 2'd0, 0, 5'd0, 64'h000000000000000f);
    run_single(5, 64'hffffffffffffff1b, 16'hffff, 8'h55, 2'd0, 1, 5'd0, 64'h55ffffffffffff1b);
    run_single(6, 64'h000000000000001b, 16'h0006, 8'hff, 2'd0, 1, 5'd23, 64'h000000000003fc1b);
    run_single(7, 64'h5b5b1b1b1b1b1b1b, 16'h1b1b, 8'haa, 2'd2, 1, 5'd0, 64'haa5b1b1b1b1b1b1b);
    run_single(8, 64'h9b1bffffffffffff, 16'h1b1b, 8'h00, 2'd0, 0, 5'd0, 64'h9b1bffffffffffff);
    run_single(9, 64'h0000000000000000, 16'h0000, 8'hff, 2'd0, 1, 5'd0, 64'hff00000000000000);
    run_single(10, 64'hffffffffffffffff, 16'hffff, 8'h00, 2'd0, 1, 5'd0, 64'h00ffffffffffffff);
        $display("== MULTI-TARGET TESTS ==");
    run_multi(1, 64'h1b1bffff1b1bffff, 16'h1b1b, 8'h55, 2'd0, 2, 0, 1, 1, 64'h551bffff551bffff);
    run_multi(2, 64'h000000000000001b, 16'h5555, 8'haa, 2'd0, 0, 0, 0, 1, 64'h000000000000001b);
    run_multi(3, 64'h1b1b1b1b1b1b1b1b, 16'h1b1b, 8'h1b, 2'd0, -1, 1, 1, 0, 64'h1b1b1b1b1b1b1b1b);
    run_multi(4, 64'hff1b1bffffffffff, 16'h1b1b, 8'haa, 2'd0, 1, 0, 1, 1, 64'hffaa1bffffffffff);
        $display("=====================================================");
        $display("  FINAL SCORE: %0d/%0d tests passed", passed, passed + failed);
        if (failed == 0) $display("  ALL TESTS PASSED"); else $display("  %0d TEST(S) FAILED", failed);
        $display("=====================================================");
        $finish;
    end
endmodule
