`timescale 1ns / 1ps

module systolic_data_setup_tb;
    localparam int DATA_WIDTH = 8;
    localparam int ARRAY_ROWS = 2;

    logic clk;
    logic reset;

    // Inputs from a simulated Unified Buffer
    logic signed [DATA_WIDTH-1:0] ub_read_data [ARRAY_ROWS];
    logic                         ub_read_valid;

    // Skewed outputs to the MMU
    logic signed [DATA_WIDTH-1:0] mmu_in_row   [ARRAY_ROWS];
    logic                         mmu_in_valid [ARRAY_ROWS];

    int errors = 0;

    systolic_data_setup #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .DATA_WIDTH(DATA_WIDTH)
    ) uut (
        .clk(clk),
        .reset(reset),
        .ub_read_data(ub_read_data),
        .ub_read_valid(ub_read_valid),
        .mmu_in_row(mmu_in_row),
        .mmu_in_valid(mmu_in_valid)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        reset = 1;
        ub_read_valid = 0;
        ub_read_data[0] = 0;
        ub_read_data[1] = 0;

        #15 reset = 0;
        @(posedge clk);
        #1;

        $display("\n Starting systolic data setup Testbench\n");

        // Cycle 0: Feed Row 0 of Activations [1, 2]
        ub_read_data[0] = 8'sd1;
        ub_read_data[1] = 8'sd2;
        ub_read_valid   = 1'b1;
        
        // Check combinational pass-through for row 0 immediately
        if (mmu_in_row[0] !== 8'sd1 || mmu_in_valid[0] !== 1'b1) begin
            $error("[FAIL] Row 0 should pass through with 0 delay.");
            errors++;
        end

        @(posedge clk);
        #1;
        
        // Cycle 1: Feed Row 1 of Activations [3, 4]
        ub_read_data[0] = 8'sd3;
        ub_read_data[1] = 8'sd4;
        ub_read_valid   = 1'b1;

        // Check that Row 1's previous input (2) has now arrived
        if (mmu_in_row[1] !== 8'sd2 || mmu_in_valid[1] !== 1'b1) begin
            $error("[FAIL] Row 1 should have a 1-cycle delay (expected 2).");
            errors++;
        end

        @(posedge clk);
        #1;

        // Cycle 2: Stop feeding
        ub_read_data[0] = 8'sd0;
        ub_read_data[1] = 8'sd0;
        ub_read_valid   = 1'b0;

        // Check that Row 1's last input (4) arrives
        if (mmu_in_row[1] !== 8'sd4 || mmu_in_valid[1] !== 1'b1) begin
            $error("[FAIL] Row 1 should output delayed value 4.");
            errors++;
        end

        if (errors == 0) $display(">>> All systolic data setup tests passed <<<\n");
        $finish;
    end
endmodule
