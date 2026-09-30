`timescale 1ns / 1ps

// hps_bridge_tb — unit test for the DE1-SoC HPS Avalon-MM host PHY.
//
// Drives the Avalon slave the way the ARM HPS would (register writes/reads over
// the lightweight bridge) and checks the byte-stream side the sequencer sees:
//   - host -> FPGA: a write to TXDATA emits one rx_valid pulse with the byte
//   - FPGA -> host: a sequencer tx_valid raises tx_busy; the byte is read back
//     from RXDATA; the read clears tx_busy; STATUS reflects RX_AVAIL correctly
//   - the tx holding register is not overwritten while a byte is pending
module hps_bridge_tb;

    logic        clk = 0;
    logic        reset;

    logic [1:0]  avs_address;
    logic        avs_read;
    logic [31:0] avs_readdata;
    logic        avs_write;
    logic [31:0] avs_writedata;

    logic [7:0]  rx_data;
    logic        rx_valid;
    logic [7:0]  tx_data;
    logic        tx_valid;
    logic        tx_busy;

    localparam logic [1:0] REG_TXDATA = 2'd0;
    localparam logic [1:0] REG_RXDATA = 2'd1;
    localparam logic [1:0] REG_STATUS = 2'd2;

    hps_bridge dut (
        .clk (clk), .reset (reset),
        .avs_address (avs_address), .avs_read (avs_read),
        .avs_readdata (avs_readdata), .avs_write (avs_write),
        .avs_writedata (avs_writedata),
        .rx_data (rx_data), .rx_valid (rx_valid),
        .tx_data (tx_data), .tx_valid (tx_valid), .tx_busy (tx_busy)
    );

    always #5 clk = ~clk;

    int errors = 0;
    task check(input cond, input string msg);
        if (cond) $display("[PASS] %s", msg);
        else begin $display("[FAIL] %s", msg); errors++; end
    endtask

    // One Avalon write (host -> slave), returns after the clock edge that
    // latches it.
    task avs_wr(input [1:0] a, input [31:0] d);
        @(negedge clk);
        avs_address   = a;
        avs_writedata = d;
        avs_write     = 1'b1;
        @(posedge clk);
        @(negedge clk);
        avs_write     = 1'b0;
    endtask

    // One Avalon read (fixed read latency 1): assert read, and one edge later
    // avs_readdata holds the value.
    task avs_rd(input [1:0] a, output [31:0] d);
        @(negedge clk);
        avs_address = a;
        avs_read    = 1'b1;
        @(posedge clk);   // slave registers readdata on this edge
        @(negedge clk);
        avs_read    = 1'b0;
        d           = avs_readdata;
    endtask

    logic [31:0] rd;

    initial begin
        avs_address = 0; avs_read = 0; avs_write = 0; avs_writedata = 0;
        tx_data = 0; tx_valid = 0;
        reset = 1;
        repeat (3) @(posedge clk);
        @(negedge clk); reset = 0;

        // --- host -> FPGA: write TXDATA, expect a single rx_valid pulse ---
        avs_wr(REG_TXDATA, 32'h0000_005A);
        // after the write edge, rx_valid should be high for exactly one cycle
        check(rx_valid === 1'b1 && rx_data === 8'h5A, "TXDATA write -> rx_valid + rx_data=0x5A");
        @(posedge clk); @(negedge clk);
        check(rx_valid === 1'b0, "rx_valid deasserts after one cycle");

        // --- STATUS idle: TX_SPACE=1, RX_AVAIL=0 ---
        avs_rd(REG_STATUS, rd);
        check(rd[0] === 1'b1, "STATUS TX_SPACE=1 when idle");
        check(rd[1] === 1'b0, "STATUS RX_AVAIL=0 when no tx byte pending");
        check(tx_busy === 1'b0, "tx_busy low when idle");

        // --- FPGA -> host: sequencer offers a byte ---
        @(negedge clk);
        tx_data  = 8'hA5;
        tx_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        tx_valid = 1'b0;
        check(tx_busy === 1'b1, "tx_busy raised after sequencer tx_valid");

        // STATUS should now show a byte waiting
        avs_rd(REG_STATUS, rd);
        check(rd[1] === 1'b1, "STATUS RX_AVAIL=1 with a tx byte pending");

        // --- holding register must not be overwritten while pending ---
        @(negedge clk);
        tx_data  = 8'h3C;
        tx_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        tx_valid = 1'b0;

        // read RXDATA: should still be the FIRST byte (0xA5), and the read
        // pops it so tx_busy clears
        avs_rd(REG_RXDATA, rd);
        check(rd[7:0] === 8'hA5, "RXDATA returns the first pending byte (0xA5), not the ignored 0x3C");
        @(negedge clk);
        check(tx_busy === 1'b0, "tx_busy clears after RXDATA read");

        avs_rd(REG_STATUS, rd);
        check(rd[1] === 1'b0, "STATUS RX_AVAIL=0 after the byte was read");

        if (errors == 0) $display(">>> ALL hps_bridge TESTS PASSED <<<");
        else             $display(">>> hps_bridge FAILED: %0d error(s) <<<", errors);
        $finish;
    end

    // safety timeout
    initial begin
        #10000;
        $display("[FAIL] timeout");
        $finish;
    end

endmodule
