`timescale 1ns / 1ps

module fifo_tb;
    localparam int WIDTH = 16;
    localparam int DEPTH = 4;

    logic                       clk;
    logic                       reset;
    logic                       write_enable;
    logic signed [WIDTH-1:0]    write_data;
    logic                       read_enable;
    logic signed [WIDTH-1:0]    read_data;
    logic                       full;
    logic                       empty;

    int errors = 0;

    fifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) uut (.*);

    always #5 clk = ~clk;

    task automatic check(string name, logic cond);
        if (!cond) begin
            $error("[FAIL] %s at time %0t", name, $time);
            errors++;
        end else begin
            $display("[PASS] %s at time %0t", name, $time);
        end
    endtask

    initial begin
        clk = 0;
        reset = 1;
        write_enable = 0;
        write_data = '0;
        read_enable = 0;
        #12 reset = 0;
        @(negedge clk);

        $display("\n=== Starting FIFO Testbench ===\n");

        check("empty after reset", empty == 1'b1);
        check("not full after reset", full == 1'b0);

        // Fill to DEPTH, confirm full flag
        for (int i = 0; i < DEPTH; i++) begin
            write_enable = 1'b1;
            write_data   = 10 + i;   // 10,11,12,13
            @(negedge clk);
        end
        write_enable = 1'b0;
        check("full after DEPTH writes", full == 1'b1);

        // Write-while-full is a no-op
        write_enable = 1'b1;
        write_data   = 16'sd999;
        @(negedge clk);
        write_enable = 1'b0;
        check("still full after write-while-full (no-op)", full == 1'b1);

        // Pure read: pop oldest entry (10)
        read_enable = 1'b1;
        check("read_data == 10 before pop", read_data == 16'sd10);
        @(negedge clk);
        read_enable = 1'b0;
        check("not full after one read", full == 1'b0);

        // True simultaneous read+write at mid-fill (count=3, not at a boundary).
        read_enable  = 1'b1;
        write_enable = 1'b1;
        write_data   = 16'sd100;
        check("read_data == 11 before simultaneous r/w", read_data == 16'sd11);
        @(negedge clk);
        read_enable  = 1'b0;
        write_enable = 1'b0;
        check("not full, not empty after simultaneous r/w", full == 1'b0 && empty == 1'b0);

        // Drain remaining 3 entries: 12, 13, 100
        begin
            int expected[3];
            expected = '{12, 13, 100};
            for (int i = 0; i < 3; i++) begin
                read_enable = 1'b1;
                check($sformatf("read_data == %0d", expected[i]), read_data == expected[i]);
                @(negedge clk);
            end
            read_enable = 1'b0;
        end
        check("empty after full drain", empty == 1'b1);

        // Read-while-empty is a no-op
        read_enable = 1'b1;
        @(negedge clk);
        read_enable = 1'b0;
        check("still empty after read-while-empty (no-op)", empty == 1'b1);

        // Simultaneous R/W on an empty fifo
        // Write succeeds, read fails, count goes 0->1
        @(negedge clk);
        check("Empty before boundary sim R/W", empty == 1'b1);
        write_enable = 1'b1;
        read_enable = 1'b1;
        write_data = 16'sd55;
        @(negedge clk);
        write_enable = 1'b0;
        read_enable = 1'b0;
        check("Count should be 1 after simul R/W on empty fifo", empty == 1'b0 && full == 1'b0);
        check("Data written should be visible", read_data == 16'sd55);
        
        read_enable = 1'b1;
        @(negedge clk);
        read_enable = 1'b0;
        check("Empty again", empty == 1'b1);

        // Continuous Burst Streaming Read
        for (int i = 0; i < DEPTH; i++) begin
            write_enable = 1'b1;
            write_data   = 200 + i; // 200, 201, 202, 203
            @(negedge clk);
        end
        write_enable = 1'b0;

        // Stream out without dropping read_enable
        read_enable = 1'b1;
        for (int i = 0; i < DEPTH; i++) begin
            check($sformatf("Burst read data item %0d == %0d", i, 200 + i), read_data == (200 + i));
            @(negedge clk);
        end
        read_enable = 1'b0;
        check("Empty after burst drain", empty == 1'b1);
        

        // Pointer wraparound: push/pop one at a time across 3 full trips around the DEPTH=4 buffer (12 iterations)
        for (int i = 0; i < 3*DEPTH; i++) begin
            write_enable = 1'b1;
            write_data   = i;
            @(negedge clk);
            write_enable = 1'b0;

            read_enable = 1'b1;
            check($sformatf("wraparound read_data == %0d", i), read_data == i);
            @(negedge clk);
            read_enable = 1'b0;
        end
        check("empty after wraparound stress", empty == 1'b1);

        if (errors == 0) $display("\n>>> ALL FIFO TESTS PASSED <<<\n");
        else $display("\n>>> %0d FIFO TESTS FAILED <<<\n", errors);

        $finish;
    end

    initial begin
        $dumpfile("fifo_simulation.vcd");
        $dumpvars(0, fifo_tb);
    end
endmodule
