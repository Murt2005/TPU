`timescale 1ns / 1ps

// HPS BRIDGE: Avalon-MM (lightweight HPS->FPGA bridge)
module hps_bridge (
    input  logic        clk,
    input  logic        reset,

    input  logic [1:0]  avs_address,
    input  logic        avs_read,
    output logic [31:0] avs_readdata,
    input  logic        avs_write,
    input  logic [31:0] avs_writedata,

    output logic [7:0]  rx_data,
    output logic        rx_valid,

    input  logic [7:0]  tx_data,
    input  logic        tx_valid,
    output logic        tx_busy
);

    localparam logic [1:0] REG_TXDATA = 2'd0;
    localparam logic [1:0] REG_RXDATA = 2'd1;
    localparam logic [1:0] REG_STATUS = 2'd2;

    logic [7:0] hold_data;
    logic       hold_valid;

    assign tx_busy = hold_valid;

    logic pop_rxdata;
    assign pop_rxdata = avs_read && (avs_address == REG_RXDATA);

    always_ff @(posedge clk) begin
        if (reset) begin
            rx_data    <= 8'h00;
            rx_valid   <= 1'b0;
            hold_data  <= 8'h00;
            hold_valid <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
            if (avs_write && (avs_address == REG_TXDATA)) begin
                rx_data  <= avs_writedata[7:0];
                rx_valid <= 1'b1;
            end

            if (pop_rxdata)
                hold_valid <= 1'b0;
            if (tx_valid && !hold_valid) begin
                hold_data  <= tx_data;
                hold_valid <= 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            avs_readdata <= 32'h0;
        end else if (avs_read) begin
            case (avs_address)
                REG_RXDATA: avs_readdata <= {24'h0, hold_data};
                REG_STATUS: avs_readdata <= {30'h0, hold_valid, 1'b1};
                default:    avs_readdata <= 32'h0;
            endcase
        end
    end

endmodule
