`timescale 1ns / 1ps

module unified_buffer_tb;
    localparam int ROWS       = 2;
    localparam int COLS       = 2;
    localparam int DATA_WIDTH = 8;
    localparam int ADDR_WIDTH = $clog2(ROWS);   // 1 bit for ROWS=2

    logic clk, reset;

    logic [ADDR_WIDTH-1:0]        host_write_addr;
    logic signed [DATA_WIDTH-1:0] host_write_data [COLS];
    logic                         host_write_valid;

    logic [ADDR_WIDTH-1:0]        host_read_addr;
    logic signed [DATA_WIDTH-1:0] host_read_data [COLS];
    logic                         host_read_en;
    logic                         host_read_valid;

    logic [ADDR_WIDTH-1:0]        ub_read_addr;
    logic                         ub_read_en;
    logic signed [DATA_WIDTH-1:0] ub_read_data [ROWS];
    logic                         ub_read_valid;

    logic signed [DATA_WIDTH-1:0] act_write_data [COLS];
    logic                         act_write_valid;
    logic                         act_write_addr_reset;
    logic                         bank_swap;

    int errors = 0;

    // Shared read-result holders (avoids local-variable issues in tasks)
    logic signed [DATA_WIDTH-1:0] rd0, rd1;

    unified_buffer #(
        .ROWS(ROWS), .COLS(COLS), .DATA_WIDTH(DATA_WIDTH)
    ) uut (.*);

    always #5 clk = ~clk;

    // Write one row via host port (synchronous, occupies 1 clock cycle)
    task automatic host_write_row(input int addr, input int d0, input int d1);
        host_write_addr    = ADDR_WIDTH'(addr);
        host_write_data[0] = DATA_WIDTH'(signed'(d0));
        host_write_data[1] = DATA_WIDTH'(signed'(d1));
        host_write_valid   = 1'b1;
        @(posedge clk); #1;
        host_write_valid = 1'b0;
    endtask

    // Assert ub_read_en for one cycle at addr, then wait for the second
    // pipeline stage.  After the task returns, ub_read_valid is high and
    // ub_read_data holds the result (captured into rd0/rd1).
    task automatic ub_read_row(input int addr);
        ub_read_addr = ADDR_WIDTH'(addr);
        ub_read_en   = 1'b1;
        @(posedge clk); #1;   // stage-1 posedge: registers addr & en
        ub_read_en = 1'b0;
        @(posedge clk); #1;   // stage-2 posedge: outputs data, valid=1
        rd0 = ub_read_data[0];
        rd1 = ub_read_data[1];
        if (!ub_read_valid) begin
            $error("[FAIL] ub_read_valid not high 2 cycles after ub_read_en at time %0t", $time);
            errors++;
        end
    endtask

    // Write one row via the activation port
    task automatic act_write_row(input int d0, input int d1);
        act_write_data[0] = DATA_WIDTH'(signed'(d0));
        act_write_data[1] = DATA_WIDTH'(signed'(d1));
        act_write_valid   = 1'b1;
        @(posedge clk); #1;
        act_write_valid = 1'b0;
    endtask

    // Read one row via host port (1-cycle latency).
    // After the task returns, host_read_valid is high and rd0/rd1 hold data.
    task automatic host_read_row(input int addr);
        host_read_addr = ADDR_WIDTH'(addr);
        host_read_en   = 1'b1;
        @(posedge clk); #1;   // posedge: registers en, reads mem, outputs data
        host_read_en = 1'b0;
        rd0 = host_read_data[0];
        rd1 = host_read_data[1];
        if (!host_read_valid) begin
            $error("[FAIL] host_read_valid not high 1 cycle after host_read_en at time %0t", $time);
            errors++;
        end
    endtask

    task automatic check(input string name, input int exp0, input int exp1);
        if (rd0 !== DATA_WIDTH'(signed'(exp0)) || rd1 !== DATA_WIDTH'(signed'(exp1))) begin
            $error("[FAIL] %s: got [%0d, %0d], expected [%0d, %0d]",
                   name, $signed(rd0), $signed(rd1), exp0, exp1);
            errors++;
        end else begin
            $display("[PASS] %s: [%0d, %0d]", name, $signed(rd0), $signed(rd1));
        end
    endtask

    initial begin
        clk = 0; reset = 1;
        host_write_addr = '0; host_write_data[0] = '0; host_write_data[1] = '0;
        host_write_valid = 0;
        host_read_addr = '0; host_read_en = 0;
        ub_read_addr = '0; ub_read_en = 0;
        act_write_data[0] = '0; act_write_data[1] = '0;
        act_write_valid = 0; act_write_addr_reset = 0; bank_swap = 0;

        #15 reset = 0;
        @(posedge clk); #1;

        $display("\n=== unified_buffer Testbench ===\n");

        // -------------------------------------------------------------------
        // Test 1: host_write then ub_read — verifies 2-cycle read latency
        //   Write [[10,20],[30,40]] via host port, read back via ub_read port.
        // -------------------------------------------------------------------
        $display("[Test 1] Host write → UB read (2-cycle latency)");
        host_write_row(0, 10, 20);
        host_write_row(1, 30, 40);

        ub_read_row(0);
        check("T1 row 0", 10, 20);
        ub_read_row(1);
        check("T1 row 1", 30, 40);

        // -------------------------------------------------------------------
        // Test 2: act_write then host_read — verifies shadow-bank separation
        //   and 1-cycle host read latency.
        //   Active bank still has [[10,20],[30,40]] from Test 1; shadow is
        //   untouched, so act_write rows land at addresses 0 and 1 of shadow.
        // -------------------------------------------------------------------
        $display("\n[Test 2] Activation write → host read (1-cycle latency, shadow bank)");
        act_write_row(50, 60);
        act_write_row(70, 80);

        host_read_row(0);
        check("T2 row 0", 50, 60);
        host_read_row(1);
        check("T2 row 1", 70, 80);

        // -------------------------------------------------------------------
        // Test 3: bank_swap — shadow (activation output) becomes active (SDS input)
        //   After swap, ub_read should return [50,60] / [70,80].
        // -------------------------------------------------------------------
        $display("\n[Test 3] Bank swap: activation output readable via ub_read after swap");
        bank_swap = 1'b1;
        @(posedge clk); #1;
        bank_swap = 1'b0;

        ub_read_row(0);
        check("T3 row 0 (post-swap)", 50, 60);
        ub_read_row(1);
        check("T3 row 1 (post-swap)", 70, 80);

        // -------------------------------------------------------------------
        // Test 4: act_write_addr_reset
        //   Write one row (ptr=0 → row 0), reset pointer, write again.
        //   Second write must overwrite row 0, not row 1.
        //   After Test 3: bank_sel=1, shadow=0; act_write goes to shadow (bank 0).
        //   bank 0 currently holds [[10,20],[30,40]] from Test 1.
        // -------------------------------------------------------------------
        $display("\n[Test 4] act_write_addr_reset: pointer resets to 0");
        act_write_row(11, 22);         // ptr=0 → shadow row 0 = [11,22]; ptr → 1
        act_write_addr_reset = 1'b1;
        @(posedge clk); #1;
        act_write_addr_reset = 1'b0;
        act_write_row(33, 44);         // ptr resets to 0 → shadow row 0 overwritten

        host_read_row(0);              // host_read reads from shadow bank
        check("T4 row 0 (after reset+rewrite)", 33, 44);
        // Row 1 should still be the original bank-0 row-1 value [30,40]
        // (written in Test 1 into bank 0 when it was active).
        host_read_row(1);
        check("T4 row 1 (untouched)", 30, 40);

        // -------------------------------------------------------------------
        // Test 5: ub_read_valid stays low with no ub_read_en
        // -------------------------------------------------------------------
        $display("\n[Test 5] ub_read_valid stays low without ub_read_en");
        repeat(4) @(posedge clk); #1;
        if (ub_read_valid !== 1'b0) begin
            $error("[FAIL] ub_read_valid unexpectedly high at time %0t", $time);
            errors++;
        end else begin
            $display("[PASS] ub_read_valid correctly stays low");
        end

        // -------------------------------------------------------------------
        // Test 6: host_read_valid stays low with no host_read_en
        // -------------------------------------------------------------------
        $display("\n[Test 6] host_read_valid stays low without host_read_en");
        repeat(4) @(posedge clk); #1;
        if (host_read_valid !== 1'b0) begin
            $error("[FAIL] host_read_valid unexpectedly high at time %0t", $time);
            errors++;
        end else begin
            $display("[PASS] host_read_valid correctly stays low");
        end

        // -------------------------------------------------------------------
        // Test 7: reset clears ub_read_valid even with a pending read in pipe
        // -------------------------------------------------------------------
        $display("\n[Test 7] Reset clears ub_read_valid mid-pipeline");
        ub_read_en = 1'b1;
        @(posedge clk); #1;   // stage-1 captures en=1
        ub_read_en = 1'b0;
        reset = 1'b1;
        @(posedge clk); #1;   // reset should suppress stage-2 output
        if (ub_read_valid !== 1'b0) begin
            $error("[FAIL] ub_read_valid not suppressed by reset at time %0t", $time);
            errors++;
        end else begin
            $display("[PASS] ub_read_valid suppressed by reset");
        end
        reset = 1'b0;
        @(posedge clk); #1;
        if (ub_read_valid !== 1'b0) begin
            $error("[FAIL] ub_read_valid not low the cycle after reset deasserts");
            errors++;
        end else begin
            $display("[PASS] ub_read_valid stays low after reset deasserts");
        end

        // -------------------------------------------------------------------
        // Test 8: post-reset host_write + ub_read round-trip
        //   Verify UB resumes correctly after reset (bank_sel back to 0).
        // -------------------------------------------------------------------
        $display("\n[Test 8] Post-reset write/read round-trip");
        host_write_row(0, -10, -20);
        host_write_row(1,  15,  25);

        ub_read_row(0);
        check("T8 row 0", -10, -20);
        ub_read_row(1);
        check("T8 row 1", 15, 25);

        // -------------------------------------------------------------------
        $display("\n=== SIMULATION COMPLETE ===");
        if (errors == 0)
            $display(">>> ALL unified_buffer TESTS PASSED <<<");
        else
            $display(">>> SIMULATION FAILED WITH %0d ERRORS <<<", errors);

        $finish;
    end

    initial begin
        $dumpfile("unified_buffer_simulation.vcd");
        $dumpvars(0, unified_buffer_tb);
    end

endmodule
