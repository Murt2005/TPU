`timescale 1ns / 1ps

// ACTIVATE dst=DDR's words into DDR3: a small FIFO of {byte address, word}, each
// written as one 128-bit beat with only its lane's byteenables. ACT emits at most
// a word a cycle, so one write a cycle keeps up. idle_out once every word has been
// accepted by the bus: ACT completes only then, so a WAIT on ACT orders later
// reads of the same bytes behind the writes
module ddr_writer #(
    parameter int DEPTH = 16
) (
    input  logic         clk,
    input  logic         reset,

    input  logic         word_valid_in,
    input  logic [31:2]  word_address_in,        // a word's address: 4-byte aligned
    input  logic [31:0]  word_in,
    output logic         full_out,
    output logic         idle_out,

    output logic [31:0]  memory_address_out,
    output logic         memory_write_out,
    output logic [127:0] memory_writedata_out,
    output logic [15:0]  memory_byteenable_out,
    input  logic         memory_waitrequest_in
);

    logic [61:0] head;          // {address[31:2], word}
    logic        empty;
    logic [1:0]  lane;

    fifo #(.WIDTH(62), .DEPTH(DEPTH)) u_words (
        .clk(clk), .reset(reset), .write_enable_in(word_valid_in), .write_data_in({word_address_in, word_in}),
        .read_enable_in(memory_write_out && !memory_waitrequest_in), .read_data_out(head),
        .full_out(full_out), .empty_out(empty));

    assign lane                  = head[33:32];
    assign memory_write_out      = !empty;
    assign memory_address_out    = {head[61:34], 4'd0};
    assign memory_writedata_out  = {4{head[31:0]}};
    assign memory_byteenable_out = 16'hF << {lane, 2'b00};
    assign idle_out              = empty;

endmodule
