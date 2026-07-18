`timescale 1ns / 1ps

module systolic_data_setup #(
    parameter int ARRAY_ROWS   = 2,
    parameter int DATA_WIDTH   = 8
) (
    input  logic                                  clk,
    input  logic                                  reset,

    input  logic signed [ARRAY_ROWS-1:0][DATA_WIDTH-1:0] ub_read_data,
    input  logic                                  ub_read_valid,

    output logic signed [ARRAY_ROWS-1:0][DATA_WIDTH-1:0] mmu_in_row,
    output logic        [ARRAY_ROWS-1:0]                 mmu_in_valid
);

    genvar i, j;
    generate
        for (i = 0; i < ARRAY_ROWS; i++) begin : row_skew
            if (i == 0) begin : gen_passthrough
                assign mmu_in_row[i]   = ub_read_data[i];
                assign mmu_in_valid[i] = ub_read_valid;
            end else begin : gen_delay_line
                logic signed [DATA_WIDTH-1:0] shift_data  [i:0];
                logic                         shift_valid [i:0];

                assign shift_data[0]  = ub_read_data[i];
                assign shift_valid[0] = ub_read_valid;

                for (j = 0; j < i; j++) begin : pipeline
                    always_ff @(posedge clk) begin
                        if (reset) begin
                            shift_data[j+1]  <= '0;
                            shift_valid[j+1] <= 1'b0;
                        end else begin
                            shift_data[j+1]  <= shift_data[j];
                            shift_valid[j+1] <= shift_valid[j];
                        end
                    end
                end

                assign mmu_in_row[i]   = shift_data[i];
                assign mmu_in_valid[i] = shift_valid[i];
            end
        end
    endgenerate

endmodule
