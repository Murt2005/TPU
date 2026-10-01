`timescale 1ns / 1ps

// weight_fifo: output stream, timing and status flags for W = [[4,5],[2,3]] loaded bottom row first
module weight_fifo_tb;
    localparam int WEIGHT_WIDTH = 8;
    localparam int FIFO_DEPTH   = 4;

    logic clk;
    logic reset;

    logic [1:0]                          write_enable_col;
    logic signed [1:0][WEIGHT_WIDTH-1:0] write_data_col;

    logic swap_banks;
    logic shadow_loaded;
    logic active_bank;

    logic loading_phase;

    logic signed [1:0][WEIGHT_WIDTH-1:0] out_col;
    logic [1:0]                          out_col_valid;

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

    // expected (value, valid) per column, checked each cycle of loading_phase
    int exp_col0_val_q[$];
    int exp_col1_val_q[$];

    always @(posedge clk) begin
        if (!reset) begin
            if (exp_col0_val_q.size() > 0 || out_col_valid[0]) begin
                // only check during the active drive window; pop tracked externally in stimulus
            end
        end
    end

    initial begin
        clk = 0;
        reset = 1;
        write_enable_col[0] = 0; write_data_col[0] = 0;
        write_enable_col[1] = 0; write_data_col[1] = 0;
        swap_banks = 0;
        loading_phase = 0;

        #12 reset = 0;
        @(negedge clk);

        $display("\nStarting weight_fifo Testbench\n");

        // test 1: load bank 0, drain during loading_phase: stagger order and 1-cycle latency
        $display("Test 1: basic single-bank load + drain");
        check("active_bank == 0 after reset", active_bank == 1'b0);
        check("active_empty after reset", active_empty == 1'b1);

        write_enable_col[0] = 1; write_data_col[0] = 8'sd2;
        write_enable_col[1] = 1; write_data_col[1] = 8'sd3;
        @(negedge clk);
        write_data_col[0] = 8'sd4;
        write_data_col[1] = 8'sd5;
        @(negedge clk);
        write_enable_col[0] = 0; write_data_col[0] = 0;
        write_enable_col[1] = 0; write_data_col[1] = 0;

        check("shadow_loaded after 2 writes", shadow_loaded == 1'b1);
        check("active_empty still 1 (writes went to shadow bank1, not active bank0)", active_empty == 1'b1);

        // swap so bank1 (just loaded) becomes active
        swap_banks = 1;
        @(negedge clk);
        swap_banks = 0;
        check("active_bank == 1 after swap", active_bank == 1'b1);
        check("active_empty == 0 after swap (bank1 now active and has data)", active_empty == 1'b0);

        // drive loading_phase, observe drain order: expect (2, valid), (4, valid), then (0,invalid)
        loading_phase = 1;
        @(negedge clk);
        check("cycle0 out_col[0] == 2", out_col[0] == 8'sd2 && out_col_valid[0] == 1'b1);
        check("cycle0 out_col[1] == 3", out_col[1] == 8'sd3 && out_col_valid[1] == 1'b1);

        @(negedge clk);
        check("cycle1 out_col[0] == 4", out_col[0] == 8'sd4 && out_col_valid[0] == 1'b1);
        check("cycle1 out_col[1] == 5", out_col[1] == 8'sd5 && out_col_valid[1] == 1'b1);

        @(negedge clk);
        check("cycle2 out_col_valid[0] == 0 (fifo drained)", out_col_valid[0] == 1'b0);
        check("cycle2 out_col_valid[1] == 0 (fifo drained)", out_col_valid[1] == 1'b0);
        check("active_empty == 1 after full drain", active_empty == 1'b1);

        loading_phase = 0;
        @(negedge clk);

        // test 2: fill the shadow bank while loading_phase is low; the active bank is untouched
        $display("\nTest 2: shadow-bank write does not disturb active/drained bank");
        write_enable_col[0] = 1; write_data_col[0] = 8'sd1;
        write_enable_col[1] = 1; write_data_col[1] = 8'sd1;
        @(negedge clk);
        write_data_col[0] = 8'sd1;
        write_data_col[1] = 8'sd1;
        @(negedge clk);
        write_enable_col[0] = 0;
        write_enable_col[1] = 0;

        check("active_empty still 1 (active=bank1, drained; writes went to shadow bank0)", active_empty == 1'b1);
        check("shadow_loaded == 1 (bank0 now has 2 entries each col)", shadow_loaded == 1'b1);

        // swap to bank0 and drain, confirm correct values arrive in order
        swap_banks = 1;
        @(negedge clk);
        swap_banks = 0;
        check("active_bank == 0 after second swap", active_bank == 1'b0);

        loading_phase = 1;
        @(negedge clk);
        check("W2 cycle0 out_col[0] == 1", out_col[0] == 8'sd1 && out_col_valid[0] == 1'b1);
        check("W2 cycle0 out_col[1] == 1", out_col[1] == 8'sd1 && out_col_valid[1] == 1'b1);
        @(negedge clk);
        check("W2 cycle1 out_col[0] == 1", out_col[0] == 8'sd1 && out_col_valid[0] == 1'b1);
        check("W2 cycle1 out_col[1] == 1", out_col[1] == 8'sd1 && out_col_valid[1] == 1'b1);
        @(negedge clk);
        check("W2 cycle2 valid == 0 (drained)", out_col_valid[0] == 1'b0 && out_col_valid[1] == 1'b0);

        loading_phase = 0;
        @(negedge clk);

        // test 3: gapped shadow writes are independent of loading_phase
        $display("\nTest 3: concurrent shadow fill while loading_phase low (simulated compute) --");
        check("active_bank == 0 (still), shadow == bank1 (empty, drained in test1)", active_bank == 1'b0);
        check("shadow bank1 empty before refill", shadow_loaded == 1'b0);

        write_enable_col[0] = 1; write_data_col[0] = 8'sd7; // bottom row first
        write_enable_col[1] = 1; write_data_col[1] = 8'sd6;
        @(negedge clk);
        write_enable_col[0] = 0; // gap cycle on col0 only
        write_data_col[1] = 8'sd8;
        @(negedge clk);
        write_enable_col[0] = 1; write_data_col[0] = 8'sd9; // top row, delayed by one cycle
        write_enable_col[1] = 0;
        @(negedge clk);
        write_enable_col[0] = 0;
        write_enable_col[1] = 0;

        check("shadow_loaded == 1 after gapped writes", shadow_loaded == 1'b1);
        check("active still empty / untouched (active=bank0, already drained)", active_empty == 1'b1);

        swap_banks = 1;
        @(negedge clk);
        swap_banks = 0;
        loading_phase = 1;
        @(negedge clk);
        check("W3 cycle0 out_col[0] == 7", out_col[0] == 8'sd7 && out_col_valid[0] == 1'b1);
        check("W3 cycle0 out_col[1] == 6", out_col[1] == 8'sd6 && out_col_valid[1] == 1'b1);
        @(negedge clk);
        check("W3 cycle1 out_col[0] == 9", out_col[0] == 8'sd9 && out_col_valid[0] == 1'b1);
        check("W3 cycle1 out_col[1] == 8", out_col[1] == 8'sd8 && out_col_valid[1] == 1'b1);
        @(negedge clk);
        check("W3 cycle2 valid == 0 (drained)", out_col_valid[0] == 1'b0 && out_col_valid[1] == 1'b0);
        loading_phase = 0;

        // test 4: full-bank status flags (active_full / any_shadow_full)
        $display("\n-- Test 4: full-bank status flags --");
        @(negedge clk);
        for (int i = 0; i < FIFO_DEPTH; i++) begin
            write_enable_col[0] = 1; write_data_col[0] = i;
            write_enable_col[1] = 1; write_data_col[1] = i;
            @(negedge clk);
        end
        write_enable_col[0] = 0;
        write_enable_col[1] = 0;
        check("any_shadow_full after DEPTH writes to shadow bank", any_shadow_full == 1'b1);
        check("active_full stays 0 (active bank untouched by shadow writes)", active_full == 1'b0);

        // drain this bank back out via swap+loading_phase so sim ends clean
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
