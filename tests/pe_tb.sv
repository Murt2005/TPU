`timescale 1ns / 1ps

module pe_tb;
    // Clock & Reset
    logic                clk;
    logic                reset;

    // Activation interface
    logic signed [7:0]   in_activation;
    logic                in_activation_valid;
    logic signed [7:0]   out_activation;
    logic                out_activation_valid;

    // Partial Sum interface
    logic signed [15:0]  in_partial_sum;
    logic                in_partial_sum_valid;
    logic signed [15:0]  out_partial_sum;
    logic                out_partial_sum_valid;

    // Configuration / Weight stream interface
    logic                loading_phase;
    logic                capture_weight;
    logic signed [7:0]   in_weight;
    logic                in_weight_valid;
    logic signed [7:0]   out_weight;
    logic                out_weight_valid;

    int errors = 0; // Track failures

    // Instantiate Unit Under Test (UUT) using implicit port connection
    pe uut (.*);

    // Clock Generation (100MHz clock period = 10ns)
    always #5 clk = ~clk;

    // --- SELF-CHECKING COMPUTE TASK ---
    // Note: Because the PE uses sequential registers for outputs, we drive 
    // the inputs on one clock cycle and read back the output on the subsequent clock cycle.
    task check_compute(
        input logic signed [7:0]  test_activation,
        input logic               test_act_valid,
        input logic signed [15:0] test_partial_sum,
        input logic               test_psum_valid,
        input logic signed [15:0] expected_partial_sum,
        input logic               expected_psum_valid,
        input logic signed [7:0]  expected_activation,
        input logic               expected_act_valid
    );
        begin
            // 1. Drive inputs synchronously on the clock edge
            @(posedge clk);
            #1; // Minor skew after clock edge to mimic upstream driver
            in_activation        = test_activation;
            in_activation_valid  = test_act_valid;
            in_partial_sum       = test_partial_sum;
            in_partial_sum_valid = test_psum_valid;
            
            // 2. Wait for the PE to capture inputs and compute output values
            @(posedge clk);
            #1; // Sample shortly after the rising edge to ensure signals are stable
            
            // 3. Evaluate results
            if (out_partial_sum       !== expected_partial_sum || 
                out_partial_sum_valid !== expected_psum_valid  || 
                out_activation        !== expected_activation   || 
                out_activation_valid  !== expected_act_valid) begin
                
                $error("[FAIL] Time: %0t\n\
  Inputs   -> Act: %d (V:%b) | PSum: %d (V:%b)\n\
  Got      -> Act: %d (V:%b) | PSum: %d (V:%b)\n\
  Expected -> Act: %d (V:%b) | PSum: %d (V:%b)", 
                       $time, 
                       test_activation, test_act_valid, test_partial_sum, test_psum_valid,
                       out_activation, out_activation_valid, out_partial_sum, out_partial_sum_valid,
                       expected_activation, expected_act_valid, expected_partial_sum, expected_psum_valid);
                errors++;
            end else begin
                $display("[PASS] Time: %0t | Out PSum: %5d (Valid: %b) | Out Act: %3d (Valid: %b)", 
                         $time, out_partial_sum, out_partial_sum_valid, out_activation, out_activation_valid);
            end
        end
    endtask

    // --- MAIN TEST BENCH SEQUENCE ---
    initial begin
        // Initialize all inputs to default states
        clk                  = 0; 
        reset                = 1;
        in_activation        = 8'sd0; 
        in_activation_valid  = 1'b0;
        in_partial_sum       = 16'sd0; 
        in_partial_sum_valid = 1'b0;
        loading_phase        = 1'b0; 
        capture_weight       = 1'b0; 
        in_weight            = 8'sd0;
        in_weight_valid      = 1'b0;
        
        // Assert reset for 2 full clock cycles
        #20;
        @(posedge clk);
        #1 reset = 0;

        // ==========================================
        // STEP 1: LOAD WEIGHT (Weight = 5)
        // ==========================================
        $display("--- Step 1: Loading Weight into Stationary Register ---");
        @(posedge clk);
        #1;
        loading_phase   = 1'b1; 
        capture_weight  = 1'b1; 
        in_weight       = 8'sd5;
        in_weight_valid = 1'b1;
        
        @(posedge clk);
        #1;
        // Terminate configuration phase, clear control lines
        loading_phase   = 1'b0; 
        capture_weight  = 1'b0; 
        in_weight       = 8'sd0;
        in_weight_valid = 1'b0;

        // ==========================================
        // STEP 2: TEST COMPUTE SCENARIOS
        // ==========================================
        $display("\n--- Step 2: Starting PE Compute Tests ---");
        
        // Test Case A: Normal Positive Values (5 * 3 + 10 = 25)
        // Format: check_compute(act, act_v, psum, psum_v, exp_psum, exp_psum_v, exp_act, exp_act_v)
        check_compute(8'sd3, 1'b1, 16'sd10, 1'b1, 16'sd25, 1'b1, 8'sd3, 1'b1);
        
        // Test Case B: Negative Activation (5 * -2 + 0 = -10)
        check_compute(-8'sd2, 1'b1, 16'sd0, 1'b1, -16'sd10, 1'b1, -8'sd2, 1'b1);
        
        // Test Case C: Valid Bubble Handling - Activating data stream missing valid token
        // Datapath should reject computation, assert 0 on outputs, and de-assert valid tags
        check_compute(8'sd4, 1'b0, 16'sd20, 1'b1, 16'sd0, 1'b0, 8'sd4, 1'b0);
        
        // Test Case D: Zero Handling (5 * 0 + 100 = 100) with restored valid stream
        check_compute(8'sd0, 1'b1, 16'sd100, 1'b1, 16'sd100, 1'b1, 8'sd0, 1'b1);
        
        // Test Case E: Boundary Processing - Max positive 8-bit input (5 * 127 + 0 = 635)
        check_compute(8'sd127, 1'b1, 16'sd0, 1'b1, 16'sd635, 1'b1, 8'sd127, 1'b1);

        // ==========================================
        // STEP 3: WRAP UP SUMMARY
        // ==========================================
        // Return datapath variables back to idle
        @(posedge clk);
        #1;
        in_activation_valid  = 1'b0;
        in_partial_sum_valid = 1'b0;
        #10;

        if (errors == 0) begin
            $display("\n=====================================");
            $display(">>> SUCCESS: ALL PE TESTS PASSED! <<<");
            $display("=====================================\n");
        end else begin
            $display("\n=====================================");
            $display(">>> FAILURE: %0d PE TESTS FAILED <<<", errors);
            $display("=====================================\n");
        end

        $finish;
    end

    // --- WAVEFORM LOGGING ---
    initial begin
        $dumpfile("pe_simulation.vcd");
        $dumpvars(0, pe_tb);
    end

endmodule
