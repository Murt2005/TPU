`include "uvm_macros.svh"

// one simulation holding every block under UVM test; +UVM_TESTNAME picks the test
module uvm_blocks_top;
    import uvm_pkg::*;
    import uvm_common_pkg::*;
    import fifo_pkg::*;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    fifo_if #(fifo_pkg::WIDTH) fifo_bus (clk);
    fifo #(.WIDTH(fifo_pkg::WIDTH), .DEPTH(fifo_pkg::DEPTH)) u_fifo (
        .clk(clk),
        .reset(fifo_bus.reset),
        .write_enable_in(fifo_bus.write_enable_in),
        .write_data_in(fifo_bus.write_data_in),
        .read_enable_in(fifo_bus.read_enable_in),
        .read_data_out(fifo_bus.read_data_out),
        .full_out(fifo_bus.full_out),
        .empty_out(fifo_bus.empty_out)
    );

    initial begin
        fifo_bus.reset = 1'b1;
        repeat (3) @(posedge clk);
        fifo_bus.reset = 1'b0;
    end

    initial begin
        uvm_config_db #(fifo_pkg::fifo_vif)::set(null, "*", "fifo_vif", fifo_bus);
        run_test();
    end
endmodule
