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

    input  logic                          queue_valid,
    input  logic [QUEUE_ENTRY_WIDTH-1:0]  queue_entry,
    output logic                          queue_pop,
    input  logic [63:0]                   completed,
    output logic                          instruction_done,

    output logic [WMEM_ADDRESS_WIDTH-1:0] WMEM_read_address,
    input  logic [ARRAY_SIZE*8-1:0]       WMEM_read_data,    // one cycle after the address

    input  logic                          fill_ready,        // weight_fifo
    input  logic                          fill_slot_next,
    output logic                          fill_advance,
    output logic                          fill_write_enable,
    output logic                          fill_slot,
    output logic [7:0]                    fill_row,
    output logic [ARRAY_SIZE*8-1:0]       fill_data,

    output logic                          idle
);

    logic [63:0] instruction, wait_snapshot;
    assign instruction   = queue_entry[63:0];
    assign wait_snapshot = queue_entry[127:64];
    logic [5:0] opcode;
    assign opcode = instruction[63:58];

    logic [31:0] weight_base;
    logic [31:0] tiles_left;                          // tiles still to issue
    logic [31:0] tile;
    logic [7:0]  row;
    logic        read_pending, read_slot, read_final;
    logic [7:0]  read_row;

    logic [23:0] matmul_tiles;
    assign matmul_tiles = 24'(11'(instruction[35:26]) + 11'd1) * 24'(13'(instruction[47:36]) + 13'd1);

    logic issuing_read;
    assign issuing_read = tiles_left != 0 && fill_ready;

    assign fill_advance      = issuing_read && row == 8'(ARRAY_SIZE - 1);
    assign fill_write_enable = read_pending;
    assign fill_slot         = read_slot;
    assign fill_row          = read_row;
    assign fill_data         = WMEM_read_data;

    assign WMEM_read_address = WMEM_ADDRESS_WIDTH'(tile * ARRAY_SIZE + 32'(row));
    assign queue_pop      = queue_valid && tiles_left == 0 && !read_pending
                        && (opcode != OPCODE_WAIT || wait_counts_reached(instruction[51:48], wait_snapshot, completed));
    assign idle       = tiles_left == 0 && !read_pending && !queue_valid;

    always_ff @(posedge clk) begin
        if (reset) begin
            weight_base      <= '0;
            tiles_left       <= '0;
            tile             <= '0;
            row              <= '0;
            read_pending     <= 1'b0;
            read_slot        <= 1'b0;
            read_final       <= 1'b0;
            read_row         <= '0;
            instruction_done <= 1'b0;
        end else begin
            instruction_done <= 1'b0;

            if (queue_pop) begin
                case (opcode)
                    OPCODE_SET_WBASE: begin
                        weight_base      <= instruction[31:0];
                        instruction_done <= 1'b1;
                    end
                    OPCODE_MATMUL: begin
                        tile        <= weight_base;
                        tiles_left  <= 32'(matmul_tiles);
                        weight_base <= weight_base + 32'(matmul_tiles);
                        row         <= '0;
                    end
                    default: instruction_done <= 1'b1;   // WAIT
                endcase
            end

            // one row read per cycle; the slot index flips as the last row issues
            read_pending <= issuing_read;
            read_slot    <= fill_slot_next;
            read_row     <= row;
            read_final   <= issuing_read && row == 8'(ARRAY_SIZE - 1) && tiles_left == 32'd1;
            if (issuing_read) begin
                if (row == 8'(ARRAY_SIZE - 1)) begin
                    row        <= '0;
                    tile       <= tile + 32'd1;
                    tiles_left <= tiles_left - 32'd1;
                end else begin
                    row <= row + 8'd1;
                end
            end

            if (read_pending && read_row == 8'(ARRAY_SIZE - 1) && read_final)
                instruction_done <= 1'b1;
        end
    end

endmodule
