`timescale 1ns / 1ps

import tpu_pkg::*;

// ACT engine: ACC rows -> bias -> ReLU/identity -> optional requantize -> UB or
// host out FIFO, plus RD_UB. control only: tpu_core wires the bias and activation
// units. shares the ACC and UB read ports with MM, which has priority there; ACT
// has priority on the UB write port
module activate_engine #(
    parameter int ARRAY_SIZE              = 8,
    parameter int UB_ADDRESS_WIDTH        = 14,
    parameter int ACC_ADDRESS_WIDTH       = 10,
    parameter int PARAMETER_ADDRESS_WIDTH = 8
) (
    input  logic                               clk,
    input  logic                               reset,

    input  logic                               queue_valid_in,
    input  logic [QUEUE_ENTRY_WIDTH-1:0]       queue_entry_in,
    output logic                               queue_pop_out,
    input  logic [63:0]                        completed_in,
    output logic                               instruction_done_out,

    output logic [ACC_ADDRESS_WIDTH-1:0]       ACC_read_address_out,
    input  logic                               ACC_read_blocked_in,        // MM owns the port this cycle

    output logic [PARAMETER_ADDRESS_WIDTH-1:0] parameter_read_address_out, // the bias and quant tables
    output logic                               bias_enable_out,            // bias unit
    output logic                               relu_enable_out,            // activation unit
    input  logic [ARRAY_SIZE*32-1:0]           activation_row_in,          //   biased, ReLU'd: stage 1
    output logic                               multiply_enable_out,        //   stage 2 multiplies row
    output logic [ARRAY_SIZE*32-1:0]           multiply_row_out,
    input  logic [ARRAY_SIZE*8-1:0]            quantized_row_in,           //   stage 3

    output logic                               UB_write_enable_out,
    output logic [UB_ADDRESS_WIDTH-1:0]        UB_write_address_out,
    output logic [ARRAY_SIZE*8-1:0]            UB_write_data_out,

    output logic                               UB_read_enable_out,
    output logic [UB_ADDRESS_WIDTH-1:0]        UB_read_address_out,
    input  logic                               UB_read_blocked_in,
    input  logic [ARRAY_SIZE*8-1:0]            UB_read_data_in,

    output logic                               output_push_out,
    output logic [31:0]                        output_word_out,
    input  logic                               output_full_in,

    output logic                               idle_out
);

    localparam int WORDS_PER_ROW = ARRAY_SIZE / 4;

    logic [63:0] instruction, wait_snapshot;
    assign instruction   = queue_entry_in[63:0];
    assign wait_snapshot = queue_entry_in[127:64];
    logic [5:0] opcode;
    assign opcode = instruction[63:58];

    typedef enum logic [2:0] {S_IDLE, S_READ, S_LATCH, S_MULTIPLY, S_ROUND, S_EMIT, S_WRITE} state_t;
    state_t state;

    logic                     is_read_UB;
    logic                     requantize, to_UB;
    logic [15:0]              UB_output_address;
    logic [8:0]               activation_rows;
    logic [10:0]              block_count, block_index;
    logic [8:0]               row_in_block;
    logic [15:0]              row_address;              // ACC row, or UB entry for RD_UB
    logic [15:0]              items_left;               // RD_UB entries
    logic [7:0]               parameter_index;
    logic [7:0]               word;                     // word within the row being emitted
    logic [ARRAY_SIZE*32-1:0] row;                      // computed row, one word per column (or packed int8)

    assign ACC_read_address_out       = ACC_ADDRESS_WIDTH'(row_address);
    assign UB_read_address_out        = UB_ADDRESS_WIDTH'(row_address);
    assign parameter_read_address_out = PARAMETER_ADDRESS_WIDTH'(parameter_index);
    assign UB_read_enable_out         = state == S_READ && is_read_UB && !UB_read_blocked_in;
    assign multiply_enable_out        = state == S_MULTIPLY;
    assign multiply_row_out           = row;

    logic [7:0] words_per_row;
    assign words_per_row = (is_read_UB || requantize) ? 8'(WORDS_PER_ROW) : 8'(ARRAY_SIZE);

    assign UB_write_enable_out  = state == S_WRITE;
    assign UB_write_address_out = UB_ADDRESS_WIDTH'(UB_output_address);
    assign UB_write_data_out    = row[ARRAY_SIZE*8-1:0];
    assign output_push_out      = state == S_EMIT && !output_full_in;
    assign output_word_out      = row[32*word +: 32];

    logic wait_satisfied;
    assign wait_satisfied = wait_counts_reached(instruction[51:48], wait_snapshot, completed_in);
    assign queue_pop_out  = queue_valid_in && state == S_IDLE && (opcode != OPCODE_WAIT || wait_satisfied);
    assign idle_out       = state == S_IDLE && !queue_valid_in;

    always_ff @(posedge clk) begin
        if (reset) begin
            state                <= S_IDLE;
            is_read_UB           <= 1'b0;
            relu_enable_out      <= 1'b0;
            bias_enable_out      <= 1'b0;
            activation_rows      <= '0;
            block_count          <= '0;
            block_index          <= '0;
            row_in_block         <= '0;
            row_address          <= '0;
            items_left           <= '0;
            parameter_index      <= '0;
            word                 <= '0;
            row                  <= '0;
            requantize           <= 1'b0;
            to_UB                <= 1'b0;
            UB_output_address    <= '0;
            instruction_done_out <= 1'b0;
        end else begin
            instruction_done_out <= 1'b0;
            case (state)
                S_IDLE: if (queue_pop_out) begin
                    if (opcode == OPCODE_ACTIVATE) begin
                        is_read_UB        <= 1'b0;
                        requantize        <= instruction[55];
                        to_UB             <= instruction[54:53] == DESTINATION_UB;
                        UB_output_address <= 16'(instruction[23:10]);
                        relu_enable_out   <= instruction[57:56] == 2'd1;
                        bias_enable_out   <= instruction[52];
                        block_count       <= 11'(instruction[51:42]) + 11'd1;
                        activation_rows   <= 9'(instruction[41:34]) + 9'd1;
                        row_address       <= 16'(instruction[33:24]);
                        parameter_index   <= instruction[9:2];
                        block_index       <= '0;
                        row_in_block      <= '0;
                        state             <= S_READ;
                    end else if (opcode == OPCODE_RD_UB) begin
                        is_read_UB  <= 1'b1;
                        requantize  <= 1'b0;
                        to_UB       <= 1'b0;
                        row_address <= 16'(instruction[45:32]);
                        items_left  <= 16'(instruction[11:0]) + 16'd1;
                        state       <= S_READ;
                    end else begin
                        instruction_done_out <= 1'b1;            // WAIT
                    end
                end
                S_READ: if (is_read_UB ? !UB_read_blocked_in : !ACC_read_blocked_in) state <= S_LATCH;
                S_LATCH: begin                         // read data valid this cycle
                    row   <= is_read_UB ? (ARRAY_SIZE*32)'(UB_read_data_in) : activation_row_in;
                    word  <= '0;
                    state <= requantize ? S_MULTIPLY : to_UB ? S_WRITE : S_EMIT;
                end
                S_MULTIPLY: state <= S_ROUND;                 // the activation unit multiplies row
                S_ROUND: begin
                    row   <= (ARRAY_SIZE*32)'(quantized_row_in);
                    state <= to_UB ? S_WRITE : S_EMIT;
                end
                S_WRITE: begin                         // one UB entry per row
                    UB_output_address <= UB_output_address + 16'd1;
                    row_address       <= row_address + 16'd1;
                    state             <= S_READ;
                    if (row_in_block == activation_rows - 9'd1) begin
                        row_in_block    <= '0;
                        parameter_index <= parameter_index + 8'd1;
                        if (block_index == block_count - 11'd1) begin
                            state                <= S_IDLE;
                            instruction_done_out <= 1'b1;
                        end
                        block_index <= block_index + 11'd1;
                    end else begin
                        row_in_block <= row_in_block + 9'd1;
                    end
                end
                S_EMIT: if (output_push_out) begin
                    if (word == words_per_row - 8'd1) begin
                        row_address <= row_address + 16'd1;
                        state       <= S_READ;
                        if (is_read_UB) begin
                            items_left <= items_left - 16'd1;
                            if (items_left == 16'd1) begin
                                state                <= S_IDLE;
                                instruction_done_out <= 1'b1;
                            end
                        end else if (row_in_block == activation_rows - 9'd1) begin
                            row_in_block    <= '0;
                            parameter_index <= parameter_index + 8'd1;
                            if (block_index == block_count - 11'd1) begin
                                state                <= S_IDLE;
                                instruction_done_out <= 1'b1;
                            end
                            block_index <= block_index + 11'd1;
                        end else begin
                            row_in_block <= row_in_block + 9'd1;
                        end
                    end else begin
                        word <= word + 8'd1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
