`timescale 1ns / 1ps

// TPU pkg: shared host<->FPGA wire-protocol constants
package tpu_pkg;

    localparam logic [7:0] CMD_LOAD_WEIGHTS = 8'h01;
    localparam logic [7:0] CMD_LOAD_BIAS    = 8'h02;
    localparam logic [7:0] CMD_LOAD_ACT     = 8'h03;
    localparam logic [7:0] CMD_RUN          = 8'h04;
    localparam logic [7:0] CMD_RESET        = 8'h05;
    localparam logic [7:0] CMD_RUN_TILE     = 8'h06;
    localparam logic [7:0] CMD_STREAM_RUN   = 8'h07;
    localparam logic [7:0] CMD_NOP          = 8'hFF;

    localparam int FLAG_TILE_FIRST = 0;
    localparam int FLAG_TILE_LAST  = 1;
    localparam int FLAG_ACT_BYPASS = 2;

    localparam logic [7:0] STATUS_OK  = 8'hAA;
    localparam logic [7:0] STATUS_ERR = 8'hFF;

endpackage
