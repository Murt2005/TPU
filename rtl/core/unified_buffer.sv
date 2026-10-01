`timescale 1ns / 1ps

// Unified Buffer: double-banked on-chip activation store
module unified_buffer #(
    parameter int ROWS       = 2,
    parameter int COLS       = 2,
    parameter int DATA_WIDTH = 8,
    parameter int ADDR_WIDTH = $clog2(ROWS)
) (
    input  logic clk,
    input  logic reset,

    input  logic [ADDR_WIDTH-1:0]         host_write_addr,
    input  logic signed [COLS-1:0][DATA_WIDTH-1:0] host_write_data,
    input  logic                          host_write_valid,

    input  logic [ADDR_WIDTH-1:0]         host_read_addr,
    output logic signed [COLS-1:0][DATA_WIDTH-1:0] host_read_data,
    input  logic                          host_read_en,
    output logic                          host_read_valid,

    input  logic [ADDR_WIDTH-1:0]         ub_read_addr,
    input  logic                          ub_read_en,
    output logic signed [COLS-1:0][DATA_WIDTH-1:0] ub_read_data,
    output logic                          ub_read_valid,

    input  logic signed [COLS-1:0][DATA_WIDTH-1:0] act_write_data,
    input  logic                          act_write_valid,
    input  logic                          act_write_addr_reset,

    input  logic                          bank_swap
);

    localparam int WORD_W = COLS * DATA_WIDTH;

    (* ram_style = "block", ramstyle = "M10K" *) logic [WORD_W-1:0] mem0 [ROWS];
    (* ram_style = "block", ramstyle = "M10K" *) logic [WORD_W-1:0] mem1 [ROWS];

    logic bank_sel;
    wire  shadow_sel = bank_sel ^ 1'b1;

    logic [ADDR_WIDTH-1:0] act_write_ptr;

    always_ff @(posedge clk) begin
        if (reset)          bank_sel <= 1'b0;
        else if (bank_swap) bank_sel <= shadow_sel;
    end

    always_ff @(posedge clk) begin
        if (reset || act_write_addr_reset)
            act_write_ptr <= '0;
        else if (act_write_valid)
            act_write_ptr <= act_write_ptr + 1'b1;
    end

    wire                  wen0   = (bank_sel == 1'b0) ? host_write_valid : act_write_valid;
    wire [ADDR_WIDTH-1:0] waddr0 = (bank_sel == 1'b0) ? host_write_addr  : act_write_ptr;
    wire [WORD_W-1:0]     wdata0 = (bank_sel == 1'b0) ? host_write_data  : act_write_data;
    wire                  wen1   = (bank_sel == 1'b1) ? host_write_valid : act_write_valid;
    wire [ADDR_WIDTH-1:0] waddr1 = (bank_sel == 1'b1) ? host_write_addr  : act_write_ptr;
    wire [WORD_W-1:0]     wdata1 = (bank_sel == 1'b1) ? host_write_data  : act_write_data;

    always_ff @(posedge clk) if (wen0) mem0[waddr0] <= wdata0;
    always_ff @(posedge clk) if (wen1) mem1[waddr1] <= wdata1;

    logic [ADDR_WIDTH-1:0] ub_addr_r;
    logic                  ub_en_r;
    logic                  ub_bank_r;

    always_ff @(posedge clk) begin
        if (reset) begin
            ub_en_r <= 1'b0;
        end else begin
            ub_addr_r <= ub_read_addr;
            ub_en_r   <= ub_read_en;
            ub_bank_r <= bank_sel;
        end
    end

    wire [ADDR_WIDTH-1:0] raddr0 = (ub_en_r && ub_bank_r == 1'b0) ? ub_addr_r : host_read_addr;
    wire [ADDR_WIDTH-1:0] raddr1 = (ub_en_r && ub_bank_r == 1'b1) ? ub_addr_r : host_read_addr;

    logic [WORD_W-1:0] rdata0, rdata1;
    always_ff @(posedge clk) rdata0 <= mem0[raddr0];
    always_ff @(posedge clk) rdata1 <= mem1[raddr1];

    logic ub_bank_rr;
    logic host_bank_r;

    always_ff @(posedge clk) begin
        if (reset) begin
            ub_read_valid   <= 1'b0;
            host_read_valid <= 1'b0;
        end else begin
            ub_read_valid   <= ub_en_r;
            ub_bank_rr      <= ub_bank_r;
            host_read_valid <= host_read_en;
            if (host_read_en) host_bank_r <= shadow_sel;
        end
    end

    assign ub_read_data   = ub_bank_rr  ? rdata1 : rdata0;
    assign host_read_data = host_bank_r ? rdata1 : rdata0;

endmodule
