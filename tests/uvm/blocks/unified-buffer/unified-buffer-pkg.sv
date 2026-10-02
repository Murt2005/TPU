`include "uvm_macros.svh"

// unified_buffer: both write ports and both read sources at random over a small
// buffer, so the same entries collide often; the activate write beats the load
// write, the matmul read beats the activate read, and a read in the cycle an entry
// is written returns the old contents
package unified_buffer_pkg;
    import uvm_pkg::*;
    import uvm_common_pkg::*;

    localparam int ARRAY_SIZE    = 4;
    localparam int DEPTH         = 16;
    localparam int ADDRESS_WIDTH = $clog2(DEPTH);

    typedef virtual unified_buffer_if #(ARRAY_SIZE, ADDRESS_WIDTH) unified_buffer_vif;
    typedef bit [ARRAY_SIZE*8-1:0]  entry_t;
    typedef bit [ADDRESS_WIDTH-1:0] address_t;

    class unified_buffer_item extends uvm_sequence_item;
        `uvm_object_utils(unified_buffer_item)
        rand bit       load_write_enable, activate_write_enable, matmul_read_enable;
        rand address_t load_write_address, activate_write_address, matmul_read_address, activate_read_address;
        rand entry_t   load_write_data, activate_write_data;

        function new(string name = "unified_buffer_item");
            super.new(name);
        endfunction
    endclass

    class unified_buffer_cycle extends uvm_sequence_item;
        `uvm_object_utils(unified_buffer_cycle)
        bit       load_write_enable, activate_write_enable, matmul_read_enable;
        address_t load_write_address, activate_write_address, matmul_read_address, activate_read_address;
        entry_t   load_write_data, activate_write_data, read_data;

        function new(string name = "unified_buffer_cycle");
            super.new(name);
        endfunction
    endclass

    // write every entry first so every later read has a known answer
    class unified_buffer_random_sequence extends uvm_sequence #(unified_buffer_item);
        `uvm_object_utils(unified_buffer_random_sequence)

        function new(string name = "unified_buffer_random_sequence");
            super.new(name);
        endfunction

        task body();
            for (int address = 0; address < DEPTH; address++) begin
                unified_buffer_item item = unified_buffer_item::type_id::create("item");
                start_item(item);
                if (!item.randomize() with { load_write_enable == 1; activate_write_enable == 0;
                                             load_write_address == address; }) `uvm_fatal("SEQUENCE", "randomize failed")
                finish_item(item);
            end
            repeat (3000) begin
                unified_buffer_item item = unified_buffer_item::type_id::create("item");
                start_item(item);
                if (!item.randomize()) `uvm_fatal("SEQUENCE", "randomize failed")
                finish_item(item);
            end
        endtask
    endclass

    class unified_buffer_driver extends uvm_driver #(unified_buffer_item);
        `uvm_component_utils(unified_buffer_driver)
        unified_buffer_vif vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            vif.load_write_enable_in     = 1'b0;
            vif.activate_write_enable_in = 1'b0;
            vif.matmul_read_enable_in    = 1'b0;
            wait (vif.reset === 1'b0);
            forever begin
                seq_item_port.get_next_item(req);
                @(negedge vif.clk);
                vif.load_write_enable_in      = req.load_write_enable;
                vif.load_write_address_in     = req.load_write_address;
                vif.load_write_data_in        = req.load_write_data;
                vif.activate_write_enable_in  = req.activate_write_enable;
                vif.activate_write_address_in = req.activate_write_address;
                vif.activate_write_data_in    = req.activate_write_data;
                vif.matmul_read_enable_in     = req.matmul_read_enable;
                vif.matmul_read_address_in    = req.matmul_read_address;
                vif.activate_read_address_in  = req.activate_read_address;
                seq_item_port.item_done();
            end
        endtask
    endclass

    class unified_buffer_monitor extends uvm_monitor;
        `uvm_component_utils(unified_buffer_monitor)
        unified_buffer_vif                        vif;
        uvm_analysis_port #(unified_buffer_cycle) cycle_port;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cycle_port = new("cycle_port", this);
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.reset !== 1'b0) continue;
                begin
                    unified_buffer_cycle cycle = unified_buffer_cycle::type_id::create("cycle");
                    cycle.load_write_enable      = vif.load_write_enable_in;
                    cycle.load_write_address     = vif.load_write_address_in;
                    cycle.load_write_data        = vif.load_write_data_in;
                    cycle.activate_write_enable  = vif.activate_write_enable_in;
                    cycle.activate_write_address = vif.activate_write_address_in;
                    cycle.activate_write_data    = vif.activate_write_data_in;
                    cycle.matmul_read_enable     = vif.matmul_read_enable_in;
                    cycle.matmul_read_address    = vif.matmul_read_address_in;
                    cycle.activate_read_address  = vif.activate_read_address_in;
                    cycle.read_data              = vif.read_data_out;
                    cycle_port.write(cycle);
                end
            end
        endtask
    endclass

    // read_data_out at an edge is the entry addressed at the edge before, as it was then
    class unified_buffer_scoreboard extends uvm_subscriber #(unified_buffer_cycle);
        `uvm_component_utils(unified_buffer_scoreboard)
        entry_t       model   [DEPTH];
        bit           written [DEPTH];
        bit           expect_read;
        entry_t       expected_read;
        coverage_bins coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            coverage = coverage_bins::type_id::create("coverage");
            coverage.add("load write");
            coverage.add("activate write");
            coverage.add("both writes, activate wins");
            coverage.add("matmul read");
            coverage.add("activate read");
            coverage.add("read of the entry being written");
        endfunction

        function void write(unified_buffer_cycle cycle);
            address_t read_address = cycle.matmul_read_enable ? cycle.matmul_read_address : cycle.activate_read_address;
            if (expect_read && cycle.read_data !== expected_read)
                `uvm_error("UB", $sformatf("read_data_out = %h, expected %h", cycle.read_data, expected_read))

            expect_read   = written[read_address];
            expected_read = model[read_address];
            coverage.hit(cycle.matmul_read_enable ? "matmul read" : "activate read");
            if ((cycle.activate_write_enable && cycle.activate_write_address == read_address)
                || (!cycle.activate_write_enable && cycle.load_write_enable && cycle.load_write_address == read_address))
                coverage.hit("read of the entry being written");

            if (cycle.activate_write_enable) begin
                model[cycle.activate_write_address]   = cycle.activate_write_data;
                written[cycle.activate_write_address] = 1'b1;
                coverage.hit(cycle.load_write_enable ? "both writes, activate wins" : "activate write");
            end else if (cycle.load_write_enable) begin
                model[cycle.load_write_address]   = cycle.load_write_data;
                written[cycle.load_write_address] = 1'b1;
                coverage.hit("load write");
            end
        endfunction

        function void check_phase(uvm_phase phase);
            coverage.check("unified_buffer");
        endfunction
    endclass

    class unified_buffer_env extends uvm_env;
        `uvm_component_utils(unified_buffer_env)
        uvm_sequencer #(unified_buffer_item) sequencer;
        unified_buffer_driver                driver;
        unified_buffer_monitor               monitor;
        unified_buffer_scoreboard            scoreboard;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            unified_buffer_vif vif;
            if (!uvm_config_db #(unified_buffer_vif)::get(this, "", "unified_buffer_vif", vif))
                `uvm_fatal("UB", "no unified_buffer_vif in the config db")
            sequencer  = uvm_sequencer #(unified_buffer_item)::type_id::create("sequencer", this);
            driver     = unified_buffer_driver::type_id::create("driver", this);
            monitor    = unified_buffer_monitor::type_id::create("monitor", this);
            scoreboard = unified_buffer_scoreboard::type_id::create("scoreboard", this);
            driver.vif  = vif;
            monitor.vif = vif;
        endfunction

        function void connect_phase(uvm_phase phase);
            driver.seq_item_port.connect(sequencer.seq_item_export);
            monitor.cycle_port.connect(scoreboard.analysis_export);
        endfunction
    endclass

    class unified_buffer_random_test extends base_test;
        `uvm_component_utils(unified_buffer_random_test)
        unified_buffer_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            env = unified_buffer_env::type_id::create("env", this);
        endfunction

        task run_phase(uvm_phase phase);
            unified_buffer_random_sequence random_sequence = unified_buffer_random_sequence::type_id::create("random_sequence");
            phase.raise_objection(this);
            random_sequence.start(env.sequencer);
            repeat (2) @(posedge env.driver.vif.clk);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
