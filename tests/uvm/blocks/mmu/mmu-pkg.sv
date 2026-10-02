`include "uvm_macros.svh"

// mmu (behind the systolic data setup): jobs of back-to-back tiles on the overlap
// schedule matmul_engine uses (a tile's m rows at the start of a max(m, N) window,
// the next tile's weight rows in its last N cycles), random m and tile counts; every
// output column must match a plain matrix multiply, in order
package mmu_pkg;
    import uvm_pkg::*;
    import uvm_common_pkg::*;

    localparam int ARRAY_SIZE       = 4;
    localparam int ROW_SELECT_WIDTH = $clog2(ARRAY_SIZE);
    localparam int MAXIMUM_ROWS     = 3 * ARRAY_SIZE;
    localparam int MAXIMUM_TILES    = 4;

    typedef virtual mmu_if #(ARRAY_SIZE) mmu_vif;
    typedef bit signed [7:0] int8_t;

    class mmu_job extends uvm_sequence_item;
        `uvm_object_utils(mmu_job)
        rand int unsigned activation_rows;
        rand int unsigned tile_count;
        rand int8_t       weights     [MAXIMUM_TILES][ARRAY_SIZE][ARRAY_SIZE];    // [tile][K row][column]
        rand int8_t       activations [MAXIMUM_TILES][MAXIMUM_ROWS][ARRAY_SIZE];  // [tile][row][K]

        constraint shape {
            activation_rows dist {1 := 20, ARRAY_SIZE := 20, 2 * ARRAY_SIZE + 1 := 20, [2 : MAXIMUM_ROWS] :/ 40};
            tile_count inside {[1 : MAXIMUM_TILES]};
        }
        constraint extremes {
            foreach (weights[t, r, c])     weights[t][r][c]     dist {-8'sd128 := 5, 8'sd127 := 5, [-8'sd127 : 8'sd126] :/ 90};
            foreach (activations[t, i, r]) activations[t][i][r] dist {-8'sd128 := 5, 8'sd127 := 5, [-8'sd127 : 8'sd126] :/ 90};
        }

        function new(string name = "mmu_job");
            super.new(name);
        endfunction

        function int expected(int tile, int row, int column);
            int sum = 0;
            for (int k = 0; k < ARRAY_SIZE; k++) sum += int'(activations[tile][row][k]) * int'(weights[tile][k][column]);
            return sum;
        endfunction
    endclass

    class mmu_output extends uvm_sequence_item;
        `uvm_object_utils(mmu_output)
        bit signed [ARRAY_SIZE-1:0][31:0] partial_sum;
        bit        [ARRAY_SIZE-1:0]       partial_sum_valid;

        function new(string name = "mmu_output");
            super.new(name);
        endfunction
    endclass

    class mmu_random_sequence extends uvm_sequence #(mmu_job);
        `uvm_object_utils(mmu_random_sequence)

        function new(string name = "mmu_random_sequence");
            super.new(name);
        endfunction

        task body();
            repeat (60) begin
                mmu_job job = mmu_job::type_id::create("job");
                start_item(job);
                if (!job.randomize()) `uvm_fatal("SEQUENCE", "randomize failed")
                finish_item(job);
            end
        endtask
    endclass

    // window w streams tile w-1's rows and loads tile w's weights; jobs drain between
    class mmu_driver extends uvm_driver #(mmu_job);
        `uvm_component_utils(mmu_driver)
        mmu_vif                     vif;
        uvm_analysis_port #(mmu_job) job_port;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            job_port = new("job_port", this);
        endfunction

        task run_phase(uvm_phase phase);
            vif.row_valid_in         = 1'b0;
            vif.row_in               = '0;
            vif.weight_valid_in      = 1'b0;
            vif.weight_row_select_in = '0;
            vif.weight_in            = '0;
            wait (vif.reset === 1'b0);
            forever begin
                int m, tiles;
                seq_item_port.get_next_item(req);
                job_port.write(req);
                m     = req.activation_rows;
                tiles = req.tile_count;
                for (int window = 0; window <= tiles; window++) begin
                    int length = (window > 0 && m > ARRAY_SIZE) ? m : (window < tiles ? ARRAY_SIZE : m);
                    for (int position = 0; position < length; position++) begin
                        bit activations = window > 0 && position < m;
                        bit weights     = window < tiles && position >= length - ARRAY_SIZE;
                        @(negedge vif.clk);
                        vif.row_valid_in = activations;
                        for (int lane = 0; lane < ARRAY_SIZE; lane++)
                            vif.row_in[lane] = activations ? {1'(position == 0), req.activations[window-1][position][lane]} : '0;
                        vif.weight_valid_in      = weights;
                        vif.weight_row_select_in = weights ? ROW_SELECT_WIDTH'(position - (length - ARRAY_SIZE)) : '0;
                        for (int column = 0; column < ARRAY_SIZE; column++)
                            vif.weight_in[column] = weights ? req.weights[window][position - (length - ARRAY_SIZE)][column] : 8'sd0;
                    end
                end
                @(negedge vif.clk);
                vif.row_valid_in    = 1'b0;
                vif.weight_valid_in = 1'b0;
                repeat (3 * ARRAY_SIZE) @(negedge vif.clk);
                seq_item_port.item_done();
            end
        endtask
    endclass

    class mmu_monitor extends uvm_monitor;
        `uvm_component_utils(mmu_monitor)
        mmu_vif                         vif;
        uvm_analysis_port #(mmu_output) output_port;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            output_port = new("output_port", this);
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.reset !== 1'b0 || vif.partial_sum_valid_out == '0) continue;
                begin
                    mmu_output sample = mmu_output::type_id::create("sample");
                    sample.partial_sum       = vif.partial_sum_out;
                    sample.partial_sum_valid = vif.partial_sum_valid_out;
                    output_port.write(sample);
                end
            end
        endtask
    endclass

    `uvm_analysis_imp_decl(_job)
    `uvm_analysis_imp_decl(_output)

    class mmu_scoreboard extends uvm_component;
        `uvm_component_utils(mmu_scoreboard)
        uvm_analysis_imp_job    #(mmu_job, mmu_scoreboard)    job_export;
        uvm_analysis_imp_output #(mmu_output, mmu_scoreboard) output_export;
        int           expected [ARRAY_SIZE][$];
        int unsigned  checked;
        coverage_bins coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            job_export    = new("job_export", this);
            output_export = new("output_export", this);
            coverage = coverage_bins::type_id::create("coverage");
            coverage.add("one row per tile");
            coverage.add("N rows: the array fed every cycle");
            coverage.add("windows longer than N");
            coverage.add("rows between 1 and N");
            coverage.add("a single tile");
            coverage.add("four back-to-back tiles");
            coverage.add("-128 x -128");
        endfunction

        function void write_job(mmu_job job);
            int m = job.activation_rows;
            for (int tile = 0; tile < job.tile_count; tile++)
                for (int row = 0; row < m; row++)
                    for (int column = 0; column < ARRAY_SIZE; column++) begin
                        expected[column].push_back(job.expected(tile, row, column));
                        for (int k = 0; k < ARRAY_SIZE; k++)
                            if (job.activations[tile][row][k] == -8'sd128 && job.weights[tile][k][column] == -8'sd128)
                                coverage.hit("-128 x -128");
                    end
            if (m == 1)                       coverage.hit("one row per tile");
            if (m == ARRAY_SIZE)              coverage.hit("N rows: the array fed every cycle");
            if (m > ARRAY_SIZE)               coverage.hit("windows longer than N");
            if (m > 1 && m < ARRAY_SIZE)      coverage.hit("rows between 1 and N");
            if (job.tile_count == 1)          coverage.hit("a single tile");
            if (job.tile_count == MAXIMUM_TILES) coverage.hit("four back-to-back tiles");
        endfunction

        function void write_output(mmu_output sample);
            for (int column = 0; column < ARRAY_SIZE; column++)
                if (sample.partial_sum_valid[column]) begin
                    if (expected[column].size() == 0) begin
                        `uvm_error("MMU", $sformatf("column %0d: an output with none expected", column))
                    end else begin
                        int want = expected[column].pop_front();
                        if (int'(sample.partial_sum[column]) !== want)
                            `uvm_error("MMU", $sformatf("column %0d: %0d, expected %0d", column, $signed(sample.partial_sum[column]), want))
                        checked++;
                    end
                end
        endfunction

        function void check_phase(uvm_phase phase);
            foreach (expected[column])
                if (expected[column].size() != 0)
                    `uvm_error("MMU", $sformatf("column %0d: %0d outputs never came", column, expected[column].size()))
            `uvm_info("MMU", $sformatf("%0d outputs checked", checked), UVM_MEDIUM)
            coverage.check("mmu");
        endfunction
    endclass

    class mmu_env extends uvm_env;
        `uvm_component_utils(mmu_env)
        uvm_sequencer #(mmu_job) sequencer;
        mmu_driver               driver;
        mmu_monitor              monitor;
        mmu_scoreboard           scoreboard;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            mmu_vif vif;
            if (!uvm_config_db #(mmu_vif)::get(this, "", "mmu_vif", vif)) `uvm_fatal("MMU", "no mmu_vif in the config db")
            sequencer  = uvm_sequencer #(mmu_job)::type_id::create("sequencer", this);
            driver     = mmu_driver::type_id::create("driver", this);
            monitor    = mmu_monitor::type_id::create("monitor", this);
            scoreboard = mmu_scoreboard::type_id::create("scoreboard", this);
            driver.vif  = vif;
            monitor.vif = vif;
        endfunction

        function void connect_phase(uvm_phase phase);
            driver.seq_item_port.connect(sequencer.seq_item_export);
            driver.job_port.connect(scoreboard.job_export);
            monitor.output_port.connect(scoreboard.output_export);
        endfunction
    endclass

    class mmu_random_test extends base_test;
        `uvm_component_utils(mmu_random_test)
        mmu_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            env = mmu_env::type_id::create("env", this);
        endfunction

        task run_phase(uvm_phase phase);
            mmu_random_sequence random_sequence = mmu_random_sequence::type_id::create("random_sequence");
            phase.raise_objection(this);
            random_sequence.start(env.sequencer);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
