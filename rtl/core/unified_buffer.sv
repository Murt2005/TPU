`timescale 1ns / 1ps

// unified buffer: on-chip activations, N int8 per entry. LD writes host data, ACT
// writes a layer's requantized output (and has priority), MM reads rows into the
// array (and has priority), ACT reads for RD_UB
module unified_buffer #(
    parameter int N     = 8,
    parameter int DEPTH = 16384,
    parameter int AW    = $clog2(DEPTH)
) (
    input  logic            clk,

    input  logic            ld_we,
    input  logic [AW-1:0]   ld_waddr,
    input  logic [N*8-1:0]  ld_wdata,
    input  logic            act_we,
    input  logic [AW-1:0]   act_waddr,
    input  logic [N*8-1:0]  act_wdata,

    input  logic            mm_re,
    input  logic [AW-1:0]   mm_raddr,
    input  logic [AW-1:0]   act_raddr,
    output logic [N*8-1:0]  rdata          // one cycle after the address
);

    logic [N*8-1:0] ub [DEPTH];

    always_ff @(posedge clk) begin
        if (act_we)     ub[act_waddr] <= act_wdata;
        else if (ld_we) ub[ld_waddr]  <= ld_wdata;
        rdata <= ub[mm_re ? mm_raddr : act_raddr];
    end

endmodule
