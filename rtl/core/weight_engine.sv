`timescale 1ns / 1ps

import tpu_pkg::*;

// WT engine: SET_WBASE, and the weight half of MATMUL: WMEM tiles into the weight
// FIFO's slots, one row read per cycle, back to back across tiles while a slot is free
module weight_engine #(
    parameter int ARRAY_SIZE         = 8,
    parameter int WMEM_ADDRESS_WIDTH = 13
) (
    input  logic                          clk,
    input  logic                          reset,

    input  logic                          queue_valid_in,
    input  logic [QUEUE_ENTRY_WIDTH-1:0]  queue_entry_in,
    output logic                          queue_pop_out,
    input  logic [63:0]                   completed_in,
    output logic                          instruction_done_out,

    output logic [WMEM_ADDRESS_WIDTH-1:0] WMEM_read_address_out,
    input  logic [ARRAY_SIZE*8-1:0]       WMEM_read_data_in,     // one cycle after the address

    input  logic                          fill_ready_in,         // weight_fifo
    input  logic                          fill_slot_next_in,
    output logic                          fill_advance_out,
    output logic                          fill_write_enable_out,
    output logic                          fill_slot_out,
    output logic [7:0]                    fill_row_out,
    output logic [ARRAY_SIZE*8-1:0]       fill_data_out,

    output logic                          idle_out
);

    logic [63:0] instruction, wait_snapshot;
    assign instruction   = queue_entry_in[63:0];
    assign wait_snapshot = queue_entry_in[127:64];
    logic [5:0] opcode;
    assign opcode = instruction[63:58];

    logic [31:0] weight_base;
    logic [31:0] tiles_left;                                // tiles still to issue
    logic [31:0] tile_index;
    logic [7:0]  row_in_tile;
    logic        read_pending, read_slot, read_is_last_row;
    logic [7:0]  read_row;

    logic [23:0] matmul_tile_count;
    assign matmul_tile_count = 24'(11'(instruction[35:26]) + 11'd1) * 24'(13'(instruction[47:36]) + 13'd1);

    logic issuing_read;
    assign issuing_read = tiles_left != 0 && fill_ready_in;

    assign fill_advance_out      = issuing_read && row_in_tile == 8'(ARRAY_SIZE - 1);
    assign fill_write_enable_out = read_pending;
    assign fill_slot_out         = read_slot;
    assign fill_row_out          = read_row;
    assign fill_data_out         = WMEM_read_data_in;

    assign WMEM_read_address_out = WMEM_ADDRESS_WIDTH'(tile_index * ARRAY_SIZE + 32'(row_in_tile));
    assign queue_pop_out         = queue_valid_in && tiles_left == 0 && !read_pending
                                   && (opcode != OPCODE_WAIT || wait_counts_reached(instruction[51:48], wait_snapshot, completed_in));
    assign idle_out              = tiles_left == 0 && !read_pending && !queue_valid_in;

    always_ff @(posedge clk) begin
        if (reset) begin
            weight_base          <= '0;
            tiles_left           <= '0;
            tile_index           <= '0;
            row_in_tile          <= '0;
            read_pending         <= 1'b0;
            read_slot            <= 1'b0;
            read_is_last_row     <= 1'b0;
            read_row             <= '0;
            instruction_done_out <= 1'b0;
        end else begin
            instruction_done_out <= 1'b0;

            if (queue_pop_out) begin
                case (opcode)
                    OPCODE_SET_WBASE: begin
                        weight_base          <= instruction[31:0];
                        instruction_done_out <= 1'b1;
                    end
                    OPCODE_MATMUL: begin
                        tile_index  <= weight_base;
                        tiles_left  <= 32'(matmul_tile_count);
                        weight_base <= weight_base + 32'(matmul_tile_count);
                        row_in_tile <= '0;
                    end
                    default: instruction_done_out <= 1'b1;   // WAIT
                endcase
            end

            // one row read per cycle; the slot index flips as the last row issues
            read_pending     <= issuing_read;
            read_slot        <= fill_slot_next_in;
            read_row         <= row_in_tile;
            read_is_last_row <= issuing_read && row_in_tile == 8'(ARRAY_SIZE - 1) && tiles_left == 32'd1;
            if (issuing_read) begin
                if (row_in_tile == 8'(ARRAY_SIZE - 1)) begin
                    row_in_tile <= '0;
                    tile_index  <= tile_index + 32'd1;
                    tiles_left  <= tiles_left - 32'd1;
                end else begin
                    row_in_tile <= row_in_tile + 8'd1;
                end
            end

            if (read_pending && read_row == 8'(ARRAY_SIZE - 1) && read_is_last_row)
                instruction_done_out <= 1'b1;
        end
    end

endmodule
