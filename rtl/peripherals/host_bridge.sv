`timescale 1ns / 1ps

// instruction-stream host bridge: 12-register Avalon-MM slave, read latency 1,
// waitrequest only on writes into a full FIFO
module host_bridge (
    input  logic        clk,
    input  logic        reset,

    input  logic [3:0]  avs_address,                      // word index
    input  logic        avs_read,
    output logic [31:0] avs_readdata,
    input  logic        avs_write,
    input  logic [31:0] avs_writedata,
    output logic        avs_waitrequest,

    output logic        instruction_push,
    output logic [63:0] instruction_word,
    input  logic        instruction_full,
    output logic        data_push,
    output logic [31:0] data_word,
    input  logic        data_full,
    output logic        output_pop,
    input  logic [31:0] output_word,
    input  logic        output_empty,

    output logic        core_reset,                       // CTRL.RESET: flush, clear ERR, memories kept
    output logic        clear_done,
    output logic        clear_performance,
    input  logic        done,
    input  logic        error,
    input  logic [7:0]  error_code,
    input  logic [31:0] error_sequence,
    input  logic [15:0] tag,
    input  logic        idle,
    input  logic [9:0]  instruction_free,
    input  logic [10:0] data_free,
    input  logic [10:0] output_count,
    input  logic [31:0] performance_cycles,
    input  logic [31:0] performance_matmul_beats,
    input  logic [31:0] performance_matmul_weight_stalls,
    input  logic [31:0] performance_matmul_sync_stalls
);

    localparam logic [3:0] REGISTER_INSTRUCTION_LOW = 4'd0,  REGISTER_INSTRUCTION_HIGH = 4'd1,  REGISTER_DATA  = 4'd2,  REGISTER_OUTPUT     = 4'd3;
    localparam logic [3:0] REGISTER_STATUS          = 4'd4,  REGISTER_LEVELS  = 4'd5,  REGISTER_CONTROL  = 4'd6,  REGISTER_ERROR_SEQUENCE = 4'd7;
    localparam logic [3:0] REGISTER_CYCLES          = 4'd8,  REGISTER_MATMUL_BEATS   = 4'd9,  REGISTER_WEIGHT_STALLS = 4'd10, REGISTER_SYNC_STALLS   = 4'd11;

    logic [31:0] instruction_low;
    logic        underflow;

    assign avs_waitrequest = avs_write && ((avs_address == REGISTER_INSTRUCTION_HIGH && instruction_full)
                                        || (avs_address == REGISTER_DATA && data_full));

    logic write_accepted;
    assign write_accepted = avs_write && !avs_waitrequest;

    assign instruction_push  = write_accepted && avs_address == REGISTER_INSTRUCTION_HIGH;
    assign instruction_word  = {avs_writedata, instruction_low};
    assign data_push         = write_accepted && avs_address == REGISTER_DATA;
    assign data_word         = avs_writedata;
    assign output_pop        = avs_read && avs_address == REGISTER_OUTPUT && !output_empty;
    assign core_reset        = write_accepted && avs_address == REGISTER_CONTROL && avs_writedata[0];
    assign clear_done        = write_accepted && avs_address == REGISTER_CONTROL && avs_writedata[1];
    assign clear_performance = write_accepted && avs_address == REGISTER_CONTROL && avs_writedata[2];

    always_ff @(posedge clk) begin
        if (reset) begin
            instruction_low <= '0;
            underflow       <= 1'b0;
            avs_readdata    <= '0;
        end else begin
            if (write_accepted && avs_address == REGISTER_INSTRUCTION_LOW)
                instruction_low <= avs_writedata;
            if (core_reset || clear_done)
                underflow <= 1'b0;
            if (avs_read && avs_address == REGISTER_OUTPUT && output_empty)
                underflow <= 1'b1;
            if (avs_read) begin
                case (avs_address)
                    REGISTER_OUTPUT:         avs_readdata <= output_empty ? 32'd0 : output_word;
                    REGISTER_STATUS:         avs_readdata <= {tag, error_code, 4'd0, underflow, idle, error, done};
                    REGISTER_LEVELS:         avs_readdata <= {output_count, data_free, instruction_free};
                    REGISTER_ERROR_SEQUENCE: avs_readdata <= error_sequence;
                    REGISTER_CYCLES:         avs_readdata <= performance_cycles;
                    REGISTER_MATMUL_BEATS:   avs_readdata <= performance_matmul_beats;
                    REGISTER_WEIGHT_STALLS:  avs_readdata <= performance_matmul_weight_stalls;
                    REGISTER_SYNC_STALLS:    avs_readdata <= performance_matmul_sync_stalls;
                    default:                 avs_readdata <= 32'd0;
                endcase
            end
        end
    end

endmodule
