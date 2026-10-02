`timescale 1ns / 1ps

import tpu_pkg::*;

// dispatcher: decodes in order, one instruction per cycle, into four engine queues
module dispatch #(
    parameter int ARRAY_SIZE      = 8,
    parameter int WMEM_ROWS       = 8192,
    parameter int UB_DEPTH        = 16384,
    parameter int ACC_DEPTH       = 1024,
    parameter int PARAMETER_DEPTH = 256
) (
    input  logic                         clk,
    input  logic                         reset,

    input  logic                         instruction_valid_in,
    input  logic [63:0]                  instruction_in,
    output logic                         instruction_pop_out,

    // queue pushes, one entry per engine
    output logic [3:0]                   queue_push_out,
    output logic [QUEUE_ENTRY_WIDTH-1:0] queue_entry_out,
    input  logic [3:0]                   queue_full_in,

    input  logic [63:0]                  completed_in,         // 4 x 16-bit, from the engines
    output logic [63:0]                  dispatched_out,

    output logic                         error_out,
    output logic [7:0]                   error_code_out,
    output logic [31:0]                  error_sequence_out,
    output logic                         done_out,
    output logic [15:0]                  tag_out,
    input  logic                         clear_done_in,
    output logic                         fence_pending_out
);

    logic [31:0] instruction_sequence;
    logic [31:0] weight_base;          // shadow of WT's WBASE, for weight range checks
    logic        fence_pending;
    logic [15:0] fence_tag;

    // -- decode -------------------------------------------------------------
    logic [5:0] opcode;
    assign opcode = instruction_in[63:58];

    logic [63:0] legal_bit_mask;
    logic        opcode_known;
    always_comb begin
        opcode_known = 1'b1;
        case (opcode)
            OPCODE_NOP:                         legal_bit_mask = MASK_NOP;
            OPCODE_WR_WMEM:                     legal_bit_mask = MASK_WR_WMEM;
            OPCODE_WR_UB, OPCODE_RD_UB:         legal_bit_mask = MASK_WR_UB;
            OPCODE_WR_BIAS, OPCODE_WR_QUANT:    legal_bit_mask = MASK_WR_PARAMETER;
            OPCODE_RD_DDR_UB:                   legal_bit_mask = MASK_RD_DDR_UB;
            OPCODE_SET_WBASE, OPCODE_SET_OBASE: legal_bit_mask = MASK_SET_32_BIT;
            OPCODE_MATMUL:                      legal_bit_mask = MASK_MATMUL;
            OPCODE_ACTIVATE:                    legal_bit_mask = MASK_ACTIVATE;
            OPCODE_WAIT:                        legal_bit_mask = MASK_WAIT;
            OPCODE_SIGNAL:                      legal_bit_mask = MASK_SIGNAL;
            default:                            begin legal_bit_mask = '0; opcode_known = 1'b0; end
        endcase
    end

    // fields (counts stored minus one)
    logic [63:0] field_row_count, field_UB_count, field_parameter_count, field_activate_block_count;
    logic [8:0]  field_matmul_rows, field_activate_rows;
    logic [12:0] field_k_tiles;
    logic [10:0] field_block_count;
    logic [63:0] field_WMEM_row, field_UB_address, field_parameter_index, field_ACC_address, field_matmul_UB_address, field_activate_ACC_address, field_activate_UB_address, field_activate_parameter_index;
    logic [1:0]  field_function, field_destination;
    logic        field_requantize, field_bias, field_weight_source;
    always_comb begin
        field_row_count                = 64'(instruction_in[15:0]) + 1;
        field_UB_count                 = 64'(instruction_in[11:0]) + 1;
        field_parameter_count          = 64'(instruction_in[7:0]) + 1;
        field_WMEM_row                 = 64'(instruction_in[47:32]);
        field_UB_address               = 64'(instruction_in[45:32]);
        field_parameter_index          = 64'(instruction_in[39:32]);
        field_weight_source            = instruction_in[56];
        field_matmul_rows              = 9'(instruction_in[55:48]) + 9'd1;
        field_k_tiles                  = 13'(instruction_in[47:36]) + 13'd1;
        field_block_count              = 11'(instruction_in[35:26]) + 11'd1;
        field_ACC_address              = 64'(instruction_in[25:16]);
        field_matmul_UB_address        = 64'(instruction_in[15:2]);
        field_function                 = instruction_in[57:56];
        field_requantize               = instruction_in[55];
        field_destination              = instruction_in[54:53];
        field_bias                     = instruction_in[52];
        field_activate_block_count     = 64'(instruction_in[51:42]) + 1;
        field_activate_rows            = 9'(instruction_in[41:34]) + 9'd1;
        field_activate_ACC_address     = 64'(instruction_in[33:24]);
        field_activate_UB_address      = 64'(instruction_in[23:10]);
        field_activate_parameter_index = 64'(instruction_in[9:2]);
    end

    // products at their real widths: 64-bit operands made Quartus build 64x64 DSP multipliers
    logic [23:0] product_block_count_k_tiles;
    logic [20:0] product_block_count_rows, product_activate_block_count_rows;
    logic [21:0] product_k_tiles_rows;
    assign product_block_count_k_tiles       = 24'(field_block_count) * 24'(field_k_tiles);
    assign product_block_count_rows          = 21'(field_block_count) * 21'(field_matmul_rows);
    assign product_k_tiles_rows              = 22'(field_k_tiles) * 22'(field_matmul_rows);
    assign product_activate_block_count_rows = 21'(field_activate_block_count[10:0]) * 21'(field_activate_rows);

    logic [7:0] decode_error;
    always_comb begin
        decode_error = ERROR_NONE;
        if (!opcode_known)
            decode_error = ERROR_OPCODE;
        else if ((instruction_in & ~legal_bit_mask) != 0)
            decode_error = ERROR_RESERVED;
        else if (opcode == OPCODE_ACTIVATE && (field_function[1] || field_destination == 2'd3))
            decode_error = ERROR_RESERVED;
        else if (opcode == OPCODE_RD_DDR_UB || opcode == OPCODE_SET_OBASE
                 || (opcode == OPCODE_MATMUL && field_weight_source)
                 || (opcode == OPCODE_ACTIVATE && field_destination == DESTINATION_DDR))
            decode_error = ERROR_UNIMPLEMENTED;   // DDR3 is phase 5
        else if (opcode == OPCODE_ACTIVATE && field_destination == DESTINATION_UB && !field_requantize)
            decode_error = ERROR_COMBINATION;
        else case (opcode)
            OPCODE_WR_WMEM:  if (field_WMEM_row + field_row_count > 64'(WMEM_ROWS)) decode_error = ERROR_RANGE;
            OPCODE_WR_UB,
            OPCODE_RD_UB:    if (field_UB_address + field_UB_count > 64'(UB_DEPTH)) decode_error = ERROR_RANGE;
            OPCODE_WR_BIAS,
            OPCODE_WR_QUANT: if (field_parameter_index + field_parameter_count > 64'(PARAMETER_DEPTH)) decode_error = ERROR_RANGE;
            OPCODE_MATMUL:   if (field_ACC_address + 64'(product_block_count_rows) > 64'(ACC_DEPTH)
                             || field_matmul_UB_address + 64'(product_k_tiles_rows) > 64'(UB_DEPTH)
                             || (64'(weight_base) + 64'(product_block_count_k_tiles)) * ARRAY_SIZE > 64'(WMEM_ROWS)) decode_error = ERROR_RANGE;
            OPCODE_ACTIVATE: if (field_activate_ACC_address + 64'(product_activate_block_count_rows) > 64'(ACC_DEPTH)
                             || ((field_bias || field_requantize) && field_activate_parameter_index + field_activate_block_count > 64'(PARAMETER_DEPTH))
                             || (field_destination == DESTINATION_UB && field_activate_UB_address + 64'(product_activate_block_count_rows) > 64'(UB_DEPTH)))
                             decode_error = ERROR_RANGE;
            default: ;
        endcase
    end

    // which queues an instruction goes to
    logic [3:0] target_queues;
    always_comb begin
        case (opcode)
            OPCODE_WR_WMEM, OPCODE_WR_UB, OPCODE_WR_BIAS, OPCODE_WR_QUANT: target_queues = 4'b0001;
            OPCODE_SET_WBASE:                                              target_queues = 4'b0010;
            OPCODE_MATMUL:                                                 target_queues = 4'b0110;
            OPCODE_ACTIVATE, OPCODE_RD_UB:                                 target_queues = 4'b1000;
            OPCODE_WAIT:                                                   target_queues = 4'b0001 << instruction_in[57:56];
            default:                                                       target_queues = 4'b0000;   // NOP, SIGNAL
        endcase
    end

    logic all_engines_quiet;
    assign all_engines_quiet = (completed_in == dispatched_out);

    logic dispatch_now;
    assign dispatch_now = instruction_valid_in && !error_out && !fence_pending && decode_error == ERROR_NONE && (target_queues & queue_full_in) == 0;

    assign instruction_pop_out = dispatch_now;
    assign queue_push_out      = dispatch_now ? target_queues : 4'b0000;
    // a WAIT carries the counts dispatched so far, not including itself
    assign queue_entry_out   = {dispatched_out, instruction_in};
    assign fence_pending_out = fence_pending;

    always_ff @(posedge clk) begin
        if (reset) begin
            instruction_sequence <= '0;
            weight_base          <= '0;
            fence_pending        <= 1'b0;
            fence_tag            <= '0;
            dispatched_out       <= '0;
            error_out            <= 1'b0;
            error_code_out       <= '0;
            error_sequence_out   <= '0;
            done_out             <= 1'b0;
            tag_out              <= '0;
        end else begin
            if (clear_done_in)
                done_out <= 1'b0;

            if (instruction_valid_in && !error_out && !fence_pending && decode_error != ERROR_NONE) begin
                error_out          <= 1'b1;
                error_code_out     <= decode_error;
                error_sequence_out <= instruction_sequence;
            end

            if (dispatch_now) begin
                instruction_sequence <= instruction_sequence + 1;
                for (int engine = 0; engine < 4; engine++)
                    if (target_queues[engine])
                        dispatched_out[16*engine +: 16] <= dispatched_out[16*engine +: 16] + 16'd1;
                if (opcode == OPCODE_SET_WBASE)
                    weight_base <= instruction_in[31:0];
                else if (opcode == OPCODE_MATMUL)
                    weight_base <= weight_base + 32'(product_block_count_k_tiles);
                if (opcode == OPCODE_SIGNAL) begin
                    fence_pending <= 1'b1;
                    fence_tag     <= instruction_in[15:0];
                end
            end

            if (fence_pending && all_engines_quiet) begin
                fence_pending <= 1'b0;
                done_out      <= 1'b1;
                tag_out       <= fence_tag;
            end
        end
    end

endmodule
