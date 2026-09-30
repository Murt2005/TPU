`timescale 1ns / 1ps

// uart_tx_tb — self-checking testbench for uart_tx.
//
// Sends bytes through uart_tx and decodes the resulting tx_serial waveform
// bit-by-bit to reconstruct the transmitted byte, then compares against
// what was sent.
//
// Tests:
//   1. Single byte 0x55
//   2. Single byte 0xAA
//   3. Back-to-back bytes (no gap): 0x01 0x02 0x03
//   4. tx_busy gate: second byte suppressed while tx_busy high
//   5. 0x00 (all-zero data)
//   6. 0xFF (all-one data)

module uart_tx_tb;

    localparam int CLK_FREQ   = 50_000_000;
    localparam int BAUD_RATE  = 115_200;
    localparam int TICKS_BIT  = CLK_FREQ / BAUD_RATE;   // 434 ticks/bit
    localparam int CLK_PERIOD = 20;

    logic       clk = 0;
    logic       reset;
    logic [7:0] tx_data;
    logic       tx_valid;
    logic       tx_busy;
    logic       tx_serial;

    int errors = 0;

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) dut (
        .clk       (clk),
        .reset     (reset),
        .tx_data   (tx_data),
        .tx_valid  (tx_valid),
        .tx_busy   (tx_busy),
        .tx_serial (tx_serial)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // Task: wait until tx_busy goes low (inter-frame gap / idle)
    task automatic wait_idle();
        int timeout = 0;
        while (tx_busy) begin
            @(posedge clk);
            timeout++;
            if (timeout > TICKS_BIT * 15) begin
                $error("[FATAL] Timed out waiting for tx_busy=0");
                $finish;
            end
        end
    endtask

    // Task: sample tx_serial to decode one 8N1 frame.
    // Waits for start bit, then samples each bit at mid-period.
    task automatic recv_byte(output logic [7:0] received);
        // Wait for start bit (falling edge)
        while (tx_serial !== 1'b0) @(posedge clk);

        // Now at the very start of the start bit.
        // Advance to mid-start-bit to confirm it's still 0
        repeat (TICKS_BIT / 2) @(posedge clk);
        if (tx_serial !== 1'b0) begin
            $error("[FAIL] Start bit is not 0 at mid-bit sample");
            errors++;
        end

        // Sample 8 data bits at mid-bit of each bit period
        for (int i = 0; i < 8; i++) begin
            repeat (TICKS_BIT) @(posedge clk);
            received[i] = tx_serial;
        end

        // Verify stop bit
        repeat (TICKS_BIT) @(posedge clk);
        if (tx_serial !== 1'b1) begin
            $error("[FAIL] Stop bit is not 1");
            errors++;
        end
    endtask

    // Task: send one byte through DUT and verify the decoded result
    task automatic send_and_check(input logic [7:0] b, input string label);
        logic [7:0] decoded;

        wait_idle();
        @(posedge clk);
        tx_data  = b;
        tx_valid = 1'b1;
        @(posedge clk);
        tx_valid = 1'b0;

        recv_byte(decoded);

        if (decoded !== b) begin
            $error("[FAIL] %s: sent 0x%02X, decoded 0x%02X", label, b, decoded);
            errors++;
        end else begin
            $display("[PASS] %s: 0x%02X", label, b);
        end
    endtask

    initial begin
        tx_data  = '0;
        tx_valid = 1'b0;
        reset    = 1'b1;
        repeat (4) @(posedge clk);
        reset = 1'b0;
        @(posedge clk);

        $display("\n=== Starting uart_tx Testbench ===\n");

        // Test 1 & 2: single bytes
        $display(" Test 1: byte 0x55");
        send_and_check(8'h55, "T1 0x55");

        $display(" Test 2: byte 0xAA");
        send_and_check(8'hAA, "T2 0xAA");

        // Test 3: back-to-back bytes (assert tx_valid the moment tx_busy drops)
        $display(" Test 3: back-to-back 0x01 0x02 0x03");
        begin
            logic [7:0] seq3_0, seq3_1, seq3_2;
            logic [7:0] decoded3;
            integer i3;
            seq3_0 = 8'h01; seq3_1 = 8'h02; seq3_2 = 8'h03;
            for (i3 = 0; i3 < 3; i3 = i3 + 1) begin
                logic [7:0] cur3;
                case (i3)
                    0: cur3 = seq3_0;
                    1: cur3 = seq3_1;
                    default: cur3 = seq3_2;
                endcase
                wait_idle();
                @(posedge clk);
                tx_data  = cur3;
                tx_valid = 1'b1;
                @(posedge clk);
                tx_valid = 1'b0;
                recv_byte(decoded3);
                if (decoded3 !== cur3) begin
                    $error("[FAIL] T3 byte%0d: sent 0x%02X, got 0x%02X", i3, cur3, decoded3);
                    errors++;
                end else begin
                    $display("[PASS] T3 byte%0d: 0x%02X", i3, decoded3);
                end
            end
        end

        // Test 4: tx_busy gate — pulse tx_valid while tx_busy is high,
        //         second byte must be silently dropped (no extra frame).
        $display(" Test 4: tx_busy gate — dropped byte");
        begin
            logic [7:0] decoded;
            // Start a legitimate transmission of 0xBB
            wait_idle();
            @(posedge clk);
            tx_data  = 8'hBB;
            tx_valid = 1'b1;
            @(posedge clk);
            tx_valid = 1'b0;

            // While that is transmitting, attempt to queue 0xCC
            // (tx_busy should be high now)
            @(posedge clk);
            if (tx_busy) begin
                tx_data  = 8'hCC;
                tx_valid = 1'b1;
                @(posedge clk);
                tx_valid = 1'b0;
            end

            // Decode what actually arrived on the wire
            recv_byte(decoded);
            if (decoded !== 8'hBB) begin
                $error("[FAIL] T4: expected 0xBB, got 0x%02X", decoded);
                errors++;
            end else begin
                $display("[PASS] T4: 0xBB received correctly");
            end

            // After 0xBB finishes, wait a bit and make sure no extra frame
            // appears (0xCC should NOT have been sent)
            begin
                integer spurious;
                spurious = 0;
                wait_idle();
                // Wait 2 bit-periods on idle line — any transition = spurious
                repeat (TICKS_BIT * 2) begin
                    @(posedge clk);
                    if (tx_serial === 1'b0) spurious = spurious + 1;
                end
                if (spurious != 0) begin
                    $error("[FAIL] T4: spurious frame detected after dropped byte");
                    errors++;
                end else begin
                    $display("[PASS] T4: dropped byte correctly not retransmitted");
                end
            end
        end

        // Test 5 & 6: boundary values
        $display(" Test 5: byte 0x00 (all zeros)");
        send_and_check(8'h00, "T5 0x00");

        $display(" Test 6: byte 0xFF (all ones)");
        send_and_check(8'hFF, "T6 0xFF");

        $display("\n=== SIMULATION COMPLETE ===");
        if (errors == 0)
            $display(">>> ALL uart_tx TESTS PASSED <<<");
        else
            $display(">>> SIMULATION FAILED WITH %0d ERRORS <<<", errors);

        $finish;
    end

endmodule
