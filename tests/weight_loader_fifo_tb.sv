`timescale 1ns / 1ps

// Integration testbench: weight_loader -> weight_fifo.
//
// Proves the loader satisfies the weight_fifo loading contract end-to-end:
// the loader fills the shadow bank from a ROM, the sequencer swaps banks,
// and draining under loading_phase yields the staggered bottom-row-first
// order the MMU expects (col0: w10 then w00; col1: w11 then w01). This is
// the integration that replaces the manual `load_weights` task currently
// hand-driven in tpu_core_tb.
module weight_loader_fifo_tb;
    localparam int WEIGHT_WIDTH   = 8;
    localparam int FIFO_DEPTH     = 4;
    localparam int ARRAY_ROWS     = 2;
    localparam int ARRAY_COLS     = 2;
    localparam int ROM_ADDR_WIDTH = 16;
    localparam int ROM_LATENCY    = 2;
    localparam int ROM_DEPTH      = 16;

    logic clk, reset;
    int errors = 0;

    // loader <-> fifo
    logic                           start_load;
    logic [ROM_ADDR_WIDTH-1:0]      tile_base_addr;
    logic                           load_done;
    logic                           wf_we_col_0, wf_we_col_1;
    logic signed [WEIGHT_WIDTH-1:0] wf_wd_col_0, wf_wd_col_1;

    // ROM
    logic [ROM_ADDR_WIDTH-1:0]      rom_addr_0, rom_addr_1;
    logic signed [WEIGHT_WIDTH-1:0] rom_data_0, rom_data_1;

    // fifo controls / outputs
    logic                           swap_banks, loading_phase;
    logic signed [WEIGHT_WIDTH-1:0] out_col_0, out_col_1;
    logic                           out_col_0_valid, out_col_1_valid;
    logic                           shadow_loaded, active_bank, active_empty;
    logic                           active_full, any_shadow_full;

    weight_loader #(
        .WEIGHT_WIDTH(WEIGHT_WIDTH), .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS), .ROM_ADDR_WIDTH(ROM_ADDR_WIDTH),
        .ROM_LATENCY(ROM_LATENCY)
    ) u_loader (
        .clk(clk), .reset(reset),
        .start_load(start_load), .tile_base_addr(tile_base_addr), .done(load_done),
        .rom_addr_0(rom_addr_0), .rom_addr_1(rom_addr_1),
        .rom_data_0(rom_data_0), .rom_data_1(rom_data_1),
        .wf_write_enable_col_0(wf_we_col_0), .wf_write_data_col_0(wf_wd_col_0),
        .wf_write_enable_col_1(wf_we_col_1), .wf_write_data_col_1(wf_wd_col_1)
    );

    weight_fifo #(.WEIGHT_WIDTH(WEIGHT_WIDTH), .FIFO_DEPTH(FIFO_DEPTH)) u_fifo (
        .clk(clk), .reset(reset),
        .write_enable_col_0(wf_we_col_0), .write_data_col_0(wf_wd_col_0),
        .write_enable_col_1(wf_we_col_1), .write_data_col_1(wf_wd_col_1),
        .swap_banks(swap_banks),
        .shadow_loaded(shadow_loaded), .active_bank(active_bank),
        .loading_phase(loading_phase),
        .out_col_0(out_col_0), .out_col_0_valid(out_col_0_valid),
        .out_col_1(out_col_1), .out_col_1_valid(out_col_1_valid),
        .active_empty(active_empty), .active_full(active_full),
        .any_shadow_full(any_shadow_full)
    );

    // Weight ROM model: fully-registered 2-cycle read.
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

    // Pulse start_load and block until the loader's done pulse.
    task automatic load_tile(input int base);
        int t;
        @(negedge clk);
        start_load = 1; tile_base_addr = base[ROM_ADDR_WIDTH-1:0];
        @(negedge clk);
        start_load = 0;
        t = 0;
        while (!load_done) begin
            @(negedge clk);
            t++;
            if (t > 100) begin $error("loader done timeout"); $finish; end
        end
    endtask

    initial begin
        clk = 0; reset = 1;
        start_load = 0; tile_base_addr = 0;
        swap_banks = 0; loading_phase = 0;
        for (int i = 0; i < ROM_DEPTH; i++) rom_mem[i] = '0;
        // W = [[4,5],[2,3]] @ base 0
        rom_mem[0] = 8'sd4; rom_mem[1] = 8'sd5;
        rom_mem[2] = 8'sd2; rom_mem[3] = 8'sd3;

        #12 reset = 0;
        @(negedge clk);

        $display("\nStarting weight_loader -> weight_fifo Integration Testbench\n");

        // 1. Loader fills the shadow bank from ROM.
        load_tile(0);
        check("shadow_loaded after ROM load", shadow_loaded == 1'b1);
        check("active bank still empty (writes went to shadow)", active_empty == 1'b1);

        // 2. Swap shadow -> active.
        swap_banks = 1;
        @(negedge clk);
        swap_banks = 0;
        check("active_bank == 1 after swap", active_bank == 1'b1);
        check("active not empty after swap", active_empty == 1'b0);

        // 3. Drain into the (would-be) MMU and confirm staggered order.
        loading_phase = 1;
        @(negedge clk);
        check("drain cyc0 col0 == 2 (w10)", out_col_0 == 8'sd2 && out_col_0_valid);
        check("drain cyc0 col1 == 3 (w11)", out_col_1 == 8'sd3 && out_col_1_valid);
        @(negedge clk);
        check("drain cyc1 col0 == 4 (w00)", out_col_0 == 8'sd4 && out_col_0_valid);
        check("drain cyc1 col1 == 5 (w01)", out_col_1 == 8'sd5 && out_col_1_valid);
        @(negedge clk);
        check("drain cyc2 col0 invalid (drained)", !out_col_0_valid);
        check("drain cyc2 col1 invalid (drained)", !out_col_1_valid);
        check("active_empty after full drain", active_empty == 1'b1);
        loading_phase = 0;

        $display("\n=== SIMULATION COMPLETE ===\n");
        if (errors == 0) $display(">>> ALL weight_loader_fifo TESTS PASSED <<<");
        else $display(">>> %0d weight_loader_fifo TEST(S) FAILED <<<", errors);

        $finish;
    end

    initial begin
        $dumpfile("weight_loader_fifo_simulation.vcd");
        $dumpvars(0, weight_loader_fifo_tb);
    end
endmodule
