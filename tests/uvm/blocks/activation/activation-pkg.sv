`include "uvm_macros.svh"

// activation: random rows through ReLU/identity, checked every cycle; then the
// requantizer over gen_requant.py's vectors (from tpu.golden.requant, independent
// of the RTL), N lanes at a time with a different quant word per lane
package activation_pkg;
    import uvm_pkg::*;
    import uvm_common_pkg::*;

    localparam int ARRAY_SIZE = 4;

    typedef virtual activation_if #(ARRAY_SIZE) activation_vif;
    typedef bit [ARRAY_SIZE*32-1:0] row_t;

    // the vector file: value, quant word, expected int8 per line
    class requantizer_vectors;
        bit [31:0] values [$];
        bit [31:0] quants [$];
        bit [7:0]  results [$];

        function new();
            string path;
            int    file;
            bit [31:0] value, quant;
            bit [7:0]  result;
            if (!$value$plusargs("vectors=%s", path)) `uvm_fatal("ACTIVATION", "pass +vectors=<gen_requant.py output>")
            file = $fopen(path, "r");
            if (file == 0) `uvm_fatal("ACTIVATION", $sformatf("can't open %s", path))
            while ($fscanf(file, "%h %h %h", value, quant, result) == 3) begin
                values.push_back(value);
                quants.push_back(quant);
                results.push_back(result);
            end
            $fclose(file);
        endfunction
    endclass

    class activation_item extends uvm_sequence_item;
        `uvm_object_utils(activation_item)
        rand bit signed [31:0] row [ARRAY_SIZE];
        rand bit               relu_enable;
        bit                    requantize;          // set: values/quants go to the requantizer instead
        bit [31:0]             values [ARRAY_SIZE];
        bit [31:0]             quants [ARRAY_SIZE];

        constraint extremes {
            foreach (row[column]) row[column] dist {32'sh80000000 := 5, 32'sh7fffffff := 5, 0 := 5, -1 := 5,
                                                   [-32'sd1000 : 32'sd1000] :/ 40, [32'sh80000001 : 32'sh7ffffffe] :/ 40};
        }

        function new(string name = "activation_item");
            super.new(name);
        endfunction
    endclass

    class activation_cycle extends uvm_sequence_item;
        `uvm_object_utils(activation_cycle)
        row_t                    row, row_out;
        bit                      relu_enable;
        bit                      requantized;      // the values and quants below produced quantized
        row_t                    values, quants;
        bit [ARRAY_SIZE*8-1:0]   quantized;

        function new(string name = "activation_cycle");
            super.new(name);
        endfunction
    endclass

    class activation_sequence extends uvm_sequence #(activation_item);
        `uvm_object_utils(activation_sequence)

        function new(string name = "activation_sequence");
            super.new(name);
        endfunction

        task body();
            requantizer_vectors vectors = new();
            repeat (1000) begin
                activation_item item = activation_item::type_id::create("item");
                start_item(item);
                if (!item.randomize()) `uvm_fatal("SEQUENCE", "randomize failed")
                finish_item(item);
            end
            for (int index = 0; index + ARRAY_SIZE <= vectors.values.size(); index += ARRAY_SIZE) begin
                activation_item item = activation_item::type_id::create("item");
                start_item(item);
                if (!item.randomize()) `uvm_fatal("SEQUENCE", "randomize failed")
                item.requantize = 1'b1;
                for (int lane = 0; lane < ARRAY_SIZE; lane++) begin
                    item.values[lane] = vectors.values[index + lane];
                    item.quants[lane] = vectors.quants[index + lane];
                end
                finish_item(item);
            end
        endtask
    endclass

    // a requantize item takes two cycles: multiply, then round with the quant words held
    class activation_driver extends uvm_driver #(activation_item);
        `uvm_component_utils(activation_driver)
        activation_vif vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            vif.row_in              = '0;
            vif.relu_enable_in      = 1'b0;
            vif.multiply_enable_in  = 1'b0;
            vif.multiply_row_in     = '0;
            vif.quantization_row_in = '0;
            wait (vif.reset === 1'b0);
            forever begin
                seq_item_port.get_next_item(req);
                @(negedge vif.clk);
                for (int column = 0; column < ARRAY_SIZE; column++) vif.row_in[32*column +: 32] = req.row[column];
                vif.relu_enable_in = req.relu_enable;
                if (req.requantize) begin
                    for (int lane = 0; lane < ARRAY_SIZE; lane++) begin
                        vif.multiply_row_in[32*lane +: 32]     = req.values[lane];
                        vif.quantization_row_in[32*lane +: 32] = req.quants[lane];
                    end
                    vif.multiply_enable_in = 1'b1;
                    @(negedge vif.clk);
                    vif.multiply_enable_in = 1'b0;
                end
                seq_item_port.item_done();
            end
        endtask
    endclass

    class activation_monitor extends uvm_monitor;
        `uvm_component_utils(activation_monitor)
        activation_vif                        vif;
        uvm_analysis_port #(activation_cycle) cycle_port;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cycle_port = new("cycle_port", this);
        endfunction

        task run_phase(uvm_phase phase);
            bit   multiplied = 1'b0;
            row_t multiplied_values;
            forever begin
                @(posedge vif.clk);
                if (vif.reset !== 1'b0) continue;
                begin
                    activation_cycle cycle = activation_cycle::type_id::create("cycle");
                    cycle.row         = vif.row_in;
                    cycle.relu_enable = vif.relu_enable_in;
                    cycle.row_out     = vif.row_out;
                    cycle.requantized = multiplied;
                    cycle.values      = multiplied_values;
                    cycle.quants      = vif.quantization_row_in;
                    cycle.quantized   = vif.quantized_row_out;
                    cycle_port.write(cycle);
                end
                multiplied        = vif.multiply_enable_in;
                multiplied_values = vif.multiply_row_in;
            end
        endtask
    endclass

    class activation_scoreboard extends uvm_subscriber #(activation_cycle);
        `uvm_component_utils(activation_scoreboard)
        requantizer_vectors vectors;
        int unsigned        next_vector, mismatches;
        coverage_bins       coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            coverage = coverage_bins::type_id::create("coverage");
            coverage.add("ReLU zeroes a negative");
            coverage.add("ReLU passes a positive");
            coverage.add("identity passes a negative");
            coverage.add("requantized lane");
            coverage.add("input saturated to 27 bits");
            coverage.add("shift 0");
            coverage.add("shift 63");
            coverage.add("clamped to 127");
            coverage.add("clamped to -128");
        endfunction

        function void build_phase(uvm_phase phase);
            vectors = new();
        endfunction

        function void write(activation_cycle cycle);
            for (int column = 0; column < ARRAY_SIZE; column++) begin
                bit signed [31:0] value    = cycle.row[32*column +: 32];
                bit signed [31:0] expected = (cycle.relu_enable && value < 0) ? 32'sd0 : value;
                if (cycle.row_out[32*column +: 32] !== expected)
                    `uvm_error("ACTIVATION", $sformatf("column %0d: %0d with relu=%0b, expected %0d", column,
                                                       $signed(cycle.row_out[32*column +: 32]), cycle.relu_enable, expected))
                if (cycle.relu_enable && value < 0)  coverage.hit("ReLU zeroes a negative");
                if (cycle.relu_enable && value > 0)  coverage.hit("ReLU passes a positive");
                if (!cycle.relu_enable && value < 0) coverage.hit("identity passes a negative");
            end
            if (cycle.requantized) begin
                for (int lane = 0; lane < ARRAY_SIZE; lane++) begin
                    int unsigned      index = next_vector + lane;
                    bit signed [31:0] value = cycle.values[32*lane +: 32];
                    bit [7:0]         got   = cycle.quantized[8*lane +: 8];
                    if (value !== vectors.values[index] || cycle.quants[32*lane +: 32] !== vectors.quants[index])
                        `uvm_fatal("ACTIVATION", $sformatf("vector %0d out of step with the file", index))
                    if (got !== vectors.results[index]) begin
                        mismatches++;
                        if (mismatches <= 5)
                            `uvm_error("ACTIVATION", $sformatf("v=%h q=%h: %h, expected %h", value, vectors.quants[index], got, vectors.results[index]))
                    end
                    coverage.hit("requantized lane");
                    if (value > 32'sd67108863 || value < -32'sd67108864) coverage.hit("input saturated to 27 bits");
                    if (vectors.quants[index][29:24] == 6'd0)  coverage.hit("shift 0");
                    if (vectors.quants[index][29:24] == 6'd63) coverage.hit("shift 63");
                    if (vectors.results[index] == 8'h7f)       coverage.hit("clamped to 127");
                    if (vectors.results[index] == 8'h80)       coverage.hit("clamped to -128");
                end
                next_vector += ARRAY_SIZE;
            end
        endfunction

        function void check_phase(uvm_phase phase);
            if (next_vector < 1000 || next_vector + ARRAY_SIZE <= vectors.values.size())
                `uvm_error("ACTIVATION", $sformatf("checked %0d of %0d vectors", next_vector, vectors.values.size()))
            if (mismatches != 0) `uvm_error("ACTIVATION", $sformatf("%0d of %0d vectors mismatched", mismatches, next_vector))
            `uvm_info("ACTIVATION", $sformatf("%0d requantizer vectors checked", next_vector), UVM_MEDIUM)
            coverage.check("activation");
        endfunction
    endclass

    class activation_env extends uvm_env;
        `uvm_component_utils(activation_env)
        uvm_sequencer #(activation_item) sequencer;
        activation_driver                driver;
        activation_monitor               monitor;
        activation_scoreboard            scoreboard;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            activation_vif vif;
            if (!uvm_config_db #(activation_vif)::get(this, "", "activation_vif", vif))
                `uvm_fatal("ACTIVATION", "no activation_vif in the config db")
            sequencer  = uvm_sequencer #(activation_item)::type_id::create("sequencer", this);
            driver     = activation_driver::type_id::create("driver", this);
            monitor    = activation_monitor::type_id::create("monitor", this);
            scoreboard = activation_scoreboard::type_id::create("scoreboard", this);
            driver.vif  = vif;
            monitor.vif = vif;
        endfunction

        function void connect_phase(uvm_phase phase);
            driver.seq_item_port.connect(sequencer.seq_item_export);
            monitor.cycle_port.connect(scoreboard.analysis_export);
        endfunction
    endclass

    class activation_test extends base_test;
        `uvm_component_utils(activation_test)
        activation_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            env = activation_env::type_id::create("env", this);
        endfunction

        task run_phase(uvm_phase phase);
            activation_sequence stimulus = activation_sequence::type_id::create("stimulus");
            phase.raise_objection(this);
            stimulus.start(env.sequencer);
            repeat (2) @(posedge env.driver.vif.clk);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
