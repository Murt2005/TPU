`timescale 1ns / 1ps

import tpu_pkg::*;

// LD engine: data FIFO words -> WMEM, UB, bias and quant tables
module load_engine #(
    parameter int ARRAY_SIZE              = 8,
    parameter int WMEM_ADDRESS_WIDTH      = 13,
    parameter int UB_ADDRESS_WIDTH        = 14,
    parameter int PARAMETER_ADDRESS_WIDTH = 8
) (
    input  logic                               clk,
    input  logic                               reset,

    input  logic                               queue_valid,
    input  logic [QUEUE_ENTRY_WIDTH-1:0]       queue_entry,
    output logic                               queue_pop,
    input  logic [63:0]                        completed,
    output logic                               instruction_done,

    input  logic                               data_valid,
    input  logic                               UB_write_blocked,          // ACT owns the UB write port this cycle
    input  logic [31:0]                        data,
    output logic                               data_pop,

    output logic                               WMEM_write_enable,
    output logic [WMEM_ADDRESS_WIDTH-1:0]      WMEM_write_address,
    output logic                               UB_write_enable,
    output logic [UB_ADDRESS_WIDTH-1:0]        UB_write_address,
    output logic [ARRAY_SIZE*8-1:0]            row_write_data,            // WMEM and UB rows
    output logic                               bias_write_enable,
    output logic                               quantization_write_enable,
    output logic [PARAMETER_ADDRESS_WIDTH-1:0] parameter_write_address,
    output logic [ARRAY_SIZE*32-1:0]           parameter_write_data,

    output logic                               idle
);

    localparam int WORDS_PER_ROW = ARRAY_SIZE / 4; // words per int8 row

    logic [63:0] instruction, wait_snapshot;
    assign instruction   = queue_entry[63:0];
    assign wait_snapshot = queue_entry[127:64];
    logic [5:0] opcode;
    assign opcode = instruction[63:58];

    logic                     busy;
    logic [5:0]               current_opcode;
    logic [16:0]              items_left;
    logic [15:0]              address;
    logic [7:0]               word_index;
    logic [ARRAY_SIZE*32-1:0] buffer;

    logic int8_rows;
    assign int8_rows = (current_opcode == OPCODE_WR_WMEM || current_opcode == OPCODE_WR_UB);
    logic [7:0] words_per_item;
    assign words_per_item = int8_rows ? 8'(WORDS_PER_ROW) : 8'(ARRAY_SIZE);

    // the item including the word arriving this cycle
    logic [ARRAY_SIZE*32-1:0] item;
    always_comb begin
        item = buffer;
        item[32*word_index +: 32] = data;
    end

    logic last_word;
    assign last_word = (word_index == words_per_item - 8'd1);

    // hold a UB entry's last word while ACT is writing the UB
    assign data_pop             = busy && data_valid && !(last_word && current_opcode == OPCODE_WR_UB && UB_write_blocked);
    assign row_write_data       = item[ARRAY_SIZE*8-1:0];
    assign parameter_write_data = item;

    always_comb begin
        WMEM_write_enable  = data_pop && last_word && current_opcode == OPCODE_WR_WMEM;
        UB_write_enable    = data_pop && last_word && current_opcode == OPCODE_WR_UB;
        bias_write_enable  = data_pop && last_word && current_opcode == OPCODE_WR_BIAS;
        quantization_write_enable = data_pop && last_word && current_opcode == OPCODE_WR_QUANT;
        WMEM_write_address = WMEM_ADDRESS_WIDTH'(address);
        UB_write_address   = UB_ADDRESS_WIDTH'(address);
        parameter_write_address  = PARAMETER_ADDRESS_WIDTH'(address);
    end

    logic wait_satisfied;
    assign wait_satisfied = wait_counts_reached(instruction[51:48], wait_snapshot, completed);
    assign queue_pop      = queue_valid && !busy && (opcode != OPCODE_WAIT || wait_satisfied);
    assign idle           = !busy && !queue_valid;

    always_ff @(posedge clk) begin
        if (reset) begin
            busy             <= 1'b0;
            current_opcode   <= OPCODE_NOP;
            items_left       <= '0;
            address          <= '0;
            word_index       <= '0;
            buffer           <= '0;
            instruction_done <= 1'b0;
        end else begin
            instruction_done <= 1'b0;
            if (queue_pop) begin
                if (opcode == OPCODE_WAIT) begin
                    instruction_done <= 1'b1;
                end else begin
                    busy           <= 1'b1;
                    current_opcode <= opcode;
                    word_index     <= '0;
                    case (opcode)
                        OPCODE_WR_WMEM: begin address <= instruction[47:32];        items_left <= 17'(instruction[15:0]) + 1; end
                        OPCODE_WR_UB:   begin address <= 16'(instruction[45:32]);   items_left <= 17'(instruction[11:0]) + 1; end
                        default:        begin address <= 16'(instruction[39:32]);   items_left <= 17'(instruction[7:0]) + 1; end
                    endcase
                end
            end
            if (data_pop) begin
                if (last_word) begin
                    word_index <= '0;
                    address    <= address + 16'd1;
                    if (items_left == 17'd1) begin
                        busy             <= 1'b0;
                        instruction_done <= 1'b1;
                    end
                    items_left <= items_left - 17'd1;
                end else begin
                    buffer     <= item;
                    word_index <= word_index + 8'd1;
                end
            end
        end
    end

endmodule
