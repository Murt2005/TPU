`timescale 1ns / 1ps

// DE1-SoC FPGA-only bring-up: tpu_top driven by replay, no HPS.
// LEDR0 pass, LEDR1 fail, LEDR2 running, LEDR3 timeout, LEDR4 core ERR,
// LEDR9 heartbeat. HEX3..2: the running test's mark, or the first failing one;
// HEX1..0: the mismatch count; "PASS" when clean. KEY0 reruns, KEY3..1 unused.
// SW9 up: HEX5..0 show capture slot SW4..0 (perf counters) in hex
module tpu_selftest #(
    parameter int ARRAY_SIZE = 8,
    parameter int ROM_DEPTH  = 16384,
    parameter     ROM_FILE   = "isa_selftest.hex"
) (
    input  logic       CLOCK_50,
    input  logic [3:0] KEY,      // only KEY0 is used
    input  logic [9:0] SW,       // SW9 + SW4..0; the rest unused
    output logic [9:0] LEDR,
    output logic [6:0] HEX0,
    output logic [6:0] HEX1,
    output logic [6:0] HEX2,
    output logic [6:0] HEX3,
    output logic [6:0] HEX4,
    output logic [6:0] HEX5
);

    logic clk;
    assign clk = CLOCK_50;

    // same power-on reset as tpu_top, so the replay waits for the core's
    logic [8:0] por_ctr = '0;
    logic       por_done = 1'b0;
    always_ff @(posedge clk)
        if (!por_done) begin
            por_ctr <= por_ctr + 1'b1;
            if (por_ctr == 9'h1FF) por_done <= 1'b1;
        end

    logic [1:0] key_sync = 2'b11;
    always_ff @(posedge clk) key_sync <= {key_sync[0], KEY[0]};
    logic run_reset;
    assign run_reset = !por_done || !key_sync[1];

    logic [3:0]  avs_address;
    logic        avs_read, avs_write, avs_waitrequest;
    logic [31:0] avs_readdata, avs_writedata;

    tpu_top #(.ARRAY_SIZE(ARRAY_SIZE)) u_tpu (
        .clk(clk), .reset_n(!run_reset),
        .avs_address(avs_address), .avs_read(avs_read), .avs_readdata(avs_readdata),
        .avs_write(avs_write), .avs_writedata(avs_writedata), .avs_waitrequest(avs_waitrequest),
        // no DDR3 here: the self-test never runs MATMUL wsrc=1
        .avm_address(), .avm_read(), .avm_write(), .avm_burstcount(), .avm_writedata(), .avm_byteenable(),
        .avm_waitrequest(1'b0), .avm_readdata('0), .avm_readdatavalid(1'b0));

    logic        finished, timed_out, core_err;
    logic [31:0] cap_value;
    logic [9:0]  sw_q;
    always_ff @(posedge clk) sw_q <= SW;            // display only, one flop is plenty
    logic [15:0] mismatches;
    logic [7:0]  first_bad_mark, mark;

    replay #(.DEPTH(ROM_DEPTH), .ROM_FILE(ROM_FILE)) u_replay (
        .clk(clk), .reset(run_reset),
        .avs_address(avs_address), .avs_read(avs_read), .avs_readdata(avs_readdata),
        .avs_write(avs_write), .avs_writedata(avs_writedata), .avs_waitrequest(avs_waitrequest),
        .finished(finished), .timed_out(timed_out), .core_err(core_err),
        .mismatches(mismatches), .first_bad_mark(first_bad_mark), .mark(mark),
        .cap_sel(sw_q[4:0]), .cap_value(cap_value));

    logic pass;
    assign pass = finished && mismatches == 16'd0;

    logic [24:0] beat = '0;
    always_ff @(posedge clk) beat <= beat + 1'b1;

    assign LEDR = {beat[24], 4'd0, core_err, timed_out, !finished, finished && !pass, pass};

    // active-low segments, {g,f,e,d,c,b,a}
    function automatic logic [6:0] seg(input logic [3:0] v);
        case (v)
            4'h0: return 7'b1000000; 4'h1: return 7'b1111001; 4'h2: return 7'b0100100;
            4'h3: return 7'b0110000; 4'h4: return 7'b0011001; 4'h5: return 7'b0010010;
            4'h6: return 7'b0000010; 4'h7: return 7'b1111000; 4'h8: return 7'b0000000;
            4'h9: return 7'b0010000; 4'hA: return 7'b0001000; 4'hB: return 7'b0000011;
            4'hC: return 7'b1000110; 4'hD: return 7'b0100001; 4'hE: return 7'b0000110;
            default: return 7'b0001110;
        endcase
    endfunction

    localparam logic [6:0] SEG_P = 7'b0001100, SEG_A = 7'b0001000, SEG_S = 7'b0010010,
                           SEG_DASH = 7'b0111111;

    localparam logic [6:0] SEG_OFF = 7'b1111111;

    always_comb begin
        {HEX5, HEX4} = {2{SEG_OFF}};
        if (sw_q[9]) begin
            {HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} = {seg(cap_value[23:20]), seg(cap_value[19:16]),
                seg(cap_value[15:12]), seg(cap_value[11:8]), seg(cap_value[7:4]), seg(cap_value[3:0])};
        end else if (!finished) begin
            {HEX3, HEX2, HEX1, HEX0} = {seg(mark[7:4]), seg(mark[3:0]), SEG_DASH, SEG_DASH};
        end else if (pass) begin
            {HEX3, HEX2, HEX1, HEX0} = {SEG_P, SEG_A, SEG_S, SEG_S};
        end else begin
            HEX3 = seg(first_bad_mark[7:4]);
            HEX2 = seg(first_bad_mark[3:0]);
            HEX1 = seg(mismatches > 16'hFF ? 4'hF : mismatches[7:4]);
            HEX0 = seg(mismatches > 16'hFF ? 4'hF : mismatches[3:0]);
        end
    end

endmodule
