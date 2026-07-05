`timescale 1ns / 1ps

// tpu_sequencer — UART command decoder + TPU pipeline orchestrator.
//
// Sits between the uart_rx/uart_tx pair and the existing tpu_core datapath.
//
//  Protocol (8-N-1, host-initiates everything)
//
//  Host → FPGA packet:
//    [0]  CMD   byte
//    [1]  LEN   byte  (number of payload bytes that follow; 0..8)
//    [2…] payload[LEN]
//
//  FPGA → Host response (sent after CMD is fully executed):
//    [0]  STATUS  0xAA = OK, 0xFF = unknown CMD / framing error
//    [1]  LEN     number of response payload bytes
//    [2…] payload[LEN]
//
//  Command table
//
//  0x01  LOAD_WEIGHTS  LEN=4  payload: [w10, w11, w00, w01]  (int8, signed)
//                             w10/w11 = bottom row first (sequencer writes them
//                             into the weight_fifo in the order the MMU expects)
//
//  0x02  LOAD_BIAS     LEN=4  payload: [b0_lo, b0_hi, b1_lo, b1_hi] (int16 LE)
//
//  0x03  LOAD_ACT      LEN=4  payload: [a00, a01, a10, a11]  (int8, signed)
//
//  0x04  RUN           LEN=0  orchestrates the full pipeline; blocks until
//                             both output rows are collected, then sends back:
//                             STATUS=0xAA, LEN=8,
//                             [r0c0_lo, r0c0_hi, r0c1_lo, r0c1_hi,
//                              r1c0_lo, r1c0_hi, r1c1_lo, r1c1_hi]
//
//  0x05  RESET         LEN=0  pulses internal reset for 4 cycles; responds OK
//
//  Pipeline orchestration for RUN
//
//  Steps driven cycle-accurately (matches tpu_core_tb.sv task sequencing):
//
//   1. Write act row 0 → unified_buffer (host_write_addr=0, host_write_valid)
//   2. Write act row 1 → unified_buffer (host_write_addr=1, host_write_valid)
//   3. Write weight bottom row (w10,w11) → weight_fifo shadow bank
//   4. Write weight top row    (w00,w01) → weight_fifo shadow bank
//   5. swap_banks = 1 for 1 cycle
//   6. loading_phase = 1 for 3 cycles  (drains 2-row weight FIFO + 1 guard)
//   7. ub_read_en = 1, addr=0  (row 0 → SDS → MMU)
//   8. ub_read_en = 1, addr=1  (row 1 → SDS → MMU)
//   9. Wait for final_row_valid × 2 (collect both output rows, 50-cycle timeout)
//  10. Pack and transmit 8-byte result via UART TX
//
//  Timing notes
//
//  All internal control signals follow the one-cycle registered latency
//  convention used throughout the rest of the RTL (pe.sv, accumulator.sv …).
//  Steps 3–8 replicate the exact task ordering in tpu_core_tb.sv:
//    load_weights  → trigger_weight_load → stream_activations_from_ub
//
//  Parameters
//
//  WAIT_TIMEOUT — max cycles to wait for two final_row_valid pulses in EXEC_WAIT
//                 before flagging an error.  Default 200 is very conservative;
//                 the real latency is ~15 cycles from stream_activations start.

module tpu_sequencer #(
    parameter int WAIT_TIMEOUT = 200
) (
    input  logic clk,
    input  logic reset,

    input  logic [7:0] rx_data,
    input  logic       rx_valid,

    output logic [7:0] tx_data,
    output logic       tx_valid,
    input  logic       tx_busy,

    output logic              write_enable_col_0,
    output logic signed [7:0] write_data_col_0,
    output logic              write_enable_col_1,
    output logic signed [7:0] write_data_col_1,
    output logic              swap_banks,
    output logic              loading_phase,

    output logic              host_write_addr,
    output logic signed [7:0] host_write_data [2],
    output logic              host_write_valid,

    output logic              ub_read_addr,
    output logic              ub_read_en,

    output logic signed [15:0] out_bias [2],

    input  logic signed [15:0] final_row_out [2],
    input  logic               final_row_valid,

    output logic               tpu_reset,

    output logic               busy          // high while processing a command
);

    localparam logic [7:0] CMD_LOAD_WEIGHTS = 8'h01;
    localparam logic [7:0] CMD_LOAD_BIAS    = 8'h02;
    localparam logic [7:0] CMD_LOAD_ACT     = 8'h03;
    localparam logic [7:0] CMD_RUN          = 8'h04;
    localparam logic [7:0] CMD_RESET        = 8'h05;

    localparam logic [7:0] STATUS_OK  = 8'hAA;
    localparam logic [7:0] STATUS_ERR = 8'hFF;

    localparam int TIMEOUT_W = $clog2(WAIT_TIMEOUT + 1);

    // Persistent register file (survives across commands)
    // Weights are stored as received: [0]=w10,[1]=w11,[2]=w00,[3]=w01
    logic signed [7:0]  reg_weights [4];
    logic signed [7:0]  reg_act     [4];   // [a00,a01,a10,a11]
    logic signed [15:0] reg_bias    [2];

    // Results captured from pipeline
    logic signed [15:0] result_row0 [2];
    logic signed [15:0] result_row1 [2];
    logic                result_ok;

    // FSM states
    typedef enum logic [4:0] {
        S_IDLE          = 5'd0,
        S_RECV_LEN      = 5'd1,
        S_RECV_PAYLOAD  = 5'd2,
        S_EXEC_DISPATCH = 5'd3,

        // RUN substates — match task sequence in tpu_core_tb.sv
        S_WR_UB_0       = 5'd4,
        S_WR_UB_1       = 5'd5,
        S_LD_WF_0       = 5'd6,
        S_LD_WF_1       = 5'd7,
        S_LD_WF_GAP     = 5'd8,   // 1-cycle gap after WF writes
        S_SWAP          = 5'd9,
        S_LOADING_0     = 5'd10,
        S_LOADING_1     = 5'd11,
        S_LOADING_2     = 5'd12,
        S_STREAM_0      = 5'd13,
        S_STREAM_1      = 5'd14,
        S_WAIT          = 5'd15,

        // RESET substate
        S_RESET_PULSE   = 5'd16,

        // TX substates
        S_TX_STATUS     = 5'd17,
        S_TX_LEN        = 5'd18,
        S_TX_DATA       = 5'd19
    } state_t;

    state_t state;

    // Latched CMD / payload
    logic [7:0] cmd_reg;
    logic [7:0] len_reg;
    logic [7:0] byte_cnt;
    logic [7:0] payload [8];

    // TX bookkeeping
    logic [7:0] tx_len_reg;
    logic [7:0] tx_byte_idx;
    logic [7:0] tx_payload [10];

    // WAIT timeout
    logic [TIMEOUT_W-1:0] wait_cnt;
    logic [1:0]            rows_got;

    // RESET pulse counter
    logic [2:0] reset_cnt;

    // Drive out_bias to the datapath at all times
    always_comb begin
        out_bias[0] = reg_bias[0];
        out_bias[1] = reg_bias[1];
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state             <= S_IDLE;
            cmd_reg           <= '0;
            len_reg           <= '0;
            byte_cnt          <= '0;
            for (int i = 0; i < 4; i++) payload[i]     <= '0;
            for (int i = 0; i < 4; i++) reg_weights[i] <= '0;
            for (int i = 0; i < 4; i++) reg_act[i]     <= '0;
            reg_bias[0]       <= '0;
            reg_bias[1]       <= '0;
            result_row0[0]    <= '0; result_row0[1] <= '0;
            result_row1[0]    <= '0; result_row1[1] <= '0;
            result_ok         <= 1'b0;

            write_enable_col_0 <= 1'b0;
            write_data_col_0   <= '0;
            write_enable_col_1 <= 1'b0;
            write_data_col_1   <= '0;
            swap_banks         <= 1'b0;
            loading_phase      <= 1'b0;
            host_write_addr    <= 1'b0;
            host_write_data[0] <= '0;
            host_write_data[1] <= '0;
            host_write_valid   <= 1'b0;
            ub_read_addr       <= 1'b0;
            ub_read_en         <= 1'b0;
            tx_data            <= '0;
            tx_valid           <= 1'b0;
            tx_len_reg         <= '0;
            tx_byte_idx        <= '0;
            wait_cnt           <= '0;
            rows_got           <= '0;
            reset_cnt          <= '0;
            tpu_reset          <= 1'b0;
            busy               <= 1'b0;
        end else begin
            write_enable_col_0 <= 1'b0;
            write_enable_col_1 <= 1'b0;
            swap_banks         <= 1'b0;
            loading_phase      <= 1'b0;
            host_write_valid   <= 1'b0;
            ub_read_en         <= 1'b0;
            tx_valid           <= 1'b0;
            tpu_reset          <= 1'b0;

            // Always capture result rows when the pipeline fires
            if (final_row_valid) begin
                if (rows_got == 2'd0) begin
                    result_row0[0] <= final_row_out[0];
                    result_row0[1] <= final_row_out[1];
                    rows_got       <= 2'd1;
                end else if (rows_got == 2'd1) begin
                    result_row1[0] <= final_row_out[0];
                    result_row1[1] <= final_row_out[1];
                    rows_got       <= 2'd2;
                end
            end

            case (state)

                // IDLE: wait for the first rx byte (the CMD byte)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (rx_valid) begin
                        cmd_reg  <= rx_data;
                        state    <= S_RECV_LEN;
                        busy     <= 1'b1;
                    end
                end

                // RECV_LEN: latch LEN, decide whether to collect payload
                S_RECV_LEN: begin
                    if (rx_valid) begin
                        len_reg  <= rx_data;
                        byte_cnt <= '0;
                        if (rx_data == 8'h00) begin
                            state <= S_EXEC_DISPATCH;
                        end else begin
                            state <= S_RECV_PAYLOAD;
                        end
                    end
                end

                // RECV_PAYLOAD: collect len_reg bytes
                S_RECV_PAYLOAD: begin
                    if (rx_valid) begin
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

                        // LOAD_WEIGHTS: store into reg_weights, ACK immediately
                        CMD_LOAD_WEIGHTS: begin
                            for (int i = 0; i < 4; i++)
                                reg_weights[i] <= signed'(payload[i]);
                            // Build ACK: STATUS_OK, LEN=0
                            tx_payload[0] <= STATUS_OK;
                            tx_payload[1] <= 8'h00;
                            tx_len_reg    <= 8'd2;
                            tx_byte_idx   <= 8'd0;
                            state         <= S_TX_STATUS;
                        end

                        // LOAD_BIAS: unpack two signed 16-bit LE values
                        CMD_LOAD_BIAS: begin
                            reg_bias[0] <= signed'({payload[1], payload[0]});
                            reg_bias[1] <= signed'({payload[3], payload[2]});
                            tx_payload[0] <= STATUS_OK;
                            tx_payload[1] <= 8'h00;
                            tx_len_reg    <= 8'd2;
                            tx_byte_idx   <= 8'd0;
                            state         <= S_TX_STATUS;
                        end

                        // LOAD_ACT: store into reg_act
                        CMD_LOAD_ACT: begin
                            for (int i = 0; i < 4; i++)
                                reg_act[i] <= signed'(payload[i]);
                            tx_payload[0] <= STATUS_OK;
                            tx_payload[1] <= 8'h00;
                            tx_len_reg    <= 8'd2;
                            tx_byte_idx   <= 8'd0;
                            state         <= S_TX_STATUS;
                        end

                        // RUN: start the pipeline orchestration sequence
                        CMD_RUN: begin
                            rows_got  <= 2'd0;
                            result_ok <= 1'b0;
                            wait_cnt  <= '0;
                            state     <= S_WR_UB_0;
                        end

                        // RESET: pulse tpu_reset
                        CMD_RESET: begin
                            reset_cnt <= 3'd0;
                            state     <= S_RESET_PULSE;
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
                // Step 1: write_activations_to_ub — row 0
                S_WR_UB_0: begin
                    host_write_addr    <= 1'b0;
                    host_write_data[0] <= reg_act[0];   // a00
                    host_write_data[1] <= reg_act[1];   // a01
                    host_write_valid   <= 1'b1;
                    state              <= S_WR_UB_1;
                end

                // Step 2: write_activations_to_ub — row 1
                S_WR_UB_1: begin
                    host_write_addr    <= 1'b1;
                    host_write_data[0] <= reg_act[2];   // a10
                    host_write_data[1] <= reg_act[3];   // a11
                    host_write_valid   <= 1'b1;
                    state              <= S_LD_WF_0;
                end

                // Step 3: load_weights — bottom row first (w10, w11)
                S_LD_WF_0: begin
                    write_enable_col_0 <= 1'b1;
                    write_data_col_0   <= reg_weights[0];   // w10
                    write_enable_col_1 <= 1'b1;
                    write_data_col_1   <= reg_weights[1];   // w11
                    state              <= S_LD_WF_1;
                end

                // Step 4: load_weights — top row (w00, w01)
                S_LD_WF_1: begin
                    write_enable_col_0 <= 1'b1;
                    write_data_col_0   <= reg_weights[2];   // w00
                    write_enable_col_1 <= 1'b1;
                    write_data_col_1   <= reg_weights[3];   // w01
                    state              <= S_LD_WF_GAP;
                end

                // Step 4b: one idle cycle after WF writes, before swap
                // (matches: @(posedge clk); #1; in load_weights task)
                S_LD_WF_GAP: begin
                    state <= S_SWAP;
                end

                // Step 5: swap_banks = 1 for 1 cycle
                S_SWAP: begin
                    swap_banks <= 1'b1;
                    state      <= S_LOADING_0;
                end

                // Step 6: loading_phase = 1 for 3 cycles
                S_LOADING_0: begin
                    loading_phase <= 1'b1;
                    state         <= S_LOADING_1;
                end
                S_LOADING_1: begin
                    loading_phase <= 1'b1;
                    state         <= S_LOADING_2;
                end
                S_LOADING_2: begin
                    loading_phase <= 1'b1;
                    state         <= S_STREAM_0;
                end

                // Step 7: ub_read_en addr=0 (row 0 → SDS → MMU)
                S_STREAM_0: begin
                    ub_read_addr <= 1'b0;
                    ub_read_en   <= 1'b1;
                    state        <= S_STREAM_1;
                end

                // Step 8: ub_read_en addr=1 (row 1 → SDS → MMU)
                S_STREAM_1: begin
                    ub_read_addr <= 1'b1;
                    ub_read_en   <= 1'b1;
                    state        <= S_WAIT;
                end

                // Step 9: wait for two final_row_valid pulses (or timeout)
                S_WAIT: begin
                    wait_cnt <= wait_cnt + 1'b1;
                    if (rows_got == 2'd2) begin
                        result_ok <= 1'b1;
                        // Pack response: STATUS_OK, LEN=8, 8 payload bytes
                        tx_payload[0] <= STATUS_OK;
                        tx_payload[1] <= 8'd8;
                        tx_payload[2] <= result_row0[0][7:0];
                        tx_payload[3] <= result_row0[0][15:8];
                        tx_payload[4] <= result_row0[1][7:0];
                        tx_payload[5] <= result_row0[1][15:8];
                        tx_payload[6] <= result_row1[0][7:0];
                        tx_payload[7] <= result_row1[0][15:8];
                        tx_payload[8] <= result_row1[1][7:0];
                        tx_payload[9] <= result_row1[1][15:8];
                        tx_len_reg    <= 8'd10;   // 2 header + 8 data
                        tx_byte_idx   <= 8'd0;
                        state         <= S_TX_STATUS;
                    end else if (wait_cnt == WAIT_TIMEOUT[TIMEOUT_W-1:0]) begin
                        // Timeout — something wrong with pipeline
                        tx_payload[0] <= STATUS_ERR;
                        tx_payload[1] <= 8'h00;
                        tx_len_reg    <= 8'd2;
                        tx_byte_idx   <= 8'd0;
                        state         <= S_TX_STATUS;
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
                // All bytes go through S_TX_DATA; S_TX_STATUS / S_TX_LEN are
                // aliases pointing at index 0 and 1 for readability, but the
                // real logic is the generic byte-loop in S_TX_DATA.

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
