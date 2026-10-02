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

    input  logic                     load_write_enable_in,
    input  logic [ADDRESS_WIDTH-1:0] load_write_address_in,
    input  logic [ARRAY_SIZE*8-1:0]  load_write_data_in,
    input  logic                     activate_write_enable_in,
    input  logic [ADDRESS_WIDTH-1:0] activate_write_address_in,
    input  logic [ARRAY_SIZE*8-1:0]  activate_write_data_in,

    input  logic                     matmul_read_enable_in,
    input  logic [ADDRESS_WIDTH-1:0] matmul_read_address_in,
    input  logic [ADDRESS_WIDTH-1:0] activate_read_address_in,
    output logic [ARRAY_SIZE*8-1:0]  read_data_out              // one cycle after the address
);

    logic [ARRAY_SIZE*8-1:0] memory [DEPTH];

    always_ff @(posedge clk) begin
        if (activate_write_enable_in)  memory[activate_write_address_in] <= activate_write_data_in;
        else if (load_write_enable_in) memory[load_write_address_in]     <= load_write_data_in;
        read_data_out <= memory[matmul_read_enable_in ? matmul_read_address_in : activate_read_address_in];
    end

endmodule
