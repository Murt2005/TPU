`timescale 1ns / 1ps

// tpu_sequencer — UART command decoder + TPU pipeline orchestrator.
//
// Sits between the uart_rx/uart_tx pair and the existing tpu_core datapath.
//
//  Protocol (8-N-1, host-initiates everything)
//
//  Host → FPGA packet:
//    [0]  CMD   byte
//    [1]  LEN   byte  (number of payload bytes that follow)
//    [2…] payload[LEN]
//
//  FPGA → Host response (sent after CMD is fully executed):
//    [0]  STATUS  0xAA = OK, 0xFF = unknown CMD / framing error
//    [1]  LEN     number of response payload bytes
//    [2…] payload[LEN]
//
//  Command table (byte counts below are for the generic ARRAY_ROWS x NUM_COLS
//  array with M_TILE activation rows; the historical 2x2 values in parens)
//
//  0x01  LOAD_WEIGHTS  LEN=ARRAY_ROWS*NUM_COLS (4)
//                             payload: weight rows BOTTOM-FIRST, each row
//                             NUM_COLS bytes (int8, signed) — i.e. for 2x2:
//                             [w10, w11, w00, w01]. The bottom-first wire
//                             order matches the order the sequencer presents
//                             rows to the weight_fifo (see the staggered
//                             loading contract in weight_fifo.sv).
//
//  0x02  LOAD_BIAS     LEN=2*NUM_COLS (4)
//                             payload: NUM_COLS int16 LE values:
//                             [b0_lo, b0_hi, b1_lo, b1_hi, ...]
//
//  0x03  LOAD_ACT      LEN=M_TILE*ARRAY_ROWS (4)
//                             payload: activation rows in natural row-major
//                             order, each row ARRAY_ROWS bytes (int8, signed)
//                             — i.e. for 2x2: [a00, a01, a10, a11]
//
//  0x04  RUN           LEN=0  orchestrates the full pipeline; blocks until
//                             all M_TILE output rows are collected, then sends:
//                             STATUS=0xAA, LEN=2*M_TILE*NUM_COLS (8),
//                             row-major int16 LE results:
//                             [r0c0_lo, r0c0_hi, r0c1_lo, r0c1_hi, ...]
//                      LEN=1  payload: [flags]  -- K-tiling variant:
//                             flags[0] = TILE_FIRST (1 = overwrite the
//                               accumulator's running sum with this pass;
//                               0 = add to it, continuing a K-reduction
//                               started by an earlier RUN)
//                             flags[1] = TILE_LAST (1 = forward the
//                               now-final running sum through bias/ReLU and
//                               return the usual result bytes; 0 = update
//                               the running sum only -- bias/activation
//                               never fire, response is STATUS=0xAA, LEN=0)
//                             LEN=0 is equivalent to flags=TILE_FIRST|TILE_LAST
//                             (single-shot behavior, unchanged for existing
//                             hosts that never send the byte).
//                             See rtl/accumulator.sv for the accumulation
//                             semantics this threads into.
//
//  0x05  RESET         LEN=0  pulses internal reset for 4 cycles; responds OK
//
//  0xFF  NOP            (no LEN byte) ignored in S_IDLE, no response — the
//                             SPI host interface's read-poll filler byte
//                             (see CMD_NOP's comment below and spi_slave.sv)
//
//  0x07  STREAM_RUN    LEN=2+K_TILES*(ARRAY_ROWS*NUM_COLS+M_TILE*ARRAY_ROWS)
//                             payload: [flags, K_TILES,
//                                       tile_0: weight bytes (natural
//                                         row-major, like RUN_TILE),
//                                               act bytes (row-major),
//                                       tile_1: ..., ...]
//                             A whole K-run in one frame: the sequencer
//                             deserializes each tile straight into the
//                             register file as its bytes arrive (no
//                             whole-frame buffering) and runs the full
//                             pipeline pass between tiles, accumulating in
//                             the datapath. flags[0]=TILE_FIRST applies to
//                             this frame's FIRST tile, flags[1]=TILE_LAST to
//                             its LAST tile, so a K-run longer than one
//                             frame's 255-byte LEN budget (max K_TILES =
//                             (255-2)/(tile bytes), 31 at 2x2) spans several
//                             STREAM_RUN frames: first=1,last=0 / 0,0 / ...
//                             / 0,last=1. (This flags byte is the one
//                             deviation from docs/SEQUENCER_REDESIGN.md
//                             §3.2's payload sketch — required because MNIST
//                             layer 1's K=144 means 72 K-tiles per output
//                             block, over the single-frame cap.)
//                             Response: on a TILE_LAST frame, STATUS=0xAA +
//                             the usual result bytes; otherwise a bare
//                             STATUS_OK/LEN=0 ACK. K_TILES=0 or a LEN that
//                             doesn't equal 2+K_TILES*(tile bytes) answers
//                             STATUS_ERR immediately.
//                             TIMING ASSUMPTION: between tiles the sequencer
//                             spends one pipeline pass (~25-35 cycles) not
//                             consuming rx bytes; this is safe because one
//                             UART byte takes 10*CLK_FREQ/BAUD_RATE cycles
//                             (~1042 at 12 MHz / 115200) — orders of
//                             magnitude longer. Any CLK_FREQ/BAUD pairing
//                             must keep byte time above pass latency.
//
//  0x06  RUN_TILE      LEN=1+ARRAY_ROWS*NUM_COLS+M_TILE*ARRAY_ROWS (9)
//                             payload: [flags,
//                                       weight bytes (ARRAY_ROWS*NUM_COLS,
//                                         NATURAL row-major, top row first —
//                                         unlike LOAD_WEIGHTS's bottom-first
//                                         legacy order; the sequencer does the
//                                         bottom-first reorder internally),
//                                       act bytes (M_TILE*ARRAY_ROWS,
//                                         row-major)]
//                             flags[0]=TILE_FIRST, flags[1]=TILE_LAST — same
//                             semantics as RUN's LEN=1 variant. Folds
//                             LOAD_WEIGHTS+LOAD_ACT+RUN into one frame: one
//                             round trip per K-tile instead of three
//                             (docs/SEQUENCER_REDESIGN.md §3.1). Response is
//                             identical to RUN's (result bytes if TILE_LAST,
//                             else a bare STATUS_OK/LEN=0 ACK). Does not
//                             touch reg_bias — LOAD_BIAS stays a separate,
//                             once-per-output-block command.
//
//  Pipeline orchestration for RUN (counter-driven; the 2x2 special case
//  matches the task sequencing in tpu_core_tb.sv cycle-for-cycle)
//
//   1. S_WR_UB   : write act row m → unified_buffer, m = 0 .. M_TILE-1
//   2. S_LD_WF   : write weight row (ARRAY_ROWS-1-i) → weight_fifo shadow
//                  bank, i = 0 .. ARRAY_ROWS-1 (bottom row FIRST — row index
//                  counts down while the loop counter counts up; getting this
//                  direction wrong silently transposes every weight matrix)
//   3. S_LD_WF_GAP: one idle cycle after WF writes
//   4. S_SWAP    : swap_banks = 1 for 1 cycle
//   5. S_LOADING : loading_phase = 1 for ARRAY_ROWS+1 cycles (drains the
//                  ARRAY_ROWS-row weight FIFO + 1 guard cycle)
//   6. S_STREAM  : ub_read_en, addr = 0 .. M_TILE-1 (rows → SDS → MMU)
//   7. S_WAIT    : wait for final_row_valid × M_TILE (or accum_pass_done for
//                  a mid-K-reduction pass), timeout-guarded
//   8. Pack and transmit the result via UART TX
//
//  Timing notes
//
//  All internal control signals follow the one-cycle registered latency
//  convention used throughout the rest of the RTL (pe.sv, accumulator.sv …).
//
//  Parameters
//
//  ARRAY_ROWS   — systolic rows = K-tile depth (weight rows; also the width
//                 of one activation row streamed into the array)
//  NUM_COLS     — systolic columns = N-tile width (weight columns)
//  M_TILE       — unified_buffer address depth = activation rows streamed per
//                 RUN. Defaults to ARRAY_ROWS (the historical square case).
//                 Must equal unified_buffer's ROWS and accumulator's
//                 rows-per-pass parameter.
//  WAIT_TIMEOUT — max cycles to wait in S_WAIT before flagging an error.
//                 Default 200 is very conservative; the real latency is
//                 ~15 cycles from stream_activations start at 2x2.

module tpu_sequencer #(
    parameter int ARRAY_ROWS   = 2,
    parameter int NUM_COLS     = 2,
    parameter int M_TILE       = ARRAY_ROWS,
    parameter int WAIT_TIMEOUT = 200,
    // Derived; do not override. Address width of the unified_buffer
    // host-write / UB-read ports (matches unified_buffer's
    // ADDR_WIDTH = $clog2(ROWS) with ROWS = M_TILE).
    parameter int UB_ADDR_W    = (M_TILE > 1) ? $clog2(M_TILE) : 1
) (
    input  logic clk,
    input  logic reset,

    input  logic [7:0] rx_data,
    input  logic       rx_valid,
    // uart_rx framing-error flag (level: latched on a bad stop bit, cleared
    // by the next good byte). A rising edge while receiving a frame aborts
    // it with an explicit STATUS_ERR instead of a silent drop + WAIT_TIMEOUT
    // on the host side (docs/SEQUENCER_REDESIGN.md §3.3 / sequencer_uart_design §5.7).
    input  logic       rx_error,

    output logic [7:0] tx_data,
    output logic       tx_valid,
    input  logic       tx_busy,

    // weight_fifo (one write enable/data lane per column, array-port style)
    output logic        [NUM_COLS-1:0]      write_enable_col,
    output logic signed [NUM_COLS-1:0][7:0] write_data_col,
    output logic                            swap_banks,
    output logic                            loading_phase,

    // unified_buffer host-write port
    output logic        [UB_ADDR_W-1:0]        host_write_addr,
    output logic signed [ARRAY_ROWS-1:0][7:0]  host_write_data,
    output logic                               host_write_valid,

    // unified_buffer UB-read port
    output logic        [UB_ADDR_W-1:0]        ub_read_addr,
    output logic                               ub_read_en,

    output logic signed [NUM_COLS-1:0][15:0]   out_bias,

    // K-tiling control -- see CMD_RUN above and rtl/accumulator.sv. Held
    // stable for the full RUN orchestration sequence.
    output logic               tile_first,
    output logic               tile_last,
    input  logic               accum_pass_done,

    input  logic signed [NUM_COLS-1:0][15:0] final_row_out,
    input  logic               final_row_valid,

    output logic               tpu_reset,

    output logic               busy          // high while processing a command
);

    // Command opcodes (CMD_*), the NOP filler byte, and STATUS_OK/STATUS_ERR
    // are the host<->FPGA wire-protocol contract; they live in tpu_pkg so the
    // one table is shared (and mirrored by tpu_host.py). See rtl/tpu_pkg.sv.
    import tpu_pkg::*;

    localparam int TIMEOUT_W = $clog2(WAIT_TIMEOUT + 1);

    localparam int ROWS_GOT_W = $clog2(M_TILE + 1);

    // Frame payload sizes (bytes). The RX payload buffer must hold the
    // largest fixed-shape command (RUN_TILE: flags + weights + acts); floor
    // of 8 keeps headroom for short unknown commands at tiny geometries.
    localparam int W_BYTES       = ARRAY_ROWS * NUM_COLS;   // LOAD_WEIGHTS
    localparam int A_BYTES       = M_TILE * ARRAY_ROWS;     // LOAD_ACT
    localparam int B_BYTES       = 2 * NUM_COLS;            // LOAD_BIAS
    localparam int RT_BYTES      = 1 + W_BYTES + A_BYTES;   // RUN_TILE
    localparam int TILE_BYTES    = W_BYTES + A_BYTES;       // one STREAM_RUN tile
    localparam int MAX_RTB       = (RT_BYTES > B_BYTES) ? RT_BYTES : B_BYTES;
    localparam int PAYLOAD_BYTES = (MAX_RTB > 8) ? MAX_RTB : 8;

    // RUN response: STATUS + LEN + int16 LE result matrix, row-major
    localparam int RESULT_BYTES = 2 * M_TILE * NUM_COLS;
    localparam int TX_BYTES     = 2 + RESULT_BYTES;

    // Persistent register file (survives across commands)
    // reg_weights is stored in NATURAL row-major order (row 0 = top row);
    // the bottom-first wire order of LOAD_WEIGHTS is undone at unpack time,
    // and S_LD_WF re-derives it at presentation time (see §2.3 of
    // docs/SEQUENCER_REDESIGN.md).
    logic signed [7:0]  reg_weights [ARRAY_ROWS][NUM_COLS];
    logic signed [7:0]  reg_act     [M_TILE][ARRAY_ROWS];
    logic signed [15:0] reg_bias    [NUM_COLS];
    logic               reg_tile_first;
    logic               reg_tile_last;

    // Results captured from pipeline, one row per final_row_valid pulse
    logic signed [15:0] result_rows [M_TILE][NUM_COLS];

    // FSM states
    typedef enum logic [4:0] {
        S_IDLE          = 5'd0,
        S_RECV_LEN      = 5'd1,
        S_RECV_PAYLOAD  = 5'd2,
        S_EXEC_DISPATCH = 5'd3,

        // RUN substates — counter-driven loops (run_cnt), one state per phase
        S_WR_UB         = 5'd4,
        S_LD_WF         = 5'd5,
        S_LD_WF_GAP     = 5'd6,   // 1-cycle gap after WF writes
        S_SWAP          = 5'd7,
        S_LOADING       = 5'd8,
        S_STREAM        = 5'd9,
        S_WAIT          = 5'd10,

        // RESET substate
        S_RESET_PULSE   = 5'd11,

        // TX substates
        S_TX_STATUS     = 5'd12,
        S_TX_DATA       = 5'd13,

        // STREAM_RUN substates: frame header, then per-tile byte
        // deserialization (straight into the register file — no
        // whole-frame payload buffering)
        S_SR_FLAGS      = 5'd14,
        S_SR_KT         = 5'd15,
        S_SR_RECV_TILE  = 5'd16
    } state_t;

    state_t state;

    // Latched CMD / payload
    logic [7:0] cmd_reg;
    logic [7:0] len_reg;
    logic [7:0] byte_cnt;
    logic [7:0] payload [PAYLOAD_BYTES];

    // TX bookkeeping
    logic [7:0] tx_len_reg;
    logic [7:0] tx_byte_idx;
    logic [7:0] tx_payload [TX_BYTES];

    // Shared loop counter for the RUN substates (each phase resets it on exit)
    logic [7:0] run_cnt;

    // STREAM_RUN bookkeeping: frame-level flags, tile count/index, and the
    // row/col cursor used to deserialize the current tile's bytes into
    // reg_weights (sr_act_phase=0) then reg_act (sr_act_phase=1).
    logic       stream_active;   // diverts S_WAIT's exit back to the next tile
    logic       stream_first;    // frame flags[0]: TILE_FIRST for this frame's tile 0
    logic       stream_last;     // frame flags[1]: TILE_LAST for this frame's final tile
    logic [7:0] k_tiles_reg;
    logic [7:0] tile_idx;
    logic [7:0] sr_row, sr_col;
    logic       sr_act_phase;

    // WAIT timeout
    logic [TIMEOUT_W-1:0]  wait_cnt;
    logic [ROWS_GOT_W-1:0] rows_got;

    // RESET pulse counter
    logic [2:0] reset_cnt;

    // rx_error is a latched level in uart_rx (set on a bad stop bit, cleared
    // by the next good byte) — edge-detect it so one framing error produces
    // exactly one STATUS_ERR response.
    logic rx_error_prev;
    wire  rx_error_rise = rx_error && !rx_error_prev;

    // Drive out_bias / tile_first / tile_last to the datapath at all times
    always_comb begin
        for (int c = 0; c < NUM_COLS; c++)
            out_bias[c] = reg_bias[c];
        tile_first = reg_tile_first;
        tile_last  = reg_tile_last;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state             <= S_IDLE;
            cmd_reg           <= '0;
            len_reg           <= '0;
            byte_cnt          <= '0;
            for (int i = 0; i < PAYLOAD_BYTES; i++) payload[i] <= '0;
            for (int r = 0; r < ARRAY_ROWS; r++)
                for (int c = 0; c < NUM_COLS; c++)
                    reg_weights[r][c] <= '0;
            for (int m = 0; m < M_TILE; m++)
                for (int k = 0; k < ARRAY_ROWS; k++)
                    reg_act[m][k] <= '0;
            for (int c = 0; c < NUM_COLS; c++)
                reg_bias[c] <= '0;
            reg_tile_first    <= 1'b1;
            reg_tile_last     <= 1'b1;
            for (int m = 0; m < M_TILE; m++)
                for (int c = 0; c < NUM_COLS; c++)
                    result_rows[m][c] <= '0;

            write_enable_col   <= '0;
            for (int c = 0; c < NUM_COLS; c++)
                write_data_col[c] <= '0;
            swap_banks         <= 1'b0;
            loading_phase      <= 1'b0;
            host_write_addr    <= '0;
            for (int k = 0; k < ARRAY_ROWS; k++)
                host_write_data[k] <= '0;
            host_write_valid   <= 1'b0;
            ub_read_addr       <= '0;
            ub_read_en         <= 1'b0;
            tx_data            <= '0;
            tx_valid           <= 1'b0;
            tx_len_reg         <= '0;
            tx_byte_idx        <= '0;
            run_cnt            <= '0;
            stream_active      <= 1'b0;
            stream_first       <= 1'b0;
            stream_last        <= 1'b0;
            k_tiles_reg        <= '0;
            tile_idx           <= '0;
            sr_row             <= '0;
            sr_col             <= '0;
            sr_act_phase       <= 1'b0;
            wait_cnt           <= '0;
            rows_got           <= '0;
            reset_cnt          <= '0;
            rx_error_prev      <= 1'b0;
            tpu_reset          <= 1'b0;
            busy               <= 1'b0;
        end else begin
            rx_error_prev      <= rx_error;
            write_enable_col   <= '0;
            swap_banks         <= 1'b0;
            loading_phase      <= 1'b0;
            host_write_valid   <= 1'b0;
            ub_read_en         <= 1'b0;
            tx_valid           <= 1'b0;
            tpu_reset          <= 1'b0;

            // Always capture result rows when the pipeline fires
            if (final_row_valid && rows_got < ROWS_GOT_W'(M_TILE)) begin
                for (int c = 0; c < NUM_COLS; c++)
                    result_rows[rows_got][c] <= final_row_out[c];
                rows_got <= rows_got + 1'b1;
            end

            case (state)

                // IDLE: wait for the first rx byte (the CMD byte). A framing
                // error here means the CMD byte itself was corrupted — the
                // host just sent a frame and is waiting, so answer STATUS_ERR.
                S_IDLE: begin
                    busy <= 1'b0;
                    if (rx_error_rise) begin
                        tx_payload[0] <= STATUS_ERR;
                        tx_payload[1] <= 8'h00;
                        tx_len_reg    <= 8'd2;
                        tx_byte_idx   <= 8'd0;
                        state         <= S_TX_STATUS;
                        busy          <= 1'b1;
                    end else if (rx_valid && rx_data != CMD_NOP) begin
                        cmd_reg  <= rx_data;
                        state    <= S_RECV_LEN;
                        busy     <= 1'b1;
                    end
                end

                // RECV_LEN: latch LEN, decide whether to collect payload
                S_RECV_LEN: begin
                    if (rx_error_rise) begin
                        tx_payload[0] <= STATUS_ERR;
                        tx_payload[1] <= 8'h00;
                        tx_len_reg    <= 8'd2;
                        tx_byte_idx   <= 8'd0;
                        state         <= S_TX_STATUS;
                    end else if (rx_valid) begin
                        len_reg  <= rx_data;
                        byte_cnt <= '0;
                        if (rx_data == 8'h00) begin
                            // (a LEN=0 STREAM_RUN lands in S_EXEC_DISPATCH's
                            // default arm → STATUS_ERR, as it should)
                            state <= S_EXEC_DISPATCH;
                        end else if (cmd_reg == CMD_STREAM_RUN) begin
                            // STREAM_RUN never buffers its (potentially
                            // 255-byte) payload — deserialize it tile by
                            // tile in the S_SR_* states instead.
                            state <= S_SR_FLAGS;
                        end else begin
                            state <= S_RECV_PAYLOAD;
                        end
                    end
                end

                // RECV_PAYLOAD: collect len_reg bytes; a framing error
                // mid-frame aborts with STATUS_ERR (the corrupted byte never
                // pulses rx_valid, so waiting would just time out the host)
                S_RECV_PAYLOAD: begin
                    if (rx_error_rise) begin
                        tx_payload[0] <= STATUS_ERR;
                        tx_payload[1] <= 8'h00;
                        tx_len_reg    <= 8'd2;
                        tx_byte_idx   <= 8'd0;
                        state         <= S_TX_STATUS;
                    end else if (rx_valid) begin
                        payload[byte_cnt] <= rx_data;
                        if (byte_cnt == len_reg - 8'd1) begin
                            byte_cnt <= '0;
                            state    <= S_EXEC_DISPATCH;
                        end else begin
                            byte_cnt <= byte_cnt + 8'd1;
                        end
                    end
                end

                // EXEC_DISPATCH: decode CMD, update register file or start RUN
                S_EXEC_DISPATCH: begin
                    case (cmd_reg)

                        // LOAD_WEIGHTS: wire order is bottom row first, so
                        // payload row-chunk i is array row ARRAY_ROWS-1-i.
                        // Stored in natural order; ACK immediately.
                        CMD_LOAD_WEIGHTS: begin
                            for (int i = 0; i < ARRAY_ROWS; i++)
                                for (int c = 0; c < NUM_COLS; c++)
                                    reg_weights[ARRAY_ROWS-1-i][c]
                                        <= signed'(payload[i*NUM_COLS + c]);
                            // Build ACK: STATUS_OK, LEN=0
                            tx_payload[0] <= STATUS_OK;
                            tx_payload[1] <= 8'h00;
                            tx_len_reg    <= 8'd2;
                            tx_byte_idx   <= 8'd0;
                            state         <= S_TX_STATUS;
                        end

                        // LOAD_BIAS: unpack NUM_COLS signed 16-bit LE values
                        CMD_LOAD_BIAS: begin
                            for (int c = 0; c < NUM_COLS; c++)
                                reg_bias[c] <= signed'({payload[2*c+1], payload[2*c]});
                            tx_payload[0] <= STATUS_OK;
                            tx_payload[1] <= 8'h00;
                            tx_len_reg    <= 8'd2;
                            tx_byte_idx   <= 8'd0;
                            state         <= S_TX_STATUS;
                        end

                        // LOAD_ACT: natural row-major, M_TILE rows of
                        // ARRAY_ROWS bytes each
                        CMD_LOAD_ACT: begin
                            for (int m = 0; m < M_TILE; m++)
                                for (int k = 0; k < ARRAY_ROWS; k++)
                                    reg_act[m][k] <= signed'(payload[m*ARRAY_ROWS + k]);
                            tx_payload[0] <= STATUS_OK;
                            tx_payload[1] <= 8'h00;
                            tx_len_reg    <= 8'd2;
                            tx_byte_idx   <= 8'd0;
                            state         <= S_TX_STATUS;
                        end

                        // RUN: start the pipeline orchestration sequence.
                        // LEN=0 -> first=last=1 (single-shot, back-compat).
                        // LEN=1 -> payload[0][0]=TILE_FIRST, [1]=TILE_LAST.
                        CMD_RUN: begin
                            rows_got  <= '0;
                            wait_cnt  <= '0;
                            run_cnt   <= '0;
                            if (len_reg == 8'd1) begin
                                reg_tile_first <= payload[0][0];
                                reg_tile_last  <= payload[0][1];
                            end else begin
                                reg_tile_first <= 1'b1;
                                reg_tile_last  <= 1'b1;
                            end
                            state     <= S_WR_UB;
                        end

                        // RESET: pulse tpu_reset
                        CMD_RESET: begin
                            reset_cnt <= 3'd0;
                            state     <= S_RESET_PULSE;
                        end

                        // RUN_TILE: LOAD_WEIGHTS + LOAD_ACT + RUN in one
                        // frame. Weights arrive in NATURAL row-major order
                        // (top row first) — no host-side pre-reversal, unlike
                        // legacy LOAD_WEIGHTS; S_LD_WF's bottom-first
                        // presentation reorder handles the staggered-loading
                        // contract either way. Bias is NOT part of this
                        // frame (LOAD_BIAS is once-per-output-block).
                        CMD_RUN_TILE: begin
                            reg_tile_first <= payload[0][0];
                            reg_tile_last  <= payload[0][1];
                            for (int r = 0; r < ARRAY_ROWS; r++)
                                for (int c = 0; c < NUM_COLS; c++)
                                    reg_weights[r][c]
                                        <= signed'(payload[1 + r*NUM_COLS + c]);
                            for (int m = 0; m < M_TILE; m++)
                                for (int k = 0; k < ARRAY_ROWS; k++)
                                    reg_act[m][k]
                                        <= signed'(payload[1 + W_BYTES + m*ARRAY_ROWS + k]);
                            rows_got  <= '0;
                            wait_cnt  <= '0;
                            run_cnt   <= '0;
                            state     <= S_WR_UB;
                        end

                        // Unknown CMD
                        default: begin
                            tx_payload[0] <= STATUS_ERR;
                            tx_payload[1] <= 8'h00;
                            tx_len_reg    <= 8'd2;
                            tx_byte_idx   <= 8'd0;
                            state         <= S_TX_STATUS;
                        end
                    endcase
                end

                // RUN substates
                // Step 1: write activation row run_cnt → unified_buffer
                S_WR_UB: begin
                    host_write_addr    <= UB_ADDR_W'(run_cnt);
                    for (int k = 0; k < ARRAY_ROWS; k++)
                        host_write_data[k] <= reg_act[run_cnt][k];
                    host_write_valid   <= 1'b1;
                    if (run_cnt == 8'(M_TILE - 1)) begin
                        run_cnt <= '0;
                        state   <= S_LD_WF;
                    end else begin
                        run_cnt <= run_cnt + 8'd1;
                    end
                end

                // Step 2: load weights, bottom row FIRST (staggered loading
                // contract, weight_fifo.sv): row index counts DOWN from
                // ARRAY_ROWS-1 while run_cnt counts up.
                S_LD_WF: begin
                    for (int c = 0; c < NUM_COLS; c++) begin
                        write_enable_col[c] <= 1'b1;
                        write_data_col[c]   <= reg_weights[ARRAY_ROWS-1-run_cnt][c];
                    end
                    if (run_cnt == 8'(ARRAY_ROWS - 1)) begin
                        run_cnt <= '0;
                        state   <= S_LD_WF_GAP;
                    end else begin
                        run_cnt <= run_cnt + 8'd1;
                    end
                end

                // Step 2b: one idle cycle after WF writes, before swap
                // (matches: @(posedge clk); #1; in load_weights task)
                S_LD_WF_GAP: begin
                    state <= S_SWAP;
                end

                // Step 3: swap_banks = 1 for 1 cycle
                S_SWAP: begin
                    swap_banks <= 1'b1;
                    state      <= S_LOADING;
                end

                // Step 4: loading_phase = 1 for ARRAY_ROWS+1 cycles
                // (ARRAY_ROWS drain cycles + 1 guard)
                S_LOADING: begin
                    loading_phase <= 1'b1;
                    if (run_cnt == 8'(ARRAY_ROWS)) begin
                        run_cnt <= '0;
                        state   <= S_STREAM;
                    end else begin
                        run_cnt <= run_cnt + 8'd1;
                    end
                end

                // Step 5: stream UB rows 0 .. M_TILE-1 (→ SDS → MMU)
                S_STREAM: begin
                    ub_read_addr <= UB_ADDR_W'(run_cnt);
                    ub_read_en   <= 1'b1;
                    if (run_cnt == 8'(M_TILE - 1)) begin
                        run_cnt <= '0;
                        state   <= S_WAIT;
                    end else begin
                        run_cnt <= run_cnt + 8'd1;
                    end
                end

                // Step 6: wait for completion, then respond (or, mid-stream,
                // loop straight back for the next tile).
                //   tile_last=1: wait for all M_TILE final_row_valid pulses
                //     and return the full result matrix. Only ever true on a
                //     stream's genuinely final tile, so it also ends the
                //     stream.
                //   tile_last=0: wait for accum_pass_done instead (bias/
                //     activation never fire this pass). Mid-stream with more
                //     tiles to go: no response — return to S_SR_RECV_TILE
                //     for the next tile's bytes. Otherwise (legacy RUN/
                //     RUN_TILE with last=0, or a stream frame whose
                //     TILE_LAST flag is 0): bare ACK, running sum stays in
                //     the accumulator for the next frame.
                S_WAIT: begin
                    wait_cnt <= wait_cnt + 1'b1;
                    if (reg_tile_last) begin
                        if (rows_got == ROWS_GOT_W'(M_TILE)) begin
                            stream_active <= 1'b0;
                            // Pack response: STATUS_OK, LEN, row-major int16 LE
                            tx_payload[0] <= STATUS_OK;
                            tx_payload[1] <= 8'(RESULT_BYTES);
                            for (int m = 0; m < M_TILE; m++)
                                for (int c = 0; c < NUM_COLS; c++) begin
                                    tx_payload[2 + 2*(m*NUM_COLS + c)]     <= result_rows[m][c][7:0];
                                    tx_payload[2 + 2*(m*NUM_COLS + c) + 1] <= result_rows[m][c][15:8];
                                end
                            tx_len_reg    <= 8'(TX_BYTES);
                            tx_byte_idx   <= 8'd0;
                            state         <= S_TX_STATUS;
                        end else if (wait_cnt == WAIT_TIMEOUT[TIMEOUT_W-1:0]) begin
                            // Timeout — something wrong with pipeline
                            stream_active <= 1'b0;
                            tx_payload[0] <= STATUS_ERR;
                            tx_payload[1] <= 8'h00;
                            tx_len_reg    <= 8'd2;
                            tx_byte_idx   <= 8'd0;
                            state         <= S_TX_STATUS;
                        end
                    end else begin
                        if (accum_pass_done) begin
                            if (stream_active && tile_idx != k_tiles_reg - 8'd1) begin
                                // More tiles in this frame — no response,
                                // straight back to the byte deserializer.
                                tile_idx <= tile_idx + 8'd1;
                                rows_got <= '0;
                                wait_cnt <= '0;
                                run_cnt  <= '0;
                                state    <= S_SR_RECV_TILE;
                            end else begin
                                stream_active <= 1'b0;
                                tx_payload[0] <= STATUS_OK;
                                tx_payload[1] <= 8'h00;   // no result yet -- mid-K ACK
                                tx_len_reg    <= 8'd2;
                                tx_byte_idx   <= 8'd0;
                                state         <= S_TX_STATUS;
                            end
                        end else if (wait_cnt == WAIT_TIMEOUT[TIMEOUT_W-1:0]) begin
                            stream_active <= 1'b0;
                            tx_payload[0] <= STATUS_ERR;
                            tx_payload[1] <= 8'h00;
                            tx_len_reg    <= 8'd2;
                            tx_byte_idx   <= 8'd0;
                            state         <= S_TX_STATUS;
                        end
                    end
                end

                // STREAM_RUN header byte 1: frame-level TILE_FIRST/TILE_LAST
                S_SR_FLAGS: begin
                    if (rx_error_rise) begin
                        tx_payload[0] <= STATUS_ERR;
                        tx_payload[1] <= 8'h00;
                        tx_len_reg    <= 8'd2;
                        tx_byte_idx   <= 8'd0;
                        state         <= S_TX_STATUS;
                    end else if (rx_valid) begin
                        stream_first <= rx_data[0];
                        stream_last  <= rx_data[1];
                        state        <= S_SR_KT;
                    end
                end

                // STREAM_RUN header byte 2: K_TILES. Validate it against the
                // frame LEN before trusting it — a mismatch means the host
                // and sequencer would disagree on where tiles end, so refuse
                // the frame up front rather than compute garbage.
                S_SR_KT: begin
                    if (rx_error_rise) begin
                        tx_payload[0] <= STATUS_ERR;
                        tx_payload[1] <= 8'h00;
                        tx_len_reg    <= 8'd2;
                        tx_byte_idx   <= 8'd0;
                        state         <= S_TX_STATUS;
                    end else if (rx_valid) begin
                        if (rx_data == 8'd0 ||
                            {8'd0, len_reg} != 16'd2 + 16'(rx_data) * 16'(TILE_BYTES)) begin
                            // Malformed frame. Note the host's remaining
                            // frame bytes (if any) will be misparsed as new
                            // commands — on any STATUS_ERR the host must
                            // flush and re-sync (tpu_host.py raises).
                            tx_payload[0] <= STATUS_ERR;
                            tx_payload[1] <= 8'h00;
                            tx_len_reg    <= 8'd2;
                            tx_byte_idx   <= 8'd0;
                            state         <= S_TX_STATUS;
                        end else begin
                            k_tiles_reg   <= rx_data;
                            tile_idx      <= '0;
                            sr_row        <= '0;
                            sr_col        <= '0;
                            sr_act_phase  <= 1'b0;
                            stream_active <= 1'b1;
                            state         <= S_SR_RECV_TILE;
                        end
                    end
                end

                // STREAM_RUN tile deserializer: write each arriving byte
                // straight into the register file — weights first (natural
                // row-major, same wire order as RUN_TILE), then activations.
                // On the tile's final byte, latch this tile's first/last
                // into the accumulator controls and launch the standard
                // S_WR_UB → ... → S_WAIT pass. S_WAIT routes back here for
                // the next tile (stream_active) until the frame is done.
                S_SR_RECV_TILE: begin
                    if (rx_error_rise) begin
                        stream_active <= 1'b0;
                        tx_payload[0] <= STATUS_ERR;
                        tx_payload[1] <= 8'h00;
                        tx_len_reg    <= 8'd2;
                        tx_byte_idx   <= 8'd0;
                        state         <= S_TX_STATUS;
                    end else if (rx_valid) begin
                        if (!sr_act_phase) begin
                            reg_weights[sr_row][sr_col] <= signed'(rx_data);
                            if (sr_col == 8'(NUM_COLS - 1)) begin
                                sr_col <= '0;
                                if (sr_row == 8'(ARRAY_ROWS - 1)) begin
                                    sr_row       <= '0;
                                    sr_act_phase <= 1'b1;
                                end else begin
                                    sr_row <= sr_row + 8'd1;
                                end
                            end else begin
                                sr_col <= sr_col + 8'd1;
                            end
                        end else begin
                            reg_act[sr_row][sr_col] <= signed'(rx_data);
                            if (sr_col == 8'(ARRAY_ROWS - 1)) begin
                                sr_col <= '0;
                                if (sr_row == 8'(M_TILE - 1)) begin
                                    // Tile complete — run the pipeline pass.
                                    sr_row         <= '0;
                                    sr_act_phase   <= 1'b0;
                                    reg_tile_first <= (tile_idx == 8'd0) && stream_first;
                                    reg_tile_last  <= (tile_idx == k_tiles_reg - 8'd1) && stream_last;
                                    rows_got       <= '0;
                                    wait_cnt       <= '0;
                                    run_cnt        <= '0;
                                    state          <= S_WR_UB;
                                end else begin
                                    sr_row <= sr_row + 8'd1;
                                end
                            end else begin
                                sr_col <= sr_col + 8'd1;
                            end
                        end
                    end
                end

                // RESET_PULSE: hold tpu_reset high for 4 cycles
                S_RESET_PULSE: begin
                    tpu_reset <= 1'b1;
                    if (reset_cnt == 3'd3) begin
                        reset_cnt <= 3'd0;
                        tx_payload[0] <= STATUS_OK;
                        tx_payload[1] <= 8'h00;
                        tx_len_reg    <= 8'd2;
                        tx_byte_idx   <= 8'd0;
                        state         <= S_TX_STATUS;
                    end else begin
                        reset_cnt <= reset_cnt + 3'd1;
                    end
                end

                // TX substates: serialize tx_payload via uart_tx
                // All bytes go through S_TX_DATA; S_TX_STATUS kicks off the
                // loop by loading byte 0 (STATUS), but the real logic is the
                // generic byte-loop in S_TX_DATA.

                // Kick off by loading byte 0 (STATUS)
                S_TX_STATUS: begin
                    if (!tx_busy) begin
                        tx_data     <= tx_payload[0];
                        tx_valid    <= 1'b1;
                        tx_byte_idx <= 8'd1;
                        state       <= S_TX_DATA;
                    end
                end

                // Send remaining bytes one at a time, waiting for tx_busy to clear
                S_TX_DATA: begin
                    if (!tx_busy && !tx_valid) begin
                        if (tx_byte_idx >= tx_len_reg) begin
                            // All bytes sent
                            state <= S_IDLE;
                            busy  <= 1'b0;
                        end else begin
                            tx_data     <= tx_payload[tx_byte_idx];
                            tx_valid    <= 1'b1;
                            tx_byte_idx <= tx_byte_idx + 8'd1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
