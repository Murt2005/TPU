`timescale 1ns / 1ps

// DDR3 bandwidth probe: a 128-bit Avalon-MM burst-read master on the HPS's
// FPGA-to-SDRAM port, with a register slave on the lightweight bridge. reads
// BEATS × 16 bytes from ADDRESS in bursts of BURST beats, at most OUTSTANDING
// bursts in flight, and reports the cycles, a checksum and the latency from each
// burst's command to its first beat. read-only: it never writes DDR3
module ddr_probe (
    input  logic         clk,
    input  logic         reset_n,

    // register slave: fixed read latency 1, no waitrequest
    input  logic [3:0]   avs_address,
    input  logic         avs_read,
    output logic [31:0]  avs_readdata,
    input  logic         avs_write,
    input  logic [31:0]  avs_writedata,

    // burst-read master, byte addresses
    output logic [31:0]  avm_address,
    output logic         avm_read,
    output logic [7:0]   avm_burstcount,
    input  logic         avm_waitrequest,
    input  logic [127:0] avm_readdata,
    input  logic         avm_readdatavalid
);

    localparam logic [31:0] IDENTITY = 32'hDD3B_0001;

    localparam logic [3:0] REGISTER_IDENTITY       = 4'd0;
    localparam logic [3:0] REGISTER_CONTROL        = 4'd1;   // W: bit 0 start, bit 1 abort (a port held in reset never answers). R: bit 0 busy
    localparam logic [3:0] REGISTER_ADDRESS        = 4'd2;   // byte address, 16-byte aligned
    localparam logic [3:0] REGISTER_BEATS          = 4'd3;   // 16-byte beats to read, a multiple of BURST
    localparam logic [3:0] REGISTER_BURST          = 4'd4;   // beats per burst, 1..128
    localparam logic [3:0] REGISTER_OUTSTANDING    = 4'd5;   // bursts in flight, 1..15
    localparam logic [3:0] REGISTER_CYCLES         = 4'd6;   // start to last beat
    localparam logic [3:0] REGISTER_RECEIVED       = 4'd7;   // beats received
    localparam logic [3:0] REGISTER_CHECKSUM       = 4'd8;   // sum of every 32-bit word, mod 2^32
    localparam logic [3:0] REGISTER_LATENCY_FIRST  = 4'd9;   // first burst: command accepted to first beat
    localparam logic [3:0] REGISTER_LATENCY_MAX    = 4'd10;
    localparam logic [3:0] REGISTER_LATENCY_SUM    = 4'd11;  // over every burst
    localparam logic [3:0] REGISTER_WAIT_CYCLES    = 4'd12;  // read held off by waitrequest
    localparam logic [3:0] REGISTER_ISSUE_CYCLES   = 4'd13;  // start to last command accepted

    logic reset;
    assign reset = ~reset_n;

    logic [31:0] start_address, beats, cycles, received, checksum;
    logic [31:0] latency_first, latency_max, latency_sum, wait_cycles, issue_cycles;
    logic [7:0]  burst;
    logic [3:0]  outstanding_limit;
    logic        busy, first_burst_seen;

    // command side
    logic [31:0] next_address, beats_to_issue;
    logic [3:0]  in_flight;
    logic        command_accepted, burst_finished;
    assign avm_read         = busy && beats_to_issue != 0 && in_flight < outstanding_limit;
    assign avm_address      = next_address;
    assign avm_burstcount   = burst;
    assign command_accepted = avm_read && !avm_waitrequest;

    // receive side: a burst ends on its last beat
    logic [7:0]  beat_in_burst;
    assign burst_finished = avm_readdatavalid && beat_in_burst == burst - 8'd1;

    // command timestamps, popped at each burst's first beat (in_flight <= 15)
    logic [31:0] timestamps [16];
    logic [3:0]  timestamp_write, timestamp_read;
    logic [31:0] latency;
    assign latency = cycles - timestamps[timestamp_read];

    logic [31:0] beat_sum;
    assign beat_sum = avm_readdata[31:0] + avm_readdata[63:32] + avm_readdata[95:64] + avm_readdata[127:96];

    logic start;
    assign start = avs_write && avs_address == REGISTER_CONTROL && avs_writedata[0] && !busy;

    always_ff @(posedge clk) begin
        if (reset) begin
            start_address <= '0; beats <= 32'd1; burst <= 8'd1; outstanding_limit <= 4'd1;
            busy <= 1'b0; avs_readdata <= '0;
            cycles <= '0; received <= '0; checksum <= '0; latency_first <= '0; latency_max <= '0;
            latency_sum <= '0; wait_cycles <= '0; issue_cycles <= '0; first_burst_seen <= 1'b0;
            next_address <= '0; beats_to_issue <= '0; in_flight <= '0; beat_in_burst <= '0;
            timestamp_write <= '0; timestamp_read <= '0;
        end else begin
            if (avs_write && !busy)
                case (avs_address)
                    REGISTER_ADDRESS:     start_address     <= {avs_writedata[31:4], 4'd0};
                    REGISTER_BEATS:       beats             <= avs_writedata;
                    REGISTER_BURST:       burst             <= avs_writedata[7:0];
                    REGISTER_OUTSTANDING: outstanding_limit <= avs_writedata[3:0];
                    default: ;
                endcase

            if (avs_write && avs_address == REGISTER_CONTROL && avs_writedata[1]) begin
                busy <= 1'b0;
            end else if (start) begin
                busy <= 1'b1;
                cycles <= '0; received <= '0; checksum <= '0; latency_first <= '0; latency_max <= '0;
                latency_sum <= '0; wait_cycles <= '0; issue_cycles <= '0; first_burst_seen <= 1'b0;
                next_address <= start_address; beats_to_issue <= beats; in_flight <= '0; beat_in_burst <= '0;
                timestamp_write <= '0; timestamp_read <= '0;
            end else if (busy) begin
                cycles <= cycles + 32'd1;
                if (avm_read && avm_waitrequest) wait_cycles <= wait_cycles + 32'd1;
                if (command_accepted) begin
                    next_address               <= next_address + {20'd0, burst, 4'd0};
                    beats_to_issue             <= beats_to_issue - 32'(burst);
                    timestamps[timestamp_write] <= cycles;
                    timestamp_write            <= timestamp_write + 4'd1;
                    issue_cycles               <= cycles + 32'd1;
                end
                in_flight <= in_flight + 4'(command_accepted) - 4'(burst_finished);

                if (avm_readdatavalid) begin
                    received      <= received + 32'd1;
                    checksum      <= checksum + beat_sum;
                    beat_in_burst <= burst_finished ? 8'd0 : beat_in_burst + 8'd1;
                    if (beat_in_burst == 8'd0) begin
                        timestamp_read <= timestamp_read + 4'd1;
                        latency_sum    <= latency_sum + latency;
                        if (latency > latency_max) latency_max <= latency;
                        if (!first_burst_seen) begin
                            latency_first    <= latency;
                            first_burst_seen <= 1'b1;
                        end
                    end
                    if (received + 32'd1 == beats) busy <= 1'b0;
                end
            end

            if (avs_read)
                case (avs_address)
                    REGISTER_IDENTITY:      avs_readdata <= IDENTITY;
                    REGISTER_CONTROL:       avs_readdata <= {31'd0, busy};
                    REGISTER_ADDRESS:       avs_readdata <= start_address;
                    REGISTER_BEATS:         avs_readdata <= beats;
                    REGISTER_BURST:         avs_readdata <= {24'd0, burst};
                    REGISTER_OUTSTANDING:   avs_readdata <= {28'd0, outstanding_limit};
                    REGISTER_CYCLES:        avs_readdata <= cycles;
                    REGISTER_RECEIVED:      avs_readdata <= received;
                    REGISTER_CHECKSUM:      avs_readdata <= checksum;
                    REGISTER_LATENCY_FIRST: avs_readdata <= latency_first;
                    REGISTER_LATENCY_MAX:   avs_readdata <= latency_max;
                    REGISTER_LATENCY_SUM:   avs_readdata <= latency_sum;
                    REGISTER_WAIT_CYCLES:   avs_readdata <= wait_cycles;
                    REGISTER_ISSUE_CYCLES:  avs_readdata <= issue_cycles;
                    default:                avs_readdata <= 32'd0;
                endcase
        end
    end

endmodule
