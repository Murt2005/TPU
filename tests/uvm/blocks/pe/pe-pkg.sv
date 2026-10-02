`include "uvm_macros.svh"

// pe: random legal stimulus, checked cycle by cycle against a two-register weight model
package pe_pkg;
    import uvm_pkg::*;
    import uvm_common_pkg::*;

    typedef virtual pe_if pe_vif;

    class pe_item extends uvm_sequence_item;
        `uvm_object_utils(pe_item)
        rand bit signed [7:0]  activation;
        rand bit signed [31:0] partial_sum;
        rand bit signed [7:0]  weight;
        bit                    activation_valid, weight_flip, partial_sum_valid, weight_valid;   // set by the sequence

        constraint extremes {
            activation  dist {-8'sd128 := 10, 8'sd127 := 10, 8'sd0 := 5, [-8'sd127 : 8'sd126] :/ 75};
            weight      dist {-8'sd128 := 10, 8'sd127 := 10, 8'sd0 := 5, [-8'sd127 : 8'sd126] :/ 75};
            partial_sum dist {32'sh7fffffff := 5, 32'sh80000000 := 5, [-32'sd1000 : 32'sd1000] :/ 50,
                              [32'sh80000001 : 32'sh7ffffffe] :/ 40};
        }

        function new(string name = "pe_item");
            super.new(name);
        endfunction
    endclass

    class pe_cycle extends uvm_sequence_item;
        `uvm_object_utils(pe_cycle)
        bit signed [7:0]  activation, weight, activation_out;
        bit               activation_valid, weight_flip, partial_sum_valid, weight_valid;
        bit signed [31:0] partial_sum, partial_sum_out;
        bit               activation_valid_out, weight_flip_out, partial_sum_valid_out;

        function new(string name = "pe_cycle");
            super.new(name);
        endfunction
    endclass

    // the control bits follow the scheduler's rules: one weight write per flip, no
    // flip without one, and a valid activation always has a valid partial sum.
    // (chosen here rather than by constraints: Verilator treats dist as a hard pick)
    class pe_random_sequence extends uvm_sequence #(pe_item);
        `uvm_object_utils(pe_random_sequence)
        int unsigned length = 3000;

        function new(string name = "pe_random_sequence");
            super.new(name);
        endfunction

        task body();
            bit weight_pending = 1'b0;
            repeat (length) begin
                pe_item item = pe_item::type_id::create("item");
                start_item(item);
                if (!item.randomize()) `uvm_fatal("SEQUENCE", "randomize failed")
                item.activation_valid  = $urandom_range(99) < 70;
                item.weight_flip       = $urandom_range(99) < 30 && (weight_pending || !item.activation_valid);
                item.partial_sum_valid = item.activation_valid || $urandom_range(1);
                item.weight_valid      = (weight_pending ? (item.activation_valid && item.weight_flip) : 1'b1)
                                         && $urandom_range(99) < 60;
                finish_item(item);
                if (item.weight_valid)                             weight_pending = 1'b1;
                else if (item.activation_valid && item.weight_flip) weight_pending = 1'b0;
            end
        endtask
    endclass

    class pe_driver extends uvm_driver #(pe_item);
        `uvm_component_utils(pe_driver)
        pe_vif vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            vif.activation_valid_in  = 1'b0;
            vif.weight_valid_in      = 1'b0;
            vif.weight_flip_in       = 1'b0;
            vif.partial_sum_valid_in = 1'b0;
            vif.activation_in        = '0;
            vif.partial_sum_in       = '0;
            vif.weight_in            = '0;
            wait (vif.reset === 1'b0);
            forever begin
                seq_item_port.get_next_item(req);
                @(negedge vif.clk);
                vif.activation_in        = req.activation;
                vif.activation_valid_in  = req.activation_valid;
                vif.weight_flip_in       = req.weight_flip;
                vif.partial_sum_in       = req.partial_sum;
                vif.partial_sum_valid_in = req.partial_sum_valid;
                vif.weight_in            = req.weight;
                vif.weight_valid_in      = req.weight_valid;
                seq_item_port.item_done();
            end
        endtask
    endclass

    class pe_monitor extends uvm_monitor;
        `uvm_component_utils(pe_monitor)
        pe_vif                        vif;
        uvm_analysis_port #(pe_cycle) cycle_port;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cycle_port = new("cycle_port", this);
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.reset !== 1'b0) continue;
                begin
                    pe_cycle cycle = pe_cycle::type_id::create("cycle");
                    cycle.activation            = vif.activation_in;
                    cycle.activation_valid      = vif.activation_valid_in;
                    cycle.weight_flip           = vif.weight_flip_in;
                    cycle.partial_sum           = vif.partial_sum_in;
                    cycle.partial_sum_valid     = vif.partial_sum_valid_in;
                    cycle.weight                = vif.weight_in;
                    cycle.weight_valid          = vif.weight_valid_in;
                    cycle.activation_out        = vif.activation_out;
                    cycle.activation_valid_out  = vif.activation_valid_out;
                    cycle.weight_flip_out       = vif.weight_flip_out;
                    cycle.partial_sum_out       = vif.partial_sum_out;
                    cycle.partial_sum_valid_out = vif.partial_sum_valid_out;
                    cycle_port.write(cycle);
                end
            end
        endtask
    endclass

    // the outputs seen at an edge are what the model computed at the edge before
    class pe_scoreboard extends uvm_subscriber #(pe_cycle);
        `uvm_component_utils(pe_scoreboard)
        bit signed [7:0]  weight_current, weight_next;
        bit signed [7:0]  expected_activation;
        bit               expected_activation_valid, expected_weight_flip, expected_partial_sum_valid;
        bit signed [31:0] expected_partial_sum;
        coverage_bins     coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            coverage = coverage_bins::type_id::create("coverage");
            coverage.add("multiply-accumulate");
            coverage.add("flip");
            coverage.add("flip with the next weight loading");
            coverage.add("weight loaded between flips");
            coverage.add("invalid activation with flip set");
            coverage.add("valid partial sum alone");
            coverage.add("-128 x -128");
            coverage.add("partial sum wraps");
        endfunction

        function void write(pe_cycle cycle);
            if (cycle.activation_out !== expected_activation || cycle.activation_valid_out !== expected_activation_valid
                || cycle.weight_flip_out !== expected_weight_flip)
                `uvm_error("PE", "activation, valid or flip did not pass through one cycle later")
            if (cycle.partial_sum_valid_out !== expected_partial_sum_valid)
                `uvm_error("PE", $sformatf("partial_sum_valid_out = %0b, expected %0b", cycle.partial_sum_valid_out, expected_partial_sum_valid))
            if (cycle.partial_sum_out !== expected_partial_sum)
                `uvm_error("PE", $sformatf("partial_sum_out = %0d, expected %0d", cycle.partial_sum_out, expected_partial_sum))

            expected_activation        = cycle.activation;
            expected_activation_valid  = cycle.activation_valid;
            expected_weight_flip       = cycle.weight_flip;
            expected_partial_sum_valid = cycle.activation_valid && cycle.partial_sum_valid;
            if (cycle.activation_valid) begin
                bit signed [7:0]  weight = cycle.weight_flip ? weight_next : weight_current;
                longint           exact  = longint'(weight) * longint'(cycle.activation) + longint'(cycle.partial_sum);
                expected_partial_sum = 32'(exact);
                coverage.hit("multiply-accumulate");
                if (exact > 64'sh7fffffff || exact < -64'sh80000000) coverage.hit("partial sum wraps");
                if (weight == -8'sd128 && cycle.activation == -8'sd128) coverage.hit("-128 x -128");
                if (cycle.weight_flip) begin
                    weight_current = weight_next;
                    coverage.hit("flip");
                    if (cycle.weight_valid) coverage.hit("flip with the next weight loading");
                end
            end else begin
                if (cycle.weight_flip)       coverage.hit("invalid activation with flip set");
                if (cycle.partial_sum_valid) coverage.hit("valid partial sum alone");
            end
            if (cycle.weight_valid) begin
                weight_next = cycle.weight;
                if (!(cycle.activation_valid && cycle.weight_flip)) coverage.hit("weight loaded between flips");
            end
        endfunction

        function void check_phase(uvm_phase phase);
            coverage.check("pe");
        endfunction
    endclass

    class pe_env extends uvm_env;
        `uvm_component_utils(pe_env)
        uvm_sequencer #(pe_item) sequencer;
        pe_driver                driver;
        pe_monitor               monitor;
        pe_scoreboard            scoreboard;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            pe_vif vif;
            if (!uvm_config_db #(pe_vif)::get(this, "", "pe_vif", vif)) `uvm_fatal("PE", "no pe_vif in the config db")
            sequencer  = uvm_sequencer #(pe_item)::type_id::create("sequencer", this);
            driver     = pe_driver::type_id::create("driver", this);
            monitor    = pe_monitor::type_id::create("monitor", this);
            scoreboard = pe_scoreboard::type_id::create("scoreboard", this);
            driver.vif  = vif;
            monitor.vif = vif;
        endfunction

        function void connect_phase(uvm_phase phase);
            driver.seq_item_port.connect(sequencer.seq_item_export);
            monitor.cycle_port.connect(scoreboard.analysis_export);
        endfunction
    endclass

    class pe_random_test extends base_test;
        `uvm_component_utils(pe_random_test)
        pe_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            env = pe_env::type_id::create("env", this);
        endfunction

        task run_phase(uvm_phase phase);
            pe_random_sequence random_sequence = pe_random_sequence::type_id::create("random_sequence");
            phase.raise_objection(this);
            random_sequence.start(env.sequencer);
            repeat (3) @(posedge env.driver.vif.clk);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
