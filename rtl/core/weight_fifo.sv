`timescale 1ns / 1ps

// weight_fifo
// ------------
// Feeds stationary weights into all NUM_COLS MMU columns during
// loading_phase, and lets off-chip memory (DMA/host) stream the NEXT
// weight matrix in while the MMU is busy computing on the CURRENT one
// (double buffering / ping-pong).
//
// Single responsibility: this module only knows how to (a) accept
// off-chip weight writes into whichever bank is currently "shadow", and
// (b) during loading_phase, drain the "active" bank's NUM_COLS column
// FIFOs one element per cycle, presenting them on the out_col[] array
// with valid tags.
//
// Columns are a generate-block array (out_col[NUM_COLS], out_col_valid
// [NUM_COLS], write_enable_col[NUM_COLS], write_data_col[NUM_COLS])
// rather than individually-named ports, so scaling the MMU's column
// count is a parameter change here, not a port-list rewrite.
//
// Built on top of the generic `fifo` module (2*NUM_COLS instances:
// NUM_COLS columns x 2 banks). All control is composed around that
// primitive rather than reimplementing queue logic here.
//
// ----------------------------------------------------------------------
// Staggered loading contract (matches pe.sv / mmu.sv exactly):
//   The MMU's PE columns are arranged so that a weight written to
//   in_col_N on cycle T is captured by the TOP row PE that same cycle
//   (if capture asserted), and propagates down to the BOTTOM row PE's
//   in_weight on cycle T+1. To stationary-load a 2x2 weight matrix
//   W = [[w00, w01], [w10, w11]] correctly, the bottom-row weights
//   (w10, w11) must be presented FIRST, followed by the top-row weights
//   (w00, w01) on the very next cycle. This module therefore expects
//   the off-chip loader to enqueue weights into each column FIFO in
//   that order (bottom row first, then top row, ... up the array for
//   larger N).
//
// ----------------------------------------------------------------------
// out_col_valid[N] doubles as the MMU's capture_weight_col_N signal:
// capture should be asserted for exactly the cycles real weight data is
// being presented, which is precisely "loading_phase AND bank has data."
// Driving capture_weight_col_N directly from out_col_valid[N] keeps that
// invariant correct automatically and removes a class of bugs where a
// hand-built sequencer's capture pulse drifts out of sync with the FIFO
// drain (e.g. capturing a stale/garbage beat once the FIFO runs dry
// mid-load due to an under-filled matrix).
//
// ----------------------------------------------------------------------
// Double buffering:
//   Two banks (0 and 1), each bank = {col0 fifo, col1 fifo}. Exactly one
//   bank is "active" (drains into the MMU) at a time; the other is
//   "shadow" (accepts off-chip writes). `active_bank` is a single
//   register. The off-chip write port ALWAYS targets the shadow bank,
//   so DMA can stream weights for the NEXT matrix while the MMU is
//   still draining/computing on the current one -- no structural
//   hazard, since reads (active bank) and writes (shadow bank) are
//   always different physical FIFO instances.
//
//   `swap_banks` flips active_bank. The owning sequencer is expected to
//   pulse swap_banks once: (a) the shadow bank has been fully loaded
//   (shadow_loaded == 1), and (b) the MMU is idle / about to enter
//   loading_phase for the new matrix. This module does not auto-swap on
//   its own -- timing of "when to cut over" is a system-level decision
//   (e.g. don't swap mid-compute-drain), so it's left to the sequencer.
module weight_fifo #(
    parameter int WEIGHT_WIDTH = 8,
    parameter int FIFO_DEPTH   = 4,  // must be a power of 2, >= array dimension (N)
    parameter int NUM_COLS     = 2
) (
    input  logic clk,
    input  logic reset,

    input  logic                                          [NUM_COLS-1:0] write_enable_col,
    input  logic signed [NUM_COLS-1:0][WEIGHT_WIDTH-1:0]                 write_data_col,

    input  logic         swap_banks,

    // Convenience status: is the CURRENT shadow bank fully loaded
    // (all column fifos non-empty would be a weak check across
    // arbitrary N; instead this just reports "every shadow fifo is
    // non-empty", giving the sequencer a hook to gate swap_banks on
    // having pushed at least one full column's worth of weights).
    output logic          shadow_loaded,
    output logic          active_bank,     // 0 or 1, for visibility/debug

    input  logic loading_phase,

    output logic signed [NUM_COLS-1:0][WEIGHT_WIDTH-1:0] out_col,
    output logic                      [NUM_COLS-1:0]      out_col_valid,

    output logic active_empty,
    output logic active_full,
    output logic any_shadow_full  // either shadow-bank fifo full (back-pressure to DMA writer)
);

    logic active_bank_q;

    always_ff @(posedge clk) begin
        if (reset) begin
            active_bank_q <= 1'b0;
        end else if (swap_banks) begin
            active_bank_q <= ~active_bank_q;
        end
    end

    assign active_bank = active_bank_q;

    logic shadow_bank_q;
    assign shadow_bank_q = ~active_bank_q;

    logic                           bank_write_enable [2][NUM_COLS]; // [bank][col]
    logic signed [WEIGHT_WIDTH-1:0] bank_write_data   [2][NUM_COLS];
    logic                           bank_read_enable  [2][NUM_COLS];
    logic signed [WEIGHT_WIDTH-1:0] bank_read_data    [2][NUM_COLS];
    logic                           bank_full         [2][NUM_COLS];
    logic                           bank_empty        [2][NUM_COLS];

    genvar b, c;
    generate
        for (b = 0; b < 2; b++) begin : gen_bank
            for (c = 0; c < NUM_COLS; c++) begin : gen_col
                fifo #(
                    .WIDTH(WEIGHT_WIDTH),
                    .DEPTH(FIFO_DEPTH)
                ) u_fifo (
                    .clk          (clk),
                    .reset        (reset),
                    .write_enable (bank_write_enable[b][c]),
                    .write_data   (bank_write_data[b][c]),
                    .read_enable  (bank_read_enable[b][c]),
                    .read_data    (bank_read_data[b][c]),
                    .full         (bank_full[b][c]),
                    .empty        (bank_empty[b][c])
                );
            end
        end
    endgenerate

    always_comb begin
        for (int bi = 0; bi < 2; bi++) begin
            for (int ci = 0; ci < NUM_COLS; ci++) begin
                bank_write_enable[bi][ci] = 1'b0;
                bank_write_data[bi][ci]   = '0;
            end
        end
        for (int ci = 0; ci < NUM_COLS; ci++) begin
            bank_write_enable[shadow_bank_q][ci] = write_enable_col[ci];
            bank_write_data[shadow_bank_q][ci]   = write_data_col[ci];
        end
    end

    // MMU-facing drain port routing: always targets the active bank.
    // Pop (read_enable) exactly when loading_phase is high and that
    // column's active fifo is non-empty -- this single condition is
    // reused as both "pop this entry" and "this is a valid weight beat
    // for the MMU to capture," per the design note above.
    logic [NUM_COLS-1:0] pop_col;

    always_comb begin
        for (int ci = 0; ci < NUM_COLS; ci++) begin
            pop_col[ci] = loading_phase && !bank_empty[active_bank_q][ci];
        end
    end

    always_comb begin
        for (int bi = 0; bi < 2; bi++) begin
            for (int ci = 0; ci < NUM_COLS; ci++) begin
                bank_read_enable[bi][ci] = 1'b0;
            end
        end
        for (int ci = 0; ci < NUM_COLS; ci++) begin
            bank_read_enable[active_bank_q][ci] = pop_col[ci];
        end
    end

    // Registered outputs to the MMU (FIFO read_data is already a
    // registered/combinational lookup of the head element; we register
    // the *presented* value + valid here for a clean, glitch-free
    // single-cycle-latency interface matching how in_col_0/in_col_1
    // are driven in the existing mmu_tb stimulus -- value+valid change
    // together, synchronously, on the same edge the pop happens).
    always_ff @(posedge clk) begin
        if (reset) begin
            for (int ci = 0; ci < NUM_COLS; ci++) begin
                out_col[ci]       <= '0;
                out_col_valid[ci] <= 1'b0;
            end
        end else begin
            for (int ci = 0; ci < NUM_COLS; ci++) begin
                out_col[ci]       <= pop_col[ci] ? bank_read_data[active_bank_q][ci] : '0;
                out_col_valid[ci] <= pop_col[ci];
            end
        end
    end

    always_comb begin
        active_empty    = 1'b1;
        active_full     = 1'b0;
        any_shadow_full = 1'b0;
        shadow_loaded   = 1'b1;
        for (int ci = 0; ci < NUM_COLS; ci++) begin
            active_empty    &= bank_empty[active_bank_q][ci];
            active_full     |= bank_full[active_bank_q][ci];
            any_shadow_full |= bank_full[shadow_bank_q][ci];
            shadow_loaded   &= !bank_empty[shadow_bank_q][ci];
        end
    end

endmodule
