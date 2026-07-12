`timescale 1ns / 1ps

// spi_slave — SPI mode-0 (CPOL=0, CPHA=0) slave presenting the same
// byte-stream interface as the uart_rx/uart_tx pair, so tpu_sequencer.sv
// plugs into either PHY unchanged (tpu_top's USE_SPI parameter selects).
//
//  Host-facing protocol notes (see docs/FPGA.md / SEQUENCER_REDESIGN.md):
//
//  * SPI is master-driven, so the request/response protocol becomes
//    write-then-poll: the master clocks the command frame out on MOSI,
//    then clocks dummy 0xFF filler bytes and watches MISO for the
//    response. MISO returns IDLE_BYTE (0x00) while the TX FIFO is empty;
//    the first non-idle byte is STATUS (0xAA/0xFF — both distinct from
//    0x00 by construction) and the LEN/payload bytes follow back to back.
//    The 0xFF poll filler is CMD_NOP, which tpu_sequencer ignores in
//    S_IDLE — that is what keeps read-polling from being parsed as
//    commands.
//
//  * RX path (MOSI → rx_data/rx_valid): shifted in the SCK domain
//    (MSB first), so the write-direction clock can approach
//    CLK_FREQ/2 — completed bytes cross to the system clock through a
//    toggle-flag synchronizer. The held byte is stable for a full byte
//    period after its flag toggles, so the 2FF latency can't race it.
//    PROTOCOL-LEVEL CAP, tighter than the PHY's: tpu_sequencer has no RX
//    backpressure and drops bytes during its inter-tile pipeline pass
//    (~25-35 clk) inside a STREAM_RUN frame — the same timing assumption
//    documented in its header for UART. Until the master paces per-tile,
//    keep the WRITE byte period >= ~40 clk (SCK <= CLK_FREQ/6 at uniform
//    pacing; e.g. 4 MHz at a 24 MHz core clock).
//
//  * TX path (tx_data/tx_valid → MISO): a system-clock engine driving
//    MISO from synchronized SCK falling edges (mode 0: master samples on
//    rising). Edge detection through a 2FF synchronizer needs >= 3 clk
//    per SCK half-period, so the READ-direction clock must stay at or
//    below CLK_FREQ/8 (conservative). Responses are tiny (2..2+result
//    bytes) so the slow read leg costs microseconds. Response bytes
//    queue in a 16-deep FIFO (fifo.sv); tx_busy = FIFO full, matching
//    uart_tx's "don't push when busy" contract.
//
//  * The master must deassert CS between the write burst and the read
//    poll (and between frames): CS resets both engines' bit alignment.
//    MISO during a write burst is unspecified garbage — the master
//    discards it.
//
//  * No framing on SPI, so there is no rx_error equivalent — tpu_top
//    ties the sequencer's rx_error low in SPI builds.
module spi_slave (
    input  logic clk,
    input  logic reset,

    // SPI pins (async to clk; sck is used as a clock for the RX shifter)
    input  logic sck,
    input  logic csn,     // active-low chip select
    input  logic mosi,
    output logic miso,

    // byte stream to/from tpu_sequencer (clk domain)
    output logic [7:0] rx_data,
    output logic       rx_valid,   // one-cycle pulse per received byte

    input  logic [7:0] tx_data,
    input  logic       tx_valid,   // push one response byte (when !tx_busy)
    output logic       tx_busy     // response FIFO full
);

    localparam logic [7:0] IDLE_BYTE = 8'h00;  // MISO filler when no response
                                               // queued; must differ from both
                                               // STATUS values (0xAA/0xFF)

    // =========================================================================
    // RX: shift MOSI in the SCK domain, byte-level toggle CDC into clk
    // =========================================================================
    logic [2:0] rx_bit = '0;        // SCK domain: bits received in current byte.
                                    // Power-up initializer matters: before the
                                    // first CS deassert edge ever fires, the
                                    // async clear has never run, and an X here
                                    // (in sim) would swallow the first burst.
    logic [6:0] rx_shift;           // SCK domain: 7 high bits shifted so far
    logic [7:0] rx_hold;            // SCK domain write / clk domain read (stable
                                    // for >= 1 full byte period after flag toggle)
    logic       rx_flag = 1'b0;     // SCK domain toggle: one flip per byte.
                                    // Power-up initializer, not reset: this
                                    // domain has no reset, and only flag *edges*
                                    // carry information anyway.

    // Bit counter: async-cleared by CS deassert so a torn byte can never
    // leave the alignment off for the next burst.
    always_ff @(posedge sck or posedge csn) begin
        if (csn) rx_bit <= '0;
        else     rx_bit <= (rx_bit == 3'd7) ? '0 : rx_bit + 3'd1;
    end

    always_ff @(posedge sck) begin
        if (!csn) begin
            rx_shift <= {rx_shift[5:0], mosi};
            if (rx_bit == 3'd7) begin
                rx_hold <= {rx_shift, mosi};
                rx_flag <= ~rx_flag;
            end
        end
    end

    logic [2:0] rx_flag_sync;  // 2FF + edge-detect stage
    always_ff @(posedge clk) begin
        if (reset) begin
            rx_flag_sync <= '0;
            rx_valid     <= 1'b0;
            rx_data      <= '0;
        end else begin
            rx_flag_sync <= {rx_flag_sync[1:0], rx_flag};
            rx_valid     <= 1'b0;
            if (rx_flag_sync[2] != rx_flag_sync[1]) begin
                rx_data  <= rx_hold;
                rx_valid <= 1'b1;
            end
        end
    end

    // =========================================================================
    // TX: response FIFO (clk domain) + MISO engine on synchronized SCK edges
    // =========================================================================
    logic        fifo_full, fifo_empty;
    logic signed [7:0] fifo_head;
    logic signed [7:0] fifo_wr_data;   // fifo.sv's ports are signed; the byte
    logic        fifo_pop;             // stream is unsigned -- bridge through
                                       // plain wires (a signed'() cast inline
                                       // in the port map trips a yosys
                                       // genrtlil assert as of yosys 0.4x)
    assign fifo_wr_data = signed'(tx_data);

    fifo #(.WIDTH(8), .DEPTH(16)) u_tx_fifo (
        .clk          (clk),
        .reset        (reset),
        .write_enable (tx_valid && !fifo_full),
        .write_data   (fifo_wr_data),
        .read_enable  (fifo_pop),
        .read_data    (fifo_head),
        .full         (fifo_full),
        .empty        (fifo_empty)
    );
    assign tx_busy = fifo_full;

    // Synchronize sck/csn into clk for the TX engine
    logic [1:0] sck_sync, csn_sync;
    logic       sck_prev, csn_prev;
    always_ff @(posedge clk) begin
        if (reset) begin
            sck_sync <= '0;
            csn_sync <= 2'b11;
            sck_prev <= 1'b0;
            csn_prev <= 1'b1;
        end else begin
            sck_sync <= {sck_sync[0], sck};
            csn_sync <= {csn_sync[0], csn};
            sck_prev <= sck_sync[1];
            csn_prev <= csn_sync[1];
        end
    end
    wire cs_active     = !csn_sync[1];
    wire cs_fall       = csn_prev && !csn_sync[1];    // freshly selected (3 clk
                                                      // after the pin edge, so the
                                                      // master must lead CS by a
                                                      // few clk before first SCK)
    wire sck_fall_sync = cs_active && sck_prev && !sck_sync[1];

    logic [7:0] tx_shift;
    logic [2:0] tx_bit;

    assign miso = tx_shift[7];   // MSB first; master samples on SCK rising

    always_ff @(posedge clk) begin
        if (reset) begin
            tx_shift <= IDLE_BYTE;
            tx_bit   <= '0;
            fifo_pop <= 1'b0;
        end else begin
            fifo_pop <= 1'b0;
            if (cs_fall) begin
                // (Re)selected: present the head byte (or idle) before the
                // master's first rising edge. Requires CS-to-first-SCK lead
                // time of >= 5 clk cycles from the master (3 for the CS edge
                // to synchronize + 1 to load + margin) — trivially true for
                // the RP2350 bridge, which gaps CS in software.
                tx_bit <= '0;
                if (!fifo_empty) begin
                    tx_shift <= 8'(fifo_head);
                    fifo_pop <= 1'b1;
                end else begin
                    tx_shift <= IDLE_BYTE;
                end
            end else if (sck_fall_sync) begin
                if (tx_bit == 3'd7) begin
                    // Byte boundary: load the next queued byte (or idle)
                    tx_bit <= '0;
                    if (!fifo_empty) begin
                        tx_shift <= 8'(fifo_head);
                        fifo_pop <= 1'b1;
                    end else begin
                        tx_shift <= IDLE_BYTE;
                    end
                end else begin
                    tx_shift <= {tx_shift[6:0], 1'b0};
                    tx_bit   <= tx_bit + 3'd1;
                end
            end
        end
    end

endmodule
