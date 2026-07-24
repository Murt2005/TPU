`timescale 1ns / 1ps

// tpu_pkg — shared host<->FPGA wire-protocol constants.
//
// Single source of truth for the command opcodes and status bytes.
// tpu_sequencer.sv imports this; the host driver tpu_host.py mirrors the same
// values (the wire protocol is the contract between the two, so they must stay
// in sync by hand — this package is the canonical RTL side).
//
// (Datapath widths stay as per-module int8/int16 parameters, which are already
// consistent and threaded from tpu_top; they are intentionally not centralized
// here to avoid making every datapath module depend on this package.)
package tpu_pkg;

    // --- Host -> FPGA command opcodes (packet byte [0]) ---
    // See tpu_sequencer.sv's header for each command's payload format.
    localparam logic [7:0] CMD_LOAD_WEIGHTS = 8'h01;
    localparam logic [7:0] CMD_LOAD_BIAS    = 8'h02;
    localparam logic [7:0] CMD_LOAD_ACT     = 8'h03;
    localparam logic [7:0] CMD_RUN          = 8'h04;
    localparam logic [7:0] CMD_RESET        = 8'h05;
    localparam logic [7:0] CMD_RUN_TILE     = 8'h06;
    localparam logic [7:0] CMD_STREAM_RUN   = 8'h07;
    // 0xFF in S_IDLE is a NOP, silently ignored (no response). The SPI host
    // interface (rtl/spi_slave.sv) needs this: reading a response over SPI
    // means the master clocks dummy filler bytes, and those arrive as rx_valid
    // bytes exactly like command bytes do. 0xFF filler + this rule keeps
    // read-polling invisible to the protocol. (UART hosts simply never send
    // 0xFF as a command; unknown-command tests use other bytes.)
    localparam logic [7:0] CMD_NOP          = 8'hFF;

    // --- FPGA -> Host status byte (response byte [0]) ---
    localparam logic [7:0] STATUS_OK  = 8'hAA;   // command accepted / completed
    localparam logic [7:0] STATUS_ERR = 8'hFF;   // unknown CMD / framing error

endpackage
