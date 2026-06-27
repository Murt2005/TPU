`timescale 1ns / 1ps

// weight_loader
// -------------
// Reads one weight tile out of an on-chip weight ROM (an M10K array that
// tpu_top initializes via $readmemh from a PyTorch-exported .mem file) and
// pushes it into the weight_fifo's shadow-bank write port in the
// bottom-row-first order that the staggered weight-load contract requires.
//
// Datapath role:
//   weight ROM (M10K, $readmemh)
//        | rom_addr_0 / rom_addr_1   (two read ports -> one full row/cycle)
//        v rom_data_0 / rom_data_1
//   weight_loader (this module)
//        | wf_write_enable_col_*, wf_write_data_col_*
//        v
//   weight_fifo (shadow bank) --swap--> MMU weight columns (loading_phase)
//
// ----------------------------------------------------------------------
// ROM organization (flat, row-major -- unchanged from the PyTorch export):
//   address = tile_base_addr + row*ARRAY_COLS + col
//   For a 2x2 tile W = [[w00,w01],[w10,w11]] at base B:
//     B+0 -> w00   B+1 -> w01   B+2 -> w10   B+3 -> w11
//
// To read a whole row (both columns) in a single cycle we present two
// adjacent read addresses simultaneously (col 0 = row_base, col 1 =
// row_base+1) into a simple dual-port ROM. Quartus infers a 2-read-port
// M10K from this. This is what lets us drive weight_fifo's col_0 and col_1
// write ports together, one element per column per cycle, exactly as the
// FIFO expects.
//
// ----------------------------------------------------------------------
// Loading order: weight_fifo requires each column FIFO be filled
// BOTTOM-ROW-FIRST (row ARRAY_ROWS-1 down to row 0), because a weight
// presented at the top of the MMU propagates down one PE per cycle, so the
// last-presented (top) row must be the last one enqueued. We therefore walk
// row_idx from ARRAY_ROWS-1 down to 0.
//
// ----------------------------------------------------------------------
// ROM read latency: a fully-registered M10K read has ROM_LATENCY=2 (one
// register on the address, one on the data). The FSM holds a row's address
// stable and waits ROM_LATENCY cycles before sampling rom_data, so the same
// RTL is correct whether the ROM model is combinational (0), output-
// registered (1), or fully registered (2). The unit testbench models the
// ROM with the same ROM_LATENCY so simulation timing matches synthesis.
//
// ----------------------------------------------------------------------
// Handshake: pulse start_load for one cycle with tile_base_addr valid. The
// loader ignores start_load unless it is IDLE. When the final weight write
// has committed into the FIFO, `done` pulses high for exactly one cycle --
// one cycle AFTER the last write_enable. The owning sequencer (tpu_top)
// should wait for `done` and then pulse weight_fifo.swap_banks on a LATER
// cycle, never on the same edge as the final write.
//
// NOTE: ARRAY_COLS is used only as the ROM row stride and for documentation;
// the write/read ports are physically 2-wide to match the current 2-column
// weight_fifo. Going past 2 columns means widening both this module's ports
// and weight_fifo together.
module weight_loader #(
    parameter int WEIGHT_WIDTH   = 8,
    parameter int ARRAY_ROWS     = 2,
    parameter int ARRAY_COLS     = 2,   // ROM row stride; ports fixed at 2 cols
    parameter int ROM_ADDR_WIDTH = 16,
    parameter int ROM_LATENCY    = 2    // M10K registered read latency (cycles)
) (
    input  logic clk,
    input  logic reset,

    // --- FSM control ---
    input  logic                       start_load,
    input  logic [ROM_ADDR_WIDTH-1:0]  tile_base_addr, // ROM addr of weight[0][0] for this tile
    output logic                       done,           // 1-cycle pulse, one cycle after last write

    // --- Weight ROM read ports (simple dual-port, ROM_LATENCY-cycle read) ---
    output logic [ROM_ADDR_WIDTH-1:0]      rom_addr_0,
    output logic [ROM_ADDR_WIDTH-1:0]      rom_addr_1,
    input  logic signed [WEIGHT_WIDTH-1:0] rom_data_0,
    input  logic signed [WEIGHT_WIDTH-1:0] rom_data_1,

    // --- weight_fifo shadow-bank write port ---
    output logic                           wf_write_enable_col_0,
    output logic signed [WEIGHT_WIDTH-1:0] wf_write_data_col_0,
    output logic                           wf_write_enable_col_1,
    output logic signed [WEIGHT_WIDTH-1:0] wf_write_data_col_1
);

    // Counter widths sized with +1/+2 margin so $clog2 never lands on a
    // power-of-2 boundary (or returns 0 for trivial parameters).
    localparam int ROW_IDX_W = $clog2(ARRAY_ROWS + 1);
    localparam int CNT_W     = $clog2(ROM_LATENCY + 2);

    // FSM states
    localparam logic [1:0] S_IDLE   = 2'd0;
    localparam logic [1:0] S_READ   = 2'd1;
    localparam logic [1:0] S_FINISH = 2'd2;

    logic [1:0]                 state;
    logic [ROW_IDX_W-1:0]       row_idx;     // current weight row (ARRAY_ROWS-1 .. 0)
    logic [CNT_W-1:0]           cnt;         // cycles the current row's address has been presented
    logic [ROM_ADDR_WIDTH-1:0]  base_addr;   // latched tile_base_addr

    // Data is valid to sample exactly ROM_LATENCY cycles after the address
    // was first presented for this row.
    logic data_ready;
    assign data_ready = (state == S_READ) && (cnt == ROM_LATENCY[CNT_W-1:0]);

    // --- Combinational outputs ---
    logic [ROM_ADDR_WIDTH-1:0] row_base;
    always_comb begin
        // Defaults
        row_base              = '0;
        rom_addr_0            = '0;
        rom_addr_1            = '0;
        wf_write_enable_col_0 = 1'b0;
        wf_write_enable_col_1 = 1'b0;
        wf_write_data_col_0   = '0;
        wf_write_data_col_1   = '0;
        done                  = 1'b0;

        case (state)
            S_READ: begin
                // Address of the current row's two columns (held stable
                // across the whole ROM_LATENCY wait window).
                row_base   = base_addr + ROM_ADDR_WIDTH'(row_idx) * ROM_ADDR_WIDTH'(ARRAY_COLS);
                rom_addr_0 = row_base;
                rom_addr_1 = row_base + ROM_ADDR_WIDTH'(1);

                // Push both columns the cycle the ROM data is valid.
                if (data_ready) begin
                    wf_write_enable_col_0 = 1'b1;
                    wf_write_enable_col_1 = 1'b1;
                    wf_write_data_col_0   = rom_data_0;
                    wf_write_data_col_1   = rom_data_1;
                end
            end
            S_FINISH: done = 1'b1;
            default: ; // S_IDLE: all defaults
        endcase
    end

    // --- Sequential state ---
    always_ff @(posedge clk) begin
        if (reset) begin
            state     <= S_IDLE;
            row_idx   <= '0;
            cnt       <= '0;
            base_addr <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (start_load) begin
                        base_addr <= tile_base_addr;
                        row_idx   <= ROW_IDX_W'(ARRAY_ROWS - 1);
                        cnt       <= '0;
                        state     <= S_READ;
                    end
                end

                S_READ: begin
                    if (data_ready) begin
                        // This cycle's push commits at this edge.
                        if (row_idx == '0) begin
                            state <= S_FINISH;
                        end else begin
                            row_idx <= row_idx - 1'b1;
                            cnt     <= '0;       // restart latency wait for next row
                        end
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                S_FINISH: begin
                    state <= S_IDLE;             // done pulsed for exactly this one cycle
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
