`include "uvm_macros.svh"

// bias: random rows and bias rows, enabled or not, with 32-bit extremes; every
// column of row_out must be row_in + bias (wrapping), or row_in when disabled
package bias_pkg;
    import uvm_pkg::*;
    import uvm_common_pkg::*;

    localparam int ARRAY_SIZE = 4;

    typedef virtual bias_if #(ARRAY_SIZE) bias_vif;
    typedef bit signed [31:0] word_t;

    class bias_item extends uvm_sequence_item;
        `uvm_object_utils(bias_item)
        rand word_t row      [ARRAY_SIZE];
        rand word_t bias_row [ARRAY_SIZE];
        rand bit    bias_enable;

        constraint extremes {
            foreach (row[column]) row[column] dist {32'sh7fffffff := 10, 32'sh80000000 := 10, 0 := 5,
                                                   [-32'sd1000 : 32'sd1000] :/ 40, [32'sh80000001 : 32'sh7ffffffe] :/ 35};
            foreach (bias_row[column]) bias_row[column] dist {32'sh7fffffff := 10, 32'sh80000000 := 10, 0 := 5,
                                                             [-32'sd1000 : 32'sd1000] :/ 40, [32'sh80000001 : 32'sh7ffffffe] :/ 35};
        }

        function new(string name = "bias_item");
            super.new(name);
        endfunction
    endclass

    class bias_cycle extends uvm_sequence_item;
        `uvm_object_utils(bias_cycle)
        bit [ARRAY_SIZE*32-1:0] row, bias_row, row_out;
        bit                     bias_enable;

        function new(string name = "bias_cycle");
            super.new(name);
        endfunction
    endclass

    class bias_random_sequence extends uvm_sequence #(bias_item);
        `uvm_object_utils(bias_random_sequence)

        function new(string name = "bias_random_sequence");
            super.new(name);
        endfunction

        task body();
            repeat (2000) begin
                bias_item item = bias_item::type_id::create("item");
                start_item(item);
                if (!item.randomize()) `uvm_fatal("SEQUENCE", "randomize failed")
                finish_item(item);
            end
        endtask
    endclass

    class bias_driver extends uvm_driver #(bias_item);
        `uvm_component_utils(bias_driver)
        bias_vif vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            vif.row_in         = '0;
            vif.bias_row_in    = '0;
            vif.bias_enable_in = 1'b0;
            wait (vif.reset === 1'b0);
            forever begin
                seq_item_port.get_next_item(req);
                @(negedge vif.clk);
                for (int column = 0; column < ARRAY_SIZE; column++) begin
                    vif.row_in[32*column +: 32]      = req.row[column];
                    vif.bias_row_in[32*column +: 32] = req.bias_row[column];
                end
                vif.bias_enable_in = req.bias_enable;
                seq_item_port.item_done();
            end
        endtask
    endclass

    class bias_monitor extends uvm_monitor;
        `uvm_component_utils(bias_monitor)
        bias_vif                        vif;
        uvm_analysis_port #(bias_cycle) cycle_port;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cycle_port = new("cycle_port", this);
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.reset !== 1'b0) continue;
                begin
                    bias_cycle cycle = bias_cycle::type_id::create("cycle");
                    cycle.row         = vif.row_in;
                    cycle.bias_row    = vif.bias_row_in;
                    cycle.bias_enable = vif.bias_enable_in;
                    cycle.row_out     = vif.row_out;
                    cycle_port.write(cycle);
                end
            end
        endtask
    endclass

    class bias_scoreboard extends uvm_subscriber #(bias_cycle);
        `uvm_component_utils(bias_scoreboard)
        coverage_bins coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            coverage = coverage_bins::type_id::create("coverage");
            coverage.add("bias added");
            coverage.add("bias disabled");
            coverage.add("wraps past the most positive");
            coverage.add("wraps past the most negative");
        endfunction

        function void write(bias_cycle cycle);
            for (int column = 0; column < ARRAY_SIZE; column++) begin
                word_t  value    = cycle.row[32*column +: 32];
                word_t  bias     = cycle.bias_row[32*column +: 32];
                longint exact    = cycle.bias_enable ? longint'(value) + longint'(bias) : longint'(value);
                word_t  expected = 32'(exact);
                if (cycle.row_out[32*column +: 32] !== expected)
                    `uvm_error("BIAS", $sformatf("column %0d: %0d, expected %0d", column, $signed(cycle.row_out[32*column +: 32]), expected))
                if (exact > 64'sh7fffffff)  coverage.hit("wraps past the most positive");
                if (exact < -64'sh80000000) coverage.hit("wraps past the most negative");
            end
            coverage.hit(cycle.bias_enable ? "bias added" : "bias disabled");
        endfunction

        function void check_phase(uvm_phase phase);
            coverage.check("bias");
        endfunction
    endclass

    class bias_env extends uvm_env;
        `uvm_component_utils(bias_env)
        uvm_sequencer #(bias_item) sequencer;
        bias_driver                driver;
        bias_monitor               monitor;
        bias_scoreboard            scoreboard;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            bias_vif vif;
            if (!uvm_config_db #(bias_vif)::get(this, "", "bias_vif", vif)) `uvm_fatal("BIAS", "no bias_vif in the config db")
            sequencer  = uvm_sequencer #(bias_item)::type_id::create("sequencer", this);
            driver     = bias_driver::type_id::create("driver", this);
            monitor    = bias_monitor::type_id::create("monitor", this);
            scoreboard = bias_scoreboard::type_id::create("scoreboard", this);
            driver.vif  = vif;
            monitor.vif = vif;
        endfunction

        function void connect_phase(uvm_phase phase);
            driver.seq_item_port.connect(sequencer.seq_item_export);
            monitor.cycle_port.connect(scoreboard.analysis_export);
        endfunction
    endclass

    class bias_random_test extends base_test;
        `uvm_component_utils(bias_random_test)
        bias_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            env = bias_env::type_id::create("env", this);
        endfunction

        task run_phase(uvm_phase phase);
            bias_random_sequence random_sequence = bias_random_sequence::type_id::create("random_sequence");
            phase.raise_objection(this);
            random_sequence.start(env.sequencer);
            @(posedge env.driver.vif.clk);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
