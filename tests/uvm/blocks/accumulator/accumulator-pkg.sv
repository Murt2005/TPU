`include "uvm_macros.svh"

// accumulator: rows arrive skewed the way the mmu emits them (column c of a row c
// cycles after its tag), in bursts and gaps, overwriting or adding into a small ACC
// so rows come round often; random activate reads every cycle. checked against an
// ACC model: every row written once and in order, an ACC read blocked exactly for
// each accumulated row, and every unblocked read
package accumulator_pkg;
    import uvm_pkg::*;
    import uvm_common_pkg::*;

    localparam int ARRAY_SIZE        = 4;
    localparam int ACC_DEPTH         = 16;
    localparam int ACC_ADDRESS_WIDTH = $clog2(ACC_DEPTH);

    typedef virtual accumulator_if #(ARRAY_SIZE, ACC_ADDRESS_WIDTH) accumulator_vif;
    typedef bit [ACC_ADDRESS_WIDTH-1:0] address_t;
    typedef bit signed [31:0]           word_t;

    class accumulator_item extends uvm_sequence_item;
        `uvm_object_utils(accumulator_item)
        rand address_t    address;
        rand bit          overwrite;
        rand word_t       values [ARRAY_SIZE];
        rand int unsigned gap_after;      // idle cycles before the next row
        address_t         recent [$];     // set by the sequence: the last ARRAY_SIZE addresses

        constraint not_recent { foreach (recent[i]) address != recent[i]; }
        constraint overwrite_rate { overwrite dist {1 := 30, 0 := 70}; }
        constraint gap_rate { gap_after dist {0 := 70, [1:3] :/ 20, [4:12] :/ 10}; }
        constraint value_extremes {
            foreach (values[column]) values[column] dist {32'sh7fffffff := 5, 32'sh80000000 := 5, 0 := 5,
                                                         [-32'sd1000 : 32'sd1000] :/ 45, [32'sh80000001 : 32'sh7ffffffe] :/ 40};
        }

        function new(string name = "accumulator_item");
            super.new(name);
        endfunction
    endclass

    class accumulator_cycle extends uvm_sequence_item;
        `uvm_object_utils(accumulator_cycle)
        word_t                      partial_sum [ARRAY_SIZE];
        bit [ARRAY_SIZE-1:0]        partial_sum_valid;
        bit                         tag_push, row_written, read_blocked;
        bit [ACC_ADDRESS_WIDTH:0]   tag;
        address_t                   read_address;
        bit [ARRAY_SIZE*32-1:0]     read_data;

        function new(string name = "accumulator_cycle");
            super.new(name);
        endfunction
    endclass

    // overwrite every row once so later accumulates start from known contents
    class accumulator_random_sequence extends uvm_sequence #(accumulator_item);
        `uvm_object_utils(accumulator_random_sequence)
        address_t recent [$];

        function new(string name = "accumulator_random_sequence");
            super.new(name);
        endfunction

        task send(bit initial_sweep, address_t address);
            accumulator_item item = accumulator_item::type_id::create("item");
            item.recent = recent;
            start_item(item);
            if (initial_sweep) begin
                // dist is a hard pick in Verilator, so the rates the sweep overrides go off
                item.overwrite_rate.constraint_mode(0);
                item.gap_rate.constraint_mode(0);
                if (!item.randomize() with { overwrite == 1; gap_after == 0; address == local::address; })
                    `uvm_fatal("SEQUENCE", "randomize failed")
            end else if (!item.randomize()) `uvm_fatal("SEQUENCE", "randomize failed")
            finish_item(item);
            recent.push_back(item.address);
            if (recent.size() > ARRAY_SIZE) void'(recent.pop_front());
        endtask

        task body();
            for (int address = 0; address < ACC_DEPTH; address++) send(1'b1, address_t'(address));
            repeat (1500) send(1'b0, '0);
        endtask
    endclass

    // column c carries the row that started c cycles ago
    class accumulator_driver extends uvm_driver #(accumulator_item);
        `uvm_component_utils(accumulator_driver)
        accumulator_vif vif;
        bit             idle = 1'b1;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            accumulator_item in_flight [ARRAY_SIZE];
            int unsigned     gap = 0;
            vif.partial_sum_in           = '0;
            vif.partial_sum_valid_in     = '0;
            vif.tag_push_in              = 1'b0;
            vif.tag_in                   = '0;
            vif.activate_read_address_in = '0;
            wait (vif.reset === 1'b0);
            forever begin
                accumulator_item starting = null;
                if (gap > 0) gap--;
                else begin
                    seq_item_port.try_next_item(req);
                    if (req != null) begin
                        starting = req;
                        gap      = req.gap_after;
                        seq_item_port.item_done();
                    end
                end
                for (int column = ARRAY_SIZE - 1; column > 0; column--) in_flight[column] = in_flight[column-1];
                in_flight[0] = starting;
                idle = 1'b1;
                foreach (in_flight[column]) if (in_flight[column] != null) idle = 1'b0;
                @(negedge vif.clk);
                vif.tag_push_in = starting != null;
                vif.tag_in      = starting != null ? {starting.overwrite, starting.address} : '0;
                for (int column = 0; column < ARRAY_SIZE; column++) begin
                    vif.partial_sum_valid_in[column] = in_flight[column] != null;
                    vif.partial_sum_in[column]       = in_flight[column] != null ? in_flight[column].values[column] : '0;
                end
                vif.activate_read_address_in = address_t'($urandom);
            end
        endtask
    endclass

    class accumulator_monitor extends uvm_monitor;
        `uvm_component_utils(accumulator_monitor)
        accumulator_vif                        vif;
        uvm_analysis_port #(accumulator_cycle) cycle_port;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cycle_port = new("cycle_port", this);
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.reset !== 1'b0) continue;
                begin
                    accumulator_cycle cycle = accumulator_cycle::type_id::create("cycle");
                    for (int column = 0; column < ARRAY_SIZE; column++) cycle.partial_sum[column] = vif.partial_sum_in[column];
                    cycle.partial_sum_valid = vif.partial_sum_valid_in;
                    cycle.tag_push          = vif.tag_push_in;
                    cycle.tag               = vif.tag_in;
                    cycle.row_written       = vif.row_written_out;
                    cycle.read_blocked      = vif.activate_read_blocked_out;
                    cycle.read_address      = vif.activate_read_address_in;
                    cycle.read_data         = vif.read_data_out;
                    cycle_port.write(cycle);
                end
            end
        endtask
    endclass

    class accumulator_row;
        address_t    address;
        bit          overwrite;
        word_t       values [ARRAY_SIZE];
        int unsigned columns_seen;
    endclass

    class accumulator_scoreboard extends uvm_subscriber #(accumulator_cycle);
        `uvm_component_utils(accumulator_scoreboard)
        word_t          model   [ACC_DEPTH][ARRAY_SIZE];
        bit             written [ACC_DEPTH];
        accumulator_row rows [$];                   // tagged and not yet written, oldest first
        int unsigned    column_count [ARRAY_SIZE];  // values seen per column so far
        int unsigned    rows_written;
        int             last_written_row [ACC_DEPTH];
        bit             expect_read, previous_blocked, previous_tag_push;
        word_t          expected_read [ARRAY_SIZE];
        coverage_bins   coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            coverage = coverage_bins::type_id::create("coverage");
            coverage.add("overwrite");
            coverage.add("accumulate");
            coverage.add("accumulate wraps");
            coverage.add("same row again ARRAY_SIZE+1 rows later");
            coverage.add("back-to-back rows");
            coverage.add("read blocked by an accumulate");
            coverage.add("read of the row being written");
            foreach (last_written_row[address]) last_written_row[address] = -1000;
        endfunction

        function void write(accumulator_cycle cycle);
            // the read issued at the last edge
            if (expect_read)
                for (int column = 0; column < ARRAY_SIZE; column++)
                    if (word_t'(cycle.read_data[32*column +: 32]) !== expected_read[column])
                        `uvm_error("ACCUMULATOR", $sformatf("read column %0d = %0d, expected %0d", column,
                                                            $signed(cycle.read_data[32*column +: 32]), expected_read[column]))

            // the read issued at this edge sees the contents before this edge's write
            expect_read = !cycle.read_blocked && written[cycle.read_address];
            for (int column = 0; column < ARRAY_SIZE; column++) expected_read[column] = model[cycle.read_address][column];
            if (cycle.read_blocked) coverage.hit("read blocked by an accumulate");

            // MM's read for an accumulated row is the cycle before its write
            if (cycle.row_written) begin
                if (rows.size() == 0 || rows[0].columns_seen != ARRAY_SIZE) begin
                    `uvm_error("ACCUMULATOR", "row_written_out with no complete row pending")
                end else begin
                    accumulator_row row = rows.pop_front();
                    if (previous_blocked == row.overwrite)
                        `uvm_error("ACCUMULATOR", $sformatf("the ACC read was %0s before an %0s row", previous_blocked ? "blocked" : "free",
                                                            row.overwrite ? "overwrite" : "accumulate"))
                    if (!cycle.read_blocked && cycle.read_address == row.address) coverage.hit("read of the row being written");
                    if (int'(rows_written) - last_written_row[row.address] == ARRAY_SIZE + 1)
                        coverage.hit("same row again ARRAY_SIZE+1 rows later");
                    last_written_row[row.address] = rows_written;
                    for (int column = 0; column < ARRAY_SIZE; column++) begin
                        longint exact = row.overwrite ? longint'(row.values[column])
                                                      : longint'(model[row.address][column]) + longint'(row.values[column]);
                        if (!row.overwrite && (exact > 64'sh7fffffff || exact < -64'sh80000000)) coverage.hit("accumulate wraps");
                        model[row.address][column] = 32'(exact);
                    end
                    written[row.address] = 1'b1;
                    rows_written++;
                    coverage.hit(row.overwrite ? "overwrite" : "accumulate");
                end
            end else if (previous_blocked) begin
                `uvm_error("ACCUMULATOR", "the ACC read was blocked with no row written after it")
            end
            previous_blocked = cycle.read_blocked;

            // rebuild rows from the inputs: a tag starts one, column c's k-th value belongs to row k
            if (cycle.tag_push) begin
                accumulator_row row = new();
                row.address   = cycle.tag[ACC_ADDRESS_WIDTH-1:0];
                row.overwrite = cycle.tag[ACC_ADDRESS_WIDTH];
                rows.push_back(row);
                if (previous_tag_push) coverage.hit("back-to-back rows");
            end
            previous_tag_push = cycle.tag_push;
            for (int column = 0; column < ARRAY_SIZE; column++)
                if (cycle.partial_sum_valid[column]) begin
                    accumulator_row row = rows[column_count[column] - rows_written];
                    row.values[column] = cycle.partial_sum[column];
                    row.columns_seen++;
                    column_count[column]++;
                end
        endfunction

        function void check_phase(uvm_phase phase);
            if (rows.size() != 0) `uvm_error("ACCUMULATOR", $sformatf("%0d rows never written", rows.size()))
            `uvm_info("ACCUMULATOR", $sformatf("%0d rows written in order", rows_written), UVM_MEDIUM)
            coverage.check("accumulator");
        endfunction
    endclass

    class accumulator_env extends uvm_env;
        `uvm_component_utils(accumulator_env)
        uvm_sequencer #(accumulator_item) sequencer;
        accumulator_driver                driver;
        accumulator_monitor               monitor;
        accumulator_scoreboard            scoreboard;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            accumulator_vif vif;
            if (!uvm_config_db #(accumulator_vif)::get(this, "", "accumulator_vif", vif))
                `uvm_fatal("ACCUMULATOR", "no accumulator_vif in the config db")
            sequencer  = uvm_sequencer #(accumulator_item)::type_id::create("sequencer", this);
            driver     = accumulator_driver::type_id::create("driver", this);
            monitor    = accumulator_monitor::type_id::create("monitor", this);
            scoreboard = accumulator_scoreboard::type_id::create("scoreboard", this);
            driver.vif  = vif;
            monitor.vif = vif;
        endfunction

        function void connect_phase(uvm_phase phase);
            driver.seq_item_port.connect(sequencer.seq_item_export);
            monitor.cycle_port.connect(scoreboard.analysis_export);
        endfunction
    endclass

    class accumulator_random_test extends base_test;
        `uvm_component_utils(accumulator_random_test)
        accumulator_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            env = accumulator_env::type_id::create("env", this);
        endfunction

        task run_phase(uvm_phase phase);
            accumulator_random_sequence random_sequence = accumulator_random_sequence::type_id::create("random_sequence");
            phase.raise_objection(this);
            random_sequence.start(env.sequencer);
            wait (env.driver.idle);
            repeat (4 * ARRAY_SIZE) @(posedge env.driver.vif.clk);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
