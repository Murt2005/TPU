`timescale 1ns / 1ps

// hps_bridge — Avalon-MM (lightweight HPS->FPGA bridge) host PHY.
//
// A third host transport for the DE1-SoC (Cyclone V), alongside uart_rx/uart_tx
// (rtl/uart_*.sv) and spi_slave (rtl/spi_slave.sv). It presents the EXACT same
// byte-stream interface to tpu_sequencer that those PHYs do —
//   rx_data/rx_valid   : one byte host -> FPGA
//   tx_data/tx_valid   : one byte FPGA -> host (tx_valid pulsed by the sequencer)
//   tx_busy            : high while a FPGA->host byte awaits host pickup
// — so the sequencer and the whole datapath are reused unchanged. Only the
// physical path to the host differs: instead of serial pins, the DE1-SoC's ARM
// HPS reads/writes a handful of memory-mapped registers over the lightweight
// h2f bridge (h2f_lw), and the host driver tpu_host.py --link hps mmaps them
// via /dev/mem from Linux running on the HPS.
//
// Register map (Avalon word address; byte offset = word << 2):
//   word 0  TXDATA (write) : writedata[7:0] is pushed to the sequencer as one
//                            rx_data byte with a 1-cycle rx_valid pulse.
//                            (host's "transmit" = FPGA's receive.)
//   word 1  RXDATA (read)  : readdata[7:0] = the pending FPGA->host byte.
//                            Reading it pops the byte (clears rx_avail / tx_busy).
//   word 2  STATUS (read)  : bit0 TX_SPACE = 1 when the host may write TXDATA
//                            (always 1 here — the sequencer never backpressures
//                            rx, and the protocol is request/response so there
//                            is no host->FPGA overrun to guard against).
//                            bit1 RX_AVAIL = 1 when a FPGA->host byte is waiting
//                            in RXDATA. The host polls this before reading.
//
// Avalon slave contract: fixed read latency 1 (readdata valid the cycle after
// avs_read), no waitrequest (never stalls). Configure the Platform Designer
// slave accordingly (readLatency=1, no waitrequest). Single clock domain: the
// bridge is clocked by the same fabric clk as the sequencer — clock the h2f_lw
// bridge from that clock in Qsys (no CDC is handled here).
module hps_bridge (
    input  logic        clk,
    input  logic        reset,

    // --- Avalon-MM slave (to the HPS lightweight bridge) ---
    input  logic [1:0]  avs_address,
    input  logic        avs_read,
    output logic [31:0] avs_readdata,
    input  logic        avs_write,
    input  logic [31:0] avs_writedata,

    // --- Byte-stream interface to tpu_sequencer (same as uart/spi PHYs) ---
    output logic [7:0]  rx_data,
    output logic        rx_valid,

    input  logic [7:0]  tx_data,
    input  logic        tx_valid,
    output logic        tx_busy
);

    // Register word addresses
    localparam logic [1:0] REG_TXDATA = 2'd0;
    localparam logic [1:0] REG_RXDATA = 2'd1;
    localparam logic [1:0] REG_STATUS = 2'd2;

    // FPGA->host holding byte: filled when the sequencer pulses tx_valid,
    // drained when the host reads RXDATA. tx_busy mirrors uart_tx: high from
    // acceptance until the byte is delivered, so the sequencer waits for it to
    // fall before sending the next byte.
    logic [7:0] hold_data;
    logic       hold_valid;

    assign tx_busy = hold_valid;

    // A host read of RXDATA this cycle (the pop strobe).
    logic pop_rxdata;
    assign pop_rxdata = avs_read && (avs_address == REG_RXDATA);

    always_ff @(posedge clk) begin
        if (reset) begin
            rx_data    <= 8'h00;
            rx_valid   <= 1'b0;
            hold_data  <= 8'h00;
            hold_valid <= 1'b0;
        end else begin
            // host -> FPGA: a write to TXDATA emits one rx_valid pulse.
            rx_valid <= 1'b0;
            if (avs_write && (avs_address == REG_TXDATA)) begin
                rx_data  <= avs_writedata[7:0];
                rx_valid <= 1'b1;
            end

            // FPGA -> host: accept a sequencer byte when idle; the host popping
            // RXDATA clears it. If a pop and a new accept coincide, the accept
            // wins (byte kept) — the sequencer only offers a new byte after
            // tx_busy fell, so this collision cannot actually occur, but the
            // ordering below makes the intent explicit.
            if (pop_rxdata)
                hold_valid <= 1'b0;
            if (tx_valid && !hold_valid) begin
                hold_data  <= tx_data;
                hold_valid <= 1'b1;
            end
        end
    end

    // Fixed read-latency-1 readdata register.
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
