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

    input  logic                               queue_valid,
    input  logic [QUEUE_ENTRY_WIDTH-1:0]       queue_entry,
    output logic                               queue_pop,
    input  logic [63:0]                        completed,
    output logic                               instruction_done,

    output logic [ACC_ADDRESS_WIDTH-1:0]       ACC_read_address,
    input  logic                               ACC_read_blocked,       // MM owns the port this cycle

    output logic [PARAMETER_ADDRESS_WIDTH-1:0] parameter_read_address, // the bias and quant tables
    output logic                               use_bias,               // bias unit
    output logic                               relu,                   // activation unit
    input  logic [ARRAY_SIZE*32-1:0]           activation_row,         //   biased, ReLU'd: stage 1
    output logic                               multiply_enable,        //   stage 2 multiplies row
    output logic [ARRAY_SIZE*32-1:0]           multiply_in,
    input  logic [ARRAY_SIZE*8-1:0]            quantized_row,          //   stage 3

    output logic                               UB_write_enable,
    output logic [UB_ADDRESS_WIDTH-1:0]        UB_write_address,
    output logic [ARRAY_SIZE*8-1:0]            UB_write_data,

    output logic                               UB_read_enable,
    output logic [UB_ADDRESS_WIDTH-1:0]        UB_read_address,
    input  logic                               UB_read_blocked,
    input  logic [ARRAY_SIZE*8-1:0]            UB_read_data,

    output logic                               output_push,
    output logic [31:0]                        output_word,
    input  logic                               output_full,

    output logic                               idle
);

    localparam int WORDS_PER_ROW = ARRAY_SIZE / 4;

    logic [63:0] instruction, wait_snapshot;
    assign instruction   = queue_entry[63:0];
    assign wait_snapshot = queue_entry[127:64];
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

    assign ACC_read_address       = ACC_ADDRESS_WIDTH'(row_address);
    assign UB_read_address        = UB_ADDRESS_WIDTH'(row_address);
    assign parameter_read_address = PARAMETER_ADDRESS_WIDTH'(parameter_index);
    assign UB_read_enable         = state == S_READ && is_read_UB && !UB_read_blocked;
    assign multiply_enable        = state == S_MULTIPLY;
    assign multiply_in            = row;

    logic [7:0] words_per_row;
    assign words_per_row = (is_read_UB || requantize) ? 8'(WORDS_PER_ROW) : 8'(ARRAY_SIZE);

    assign UB_write_enable  = state == S_WRITE;
    assign UB_write_address = UB_ADDRESS_WIDTH'(UB_output_address);
    assign UB_write_data    = row[ARRAY_SIZE*8-1:0];
    assign output_push      = state == S_EMIT && !output_full;
    assign output_word      = row[32*word +: 32];

    logic wait_satisfied;
    assign wait_satisfied = wait_counts_reached(instruction[51:48], wait_snapshot, completed);
    assign queue_pop      = queue_valid && state == S_IDLE && (opcode != OPCODE_WAIT || wait_satisfied);
    assign idle           = state == S_IDLE && !queue_valid;

    always_ff @(posedge clk) begin
        if (reset) begin
            state             <= S_IDLE;
            is_read_UB        <= 1'b0;
            relu              <= 1'b0;
            use_bias          <= 1'b0;
            activation_rows   <= '0;
            block_count       <= '0;
            block_index       <= '0;
            row_in_block      <= '0;
            row_address       <= '0;
            items_left        <= '0;
            parameter_index   <= '0;
            word              <= '0;
            row               <= '0;
            requantize        <= 1'b0;
            to_UB             <= 1'b0;
            UB_output_address <= '0;
            instruction_done  <= 1'b0;
        end else begin
            instruction_done <= 1'b0;
            case (state)
                S_IDLE: if (queue_pop) begin
                    if (opcode == OPCODE_ACTIVATE) begin
                        is_read_UB        <= 1'b0;
                        requantize        <= instruction[55];
                        to_UB             <= instruction[54:53] == DESTINATION_UB;
                        UB_output_address <= 16'(instruction[23:10]);
                        relu              <= instruction[57:56] == 2'd1;
                        use_bias          <= instruction[52];
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
                        instruction_done <= 1'b1;            // WAIT
                    end
                end
                S_READ: if (is_read_UB ? !UB_read_blocked : !ACC_read_blocked) state <= S_LATCH;
                S_LATCH: begin                         // read data valid this cycle
                    row   <= is_read_UB ? (ARRAY_SIZE*32)'(UB_read_data) : activation_row;
                    word  <= '0;
                    state <= requantize ? S_MULTIPLY : to_UB ? S_WRITE : S_EMIT;
                end
                S_MULTIPLY: state <= S_ROUND;                 // the activation unit multiplies row
                S_ROUND: begin
                    row   <= (ARRAY_SIZE*32)'(quantized_row);
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
                            state            <= S_IDLE;
                            instruction_done <= 1'b1;
                        end
                        block_index <= block_index + 11'd1;
                    end else begin
                        row_in_block <= row_in_block + 9'd1;
                    end
                end
                S_EMIT: if (output_push) begin
                    if (word == words_per_row - 8'd1) begin
                        row_address <= row_address + 16'd1;
                        state       <= S_READ;
                        if (is_read_UB) begin
                            items_left <= items_left - 16'd1;
                            if (items_left == 16'd1) begin
                                state            <= S_IDLE;
                                instruction_done <= 1'b1;
                            end
                        end else if (row_in_block == activation_rows - 9'd1) begin
                            row_in_block    <= '0;
                            parameter_index <= parameter_index + 8'd1;
                            if (block_index == block_count - 11'd1) begin
                                state            <= S_IDLE;
                                instruction_done <= 1'b1;
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
