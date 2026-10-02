`include "uvm_macros.svh"

// tpu_top under UVM; ARRAY_SIZE must match the cases file (+cases=)
module uvm_tpu_top #(parameter int ARRAY_SIZE = 8);
    import uvm_pkg::*;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    tpu_top_if bus (clk);
    assign bus.reset_n = 1'b1;      // tpu_top's own power-on reset does the work

    tpu_top #(.ARRAY_SIZE(ARRAY_SIZE)) u_tpu_top (
        .clk(clk),
        .reset_n(bus.reset_n),
        .avs_address(bus.avs_address),
        .avs_read(bus.avs_read),
        .avs_readdata(bus.avs_readdata),
        .avs_write(bus.avs_write),
        .avs_writedata(bus.avs_writedata),
        .avs_waitrequest(bus.avs_waitrequest),
        // no DDR3 model in this environment: tb_isa covers MATMUL wsrc=1
        .avm_address(),
        .avm_read(),
        .avm_burstcount(),
        .avm_waitrequest(1'b0),
        .avm_readdata('0),
        .avm_readdatavalid(1'b0)
    );

    initial begin
        uvm_config_db #(tpu_top_pkg::tpu_top_vif)::set(null, "*", "tpu_top_vif", bus);
        run_test("tpu_top_test");
    end
endmodule
