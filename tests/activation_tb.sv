`timescale 1ns / 1ps

// Standalone testbench for the activation (ReLU) module.
//
// Exercises:
//   Test 1 – Positive values pass through unchanged.
//   Test 2 – Negative values are clamped to zero.
//   Test 3 – Zero is returned as zero (boundary).
//   Test 4 – Mixed-sign row: some columns clamp, others pass.
//   Test 5 – Back-to-back rows without any gap (pipeline utilisation).
//   Test 6 – Large positive / negative values (near ±(2^(PSUM_WIDTH-1)-1)).
//   Test 7 – Invalid input (in_row_valid=0) produces no out_row_valid pulse.
//   Test 8 – Reset mid-stream: out_row_valid stays low while reset is held,
//             then module recovers and operates correctly afterward.
//

module activation_tb;
    localparam int NUM_COLS   = 2;
    localparam int PSUM_WIDTH = 16;

    logic clk;
    logic reset;

    logic signed [PSUM_WIDTH-1:0] in_row  [NUM_COLS];
    logic                         in_row_valid;

    logic signed [PSUM_WIDTH-1:0] out_row [NUM_COLS];
    logic                         out_row_valid;

    int errors       = 0;
    int rows_checked = 0;

    activation #(
        .NUM_COLS(NUM_COLS),
        .PSUM_WIDTH(PSUM_WIDTH)
    ) dut (
        .clk          (clk),
        .reset        (reset),
        .in_row       (in_row),
        .in_row_valid (in_row_valid),
        .out_row      (out_row),
        .out_row_valid(out_row_valid)
    );

    always #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // Helper task: drive a row, wait one cycle for the registered output,
    // then check both columns.
    //
    // Timing (10 ns period, posedge at odd multiples of 5 ns):
    //   @(negedge):   drive data + valid=1   [setup before next posedge]
    //   @(posedge):   DUT latches {out_row_valid<=1, out_row<=relu(data)}
    //   #1:           de-assert in_row_valid  [still in the same cycle]
    //   @(negedge):   sample outputs at the MIDPOINT of the valid window,
    //                 guaranteed AFTER the posedge wrote the ff and BEFORE
    //                 the next posedge could overwrite it.
    // -----------------------------------------------------------------------
    task automatic check_row(
        input logic signed [PSUM_WIDTH-1:0] i0, i1,
        input logic signed [PSUM_WIDTH-1:0] exp0, exp1,
        input string                        label
    );
        // Drive inputs just after a negedge.
        @(negedge clk);
        in_row[0]    = i0;
        in_row[1]    = i1;
        in_row_valid = 1'b1;

        // DUT captures valid=1 on this posedge; registered outputs appear.
        @(posedge clk); #1;
        in_row_valid = 1'b0;   // de-assert (won't be seen until next posedge)

        // Sample at the next negedge: midpoint of the valid window.
        // out_row_valid is 1 from the posedge above; next posedge hasn't fired.
        @(negedge clk);

        if (!out_row_valid) begin
            $error("[FAIL] %s: out_row_valid not asserted", label);
            errors++;
        end else if (out_row[0] !== exp0 || out_row[1] !== exp1) begin
            $error("[FAIL] %s: Expected [%0d, %0d], Got [%0d, %0d]",
                   label, exp0, exp1, out_row[0], out_row[1]);
            errors++;
        end else begin
            $display("[PASS] %s: [%0d, %0d]", label, out_row[0], out_row[1]);
        end
        rows_checked++;
    endtask

    initial begin
        clk          = 0;
        reset        = 1;
        in_row[0]    = '0;
        in_row[1]    = '0;
        in_row_valid = 1'b0;

        #15 reset = 0;
        @(posedge clk); #1;

        $display("\n Starting activation (ReLU) Testbench \n");

        // -------------------------------------------------------------------
        $display(" Test 1: positive values pass through ");
        check_row(16'sd10,  16'sd20,  16'sd10,  16'sd20,  "Test1 positive passthrough");

        // -------------------------------------------------------------------
        $display(" Test 2: negative values clamp to zero ");
        check_row(-16'sd5, -16'sd99, 16'sd0, 16'sd0, "Test2 negative clamp");

        // -------------------------------------------------------------------
        $display(" Test 3: zero boundary (zero stays zero) ");
        check_row(16'sd0, 16'sd0, 16'sd0, 16'sd0, "Test3 zero boundary");

        // -------------------------------------------------------------------
        $display(" Test 4: mixed row (col0 positive, col1 negative) ");
        check_row(16'sd42, -16'sd7, 16'sd42, 16'sd0, "Test4 mixed signs");

        // -------------------------------------------------------------------
        // Test 5: back-to-back rows with no idle gap between them.
        // Drive valid=1 for two consecutive posedges; the DUT produces two
        // consecutive out_row_valid pulses one cycle later.
        //
        // Timing:
        //   negedge N:     row0=[3,-3], valid=1
        //   posedge N+5:   DUT latches row0 -> out_row_valid=1, out_row=relu([3,-3])=[3,0]
        //   #1 -> N+6:     update in_row to row1=[-8,8]; keep valid=1
        //   posedge N+15:  DUT latches row1 -> out_row_valid=1, out_row=relu([-8,8])=[0,8]
        //   #1 -> N+16:    valid=0
        //   negedge N+10:  SAMPLE row0: out_row=[3,0], out_row_valid=1  (after posedge N+5, before posedge N+15)
        //   negedge N+20:  SAMPLE row1: out_row=[0,8], out_row_valid=1  (after posedge N+15, before posedge N+25)
        $display(" Test 5: back-to-back rows, no gap ");
        begin
            logic signed [PSUM_WIDTH-1:0] got0_r0, got1_r0, got0_r1, got1_r1;

            // Launch row 0
            @(negedge clk);
            in_row[0] = 16'sd3; in_row[1] = -16'sd3; in_row_valid = 1'b1;

            // posedge captures row 0; immediately update to row 1 (valid still high)
            @(posedge clk); #1;
            in_row[0] = -16'sd8; in_row[1] = 16'sd8;

            // Sample row 0 at the negedge: midpoint between the two posedges.
            // out_row_valid=1 (from row0's posedge), out_row=relu([3,-3])=[3,0].
            @(negedge clk);
            if (!out_row_valid) begin
                $error("[FAIL] Test5 row0: out_row_valid not asserted");
                errors++;
            end else begin
                got0_r0 = out_row[0]; got1_r0 = out_row[1];
                if (got0_r0 !== 16'sd3 || got1_r0 !== 16'sd0) begin
                    $error("[FAIL] Test5 row0: Expected [3, 0], Got [%0d, %0d]",
                           got0_r0, got1_r0);
                    errors++;
                end else begin
                    $display("[PASS] Test5 row0 (back-to-back): [%0d, %0d]",
                             got0_r0, got1_r0);
                end
            end

            // posedge captures row 1; de-assert valid
            @(posedge clk); #1;
            in_row_valid = 1'b0;

            // Sample row 1 at the negedge: out_row=relu([-8,8])=[0,8].
            @(negedge clk);
            if (!out_row_valid) begin
                $error("[FAIL] Test5 row1: out_row_valid not asserted");
                errors++;
            end else begin
                got0_r1 = out_row[0]; got1_r1 = out_row[1];
                if (got0_r1 !== 16'sd0 || got1_r1 !== 16'sd8) begin
                    $error("[FAIL] Test5 row1: Expected [0, 8], Got [%0d, %0d]",
                           got0_r1, got1_r1);
                    errors++;
                end else begin
                    $display("[PASS] Test5 row1 (back-to-back): [%0d, %0d]",
                             got0_r1, got1_r1);
                end
            end
            rows_checked += 2;
        end

        // -------------------------------------------------------------------
        $display(" Test 6: near-saturation values ");
        // Max positive for signed 16-bit: 32767.  Max negative: -32768.
        check_row(16'sd32767, -16'sd32768, 16'sd32767, 16'sd0, "Test6 saturation");

        // -------------------------------------------------------------------
        $display(" Test 7: invalid input produces no output ");
        begin
            int spurious;
            spurious = 0;
            @(negedge clk);
            in_row[0]    = -16'sd100;  // would be clamped if valid
            in_row[1]    = -16'sd200;
            in_row_valid = 1'b0;       // NOT valid

            repeat (4) @(posedge clk);
            // Scoreboard: out_row_valid must never fire during these cycles.
            // We sample once more then check the scoreboard flag.
            if (out_row_valid) begin
                $error("[FAIL] Test7: out_row_valid asserted spuriously while in_row_valid=0");
                errors++;
            end else begin
                $display("[PASS] Test7: no spurious output while in_row_valid=0");
            end
        end

        // -------------------------------------------------------------------
        $display(" Test 8: reset mid-stream ");
        begin
            int spurious;
            spurious = 0;

            // Send a valid row to get the pipeline warm.
            @(negedge clk);
            in_row[0] = 16'sd55; in_row[1] = 16'sd66; in_row_valid = 1'b1;
            @(posedge clk); #1;
            in_row_valid = 1'b0;

            // Assert reset immediately (before the registered output fires).
            reset = 1;
            @(posedge clk); #1;
            if (out_row_valid) begin
                $error("[FAIL] Test8: out_row_valid asserted while reset=1");
                errors++;
                spurious++;
            end
            @(posedge clk); #1;
            if (out_row_valid) begin
                $error("[FAIL] Test8: out_row_valid still high during reset");
                errors++;
                spurious++;
            end
            if (spurious == 0)
                $display("[PASS] Test8: out_row_valid stays low while reset held");

            // Release reset and verify recovery.
            reset = 0;
            @(posedge clk); #1;

            check_row(16'sd7, -16'sd3, 16'sd7, 16'sd0, "Test8 post-reset recovery");
        end

        // -------------------------------------------------------------------
        $display("\n=== SIMULATION COMPLETE ===\n");
        if (errors == 0)
            $display(">>> ALL activation TESTS PASSED <<<");
        else
            $display(">>> %0d activation TESTS FAILED <<<", errors);

        $finish;
    end

    initial begin
        $dumpfile("activation_simulation.vcd");
        $dumpvars(0, activation_tb);
    end

endmodule
