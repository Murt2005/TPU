`timescale 1ns / 1ps

// replays a ROM transcript into isa_bridge's Avalon slave and checks every read.
// entry = {op[3:0], addr[3:0], data[31:0]}; the transcript comes from the
// reference model (gen_selftest.py), so no host is needed to validate silicon
module isa_replay #(
    parameter int    DEPTH    = 16384,
    parameter        ROM_FILE = "isa_selftest.hex",
    parameter int    TIMEOUT  = 1 << 26        // cycles per WAIT_DONE
) (
    input  logic        clk,
    input  logic        reset,

    output logic [3:0]  avs_address,
    output logic        avs_read,
    input  logic [31:0] avs_readdata,
    output logic        avs_write,
    output logic [31:0] avs_writedata,
    input  logic        avs_waitrequest,

    output logic        finished,
    output logic        timed_out,
    output logic        core_err,
    output logic [15:0] mismatches,
    output logic [7:0]  first_bad_mark,    // MARK of the first failing check
    output logic [7:0]  mark
);

    // op 0 is invalid on purpose: a ROM that failed to load fails, not spins
    localparam logic [3:0] OP_WR = 4'h1, OP_RD = 4'h2, OP_WAIT_DONE = 4'h3, OP_MARK = 4'h4,
                           OP_END = 4'hF;
    localparam logic [3:0] A_STATUS = 4'd4;
    localparam int AW = $clog2(DEPTH);

    (* ram_style = "block" *) logic [39:0] rom [DEPTH];
    initial $readmemh(ROM_FILE, rom);

    logic [AW-1:0] pc;
    logic [39:0]   ent;
    logic [3:0]    op;
    assign op = ent[39:36];

    typedef enum logic [2:0] {S_FETCH, S_DECODE, S_WRITE, S_READ, S_CHECK, S_POLL, S_POLL_CHECK, S_DONE} state_t;
    state_t state;
    logic [31:0] waited;

    always_ff @(posedge clk) ent <= rom[pc];

    assign avs_write     = state == S_WRITE;
    assign avs_read      = state == S_READ || state == S_POLL;
    assign avs_address   = state == S_POLL ? A_STATUS : ent[35:32];
    assign avs_writedata = ent[31:0];

    task automatic fail();
        if (mismatches == 16'd0)
            first_bad_mark <= mark;
        if (mismatches != 16'hFFFF)
            mismatches <= mismatches + 16'd1;
    endtask

    always_ff @(posedge clk) begin
        if (reset) begin
            state          <= S_FETCH;
            pc             <= '0;
            finished       <= 1'b0;
            timed_out      <= 1'b0;
            core_err       <= 1'b0;
            mismatches     <= '0;
            first_bad_mark <= '0;
            mark           <= '0;
            waited         <= '0;
        end else begin
            case (state)
                S_FETCH: state <= S_DECODE;            // ROM read latency
                S_DECODE: begin
                    case (op)
                        OP_WR:        state <= S_WRITE;
                        OP_RD:        state <= S_READ;
                        OP_WAIT_DONE: begin
                            waited <= '0;
                            state  <= S_POLL;
                        end
                        OP_MARK: begin
                            mark  <= ent[7:0];
                            pc    <= pc + 1'b1;
                            state <= S_FETCH;
                        end
                        OP_END: begin
                            finished <= 1'b1;
                            state    <= S_DONE;
                        end
                        default: begin                 // a corrupt ROM counts as a failure
                            fail();
                            finished <= 1'b1;
                            state    <= S_DONE;
                        end
                    endcase
                end
                S_WRITE: if (!avs_waitrequest) begin
                    pc    <= pc + 1'b1;
                    state <= S_FETCH;
                end
                S_READ:  state <= S_CHECK;
                S_CHECK: begin                         // read latency 1
                    if (avs_readdata != ent[31:0])
                        fail();
                    pc    <= pc + 1'b1;
                    state <= S_FETCH;
                end
                S_POLL: begin
                    waited <= waited + 32'd1;
                    state  <= S_POLL_CHECK;
                end
                S_POLL_CHECK: begin
                    if (avs_readdata[1]) begin         // ERR: the transcript never expects one
                        core_err <= 1'b1;
                        fail();
                        finished <= 1'b1;
                        state    <= S_DONE;
                    end else if (avs_readdata[0]) begin
                        pc    <= pc + 1'b1;
                        state <= S_FETCH;
                    end else if (waited >= 32'(TIMEOUT)) begin
                        timed_out <= 1'b1;
                        fail();
                        finished  <= 1'b1;
                        state     <= S_DONE;
                    end else begin
                        state <= S_POLL;
                    end
                end
                default: ;                             // S_DONE: hold the result
            endcase
        end
    end

endmodule
