`timescale 1ns / 1ps

import tpu_pkg::*;

// LD engine: data FIFO words -> WMEM, UB, bias and quant tables; and RD_DDR_UB,
// DDR3 rows -> UB entries through ddr_reader
module load_engine #(
    parameter int ARRAY_SIZE              = 8,
    parameter int WMEM_ADDRESS_WIDTH      = 13,
    parameter int UB_ADDRESS_WIDTH        = 14,
    parameter int PARAMETER_ADDRESS_WIDTH = 8,
    parameter int BEAT_BYTES              = 16
) (
    input  logic                               clk,
    input  logic                               reset,

    input  logic                               queue_valid_in,
    input  logic [QUEUE_ENTRY_WIDTH-1:0]       queue_entry_in,
    output logic                               queue_pop_out,
    input  logic [63:0]                        completed_in,
    output logic                               instruction_done_out,

    input  logic                               data_valid_in,
    input  logic                               UB_write_blocked_in,           // ACT owns the UB write port this cycle
    input  logic [31:0]                        data_in,
    output logic                               data_pop_out,

    input  logic                               DDR_request_ready_in,          // ddr_reader
    output logic                               DDR_request_out,
    output logic [31:0]                        DDR_request_address_out,
    output logic [31:0]                        DDR_request_beats_out,
    output logic [3:0]                         DDR_request_skip_out,
    output logic [31:0]                        DDR_request_rows_out,
    input  logic                               DDR_row_valid_in,
    input  logic [ARRAY_SIZE*8-1:0]            DDR_row_data_in,
    output logic                               DDR_row_pop_out,

    output logic                               WMEM_write_enable_out,
    output logic [WMEM_ADDRESS_WIDTH-1:0]      WMEM_write_address_out,
    output logic                               UB_write_enable_out,
    output logic [UB_ADDRESS_WIDTH-1:0]        UB_write_address_out,
    output logic [ARRAY_SIZE*8-1:0]            row_write_data_out,            // WMEM and UB rows
    output logic                               bias_write_enable_out,
    output logic                               quantization_write_enable_out,
    output logic [PARAMETER_ADDRESS_WIDTH-1:0] parameter_write_address_out,
    output logic [ARRAY_SIZE*32-1:0]           parameter_write_data_out,

    output logic                               blocked_out,                   // has work it can't advance (profiler)
    output logic                               idle_out
);

    localparam int WORDS_PER_INT8_ROW = ARRAY_SIZE / 4;

    logic [63:0] instruction, wait_snapshot;
    assign instruction   = queue_entry_in[63:0];
    assign wait_snapshot = queue_entry_in[127:64];
    logic [5:0] opcode;
    assign opcode = instruction[63:58];

    logic                     busy;
    logic [5:0]               current_opcode;
    logic [16:0]              items_left;
    logic [15:0]              write_address;
    logic [7:0]               word_index;
    logic [ARRAY_SIZE*32-1:0] item_buffer;

    logic writes_int8_rows;
    assign writes_int8_rows = (current_opcode == OPCODE_WR_WMEM || current_opcode == OPCODE_WR_UB);
    logic [7:0] words_per_item;
    assign words_per_item = writes_int8_rows ? 8'(WORDS_PER_INT8_ROW) : 8'(ARRAY_SIZE);

    // the item including the word arriving this cycle
    logic [ARRAY_SIZE*32-1:0] assembled_item;
    always_comb begin
        assembled_item                      = item_buffer;
        assembled_item[32*word_index +: 32] = data_in;
    end

    logic is_last_word;
    assign is_last_word = (word_index == words_per_item - 8'd1);

    // RD_DDR_UB: whole beats from the one holding the first entry; the
    // entries before it in that beat are skipped (the address is entry-aligned)
    logic        reading_DDR, item_done;
    logic [31:0] DDR_address, DDR_bytes;
    assign reading_DDR             = busy && current_opcode == OPCODE_RD_DDR_UB;
    assign DDR_address             = instruction[31:0];
    localparam int BEAT_SHIFT = $clog2(BEAT_BYTES);
    logic [31:0] DDR_offset;                                  // the first entry's byte within its beat
    assign DDR_offset              = DDR_address & 32'(BEAT_BYTES - 1);
    assign DDR_bytes               = DDR_offset + (32'(instruction[43:32]) + 32'd1) * 32'(ARRAY_SIZE);
    assign DDR_request_out         = queue_pop_out && opcode == OPCODE_RD_DDR_UB;
    assign DDR_request_address_out = DDR_address & ~32'(BEAT_BYTES - 1);
    assign DDR_request_beats_out   = (DDR_bytes + 32'(BEAT_BYTES - 1)) >> BEAT_SHIFT;
    assign DDR_request_skip_out    = 4'(DDR_offset / 32'(ARRAY_SIZE));
    assign DDR_request_rows_out    = 32'(instruction[43:32]) + 32'd1;
    // ACT owns the UB write port when it writes, as for WR_UB
    assign DDR_row_pop_out         = reading_DDR && DDR_row_valid_in && !UB_write_blocked_in;

    // hold a UB entry's last word while ACT is writing the UB
    assign data_pop_out             = busy && !reading_DDR && data_valid_in
                                      && !(is_last_word && current_opcode == OPCODE_WR_UB && UB_write_blocked_in);
    assign row_write_data_out       = reading_DDR ? DDR_row_data_in : assembled_item[ARRAY_SIZE*8-1:0];
    assign parameter_write_data_out = assembled_item;
    assign item_done                = DDR_row_pop_out || (data_pop_out && is_last_word);

    always_comb begin
        WMEM_write_enable_out         = data_pop_out && is_last_word && current_opcode == OPCODE_WR_WMEM;
        UB_write_enable_out           = (data_pop_out && is_last_word && current_opcode == OPCODE_WR_UB) || DDR_row_pop_out;
        bias_write_enable_out         = data_pop_out && is_last_word && current_opcode == OPCODE_WR_BIAS;
        quantization_write_enable_out = data_pop_out && is_last_word && current_opcode == OPCODE_WR_QUANT;
        WMEM_write_address_out        = WMEM_ADDRESS_WIDTH'(write_address);
        UB_write_address_out          = UB_ADDRESS_WIDTH'(write_address);
        parameter_write_address_out   = PARAMETER_ADDRESS_WIDTH'(write_address);
    end

    logic wait_satisfied;
    assign wait_satisfied = wait_counts_reached(instruction[51:48], wait_snapshot, completed_in);
    assign queue_pop_out  = queue_valid_in && !busy && (opcode != OPCODE_WAIT || wait_satisfied)
                            && (opcode != OPCODE_RD_DDR_UB || DDR_request_ready_in);
    assign idle_out       = !busy && !queue_valid_in;
    // a WAIT not yet satisfied, the DDR3 reader not ready, or mid-instruction with no word or row to take
    assign blocked_out    = (queue_valid_in && !busy && !queue_pop_out) || (busy && !data_pop_out && !DDR_row_pop_out);

    always_ff @(posedge clk) begin
        if (reset) begin
            busy                 <= 1'b0;
            current_opcode       <= OPCODE_NOP;
            items_left           <= '0;
            write_address        <= '0;
            word_index           <= '0;
            item_buffer          <= '0;
            instruction_done_out <= 1'b0;
        end else begin
            instruction_done_out <= 1'b0;
            if (queue_pop_out) begin
                if (opcode == OPCODE_WAIT) begin
                    instruction_done_out <= 1'b1;
                end else begin
                    busy           <= 1'b1;
                    current_opcode <= opcode;
                    word_index     <= '0;
                    case (opcode)
                        OPCODE_WR_WMEM: begin write_address <= instruction[47:32];        items_left <= 17'(instruction[15:0]) + 1; end
                        OPCODE_WR_UB:   begin write_address <= 16'(instruction[45:32]);   items_left <= 17'(instruction[11:0]) + 1; end
                        OPCODE_RD_DDR_UB: begin write_address <= 16'(instruction[57:44]); items_left <= 17'(instruction[43:32]) + 1; end
                        default:        begin write_address <= 16'(instruction[39:32]);   items_left <= 17'(instruction[7:0]) + 1; end
                    endcase
                end
            end
            if (item_done) begin
                word_index    <= '0;
                write_address <= write_address + 16'd1;
                if (items_left == 17'd1) begin
                    busy                 <= 1'b0;
                    instruction_done_out <= 1'b1;
                end
                items_left <= items_left - 17'd1;
            end else if (data_pop_out) begin
                item_buffer <= assembled_item;
                word_index  <= word_index + 8'd1;
            end
        end
    end

endmodule
