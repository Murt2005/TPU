`include "uvm_macros.svh"

// fifo: random pushes and pops in fill-, drain- and balanced phases, checked cycle
// by cycle against a queue model: show-ahead data, full/empty, dropped writes when
// full, ignored reads when empty, and pointer wrap-around
package fifo_pkg;
    import uvm_pkg::*;
    import uvm_common_pkg::*;

    localparam int WIDTH = 16;
    localparam int DEPTH = 4;

    typedef virtual fifo_if #(WIDTH) fifo_vif;

    // one cycle of stimulus
    class fifo_item extends uvm_sequence_item;
        `uvm_object_utils(fifo_item)
        rand bit                    write_enable;
        rand bit                    read_enable;
        rand bit signed [WIDTH-1:0] write_data;
        int unsigned                write_percent = 50;
        int unsigned                read_percent  = 50;

        constraint enable_rates {
            write_enable dist {1 := write_percent, 0 := 100 - write_percent};
            read_enable  dist {1 := read_percent,  0 := 100 - read_percent};
        }
        constraint data_extremes {
            write_data dist {16'sh8000 := 5, 16'sh7fff := 5, [16'sh8001 : 16'sh7ffe] :/ 90};
        }

        function new(string name = "fifo_item");
            super.new(name);
        endfunction
    endclass

    // what the monitor saw on one clock edge: the inputs and the outputs before it
    class fifo_cycle extends uvm_sequence_item;
        `uvm_object_utils(fifo_cycle)
        bit                    write_enable, read_enable, full, empty;
        bit signed [WIDTH-1:0] write_data, read_data;

        function new(string name = "fifo_cycle");
            super.new(name);
        endfunction
    endclass

    // phases of filling, draining and mixing so full, empty and wrap-around all happen
    class fifo_random_sequence extends uvm_sequence #(fifo_item);
        `uvm_object_utils(fifo_random_sequence)
        int unsigned phase_count  = 40;
        int unsigned phase_length = 24;

        function new(string name = "fifo_random_sequence");
            super.new(name);
        endfunction

        task body();
            for (int phase_index = 0; phase_index < phase_count; phase_index++) begin
                int unsigned write_percent, read_percent;
                case (phase_index % 3)
                    0:       begin write_percent = 85; read_percent = 15; end
                    1:       begin write_percent = 15; read_percent = 85; end
                    default: begin write_percent = 50; read_percent = 50; end
                endcase
                repeat (phase_length) begin
                    fifo_item item = fifo_item::type_id::create("item");
                    item.write_percent = write_percent;
                    item.read_percent  = read_percent;
                    start_item(item);
                    if (!item.randomize()) `uvm_fatal("SEQUENCE", "randomize failed")
                    finish_item(item);
                end
            end
        endtask
    endclass

    class fifo_driver extends uvm_driver #(fifo_item);
        `uvm_component_utils(fifo_driver)
        fifo_vif vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            vif.write_enable_in = 1'b0;
            vif.read_enable_in  = 1'b0;
            vif.write_data_in   = '0;
            wait (vif.reset === 1'b0);
            forever begin
                seq_item_port.get_next_item(req);
                @(negedge vif.clk);
                vif.write_enable_in = req.write_enable;
                vif.read_enable_in  = req.read_enable;
                vif.write_data_in   = req.write_data;
                seq_item_port.item_done();
            end
        endtask
    endclass

    class fifo_monitor extends uvm_monitor;
        `uvm_component_utils(fifo_monitor)
        fifo_vif                        vif;
        uvm_analysis_port #(fifo_cycle) cycle_port;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cycle_port = new("cycle_port", this);
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.reset !== 1'b0) continue;
                begin
                    fifo_cycle cycle = fifo_cycle::type_id::create("cycle");
                    cycle.write_enable = vif.write_enable_in;
                    cycle.read_enable  = vif.read_enable_in;
                    cycle.write_data   = vif.write_data_in;
                    cycle.read_data    = vif.read_data_out;
                    cycle.full         = vif.full_out;
                    cycle.empty        = vif.empty_out;
                    cycle_port.write(cycle);
                end
            end
        endtask
    endclass

    // a queue of at most DEPTH entries; both accepts are decided by the state before the edge
    class fifo_scoreboard extends uvm_subscriber #(fifo_cycle);
        `uvm_component_utils(fifo_scoreboard)
        bit signed [WIDTH-1:0] model [$];
        int unsigned           writes_accepted;
        coverage_bins          coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            coverage = coverage_bins::type_id::create("coverage");
            coverage.add("write accepted");
            coverage.add("read accepted");
            coverage.add("full");
            coverage.add("empty");
            coverage.add("write dropped when full");
            coverage.add("read ignored when empty");
            coverage.add("read and write together");
            coverage.add("read and write when full");
            coverage.add("pointer wrap-around");
            coverage.add("most negative data");
            coverage.add("most positive data");
        endfunction

        function void write(fifo_cycle cycle);
            bit model_full  = model.size() == DEPTH;
            bit model_empty = model.size() == 0;
            bit write_accepted = cycle.write_enable && !model_full;
            bit read_accepted  = cycle.read_enable && !model_empty;

            if (cycle.full !== model_full)
                `uvm_error("FIFO", $sformatf("full_out = %0b, model holds %0d", cycle.full, model.size()))
            if (cycle.empty !== model_empty)
                `uvm_error("FIFO", $sformatf("empty_out = %0b, model holds %0d", cycle.empty, model.size()))

            if (read_accepted) begin
                bit signed [WIDTH-1:0] expected = model.pop_front();
                if (cycle.read_data !== expected)
                    `uvm_error("FIFO", $sformatf("read_data_out = %0d, expected %0d", cycle.read_data, expected))
                coverage.hit("read accepted");
            end
            if (write_accepted) begin
                model.push_back(cycle.write_data);
                writes_accepted++;
                coverage.hit("write accepted");
                if (writes_accepted == DEPTH + 1) coverage.hit("pointer wrap-around");
                if (cycle.write_data == 16'sh8000) coverage.hit("most negative data");
                if (cycle.write_data == 16'sh7fff) coverage.hit("most positive data");
            end

            if (model_full)                                        coverage.hit("full");
            if (model_empty)                                       coverage.hit("empty");
            if (cycle.write_enable && model_full)                  coverage.hit("write dropped when full");
            if (cycle.read_enable && model_empty)                  coverage.hit("read ignored when empty");
            if (write_accepted && read_accepted)                   coverage.hit("read and write together");
            if (cycle.write_enable && read_accepted && model_full) coverage.hit("read and write when full");
        endfunction

        function void check_phase(uvm_phase phase);
            coverage.check("fifo");
        endfunction
    endclass

    class fifo_env extends uvm_env;
        `uvm_component_utils(fifo_env)
        uvm_sequencer #(fifo_item) sequencer;
        fifo_driver                driver;
        fifo_monitor               monitor;
        fifo_scoreboard            scoreboard;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            fifo_vif vif;
            if (!uvm_config_db #(fifo_vif)::get(this, "", "fifo_vif", vif))
                `uvm_fatal("FIFO", "no fifo_vif in the config db")
            sequencer  = uvm_sequencer #(fifo_item)::type_id::create("sequencer", this);
            driver     = fifo_driver::type_id::create("driver", this);
            monitor    = fifo_monitor::type_id::create("monitor", this);
            scoreboard = fifo_scoreboard::type_id::create("scoreboard", this);
            driver.vif  = vif;
            monitor.vif = vif;
        endfunction

        function void connect_phase(uvm_phase phase);
            driver.seq_item_port.connect(sequencer.seq_item_export);
            monitor.cycle_port.connect(scoreboard.analysis_export);
        endfunction
    endclass

    class fifo_random_test extends base_test;
        `uvm_component_utils(fifo_random_test)
        fifo_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            env = fifo_env::type_id::create("env", this);
        endfunction

        task run_phase(uvm_phase phase);
            fifo_random_sequence random_sequence = fifo_random_sequence::type_id::create("sequence");
            phase.raise_objection(this);
            random_sequence.start(env.sequencer);
            repeat (4) @(posedge env.driver.vif.clk);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
