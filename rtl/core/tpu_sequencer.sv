`timescale 1ns / 1ps

// file-scope import: the only form yosys's frontend accepts
import tpu_pkg::*;

// TPU sequencer: host command decoder + pipeline orchestrator (spec: docs/protocol.md)
module tpu_sequencer #(
    parameter int ARRAY_ROWS   = 2,
    parameter int NUM_COLS     = 2,
    parameter int M_TILE       = ARRAY_ROWS,
    // widening changes the wire format: PSUM_WIDTH/8 bytes per bias/result element
    parameter int PSUM_WIDTH   = 16,
    parameter int WAIT_TIMEOUT = 200,
    // derived, do not override
    parameter int UB_ADDR_W    = (M_TILE > 1) ? $clog2(M_TILE) : 1
) (
    input  logic clk,
    input  logic reset,

    input  logic [7:0] rx_data,
    input  logic       rx_valid,
    // level from uart_rx, edge-detected below
    input  logic       rx_error,

    output logic [7:0] tx_data,
    output logic       tx_valid,
    input  logic       tx_busy,

    // weight_fifo
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

    output logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0]   out_bias,

    // pass flags, held stable for the whole pass
    output logic               tile_first,
    output logic               tile_last,
    output logic               act_bypass,
    input  logic               accum_pass_done,

    input  logic signed [NUM_COLS-1:0][PSUM_WIDTH-1:0] final_row_out,
    input  logic               final_row_valid,

    output logic               tpu_reset,

    output logic               busy
);

    localparam int TIMEOUT_W = $clog2(WAIT_TIMEOUT + 1);

    localparam int ROWS_GOT_W = $clog2(M_TILE + 1);

    localparam int PSUM_BYTES    = PSUM_WIDTH / 8;
    localparam int W_BYTES       = ARRAY_ROWS * NUM_COLS;
    localparam int A_BYTES       = M_TILE * ARRAY_ROWS;
    localparam int B_BYTES       = PSUM_BYTES * NUM_COLS;
    localparam int RT_BYTES      = 1 + W_BYTES + A_BYTES;
    localparam int TILE_BYTES    = W_BYTES + A_BYTES;
    localparam int MAX_RTB       = (RT_BYTES > B_BYTES) ? RT_BYTES : B_BYTES;
    // floor of 8 so short unknown commands still fit at tiny shapes
    localparam int PAYLOAD_BYTES = (MAX_RTB > 8) ? MAX_RTB : 8;

    localparam int RESULT_BYTES = PSUM_BYTES * M_TILE * NUM_COLS;
    localparam int TX_BYTES     = 2 + RESULT_BYTES;

    // LEN is one byte: fail at elaboration rather than truncate a frame
    if (PSUM_WIDTH % 8 != 0) begin : gen_psum_width_check
        $error("PSUM_WIDTH must be a multiple of 8 (got %0d)", PSUM_WIDTH);
    end
    if (RESULT_BYTES > 255) begin : gen_result_bytes_check
        $error("RESULT_BYTES=%0d exceeds the 255-byte LEN cap", RESULT_BYTES);
    end
    if (B_BYTES > 255) begin : gen_bias_bytes_check
        $error("LOAD_BIAS payload=%0d exceeds the 255-byte LEN cap", B_BYTES);
    end

    // register file, persists across commands; weights stored top row first
    logic signed [7:0]  reg_weights [ARRAY_ROWS][NUM_COLS];
    logic signed [7:0]  reg_act     [M_TILE][ARRAY_ROWS];
    logic signed [PSUM_WIDTH-1:0] reg_bias    [NUM_COLS];
    logic               reg_tile_first;
    logic               reg_tile_last;
    logic               reg_act_bypass;

    logic signed [PSUM_WIDTH-1:0] result_rows [M_TILE][NUM_COLS];

    typedef enum logic [4:0] {
        S_IDLE          = 5'd0,
        S_RECV_LEN      = 5'd1,
        S_RECV_PAYLOAD  = 5'd2,
        S_EXEC_DISPATCH = 5'd3,

        // RUN pass, counter-driven via run_cnt
        S_WR_UB         = 5'd4,
        S_LD_WF         = 5'd5,
        S_LD_WF_GAP     = 5'd6,
        S_SWAP          = 5'd7,
        S_LOADING       = 5'd8,
        S_STREAM        = 5'd9,
        S_WAIT          = 5'd10,

        S_RESET_PULSE   = 5'd11,

        S_TX_STATUS     = 5'd12,
        S_TX_DATA       = 5'd13,

        // STREAM_RUN: tiles deserialize straight into the register file, no frame buffer
        S_SR_FLAGS      = 5'd14,
        S_SR_KT         = 5'd15,
        S_SR_RECV_TILE  = 5'd16
    } state_t;

    state_t state;

    logic [7:0] cmd_reg;
    logic [7:0] len_reg;
    logic [7:0] byte_cnt;
    logic [7:0] payload [PAYLOAD_BYTES];

    logic [7:0] tx_len_reg;
    logic [7:0] tx_byte_idx;
    logic [7:0] tx_payload [TX_BYTES];

    logic [7:0] run_cnt;  // shared by the RUN states, each resets it on exit

    logic       stream_active;   // routes S_WAIT back to the next tile
    logic       stream_first;
    logic       stream_last;
    logic       stream_act_bypass;
    logic [7:0] k_tiles_reg;
    logic [7:0] tile_idx;
    logic [7:0] sr_row, sr_col;
    logic       sr_act_phase;    // 0: filling reg_weights, 1: reg_act

    logic [TIMEOUT_W-1:0]  wait_cnt;
    logic [ROWS_GOT_W-1:0] rows_got;

    logic [2:0] reset_cnt;

    // one STATUS_ERR per framing error, not one per cycle the level is held
    logic rx_error_prev;
    wire  rx_error_rise = rx_error && !rx_error_prev;

    always_comb begin
        for (int c = 0; c < NUM_COLS; c++)
            out_bias[c] = reg_bias[c];
        tile_first = reg_tile_first;
        tile_last  = reg_tile_last;
        act_bypass = reg_act_bypass;
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
            reg_act_bypass    <= 1'b0;
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
            stream_act_bypass  <= 1'b0;
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

            if (final_row_valid && rows_got < ROWS_GOT_W'(M_TILE)) begin
                for (int c = 0; c < NUM_COLS; c++)
                    result_rows[rows_got][c] <= final_row_out[c];
                rows_got <= rows_got + 1'b1;
            end

            case (state)

                // a framing error here is a corrupted CMD byte: answer it, the host is waiting
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
                            // a LEN=0 STREAM_RUN falls to the default arm: STATUS_ERR
                            state <= S_EXEC_DISPATCH;
                        end else if (cmd_reg == CMD_STREAM_RUN) begin
                            state <= S_SR_FLAGS;
                        end else begin
                            state <= S_RECV_PAYLOAD;
                        end
                    end
                end

                // abort on a framing error: the bad byte never pulses rx_valid
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

                S_EXEC_DISPATCH: begin
                    case (cmd_reg)

                        // legacy wire order is bottom row first
                        CMD_LOAD_WEIGHTS: begin
                            for (int i = 0; i < ARRAY_ROWS; i++)
                                for (int c = 0; c < NUM_COLS; c++)
                                    reg_weights[ARRAY_ROWS-1-i][c]
                                        <= signed'(payload[i*NUM_COLS + c]);
                            tx_payload[0] <= STATUS_OK;
                            tx_payload[1] <= 8'h00;
                            tx_len_reg    <= 8'd2;
                            tx_byte_idx   <= 8'd0;
                            state         <= S_TX_STATUS;
                        end

                        CMD_LOAD_BIAS: begin
                            for (int c = 0; c < NUM_COLS; c++)
                                for (int b = 0; b < PSUM_BYTES; b++)
                                    reg_bias[c][8*b +: 8] <= payload[PSUM_BYTES*c + b];
                            tx_payload[0] <= STATUS_OK;
                            tx_payload[1] <= 8'h00;
                            tx_len_reg    <= 8'd2;
                            tx_byte_idx   <= 8'd0;
                            state         <= S_TX_STATUS;
                        end

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

                        // LEN=0 means first=last=1, so hosts that never send flags still work
                        CMD_RUN: begin
                            rows_got  <= '0;
                            wait_cnt  <= '0;
                            run_cnt   <= '0;
                            if (len_reg == 8'd1) begin
                                reg_tile_first <= payload[0][FLAG_TILE_FIRST];
                                reg_tile_last  <= payload[0][FLAG_TILE_LAST];
                                reg_act_bypass <= payload[0][FLAG_ACT_BYPASS];
                            end else begin
                                reg_tile_first <= 1'b1;
                                reg_tile_last  <= 1'b1;
                                reg_act_bypass <= 1'b0;
                            end
                            state     <= S_WR_UB;
                        end

                        CMD_RESET: begin
                            reset_cnt <= 3'd0;
                            state     <= S_RESET_PULSE;
                        end

                        CMD_RUN_TILE: begin
                            reg_tile_first <= payload[0][FLAG_TILE_FIRST];
                            reg_tile_last  <= payload[0][FLAG_TILE_LAST];
                            reg_act_bypass <= payload[0][FLAG_ACT_BYPASS];
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

                        default: begin
                            tx_payload[0] <= STATUS_ERR;
                            tx_payload[1] <= 8'h00;
                            tx_len_reg    <= 8'd2;
                            tx_byte_idx   <= 8'd0;
                            state         <= S_TX_STATUS;
                        end
                    endcase
                end

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

                // bottom row first, or the stagger transposes every matrix
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

                S_LD_WF_GAP: begin
                    state <= S_SWAP;
                end

                S_SWAP: begin
                    swap_banks <= 1'b1;
                    state      <= S_LOADING;
                end

                // ARRAY_ROWS drain cycles + 1 guard
                S_LOADING: begin
                    loading_phase <= 1'b1;
                    if (run_cnt == 8'(ARRAY_ROWS)) begin
                        run_cnt <= '0;
                        state   <= S_STREAM;
                    end else begin
                        run_cnt <= run_cnt + 8'd1;
                    end
                end

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

                // non-last passes never reach final_row_valid, so they wait on accum_pass_done
                S_WAIT: begin
                    wait_cnt <= wait_cnt + 1'b1;
                    if (reg_tile_last) begin
                        if (rows_got == ROWS_GOT_W'(M_TILE)) begin
                            stream_active <= 1'b0;
                            tx_payload[0] <= STATUS_OK;
                            tx_payload[1] <= 8'(RESULT_BYTES);
                            for (int m = 0; m < M_TILE; m++)
                                for (int c = 0; c < NUM_COLS; c++)
                                    for (int b = 0; b < PSUM_BYTES; b++)
                                        tx_payload[2 + PSUM_BYTES*(m*NUM_COLS + c) + b]
                                            <= result_rows[m][c][8*b +: 8];
                            tx_len_reg    <= 8'(TX_BYTES);
                            tx_byte_idx   <= 8'd0;
                            state         <= S_TX_STATUS;
                        end else if (wait_cnt == WAIT_TIMEOUT[TIMEOUT_W-1:0]) begin
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
                                // more tiles in this frame: no response yet
                                tile_idx <= tile_idx + 8'd1;
                                rows_got <= '0;
                                wait_cnt <= '0;
                                run_cnt  <= '0;
                                state    <= S_SR_RECV_TILE;
                            end else begin
                                stream_active <= 1'b0;
                                tx_payload[0] <= STATUS_OK;
                                tx_payload[1] <= 8'h00;
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

                S_SR_FLAGS: begin
                    if (rx_error_rise) begin
                        tx_payload[0] <= STATUS_ERR;
                        tx_payload[1] <= 8'h00;
                        tx_len_reg    <= 8'd2;
                        tx_byte_idx   <= 8'd0;
                        state         <= S_TX_STATUS;
                    end else if (rx_valid) begin
                        stream_first      <= rx_data[FLAG_TILE_FIRST];
                        stream_last       <= rx_data[FLAG_TILE_LAST];
                        stream_act_bypass <= rx_data[FLAG_ACT_BYPASS];
                        state        <= S_SR_KT;
                    end
                end

                // reject a K_TILES that disagrees with LEN before computing garbage
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
                            // the rest of the frame parses as junk commands; the host must resync
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
                                    sr_row         <= '0;
                                    sr_act_phase   <= 1'b0;
                                    reg_tile_first <= (tile_idx == 8'd0) && stream_first;
                                    reg_tile_last  <= (tile_idx == k_tiles_reg - 8'd1) && stream_last;
                                    reg_act_bypass <= stream_act_bypass;
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

                S_TX_STATUS: begin
                    if (!tx_busy) begin
                        tx_data     <= tx_payload[0];
                        tx_valid    <= 1'b1;
                        tx_byte_idx <= 8'd1;
                        state       <= S_TX_DATA;
                    end
                end

                S_TX_DATA: begin
                    if (!tx_busy && !tx_valid) begin
                        if (tx_byte_idx >= tx_len_reg) begin
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
