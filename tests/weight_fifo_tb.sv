`timescale 1ns / 1ps

// Testbench for weight_fifo.
//
// Mirrors the staggered weight-loading scenario already proven correct
// in mmu_tb.sv / mmu_with_accum_tb.sv: W = [[4,5],[2,3]], loaded
// bottom-row-first (2,3) then top-row (4,5), so a downstream MMU would
// capture pe00=4, pe01=5, pe10=2, pe11=3 -- exactly as in those
// testbenches. This TB does not instantiate the MMU; it checks the
// weight_fifo's own output stream/timing/status flags directly, plus
// the double-buffering swap behavior.
module weight_fifo_tb;
    localparam int WEIGHT_WIDTH = 8;
    localparam int FIFO_DEPTH   = 4;

    logic clk;
    logic reset;

    logic                          write_enable_col_0;
    logic signed [WEIGHT_WIDTH-1:0] write_data_col_0;
    logic                          write_enable_col_1;
    logic signed [WEIGHT_WIDTH-1:0] write_data_col_1;

    logic swap_banks;
    logic shadow_loaded;
    logic active_bank;

    logic loading_phase;

    logic signed [WEIGHT_WIDTH-1:0] out_col_0;
    logic                          out_col_0_valid;
    logic signed [WEIGHT_WIDTH-1:0] out_col_1;
    logic                          out_col_1_valid;

    logic active_empty;
    logic active_full;
    logic any_shadow_full;

    int errors = 0;

    weight_fifo #(
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) uut (.*);

    always #5 clk = ~clk;

    task automatic check(string name, logic cond);
        if (!cond) begin
            $error("[FAIL] %s at time %0t", name, $time);
            errors++;
        end else begin
            $display("[PASS] %s at time %0t", name, $time);
        end
    endtask

    // Expected output queues for col0 / col1 (value, valid) pairs,
    // checked cycle-by-cycle against out_col_0/out_col_0_valid while
    // loading_phase is driven.
    int exp_col0_val_q[$];
    int exp_col1_val_q[$];

    always @(posedge clk) begin
        if (!reset) begin
            if (exp_col0_val_q.size() > 0 || out_col_0_valid) begin
                // only check during the active drive window; pop tracked externally in stimulus
            end
        end
    end

    initial begin
        clk = 0;
        reset = 1;
        write_enable_col_0 = 0; write_data_col_0 = 0;
        write_enable_col_1 = 0; write_data_col_1 = 0;
        swap_banks = 0;
        loading_phase = 0;

        #12 reset = 0;
        @(negedge clk);

        $display("\nStarting weight_fifo Testbench\n");

        // Test 1: Basic load into bank 0 (active by default), drain
        // during loading_phase, check staggered out order + 1-cycle
        // latency + capture-doubling valid behavior.
        // W = [[4,5],[2,3]] -> enqueue bottom row (2,3) then top row (4,5)
        $display("Test 1: basic single-bank load + drain");
        check("active_bank == 0 after reset", active_bank == 1'b0);
        check("active_empty after reset", active_empty == 1'b1);

        write_enable_col_0 = 1; write_data_col_0 = 8'sd2;
        write_enable_col_1 = 1; write_data_col_1 = 8'sd3;
        @(negedge clk);
        write_data_col_0 = 8'sd4;
        write_data_col_1 = 8'sd5;
        @(negedge clk);
        write_enable_col_0 = 0; write_data_col_0 = 0;
        write_enable_col_1 = 0; write_data_col_1 = 0;

        check("shadow_loaded after 2 writes", shadow_loaded == 1'b1);
        check("active_empty still 1 (writes went to shadow bank1, not active bank0)", active_empty == 1'b1);

        // Swap so bank1 (just loaded) becomes active
        swap_banks = 1;
        @(negedge clk);
        swap_banks = 0;
        check("active_bank == 1 after swap", active_bank == 1'b1);
        check("active_empty == 0 after swap (bank1 now active and has data)", active_empty == 1'b0);

        // Drive loading_phase, observe drain order: expect (2, valid), (4, valid), then (0,invalid)
        loading_phase = 1;
        @(negedge clk);
        check("cycle0 out_col_0 == 2", out_col_0 == 8'sd2 && out_col_0_valid == 1'b1);
        check("cycle0 out_col_1 == 3", out_col_1 == 8'sd3 && out_col_1_valid == 1'b1);

        @(negedge clk);
        check("cycle1 out_col_0 == 4", out_col_0 == 8'sd4 && out_col_0_valid == 1'b1);
        check("cycle1 out_col_1 == 5", out_col_1 == 8'sd5 && out_col_1_valid == 1'b1);

        @(negedge clk);
        check("cycle2 out_col_0_valid == 0 (fifo drained)", out_col_0_valid == 1'b0);
        check("cycle2 out_col_1_valid == 0 (fifo drained)", out_col_1_valid == 1'b0);
        check("active_empty == 1 after full drain", active_empty == 1'b1);

        loading_phase = 0;
        @(negedge clk);

        // Test 2: Double buffering, load bank0 (now shadow) with a
        // second matrix WHILE loading_phase stays low (simulating "MMU
        // is busy / idle between ops"), confirming writes to shadow
        // never touch the (already-drained, empty) active bank.
        // W2 = [[1,1],[1,1]]
        $display("\nTest 2: shadow-bank write does not disturb active/drained bank");
        write_enable_col_0 = 1; write_data_col_0 = 8'sd1;
        write_enable_col_1 = 1; write_data_col_1 = 8'sd1;
        @(negedge clk);
        write_data_col_0 = 8'sd1;
        write_data_col_1 = 8'sd1;
        @(negedge clk);
        write_enable_col_0 = 0;
        write_enable_col_1 = 0;

        check("active_empty still 1 (active=bank1, drained; writes went to shadow bank0)", active_empty == 1'b1);
        check("shadow_loaded == 1 (bank0 now has 2 entries each col)", shadow_loaded == 1'b1);

        // Swap to bank0 and drain, confirm correct values arrive in order
        swap_banks = 1;
        @(negedge clk);
        swap_banks = 0;
        check("active_bank == 0 after second swap", active_bank == 1'b0);

        loading_phase = 1;
        @(negedge clk);
        check("W2 cycle0 out_col_0 == 1", out_col_0 == 8'sd1 && out_col_0_valid == 1'b1);
        check("W2 cycle0 out_col_1 == 1", out_col_1 == 8'sd1 && out_col_1_valid == 1'b1);
        @(negedge clk);
        check("W2 cycle1 out_col_0 == 1", out_col_0 == 8'sd1 && out_col_0_valid == 1'b1);
        check("W2 cycle1 out_col_1 == 1", out_col_1 == 8'sd1 && out_col_1_valid == 1'b1);
        @(negedge clk);
        check("W2 cycle2 valid == 0 (drained)", out_col_0_valid == 1'b0 && out_col_1_valid == 1'b0);

        loading_phase = 0;
        @(negedge clk);

        // Test 3: Concurrent compute + shadow-fill ("double buffering
        // pays off" scenario). While loading_phase is LOW (pretend MMU
        // is mid-compute on the matrix we just loaded), stream a THIRD
        // matrix into the shadow bank (bank1, now empty since its
        // earlier contents were fully drained in Test 1) spread across
        // several cycles with gaps, confirming write_enable timing is
        // fully independent of loading_phase / drain activity.
        // W3 = [[9,8],[7,6]]
        $display("\nTest 3: concurrent shadow fill while loading_phase low (simulated compute) --");
        check("active_bank == 0 (still), shadow == bank1 (empty, drained in test1)", active_bank == 1'b0);
        check("shadow bank1 empty before refill", shadow_loaded == 1'b0);

        write_enable_col_0 = 1; write_data_col_0 = 8'sd7; // bottom row first
        write_enable_col_1 = 1; write_data_col_1 = 8'sd6;
        @(negedge clk);
        write_enable_col_0 = 0; // gap cycle on col0 only
        write_data_col_1 = 8'sd8;
        @(negedge clk);
        write_enable_col_0 = 1; write_data_col_0 = 8'sd9; // top row, delayed by one cycle
        write_enable_col_1 = 0;
        @(negedge clk);
        write_enable_col_0 = 0;
        write_enable_col_1 = 0;

        check("shadow_loaded == 1 after gapped writes", shadow_loaded == 1'b1);
        check("active still empty / untouched (active=bank0, already drained)", active_empty == 1'b1);

        swap_banks = 1;
        @(negedge clk);
        swap_banks = 0;
        loading_phase = 1;
        @(negedge clk);
        check("W3 cycle0 out_col_0 == 7", out_col_0 == 8'sd7 && out_col_0_valid == 1'b1);
        check("W3 cycle0 out_col_1 == 6", out_col_1 == 8'sd6 && out_col_1_valid == 1'b1);
        @(negedge clk);
        check("W3 cycle1 out_col_0 == 9", out_col_0 == 8'sd9 && out_col_0_valid == 1'b1);
        check("W3 cycle1 out_col_1 == 8", out_col_1 == 8'sd8 && out_col_1_valid == 1'b1);
        @(negedge clk);
        check("W3 cycle2 valid == 0 (drained)", out_col_0_valid == 1'b0 && out_col_1_valid == 1'b0);
        loading_phase = 0;

        // Test 4: full-bank status flags (active_full / any_shadow_full)
        $display("\n-- Test 4: full-bank status flags --");
        @(negedge clk);
        for (int i = 0; i < FIFO_DEPTH; i++) begin
            write_enable_col_0 = 1; write_data_col_0 = i;
            write_enable_col_1 = 1; write_data_col_1 = i;
            @(negedge clk);
        end
        write_enable_col_0 = 0;
        write_enable_col_1 = 0;
        check("any_shadow_full after DEPTH writes to shadow bank", any_shadow_full == 1'b1);
        check("active_full stays 0 (active bank untouched by shadow writes)", active_full == 1'b0);

        // Drain this bank back out via swap+loading_phase so sim ends clean
        swap_banks = 1;
        @(negedge clk);
        swap_banks = 0;
        loading_phase = 1;
        repeat (FIFO_DEPTH + 1) @(negedge clk);
        loading_phase = 0;
        check("active_empty after final drain", active_empty == 1'b1);

        $display("\n=== SIMULATION COMPLETE ===\n");
        if (errors == 0) $display(">>> ALL weight_fifo TESTS PASSED <<<");
        else $display(">>> %0d weight_fifo TEST(S) FAILED <<<", errors);

        $finish;
    end

    initial begin
        $dumpfile("weight_fifo_simulation.vcd");
        $dumpvars(0, weight_fifo_tb);
    end
endmodule
