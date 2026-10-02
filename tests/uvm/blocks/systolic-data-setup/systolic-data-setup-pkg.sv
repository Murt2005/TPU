`include "uvm_macros.svh"

// systolic_data_setup: random rows in bursts and gaps; every cycle, lane i must
// show the row (data and valid) that entered i cycles earlier
package systolic_data_setup_pkg;
    import uvm_pkg::*;
    import uvm_common_pkg::*;

    localparam int ARRAY_SIZE = 4;
    localparam int DATA_WIDTH = 8;

    typedef virtual systolic_data_setup_if #(ARRAY_SIZE, DATA_WIDTH) systolic_data_setup_vif;
    typedef bit signed [ARRAY_SIZE-1:0][DATA_WIDTH-1:0] row_t;

    class systolic_data_setup_item extends uvm_sequence_item;
        `uvm_object_utils(systolic_data_setup_item)
        rand row_t  row;
        rand bit    row_valid;
        int unsigned valid_percent = 50;

        constraint rate { row_valid dist {1 := valid_percent, 0 := 100 - valid_percent}; }

        function new(string name = "systolic_data_setup_item");
            super.new(name);
        endfunction
    endclass

    class systolic_data_setup_cycle extends uvm_sequence_item;
        `uvm_object_utils(systolic_data_setup_cycle)
        row_t                  row, skewed_row;
        bit                    row_valid;
        bit [ARRAY_SIZE-1:0]   skewed_valid;

        function new(string name = "systolic_data_setup_cycle");
            super.new(name);
        endfunction
    endclass

    // back-to-back bursts, sparse stretches and idle gaps
    class systolic_data_setup_random_sequence extends uvm_sequence #(systolic_data_setup_item);
        `uvm_object_utils(systolic_data_setup_random_sequence)

        function new(string name = "systolic_data_setup_random_sequence");
            super.new(name);
        endfunction

        task body();
            for (int phase_index = 0; phase_index < 60; phase_index++) begin
                int unsigned valid_percent = (phase_index % 3 == 0) ? 100 : (phase_index % 3 == 1) ? 30 : 0;
                repeat (12) begin
                    systolic_data_setup_item item = systolic_data_setup_item::type_id::create("item");
                    item.valid_percent = valid_percent;
                    start_item(item);
                    if (!item.randomize()) `uvm_fatal("SEQUENCE", "randomize failed")
                    finish_item(item);
                end
            end
        endtask
    endclass

    class systolic_data_setup_driver extends uvm_driver #(systolic_data_setup_item);
        `uvm_component_utils(systolic_data_setup_driver)
        systolic_data_setup_vif vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            vif.row_valid_in = 1'b0;
            vif.row_in       = '0;
            wait (vif.reset === 1'b0);
            forever begin
                seq_item_port.get_next_item(req);
                @(negedge vif.clk);
                vif.row_in       = req.row;
                vif.row_valid_in = req.row_valid;
                seq_item_port.item_done();
            end
        endtask
    endclass

    class systolic_data_setup_monitor extends uvm_monitor;
        `uvm_component_utils(systolic_data_setup_monitor)
        systolic_data_setup_vif                         vif;
        uvm_analysis_port #(systolic_data_setup_cycle)  cycle_port;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cycle_port = new("cycle_port", this);
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.reset !== 1'b0) continue;
                begin
                    systolic_data_setup_cycle cycle = systolic_data_setup_cycle::type_id::create("cycle");
                    cycle.row          = vif.row_in;
                    cycle.row_valid    = vif.row_valid_in;
                    cycle.skewed_row   = vif.skewed_row_out;
                    cycle.skewed_valid = vif.skewed_valid_out;
                    cycle_port.write(cycle);
                end
            end
        endtask
    endclass

    // a history of the rows driven, newest first; lane i reads entry i
    class systolic_data_setup_scoreboard extends uvm_subscriber #(systolic_data_setup_cycle);
        `uvm_component_utils(systolic_data_setup_scoreboard)
        row_t         history_row   [ARRAY_SIZE];
        bit           history_valid [ARRAY_SIZE];
        coverage_bins coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            coverage = coverage_bins::type_id::create("coverage");
            coverage.add("every lane valid at once");
            coverage.add("a bubble between rows");
            coverage.add("back-to-back rows");
            coverage.add("idle");
        endfunction

        function void write(systolic_data_setup_cycle cycle);
            for (int lane = ARRAY_SIZE - 1; lane > 0; lane--) begin
                history_row[lane]   = history_row[lane-1];
                history_valid[lane] = history_valid[lane-1];
            end
            history_row[0]   = cycle.row;
            history_valid[0] = cycle.row_valid;
            for (int lane = 0; lane < ARRAY_SIZE; lane++) begin
                if (cycle.skewed_valid[lane] !== history_valid[lane])
                    `uvm_error("SKEW", $sformatf("lane %0d valid = %0b, expected %0b", lane, cycle.skewed_valid[lane], history_valid[lane]))
                if (history_valid[lane] && cycle.skewed_row[lane] !== history_row[lane][lane])
                    `uvm_error("SKEW", $sformatf("lane %0d data = %0d, expected %0d", lane, cycle.skewed_row[lane], history_row[lane][lane]))
            end
            if (&cycle.skewed_valid)                             coverage.hit("every lane valid at once");
            if (history_valid[0] && !history_valid[1] && history_valid[2]) coverage.hit("a bubble between rows");
            if (history_valid[0] && history_valid[1])            coverage.hit("back-to-back rows");
            if (cycle.skewed_valid == '0)                        coverage.hit("idle");
        endfunction

        function void check_phase(uvm_phase phase);
            coverage.check("systolic_data_setup");
        endfunction
    endclass

    class systolic_data_setup_env extends uvm_env;
        `uvm_component_utils(systolic_data_setup_env)
        uvm_sequencer #(systolic_data_setup_item) sequencer;
        systolic_data_setup_driver                driver;
        systolic_data_setup_monitor               monitor;
        systolic_data_setup_scoreboard            scoreboard;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            systolic_data_setup_vif vif;
            if (!uvm_config_db #(systolic_data_setup_vif)::get(this, "", "systolic_data_setup_vif", vif))
                `uvm_fatal("SKEW", "no systolic_data_setup_vif in the config db")
            sequencer  = uvm_sequencer #(systolic_data_setup_item)::type_id::create("sequencer", this);
            driver     = systolic_data_setup_driver::type_id::create("driver", this);
            monitor    = systolic_data_setup_monitor::type_id::create("monitor", this);
            scoreboard = systolic_data_setup_scoreboard::type_id::create("scoreboard", this);
            driver.vif  = vif;
            monitor.vif = vif;
        endfunction

        function void connect_phase(uvm_phase phase);
            driver.seq_item_port.connect(sequencer.seq_item_export);
            monitor.cycle_port.connect(scoreboard.analysis_export);
        endfunction
    endclass

    class systolic_data_setup_random_test extends base_test;
        `uvm_component_utils(systolic_data_setup_random_test)
        systolic_data_setup_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            env = systolic_data_setup_env::type_id::create("env", this);
        endfunction

        task run_phase(uvm_phase phase);
            systolic_data_setup_random_sequence random_sequence = systolic_data_setup_random_sequence::type_id::create("random_sequence");
            phase.raise_objection(this);
            random_sequence.start(env.sequencer);
            repeat (ARRAY_SIZE + 2) @(posedge env.driver.vif.clk);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
