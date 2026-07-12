`timescale 1ns / 1ps

// spi_slave_tb — unit test for rtl/spi_slave.sv (SPI mode-0 slave PHY).
//
// Drives the SPI pins as a mode-0 master at two rates matching the module's
// documented envelope: a fast write clock (~CLK/2, the bulk MOSI direction)
// and a slower read clock (CLK/10 < the CLK/8 cap, the MISO poll direction).
//
//  T1: RX bytes at fast SCK arrive as one rx_valid pulse each, MSB first
//  T2: MISO returns IDLE_BYTE (0x00) while the TX FIFO is empty
//  T3: queued response bytes read back in order, then idle again
//  T4: CS deassert mid-byte discards the torn byte; alignment recovers
//  T5: tx_busy backpressure at FIFO depth (16); order preserved end-to-end
//  T6: full-duplex frame: MOSI bytes still received correctly while MISO
//      is simultaneously draining queued bytes

module spi_slave_tb;

    // 12 MHz-ish system clock (exact period irrelevant; ratios matter)
    localparam int CLK_PERIOD = 10;

    logic clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    logic reset;

    // SPI pins
    logic sck = 0, csn = 1, mosi = 0;
    logic miso;

    // byte-stream side
    logic [7:0] rx_data;
    logic       rx_valid;
    logic [7:0] tx_data;
    logic       tx_valid = 0;
    logic       tx_busy;

    spi_slave dut (
        .clk      (clk),
        .reset    (reset),
        .sck      (sck),
        .csn      (csn),
        .mosi     (mosi),
        .miso     (miso),
        .rx_data  (rx_data),
        .rx_valid (rx_valid),
        .tx_data  (tx_data),
        .tx_valid (tx_valid),
        .tx_busy  (tx_busy)
    );

    integer errors = 0;

    // Capture every rx_valid pulse
    logic [7:0] rx_buf [64];
    integer     rx_cnt = 0;
    always @(posedge clk)
        if (rx_valid && rx_cnt < 64) begin
            rx_buf[rx_cnt] = rx_data;
            rx_cnt = rx_cnt + 1;
        end

    // -- SPI master BFM (mode 0: sample on rising, shift on falling) --------
    // half = half-period in ns. Fast writes: half=10 (SCK=CLK/2).
    // Read polls: half=50 (SCK=CLK/10, under the documented CLK/8 cap).
    task automatic spi_xfer_byte(input logic [7:0] w, output logic [7:0] r,
                                 input integer half);
        for (int i = 7; i >= 0; i--) begin
            mosi = w[i];
            #(half) sck = 1;      // master drives bit, then rising edge:
            r[i] = miso;          //   both sides sample here (mode 0)
            #(half) sck = 0;      // falling edge: both sides shift
        end
    endtask

    task automatic cs_begin();
        csn = 0;
        #(6 * CLK_PERIOD);  // CS-to-first-SCK lead (module needs >= 5 clk)
    endtask

    task automatic cs_end();
        #(2 * CLK_PERIOD);
        csn = 1;
        #(4 * CLK_PERIOD);
    endtask

    // Push one byte into the response FIFO (clk domain, like the sequencer)
    task automatic push_tx(input logic [7:0] b);
        @(posedge clk);
        while (tx_busy) @(posedge clk);
        tx_data  <= b;
        tx_valid <= 1'b1;
        @(posedge clk);
        tx_valid <= 1'b0;
    endtask

    logic [7:0] rd;
    logic [7:0] wr_bytes [6];

    initial begin
        $dumpfile("spi_slave_tb.vcd");
        $dumpvars(0, spi_slave_tb);

        reset = 1;
        repeat (5) @(posedge clk);
        reset = 0;
        repeat (5) @(posedge clk);

        // ---------------- T1: fast-clock RX ----------------
        $display("[Test 1] RX at fast SCK (CLK/2)");
        wr_bytes[0] = 8'h01; wr_bytes[1] = 8'hA5; wr_bytes[2] = 8'h5A;
        wr_bytes[3] = 8'hFF; wr_bytes[4] = 8'h00; wr_bytes[5] = 8'h80;
        cs_begin();
        for (int i = 0; i < 6; i++) spi_xfer_byte(wr_bytes[i], rd, 10);
        cs_end();
        repeat (10) @(posedge clk);   // let the last byte cross the CDC
        if (rx_cnt != 6) begin
            $error("[FAIL] T1: expected 6 rx bytes, got %0d", rx_cnt);
            errors++;
        end else begin
            for (int i = 0; i < 6; i++)
                if (rx_buf[i] !== wr_bytes[i]) begin
                    $error("[FAIL] T1: byte %0d: got %02X expected %02X",
                           i, rx_buf[i], wr_bytes[i]);
                    errors++;
                end
            if (errors == 0) $display("[PASS] T1: 6/6 bytes received MSB-first");
        end
        rx_cnt = 0;

        // ---------------- T2: idle MISO ----------------
        $display("[Test 2] MISO idles at 0x00 with empty TX FIFO");
        cs_begin();
        spi_xfer_byte(8'hFF, rd, 50);
        cs_end();
        if (rd !== 8'h00) begin
            $error("[FAIL] T2: idle MISO got %02X, expected 00", rd);
            errors++;
        end else $display("[PASS] T2: idle byte 0x00");
        rx_cnt = 0;   // discard the 0xFF poll filler byte the RX side saw

        // ---------------- T3: queued response readback ----------------
        $display("[Test 3] queued bytes read back in order, then idle");
        push_tx(8'hAA);
        push_tx(8'h08);
        push_tx(8'h6C);
        repeat (4) @(posedge clk);
        cs_begin();
        spi_xfer_byte(8'hFF, rd, 50);
        if (rd !== 8'hAA) begin $error("[FAIL] T3: byte0 %02X != AA", rd); errors++; end
        spi_xfer_byte(8'hFF, rd, 50);
        if (rd !== 8'h08) begin $error("[FAIL] T3: byte1 %02X != 08", rd); errors++; end
        spi_xfer_byte(8'hFF, rd, 50);
        if (rd !== 8'h6C) begin $error("[FAIL] T3: byte2 %02X != 6C", rd); errors++; end
        spi_xfer_byte(8'hFF, rd, 50);
        if (rd !== 8'h00) begin $error("[FAIL] T3: post-drain %02X != 00 idle", rd); errors++; end
        cs_end();
        if (errors == 0) $display("[PASS] T3: 3 bytes in order + idle after drain");
        rx_cnt = 0;

        // ---------------- T4: CS abort mid-byte ----------------
        $display("[Test 4] CS deassert mid-byte discards torn byte");
        cs_begin();
        for (int i = 7; i >= 3; i--) begin   // only 5 bits of 0xDE
            mosi = 8'hDE >> i;
            #(10) sck = 1;
            #(10) sck = 0;
        end
        cs_end();                            // torn byte must vanish
        cs_begin();
        spi_xfer_byte(8'h3C, rd, 10);
        cs_end();
        repeat (10) @(posedge clk);
        if (rx_cnt != 1 || rx_buf[0] !== 8'h3C) begin
            $error("[FAIL] T4: got %0d byte(s), first %02X (expected 1 byte, 3C)",
                   rx_cnt, rx_buf[0]);
            errors++;
        end else $display("[PASS] T4: torn byte discarded, next byte aligned");
        rx_cnt = 0;

        // ---------------- T5: FIFO backpressure ----------------
        $display("[Test 5] tx_busy at FIFO depth, order preserved");
        for (int i = 0; i < 16; i++) push_tx(8'h10 + i[7:0]);
        @(posedge clk);
        if (!tx_busy) begin
            $error("[FAIL] T5: tx_busy low with 16 bytes queued");
            errors++;
        end
        cs_begin();
        for (int i = 0; i < 16; i++) begin
            spi_xfer_byte(8'hFF, rd, 50);
            if (rd !== 8'h10 + i[7:0]) begin
                $error("[FAIL] T5: byte %0d: got %02X expected %02X",
                       i, rd, 8'h10 + i[7:0]);
                errors++;
            end
        end
        cs_end();
        @(posedge clk);
        if (tx_busy) begin
            $error("[FAIL] T5: tx_busy still high after drain");
            errors++;
        end
        if (errors == 0) $display("[PASS] T5: backpressure + 16/16 in order");
        rx_cnt = 0;

        // ---------------- T6: full duplex ----------------
        $display("[Test 6] simultaneous MOSI command + MISO drain");
        push_tx(8'hC3);
        push_tx(8'h96);
        repeat (4) @(posedge clk);
        cs_begin();
        spi_xfer_byte(8'h11, rd, 50);
        if (rd !== 8'hC3) begin $error("[FAIL] T6: miso0 %02X != C3", rd); errors++; end
        spi_xfer_byte(8'h22, rd, 50);
        if (rd !== 8'h96) begin $error("[FAIL] T6: miso1 %02X != 96", rd); errors++; end
        cs_end();
        repeat (10) @(posedge clk);
        if (rx_cnt != 2 || rx_buf[0] !== 8'h11 || rx_buf[1] !== 8'h22) begin
            $error("[FAIL] T6: mosi side got %0d bytes [%02X %02X], expected [11 22]",
                   rx_cnt, rx_buf[0], rx_buf[1]);
            errors++;
        end
        if (errors == 0) $display("[PASS] T6: both directions correct in one frame");

        // ---------------- summary ----------------
        $display("");
        if (errors == 0) $display(">>> ALL spi_slave TESTS PASSED <<<");
        else             $display(">>> spi_slave: %0d ERROR(S) <<<", errors);
        $finish;
    end

endmodule
