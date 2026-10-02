`timescale 1ns / 1ps

// unified buffer: on-chip activations, N int8 per entry. LD writes host data, ACT
// writes a layer's requantized output (and has priority), MM reads rows into the
// array (and has priority), ACT reads for RD_UB
module unified_buffer #(
    parameter int ARRAY_SIZE    = 8,
    parameter int DEPTH         = 16384,
    parameter int ADDRESS_WIDTH = $clog2(DEPTH)
) (
    input  logic                     clk,

    input  logic                     load_write_enable,
    input  logic [ADDRESS_WIDTH-1:0] load_write_address,
    input  logic [ARRAY_SIZE*8-1:0]  load_write_data,
    input  logic                     activate_write_enable,
    input  logic [ADDRESS_WIDTH-1:0] activate_write_address,
    input  logic [ARRAY_SIZE*8-1:0]  activate_write_data,

    input  logic                     matmul_read_enable,
    input  logic [ADDRESS_WIDTH-1:0] matmul_read_address,
    input  logic [ADDRESS_WIDTH-1:0] activate_read_address,
    output logic [ARRAY_SIZE*8-1:0]  read_data               // one cycle after the address
);

    logic [ARRAY_SIZE*8-1:0] memory [DEPTH];

    always_ff @(posedge clk) begin
        if (activate_write_enable)     memory[activate_write_address] <= activate_write_data;
        else if (load_write_enable) memory[load_write_address]  <= load_write_data;
        read_data <= memory[matmul_read_enable ? matmul_read_address : activate_read_address];
    end

endmodule
