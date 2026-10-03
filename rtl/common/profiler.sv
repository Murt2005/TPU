`timescale 1ns / 1ps

// instruction-level profiler: one 128-bit event for every cycle in which the
// dispatcher issues, or an engine pops or completes an instruction, into a FIFO the
// host drains through PROFILE_DATA. each engine pops and completes in queue order
// and the dispatcher routes by opcode, so the host recovers which instruction every
// bit belongs to from the program alone. an event:
//   [39:0]    cycle (free-running since power-on or CLEAR_PROFILE)
//   [40]      the dispatcher issued an instruction
//   [44:41]   engines that popped an instruction (LD, WT, MM, ACT)
//   [48:45]   engines that completed one
//   [124:49]  per engine, 19 bits at 49 + 19e: cycles it was blocked since its last
//             completion (a WAIT unsatisfied, starved of data, a weight stall, DDR3
//             waits), saturating at 2^19 - 1; meaningful where the done bit is set.
//             a WAIT's own wait the host can also take from the timestamps
// only power-on and CLEAR_PROFILE reset it: CTRL.RESET runs before every program
// and the profile spans many. a full FIFO drops events and counts them
module profiler #(
    parameter int DEPTH = 512
) (
    input  logic        clk,
    input  logic        reset,              // power-on
    input  logic        clear_in,           // CTRL.CLEAR_PROFILE

    input  logic        dispatch_in,
    input  logic [3:0]  pop_in,
    input  logic [3:0]  done_in,
    input  logic [3:0]  blocked_in,

    input  logic        read_in,            // a read of PROFILE_DATA: the word below, then the next
    output logic [31:0] word_out,
    output logic [15:0] level_out,          // whole events readable
    output logic [15:0] dropped_out         // events lost to a full FIFO, saturating
);

    logic        restart;
    logic [39:0] cycle;
    localparam int BLOCKED_WIDTH = 19;
    localparam logic [BLOCKED_WIDTH-1:0] BLOCKED_MAX = '1;
    logic [BLOCKED_WIDTH-1:0] blocked_cycles [4];
    logic        event_now, full, empty, pop_event;
    logic [127:0] event_word, head;
    logic [1:0]  word_index;
    logic        written;

    assign restart   = reset || clear_in;
    assign event_now = dispatch_in || pop_in != '0 || done_in != '0;
    always_comb begin
        event_word = '0;
        event_word[39:0]  = cycle;
        event_word[40]    = dispatch_in;
        event_word[44:41] = pop_in;
        event_word[48:45] = done_in;
        for (int engine = 0; engine < 4; engine++)
            event_word[49 + BLOCKED_WIDTH*engine +: BLOCKED_WIDTH] = blocked_cycles[engine] + BLOCKED_WIDTH'(blocked_in[engine] && blocked_cycles[engine] != BLOCKED_MAX);
    end

    block_fifo #(.WIDTH(128), .DEPTH(DEPTH)) u_events (
        .clk(clk), .reset(restart),
        .write_enable_in(event_now), .write_data_in(event_word),
        .read_enable_in(pop_event), .read_data_out(head),
        .full_out(full), .empty_out(empty));

    assign word_out  = empty ? 32'd0 : head[32*word_index +: 32];
    assign pop_event = read_in && !empty && word_index == 2'd3;

    always_ff @(posedge clk) begin
        if (restart) begin
            cycle       <= '0;
            word_index  <= '0;
            level_out   <= '0;
            dropped_out <= '0;
            written     <= 1'b0;
            for (int engine = 0; engine < 4; engine++) blocked_cycles[engine] <= '0;
        end else begin
            cycle <= cycle + 40'd1;
            for (int engine = 0; engine < 4; engine++)
                if (done_in[engine])
                    blocked_cycles[engine] <= '0;
                else if (blocked_in[engine] && blocked_cycles[engine] != BLOCKED_MAX)
                    blocked_cycles[engine] <= blocked_cycles[engine] + BLOCKED_WIDTH'(1);
            if (read_in && !empty)
                word_index <= word_index + 2'd1;
            // an entry is readable two cycles after its write (block_fifo)
            written   <= event_now && !full;
            level_out <= level_out + 16'(written) - 16'(pop_event);
            if (event_now && full && dropped_out != 16'hFFFF)
                dropped_out <= dropped_out + 16'd1;
        end
    end

endmodule
