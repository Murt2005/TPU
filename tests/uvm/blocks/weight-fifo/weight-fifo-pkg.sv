`include "uvm_macros.svh"

// weight_fifo: the driver fills tiles the way the weight engine does (a row issued
// only when fill_ready_out allows, landing a cycle later, advance on the last row)
// while a taker drains whole tiles at random; every taken tile must be the next one
// filled, and fill_ready_out / tile_full_out must follow the two-slot rule
package weight_fifo_pkg;
    import uvm_pkg::*;
    import uvm_common_pkg::*;

    localparam int ARRAY_SIZE = 4;

    typedef virtual weight_fifo_if #(ARRAY_SIZE) weight_fifo_vif;
    typedef bit [ARRAY_SIZE-1:0][ARRAY_SIZE*8-1:0] tile_t;

    // one tile to fill, with the chance of stalling before each row and of taking each cycle
    class weight_fifo_item extends uvm_sequence_item;
        `uvm_object_utils(weight_fifo_item)
        rand tile_t       tile;
        rand int unsigned stall_percent;
        rand int unsigned take_percent;

        constraint rates {
            stall_percent dist {0 := 50, [1:30] :/ 30, [60:80] :/ 20};
            take_percent  dist {100 := 30, [5:30] :/ 40, [50:90] :/ 30};
        }

        function new(string name = "weight_fifo_item");
            super.new(name);
        endfunction
    endclass

    class weight_fifo_cycle extends uvm_sequence_item;
        `uvm_object_utils(weight_fifo_cycle)
        bit                    fill_ready, fill_advance, fill_write_enable, fill_slot, tile_full, tile_take;
        bit [7:0]              fill_row;
        bit [ARRAY_SIZE*8-1:0] fill_data;
        tile_t                 tile;

        function new(string name = "weight_fifo_cycle");
            super.new(name);
        endfunction
    endclass

    class weight_fifo_random_sequence extends uvm_sequence #(weight_fifo_item);
        `uvm_object_utils(weight_fifo_random_sequence)
        int unsigned tile_count = 150;

        function new(string name = "weight_fifo_random_sequence");
            super.new(name);
        endfunction

        task body();
            repeat (tile_count) begin
                weight_fifo_item item = weight_fifo_item::type_id::create("item");
                start_item(item);
                if (!item.randomize()) `uvm_fatal("SEQUENCE", "randomize failed")
                finish_item(item);
            end
        endtask
    endclass

    // every negedge: the taker decides first (fill_ready_out depends on the take),
    // then a row is issued if allowed; the row issued last cycle lands now
    class weight_fifo_driver extends uvm_driver #(weight_fifo_item);
        `uvm_component_utils(weight_fifo_driver)
        weight_fifo_vif vif;
        bit             idle = 1'b1;
        int unsigned    issue_row = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            bit                    landing_valid = 1'b0, landing_slot;
            bit [7:0]              landing_row;
            bit [ARRAY_SIZE*8-1:0] landing_data;
            int unsigned           take_percent = 50;
            vif.fill_advance_in      = 1'b0;
            vif.fill_write_enable_in = 1'b0;
            vif.fill_slot_in         = 1'b0;
            vif.fill_row_in          = '0;
            vif.fill_data_in         = '0;
            vif.tile_take_in         = 1'b0;
            wait (vif.reset === 1'b0);
            forever begin
                bit have_tile = 1'b0;
                if (req == null) begin
                    seq_item_port.try_next_item(req);
                    if (req != null) take_percent = req.take_percent;
                end
                have_tile = req != null;
                idle      = !have_tile && !landing_valid;
                @(negedge vif.clk);
                vif.fill_write_enable_in = landing_valid;
                vif.fill_slot_in         = landing_slot;
                vif.fill_row_in          = landing_row;
                vif.fill_data_in         = landing_data;
                vif.tile_take_in         = vif.tile_full_out && ($urandom_range(99) < take_percent);
                #1;
                landing_valid       = 1'b0;
                vif.fill_advance_in = 1'b0;
                if (have_tile && vif.fill_ready_out && $urandom_range(99) >= req.stall_percent) begin
                    landing_valid = 1'b1;
                    landing_slot  = vif.fill_slot_next_out;
                    landing_row   = 8'(issue_row);
                    landing_data  = req.tile[issue_row];
                    if (issue_row == ARRAY_SIZE - 1) begin
                        vif.fill_advance_in = 1'b1;
                        issue_row = 0;
                        seq_item_port.item_done();
                        req = null;
                    end else begin
                        issue_row++;
                    end
                end
            end
        endtask
    endclass

    class weight_fifo_monitor extends uvm_monitor;
        `uvm_component_utils(weight_fifo_monitor)
        weight_fifo_vif                         vif;
        uvm_analysis_port #(weight_fifo_cycle)  cycle_port;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cycle_port = new("cycle_port", this);
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.reset !== 1'b0) continue;
                begin
                    weight_fifo_cycle cycle = weight_fifo_cycle::type_id::create("cycle");
                    cycle.fill_ready        = vif.fill_ready_out;
                    cycle.fill_advance      = vif.fill_advance_in;
                    cycle.fill_write_enable = vif.fill_write_enable_in;
                    cycle.fill_slot         = vif.fill_slot_in;
                    cycle.fill_row          = vif.fill_row_in;
                    cycle.fill_data         = vif.fill_data_in;
                    cycle.tile              = vif.tile_out;
                    cycle.tile_full         = vif.tile_full_out;
                    cycle.tile_take         = vif.tile_take_in;
                    cycle_port.write(cycle);
                end
            end
        endtask
    endclass

    // claimed = tiles advanced and not yet taken (at most two); complete = tiles whose
    // last row has landed and not yet taken, oldest first
    class weight_fifo_scoreboard extends uvm_subscriber #(weight_fifo_cycle);
        `uvm_component_utils(weight_fifo_scoreboard)
        int unsigned  claimed;
        tile_t        filling;
        tile_t        complete [$];
        int unsigned  taken;
        bit           ready_only_by_take;   // last cycle, fill_ready_out was high only because of a take
        coverage_bins coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            coverage = coverage_bins::type_id::create("coverage");
            coverage.add("both slots claimed");
            coverage.add("row issued into the slot being taken");
            coverage.add("take while the other slot fills");
            coverage.add("fill stalled by no free slot");
            coverage.add("tile taken");
            coverage.add("empty");
        endfunction

        function void write(weight_fifo_cycle cycle);
            bit expected_ready = claimed < 2 || (cycle.tile_take && cycle.tile_full);
            if (cycle.fill_ready !== expected_ready)
                `uvm_error("WEIGHT_FIFO", $sformatf("fill_ready_out = %0b with %0d slots claimed", cycle.fill_ready, claimed))
            if (cycle.tile_full !== (complete.size() > 0))
                `uvm_error("WEIGHT_FIFO", $sformatf("tile_full_out = %0b with %0d complete tiles", cycle.tile_full, complete.size()))
            if (cycle.tile_take && !cycle.tile_full)
                `uvm_error("WEIGHT_FIFO", "the driver took an empty slot")

            if (claimed == 2)                                  coverage.hit("both slots claimed");
            if (cycle.fill_write_enable && ready_only_by_take) coverage.hit("row issued into the slot being taken");
            ready_only_by_take = claimed == 2 && cycle.fill_ready;
            if (cycle.tile_take && cycle.fill_write_enable)    coverage.hit("take while the other slot fills");
            if (!cycle.fill_ready)                             coverage.hit("fill stalled by no free slot");
            if (claimed == 0)                                  coverage.hit("empty");

            if (cycle.tile_take && complete.size() > 0) begin
                tile_t expected = complete.pop_front();
                if (cycle.tile !== expected) `uvm_error("WEIGHT_FIFO", $sformatf("tile %0d taken with the wrong rows", taken))
                taken++;
                claimed--;
                coverage.hit("tile taken");
            end
            if (cycle.fill_advance) claimed++;
            if (cycle.fill_write_enable) begin
                filling[cycle.fill_row] = cycle.fill_data;
                if (cycle.fill_row == ARRAY_SIZE - 1) complete.push_back(filling);
            end
        endfunction

        function void check_phase(uvm_phase phase);
            if (taken == 0) `uvm_error("WEIGHT_FIFO", "no tiles taken")
            `uvm_info("WEIGHT_FIFO", $sformatf("%0d tiles taken in order", taken), UVM_MEDIUM)
            coverage.check("weight_fifo");
        endfunction
    endclass

    class weight_fifo_env extends uvm_env;
        `uvm_component_utils(weight_fifo_env)
        uvm_sequencer #(weight_fifo_item) sequencer;
        weight_fifo_driver                driver;
        weight_fifo_monitor               monitor;
        weight_fifo_scoreboard            scoreboard;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            weight_fifo_vif vif;
            if (!uvm_config_db #(weight_fifo_vif)::get(this, "", "weight_fifo_vif", vif))
                `uvm_fatal("WEIGHT_FIFO", "no weight_fifo_vif in the config db")
            sequencer  = uvm_sequencer #(weight_fifo_item)::type_id::create("sequencer", this);
            driver     = weight_fifo_driver::type_id::create("driver", this);
            monitor    = weight_fifo_monitor::type_id::create("monitor", this);
            scoreboard = weight_fifo_scoreboard::type_id::create("scoreboard", this);
            driver.vif  = vif;
            monitor.vif = vif;
        endfunction

        function void connect_phase(uvm_phase phase);
            driver.seq_item_port.connect(sequencer.seq_item_export);
            monitor.cycle_port.connect(scoreboard.analysis_export);
        endfunction
    endclass

    class weight_fifo_random_test extends base_test;
        `uvm_component_utils(weight_fifo_random_test)
        weight_fifo_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            env = weight_fifo_env::type_id::create("env", this);
        endfunction

        // after the last tile is issued, keep taking until the FIFO is empty
        task run_phase(uvm_phase phase);
            weight_fifo_random_sequence random_sequence = weight_fifo_random_sequence::type_id::create("random_sequence");
            phase.raise_objection(this);
            random_sequence.start(env.sequencer);
            wait (env.driver.idle);
            repeat (200) begin
                @(posedge env.driver.vif.clk);
                if (env.scoreboard.claimed == 0) break;
            end
            if (env.scoreboard.claimed != 0) `uvm_error("WEIGHT_FIFO", "tiles left undrained")
            phase.drop_objection(this);
        endtask
    endclass
endpackage
