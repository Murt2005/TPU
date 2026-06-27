`timescale 1ns / 1ps

// Unit testbench for weight_loader.
//
// Models the weight ROM with a fully-registered 2-cycle read (the M10K
// contract) so simulation timing matches synthesis. Checks that the loader:
//   1. Reads a tile out of the ROM and presents it on the weight_fifo write
//      port BOTTOM-ROW-FIRST (col0: w10 then w00; col1: w11 then w01).
//   2. Pulses `done` exactly once, after the final write.
//   3. Handles a second, differently-based tile load back-to-back.
module weight_loader_tb;
    localparam int WEIGHT_WIDTH   = 8;
    localparam int ARRAY_ROWS     = 2;
    localparam int ARRAY_COLS     = 2;
    localparam int ROM_ADDR_WIDTH = 16;
    localparam int ROM_LATENCY    = 2;
    localparam int ROM_DEPTH      = 16;

    logic clk;
    logic reset;

    logic                       start_load;
    logic [ROM_ADDR_WIDTH-1:0]  tile_base_addr;
    logic                       done;

    logic [ROM_ADDR_WIDTH-1:0]      rom_addr_0, rom_addr_1;
    logic signed [WEIGHT_WIDTH-1:0] rom_data_0, rom_data_1;

    logic                           wf_we_col_0, wf_we_col_1;
    logic signed [WEIGHT_WIDTH-1:0] wf_wd_col_0, wf_wd_col_1;

    int errors = 0;

    weight_loader #(
        .WEIGHT_WIDTH(WEIGHT_WIDTH), .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS), .ROM_ADDR_WIDTH(ROM_ADDR_WIDTH),
        .ROM_LATENCY(ROM_LATENCY)
    ) uut (
        .clk(clk), .reset(reset),
        .start_load(start_load), .tile_base_addr(tile_base_addr), .done(done),
        .rom_addr_0(rom_addr_0), .rom_addr_1(rom_addr_1),
        .rom_data_0(rom_data_0), .rom_data_1(rom_data_1),
        .wf_write_enable_col_0(wf_we_col_0), .wf_write_data_col_0(wf_wd_col_0),
        .wf_write_enable_col_1(wf_we_col_1), .wf_write_data_col_1(wf_wd_col_1)
    );

    // ---- Weight ROM model: fully-registered 2-cycle read (M10K) ----
    logic signed [WEIGHT_WIDTH-1:0] rom_mem [ROM_DEPTH];
    logic [ROM_ADDR_WIDTH-1:0]      raddr0_q, raddr1_q;
    always_ff @(posedge clk) begin
        raddr0_q   <= rom_addr_0;
        rom_data_0 <= rom_mem[raddr0_q];
        raddr1_q   <= rom_addr_1;
        rom_data_1 <= rom_mem[raddr1_q];
    end

    always #5 clk = ~clk;

    task automatic check(string name, logic cond);
        if (!cond) begin
            $error("[FAIL] %s at time %0t", name, $time);
            errors++;
        end else begin
            $display("[PASS] %s", name);
        end
    endtask

    // ---- Write-port monitor: collect pushed values per column ----
    int got_col0 [$];
    int got_col1 [$];
    int done_pulses;

    always @(negedge clk) begin
        if (!reset) begin
            if (wf_we_col_0) got_col0.push_back(wf_wd_col_0);
            if (wf_we_col_1) got_col1.push_back(wf_wd_col_1);
            if (done)        done_pulses++;
        end
    end

    // Run one tile load and verify the captured push streams.
    task automatic run_and_check(input int base,
                                 input int exp_c0_0, input int exp_c0_1,
                                 input int exp_c1_0, input int exp_c1_1,
                                 input string label);
        got_col0.delete();
        got_col1.delete();
        done_pulses = 0;

        @(negedge clk);
        start_load = 1; tile_base_addr = base[ROM_ADDR_WIDTH-1:0];
        @(negedge clk);
        start_load = 0;

        // Deterministic latency: ARRAY_ROWS*(ROM_LATENCY+1) + done + margin.
        repeat (ARRAY_ROWS * (ROM_LATENCY + 1) + 4) @(negedge clk);

        check({label, ": exactly 2 col0 pushes"}, got_col0.size() == 2);
        check({label, ": exactly 2 col1 pushes"}, got_col1.size() == 2);
        check({label, ": col0 bottom-first value"}, got_col0[0] == exp_c0_0);
        check({label, ": col0 top value"},          got_col0[1] == exp_c0_1);
        check({label, ": col1 bottom-first value"}, got_col1[0] == exp_c1_0);
        check({label, ": col1 top value"},          got_col1[1] == exp_c1_1);
        check({label, ": done pulsed exactly once"}, done_pulses == 1);
    endtask

    initial begin
        clk = 0; reset = 1;
        start_load = 0; tile_base_addr = 0;
        for (int i = 0; i < ROM_DEPTH; i++) rom_mem[i] = '0;

        // Tile 1 @ base 0: W=[[4,5],[2,3]] -> addr 0:4 1:5 2:2 3:3
        rom_mem[0] = 8'sd4; rom_mem[1] = 8'sd5;
        rom_mem[2] = 8'sd2; rom_mem[3] = 8'sd3;
        // Tile 2 @ base 4: W=[[1,2],[3,4]] -> addr 4:1 5:2 6:3 7:4
        rom_mem[4] = 8'sd1; rom_mem[5] = 8'sd2;
        rom_mem[6] = 8'sd3; rom_mem[7] = 8'sd4;

        #12 reset = 0;
        @(negedge clk);

        $display("\nStarting weight_loader Testbench\n");

        // Tile 1: bottom row (w10=2,w11=3) first, then top row (w00=4,w01=5)
        $display("Test 1: load tile @ base 0  W=[[4,5],[2,3]]");
        run_and_check(0, 2, 4, 3, 5, "T1");

        // Tile 2: bottom row (w10=3,w11=4) first, then top row (w00=1,w01=2)
        $display("\nTest 2: back-to-back load tile @ base 4  W=[[1,2],[3,4]]");
        run_and_check(4, 3, 1, 4, 2, "T2");

        // start_load ignored while idle-gating: a second pulse with no
        // intervening work should still produce exactly one clean load.
        $display("\nTest 3: re-load tile @ base 0 again (idle re-trigger)");
        run_and_check(0, 2, 4, 3, 5, "T3");

        $display("\n=== SIMULATION COMPLETE ===\n");
        if (errors == 0) $display(">>> ALL weight_loader TESTS PASSED <<<");
        else $display(">>> %0d weight_loader TEST(S) FAILED <<<", errors);

        $finish;
    end

    initial begin
        $dumpfile("weight_loader_simulation.vcd");
        $dumpvars(0, weight_loader_tb);
    end
endmodule
