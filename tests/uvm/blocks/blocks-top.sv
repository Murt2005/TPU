`include "uvm_macros.svh"

// one simulation holding every block under UVM test; +UVM_TESTNAME picks the test.
// each block has its own interface and reset, so only the tested one sees traffic
module uvm_blocks_top;
    import uvm_pkg::*;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    // -- fifo ------------------------------------------------------------------
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

    // -- pe --------------------------------------------------------------------
    pe_if pe_bus (clk);
    pe u_pe (
        .clk(clk),
        .reset(pe_bus.reset),
        .activation_in(pe_bus.activation_in),
        .activation_valid_in(pe_bus.activation_valid_in),
        .weight_flip_in(pe_bus.weight_flip_in),
        .partial_sum_in(pe_bus.partial_sum_in),
        .partial_sum_valid_in(pe_bus.partial_sum_valid_in),
        .weight_in(pe_bus.weight_in),
        .weight_valid_in(pe_bus.weight_valid_in),
        .activation_out(pe_bus.activation_out),
        .activation_valid_out(pe_bus.activation_valid_out),
        .weight_flip_out(pe_bus.weight_flip_out),
        .partial_sum_out(pe_bus.partial_sum_out),
        .partial_sum_valid_out(pe_bus.partial_sum_valid_out)
    );

    // -- systolic data setup ---------------------------------------------------
    systolic_data_setup_if #(systolic_data_setup_pkg::ARRAY_SIZE, systolic_data_setup_pkg::DATA_WIDTH) systolic_data_setup_bus (clk);
    systolic_data_setup #(.ARRAY_SIZE(systolic_data_setup_pkg::ARRAY_SIZE), .DATA_WIDTH(systolic_data_setup_pkg::DATA_WIDTH)) u_systolic_data_setup (
        .clk(clk),
        .reset(systolic_data_setup_bus.reset),
        .row_in(systolic_data_setup_bus.row_in),
        .row_valid_in(systolic_data_setup_bus.row_valid_in),
        .skewed_row_out(systolic_data_setup_bus.skewed_row_out),
        .skewed_valid_out(systolic_data_setup_bus.skewed_valid_out)
    );

    // -- weight fifo -----------------------------------------------------------
    weight_fifo_if #(weight_fifo_pkg::ARRAY_SIZE) weight_fifo_bus (clk);
    weight_fifo #(.ARRAY_SIZE(weight_fifo_pkg::ARRAY_SIZE)) u_weight_fifo (
        .clk(clk),
        .reset(weight_fifo_bus.reset),
        .fill_ready_out(weight_fifo_bus.fill_ready_out),
        .fill_slot_next_out(weight_fifo_bus.fill_slot_next_out),
        .fill_advance_in(weight_fifo_bus.fill_advance_in),
        .fill_write_enable_in(weight_fifo_bus.fill_write_enable_in),
        .fill_slot_in(weight_fifo_bus.fill_slot_in),
        .fill_row_in(weight_fifo_bus.fill_row_in),
        .fill_data_in(weight_fifo_bus.fill_data_in),
        .tile_out(weight_fifo_bus.tile_out),
        .tile_full_out(weight_fifo_bus.tile_full_out),
        .tile_take_in(weight_fifo_bus.tile_take_in)
    );

    // -- accumulator -----------------------------------------------------------
    accumulator_if #(accumulator_pkg::ARRAY_SIZE, accumulator_pkg::ACC_ADDRESS_WIDTH) accumulator_bus (clk);
    accumulator #(.ARRAY_SIZE(accumulator_pkg::ARRAY_SIZE), .ACC_DEPTH(accumulator_pkg::ACC_DEPTH)) u_accumulator (
        .clk(clk),
        .reset(accumulator_bus.reset),
        .partial_sum_in(accumulator_bus.partial_sum_in),
        .partial_sum_valid_in(accumulator_bus.partial_sum_valid_in),
        .tag_push_in(accumulator_bus.tag_push_in),
        .tag_in(accumulator_bus.tag_in),
        .row_written_out(accumulator_bus.row_written_out),
        .activate_read_address_in(accumulator_bus.activate_read_address_in),
        .activate_read_blocked_out(accumulator_bus.activate_read_blocked_out),
        .read_data_out(accumulator_bus.read_data_out)
    );

    // -- bias ------------------------------------------------------------------
    bias_if #(bias_pkg::ARRAY_SIZE) bias_bus (clk);
    bias #(.ARRAY_SIZE(bias_pkg::ARRAY_SIZE)) u_bias (
        .row_in(bias_bus.row_in),
        .bias_row_in(bias_bus.bias_row_in),
        .bias_enable_in(bias_bus.bias_enable_in),
        .row_out(bias_bus.row_out)
    );

    // -- activation ------------------------------------------------------------
    activation_if #(activation_pkg::ARRAY_SIZE) activation_bus (clk);
    activation #(.ARRAY_SIZE(activation_pkg::ARRAY_SIZE)) u_activation (
        .clk(clk),
        .reset(activation_bus.reset),
        .row_in(activation_bus.row_in),
        .relu_enable_in(activation_bus.relu_enable_in),
        .row_out(activation_bus.row_out),
        .multiply_enable_in(activation_bus.multiply_enable_in),
        .multiply_row_in(activation_bus.multiply_row_in),
        .quantization_row_in(activation_bus.quantization_row_in),
        .quantized_row_out(activation_bus.quantized_row_out)
    );

    // -- unified buffer --------------------------------------------------------
    unified_buffer_if #(unified_buffer_pkg::ARRAY_SIZE, unified_buffer_pkg::ADDRESS_WIDTH) unified_buffer_bus (clk);
    unified_buffer #(.ARRAY_SIZE(unified_buffer_pkg::ARRAY_SIZE), .DEPTH(unified_buffer_pkg::DEPTH)) u_unified_buffer (
        .clk(clk),
        .load_write_enable_in(unified_buffer_bus.load_write_enable_in),
        .load_write_address_in(unified_buffer_bus.load_write_address_in),
        .load_write_data_in(unified_buffer_bus.load_write_data_in),
        .activate_write_enable_in(unified_buffer_bus.activate_write_enable_in),
        .activate_write_address_in(unified_buffer_bus.activate_write_address_in),
        .activate_write_data_in(unified_buffer_bus.activate_write_data_in),
        .matmul_read_enable_in(unified_buffer_bus.matmul_read_enable_in),
        .matmul_read_address_in(unified_buffer_bus.matmul_read_address_in),
        .activate_read_address_in(unified_buffer_bus.activate_read_address_in),
        .read_data_out(unified_buffer_bus.read_data_out)
    );

    // -- mmu, behind its systolic data setup as in tpu_core --------------------
    mmu_if #(mmu_pkg::ARRAY_SIZE) mmu_bus (clk);
    logic signed [mmu_pkg::ARRAY_SIZE-1:0][8:0] mmu_skewed_row;
    logic        [mmu_pkg::ARRAY_SIZE-1:0]      mmu_skewed_valid;
    logic signed [mmu_pkg::ARRAY_SIZE-1:0][7:0] mmu_activation;
    logic        [mmu_pkg::ARRAY_SIZE-1:0]      mmu_weight_flip;
    always_comb
        for (int row = 0; row < mmu_pkg::ARRAY_SIZE; row++) begin
            mmu_activation[row]  = mmu_skewed_row[row][7:0];
            mmu_weight_flip[row] = mmu_skewed_row[row][8];
        end
    systolic_data_setup #(.ARRAY_SIZE(mmu_pkg::ARRAY_SIZE), .DATA_WIDTH(9)) u_mmu_systolic_data_setup (
        .clk(clk),
        .reset(mmu_bus.reset),
        .row_in(mmu_bus.row_in),
        .row_valid_in(mmu_bus.row_valid_in),
        .skewed_row_out(mmu_skewed_row),
        .skewed_valid_out(mmu_skewed_valid)
    );
    mmu #(.ARRAY_SIZE(mmu_pkg::ARRAY_SIZE)) u_mmu (
        .clk(clk),
        .reset(mmu_bus.reset),
        .activation_in(mmu_activation),
        .activation_valid_in(mmu_skewed_valid),
        .weight_flip_in(mmu_weight_flip),
        .weight_in(mmu_bus.weight_in),
        .weight_valid_in(mmu_bus.weight_valid_in),
        .weight_row_select_in(mmu_bus.weight_row_select_in),
        .partial_sum_out(mmu_bus.partial_sum_out),
        .partial_sum_valid_out(mmu_bus.partial_sum_valid_out)
    );

    initial begin
        {fifo_bus.reset, pe_bus.reset, systolic_data_setup_bus.reset, weight_fifo_bus.reset, accumulator_bus.reset,
         bias_bus.reset, activation_bus.reset, unified_buffer_bus.reset, mmu_bus.reset} = '1;
        repeat (3) @(posedge clk);
        {fifo_bus.reset, pe_bus.reset, systolic_data_setup_bus.reset, weight_fifo_bus.reset, accumulator_bus.reset,
         bias_bus.reset, activation_bus.reset, unified_buffer_bus.reset, mmu_bus.reset} = '0;
    end

    initial begin
        uvm_config_db #(fifo_pkg::fifo_vif)::set(null, "*", "fifo_vif", fifo_bus);
        uvm_config_db #(pe_pkg::pe_vif)::set(null, "*", "pe_vif", pe_bus);
        uvm_config_db #(systolic_data_setup_pkg::systolic_data_setup_vif)::set(null, "*", "systolic_data_setup_vif", systolic_data_setup_bus);
        uvm_config_db #(weight_fifo_pkg::weight_fifo_vif)::set(null, "*", "weight_fifo_vif", weight_fifo_bus);
        uvm_config_db #(accumulator_pkg::accumulator_vif)::set(null, "*", "accumulator_vif", accumulator_bus);
        uvm_config_db #(bias_pkg::bias_vif)::set(null, "*", "bias_vif", bias_bus);
        uvm_config_db #(activation_pkg::activation_vif)::set(null, "*", "activation_vif", activation_bus);
        uvm_config_db #(unified_buffer_pkg::unified_buffer_vif)::set(null, "*", "unified_buffer_vif", unified_buffer_bus);
        uvm_config_db #(mmu_pkg::mmu_vif)::set(null, "*", "mmu_vif", mmu_bus);
        run_test();
    end
endmodule
