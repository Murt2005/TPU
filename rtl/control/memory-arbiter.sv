`timescale 1ns / 1ps

// the core's one DDR3 master, shared by WT's reader (weights), LD's reader
// (RD_DDR_UB) and ACT's writer (ACTIVATE dst=DDR), in that priority. a grant holds
// while the bus holds its command off, as Avalon requires. read data comes back
// in issue order, so a FIFO of {client, burst length} routes each beat
module memory_arbiter #(
    parameter int PENDING = 32               // read bursts in flight; the port takes 14
) (
    input  logic         clk,
    input  logic         reset,              // power-on only

    input  logic [31:0]  weight_address_in,
    input  logic         weight_read_in,
    input  logic [7:0]   weight_burstcount_in,
    output logic         weight_waitrequest_out,
    output logic         weight_readdatavalid_out,

    input  logic [31:0]  load_address_in,
    input  logic         load_read_in,
    input  logic [7:0]   load_burstcount_in,
    output logic         load_waitrequest_out,
    output logic         load_readdatavalid_out,

    input  logic [31:0]  activate_address_in,
    input  logic         activate_write_in,
    input  logic [127:0] activate_writedata_in,
    input  logic [15:0]  activate_byteenable_in,
    output logic         activate_waitrequest_out,

    output logic [31:0]  memory_address_out,
    output logic         memory_read_out,
    output logic         memory_write_out,
    output logic [7:0]   memory_burstcount_out,
    output logic [127:0] memory_writedata_out,
    output logic [15:0]  memory_byteenable_out,
    input  logic         memory_waitrequest_in,
    input  logic         memory_readdatavalid_in
);

    typedef enum logic [1:0] {GRANT_WEIGHT, GRANT_LOAD, GRANT_ACTIVATE} grant_t;
    grant_t grant, held_grant;
    logic   holding;                         // last cycle's command is still waiting
    logic   tag_empty, tag_full;

    always_comb begin
        if (holding)                grant = held_grant;
        else if (weight_read_in)    grant = GRANT_WEIGHT;
        else if (load_read_in)      grant = GRANT_LOAD;
        else                        grant = GRANT_ACTIVATE;
    end

    always_comb begin
        memory_read_out       = 1'b0;
        memory_write_out      = 1'b0;
        memory_address_out    = activate_address_in;
        memory_burstcount_out = 8'd1;
        case (grant)
            GRANT_WEIGHT: begin
                memory_read_out = weight_read_in && !tag_full; memory_address_out = weight_address_in; memory_burstcount_out = weight_burstcount_in;
            end
            GRANT_LOAD: begin
                memory_read_out = load_read_in && !tag_full; memory_address_out = load_address_in; memory_burstcount_out = load_burstcount_in;
            end
            default: memory_write_out = activate_write_in;
        endcase
    end
    assign memory_writedata_out  = activate_writedata_in;
    assign memory_byteenable_out = activate_byteenable_in;

    // reads also wait while every routing tag is taken (the port's own limit is lower)
    assign weight_waitrequest_out   = grant != GRANT_WEIGHT   || memory_waitrequest_in || tag_full;
    assign load_waitrequest_out     = grant != GRANT_LOAD     || memory_waitrequest_in || tag_full;
    assign activate_waitrequest_out = grant != GRANT_ACTIVATE || memory_waitrequest_in;

    always_ff @(posedge clk) begin
        if (reset) begin
            holding    <= 1'b0;
            held_grant <= GRANT_WEIGHT;
        end else begin
            holding    <= (memory_read_out || memory_write_out) && memory_waitrequest_in;
            held_grant <= grant;
        end
    end

    // -- read data back to its client --------------------------------------------
    logic       read_accepted, burst_done;
    logic [8:0] tag;                                  // {client is LD, burst length}
    logic [7:0] beat_in_burst;

    assign read_accepted = memory_read_out && !memory_waitrequest_in;
    assign burst_done    = memory_readdatavalid_in && beat_in_burst == tag[7:0] - 8'd1;

    fifo #(.WIDTH(9), .DEPTH(PENDING)) u_tags (
        .clk(clk), .reset(reset), .write_enable_in(read_accepted),
        .write_data_in({grant == GRANT_LOAD, memory_burstcount_out}),
        .read_enable_in(burst_done), .read_data_out(tag), .full_out(tag_full), .empty_out(tag_empty));

    assign weight_readdatavalid_out = memory_readdatavalid_in && !tag[8];
    assign load_readdatavalid_out   = memory_readdatavalid_in && tag[8];

    always_ff @(posedge clk) begin
        if (reset)                        beat_in_burst <= '0;
        else if (burst_done)              beat_in_burst <= '0;
        else if (memory_readdatavalid_in) beat_in_burst <= beat_in_burst + 8'd1;
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!reset && memory_readdatavalid_in && tag_empty) $fatal(1, "memory_arbiter: read data with nothing in flight");
    end
`endif

endmodule
