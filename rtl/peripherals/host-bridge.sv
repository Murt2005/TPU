`timescale 1ns / 1ps

// instruction-stream host bridge: 14-register Avalon-MM slave, read latency 1,
// waitrequest only on writes into a full FIFO
module host_bridge (
    input  logic        clk,
    input  logic        reset,

    input  logic [3:0]  avs_address,                         // word index
    input  logic        avs_read,
    output logic [31:0] avs_readdata,
    input  logic        avs_write,
    input  logic [31:0] avs_writedata,
    output logic        avs_waitrequest,

    output logic        instruction_push_out,
    output logic [63:0] instruction_word_out,
    input  logic        instruction_full_in,
    output logic        data_push_out,
    output logic [31:0] data_word_out,
    input  logic        data_full_in,
    output logic        output_pop_out,
    input  logic [31:0] output_word_in,
    input  logic        output_empty_in,

    output logic        core_reset_out,                      // CTRL.RESET: flush, clear ERR, memories kept
    output logic        clear_done_out,
    output logic        clear_performance_out,
    input  logic        done_in,
    input  logic        error_in,
    input  logic [7:0]  error_code_in,
    input  logic [31:0] error_sequence_in,
    input  logic [15:0] tag_in,
    input  logic        idle_in,
    input  logic [9:0]  instruction_free_in,
    input  logic [10:0] data_free_in,
    input  logic [10:0] output_count_in,
    input  logic [31:0] performance_cycles_in,
    input  logic [31:0] performance_matmul_beats_in,
    input  logic [31:0] performance_matmul_weight_stalls_in,
    input  logic [31:0] performance_matmul_sync_stalls_in,
    output logic        clear_profile_out,
    output logic        profile_read_out,
    input  logic [31:0] profile_word_in,
    input  logic [15:0] profile_level_in,
    input  logic [15:0] profile_dropped_in
);

    localparam logic [3:0] REGISTER_INSTRUCTION_LOW  = 4'd0;
    localparam logic [3:0] REGISTER_INSTRUCTION_HIGH = 4'd1;
    localparam logic [3:0] REGISTER_DATA             = 4'd2;
    localparam logic [3:0] REGISTER_OUTPUT           = 4'd3;
    localparam logic [3:0] REGISTER_STATUS           = 4'd4;
    localparam logic [3:0] REGISTER_LEVELS           = 4'd5;
    localparam logic [3:0] REGISTER_CONTROL          = 4'd6;
    localparam logic [3:0] REGISTER_ERROR_SEQUENCE   = 4'd7;
    localparam logic [3:0] REGISTER_CYCLES           = 4'd8;
    localparam logic [3:0] REGISTER_MATMUL_BEATS     = 4'd9;
    localparam logic [3:0] REGISTER_WEIGHT_STALLS    = 4'd10;
    localparam logic [3:0] REGISTER_SYNC_STALLS      = 4'd11;
    localparam logic [3:0] REGISTER_PROFILE_LEVEL    = 4'd12;
    localparam logic [3:0] REGISTER_PROFILE_DATA     = 4'd13;

    logic [31:0] instruction_low;
    logic        underflow;

    assign avs_waitrequest = avs_write && ((avs_address == REGISTER_INSTRUCTION_HIGH && instruction_full_in)
                                        || (avs_address == REGISTER_DATA && data_full_in));

    logic write_accepted;
    assign write_accepted = avs_write && !avs_waitrequest;

    assign instruction_push_out  = write_accepted && avs_address == REGISTER_INSTRUCTION_HIGH;
    assign instruction_word_out  = {avs_writedata, instruction_low};
    assign data_push_out         = write_accepted && avs_address == REGISTER_DATA;
    assign data_word_out         = avs_writedata;
    assign output_pop_out        = avs_read && avs_address == REGISTER_OUTPUT && !output_empty_in;
    assign core_reset_out        = write_accepted && avs_address == REGISTER_CONTROL && avs_writedata[0];
    assign clear_done_out        = write_accepted && avs_address == REGISTER_CONTROL && avs_writedata[1];
    assign clear_performance_out = write_accepted && avs_address == REGISTER_CONTROL && avs_writedata[2];
    assign clear_profile_out     = write_accepted && avs_address == REGISTER_CONTROL && avs_writedata[3];
    assign profile_read_out      = avs_read && avs_address == REGISTER_PROFILE_DATA;

    always_ff @(posedge clk) begin
        if (reset) begin
            instruction_low <= '0;
            underflow       <= 1'b0;
            avs_readdata    <= '0;
        end else begin
            if (write_accepted && avs_address == REGISTER_INSTRUCTION_LOW)
                instruction_low <= avs_writedata;
            if (core_reset_out || clear_done_out)
                underflow <= 1'b0;
            if (avs_read && avs_address == REGISTER_OUTPUT && output_empty_in)
                underflow <= 1'b1;
            if (avs_read) begin
                case (avs_address)
                    REGISTER_OUTPUT:         avs_readdata <= output_empty_in ? 32'd0 : output_word_in;
                    REGISTER_STATUS:         avs_readdata <= {tag_in, error_code_in, 4'd0, underflow, idle_in, error_in, done_in};
                    REGISTER_LEVELS:         avs_readdata <= {output_count_in, data_free_in, instruction_free_in};
                    REGISTER_ERROR_SEQUENCE: avs_readdata <= error_sequence_in;
                    REGISTER_CYCLES:         avs_readdata <= performance_cycles_in;
                    REGISTER_MATMUL_BEATS:   avs_readdata <= performance_matmul_beats_in;
                    REGISTER_WEIGHT_STALLS:  avs_readdata <= performance_matmul_weight_stalls_in;
                    REGISTER_SYNC_STALLS:    avs_readdata <= performance_matmul_sync_stalls_in;
                    REGISTER_PROFILE_LEVEL:  avs_readdata <= {profile_dropped_in, profile_level_in};
                    REGISTER_PROFILE_DATA:   avs_readdata <= profile_word_in;
                    default:                 avs_readdata <= 32'd0;
                endcase
            end
        end
    end

endmodule
