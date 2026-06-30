`timescale 1ns / 1ps

// uart_rx_tb — self-checking testbench for uart_rx.
//
// Drives synthetic UART waveforms at 115200 baud (with 50 MHz system clock)
// and checks that the received bytes match the sent ones.
//
// Tests:
//   1. Single byte 0x55 (alternating 0/1, good toggle stress test)
//   2. Single byte 0xAA
//   3. Multi-byte sequence 0x01 0x04 0xDE 0xAD
//   4. Glitch rejection: start pulse shorter than half-bit, must NOT produce a byte
//   5. Framing error: stop bit driven low

module uart_rx_tb;

    localparam int CLK_FREQ   = 50_000_000;
    localparam int BAUD_RATE  = 115_200;
    localparam int TICKS_BIT  = CLK_FREQ / BAUD_RATE;  // 434 ticks / bit
    localparam int CLK_PERIOD = 20;                     // 20 ns → 50 MHz

    logic       clk = 0;
    logic       reset;
    logic       rx_serial;
    logic [7:0] rx_data;
    logic       rx_valid;
    logic       rx_error;

    int errors = 0;

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)) dut (
        .clk       (clk),
        .reset     (reset),
        .rx_serial (rx_serial),
        .rx_data   (rx_data),
        .rx_valid  (rx_valid),
        .rx_error  (rx_error)
    );

    always #(CLK_PERIOD/2) clk = ~clk;

    // Task: drive one 8N1 frame onto rx_serial
    task automatic send_byte(input logic [7:0] b);
        integer i;
        // Start bit
        rx_serial = 1'b0;
        repeat (TICKS_BIT) @(posedge clk);
        // 8 data bits, LSB first
        for (i = 0; i < 8; i++) begin
            rx_serial = b[i];
            repeat (TICKS_BIT) @(posedge clk);
        end
        // Stop bit
        rx_serial = 1'b1;
        repeat (TICKS_BIT) @(posedge clk);
    endtask

    // Task: wait for rx_valid with timeout, check data
    task automatic await_byte(input logic [7:0] expected, input string label);
        int timeout;
        timeout = 0;
        begin : await_byte_body
            while (!rx_valid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > TICKS_BIT * 12) begin
                    $error("[FAIL] %s TIMEOUT waiting for rx_valid (expected 0x%02X)", label, expected);
                    errors++;
                    disable await_byte_body;
                end
            end
            if (rx_data !== expected) begin
                $error("[FAIL] %s: expected 0x%02X, got 0x%02X", label, expected, rx_data);
                errors++;
            end else begin
                $display("[PASS] %s: 0x%02X", label, rx_data);
            end
        end
    endtask

    initial begin
        rx_serial = 1'b1;
        reset     = 1'b1;
        repeat (4) @(posedge clk);
        reset = 1'b0;
        @(posedge clk);

        $display("\n=== Starting uart_rx Testbench ===\n");

        // Test 1: byte 0x55 (01010101)
        $display(" Test 1: byte 0x55");
        fork
            send_byte(8'h55);
            await_byte(8'h55, "T1 0x55");
        join

        // Test 2: byte 0xAA (10101010)
        $display(" Test 2: byte 0xAA");
        fork
            send_byte(8'hAA);
            await_byte(8'hAA, "T2 0xAA");
        join

        // Test 3: multi-byte sequence
        $display(" Test 3: multi-byte 0x01 0x04 0xDE 0xAD");
        begin
            logic [7:0] seq3 [4];
            seq3[0] = 8'h01; seq3[1] = 8'h04; seq3[2] = 8'hDE; seq3[3] = 8'hAD;
            for (int i = 0; i < 4; i++) begin
                fork
                    send_byte(seq3[i]);
                    await_byte(seq3[i], $sformatf("T3 byte%0d", i));
                join
            end
        end

        // Test 4: glitch rejection — start pulse < half-bit, no byte expected
        $display(" Test 4: glitch rejection (no output expected)");
        begin
            // Glitch: drive low for only TICKS_BIT/4 ticks, then back high
            rx_serial = 1'b0;
            repeat (TICKS_BIT/4) @(posedge clk);
            rx_serial = 1'b1;
            // Wait a full bit period and check rx_valid never fired
            begin
                integer glitch_cnt;
                glitch_cnt = 0;
                repeat (TICKS_BIT * 2) begin
                    @(posedge clk);
                    if (rx_valid) glitch_cnt = glitch_cnt + 1;
                end
                if (glitch_cnt != 0) begin
                    $error("[FAIL] T4 glitch: rx_valid fired %0d times (expected 0)", glitch_cnt);
                    errors++;
                end else begin
                    $display("[PASS] T4: glitch correctly ignored");
                end
            end
        end

        // Test 5: framing error — stop bit driven low
        $display(" Test 5: framing error (stop bit = 0)");
        begin
            // Send 0xFF but with stop bit held low
            rx_serial = 1'b0;                           // start
            repeat (TICKS_BIT) @(posedge clk);
            repeat (8) begin
                rx_serial = 1'b1;                       // all data bits high
                repeat (TICKS_BIT) @(posedge clk);
            end
            rx_serial = 1'b0;                           // BAD stop bit

            // Wait just past the mid-stop-bit sample point (TICKS_BIT/2 + margin)
            repeat (TICKS_BIT/2 + 10) @(posedge clk);
            if (!rx_error) begin
                $error("[FAIL] T5: rx_error not asserted on framing error");
                errors++;
            end else begin
                $display("[PASS] T5: framing error detected");
            end

            // Release the line to HIGH before Test 6
            rx_serial = 1'b1;
            // Wait for the FSM to settle back to IDLE after line release
            repeat (TICKS_BIT * 3) @(posedge clk);
        end

        // Test 6: recovery after framing error — normal byte arrives OK
        $display(" Test 6: recovery after framing error");
        fork
            send_byte(8'h42);
            await_byte(8'h42, "T6 0x42");
        join

        $display("\n=== SIMULATION COMPLETE ===");
        if (errors == 0)
            $display(">>> ALL uart_rx TESTS PASSED <<<");
        else
            $display(">>> SIMULATION FAILED WITH %0d ERRORS <<<", errors);

        $finish;
    end

endmodule
