`include "uvm_macros.svh"

// tpu_top through its Avalon-MM slave: gen_cases.py's programs (the reference
// model's expected words) replayed with random bus timing: instruction and data
// pushes interleaved, idle gaps, OUT drained while the core runs, data writes
// left to stall on waitrequest once every instruction is in. every OUT word, the
// final status and the FIFO levels are checked against the model
package tpu_top_pkg;
    import uvm_pkg::*;
    import uvm_common_pkg::*;

    typedef virtual tpu_top_if tpu_top_vif;

    localparam bit [3:0] INSTRUCTION_LOW = 4'd0, INSTRUCTION_HIGH = 4'd1, DATA = 4'd2, OUTPUT = 4'd3,
                         STATUS = 4'd4, LEVELS = 4'd5, CONTROL = 4'd6, ERROR_SEQUENCE = 4'd7;
    localparam int INSTRUCTION_DEPTH = 512, DATA_DEPTH = 1024;

    // one case from gen_cases.py
    class tpu_case;
        string        name;
        bit [63:0]    instructions [$];
        bit [31:0]    data [$];
        bit [31:0]    out [$];
        bit           done, reads_empty_out, full_speed;
        bit [15:0]    tag;
        bit [7:0]     error_code;
        bit [31:0]    error_sequence;
    endclass

    class tpu_case_file;
        tpu_case cases [$];

        function new(string path);
            int    file = $fopen(path, "r");
            string keyword;
            int    count;
            if (file == 0) `uvm_fatal("TPU", $sformatf("can't open %s", path))
            while ($fscanf(file, "%s", keyword) == 1) begin
                tpu_case c;
                bit [63:0] word;
                if (keyword != "case") `uvm_fatal("TPU", $sformatf("expected 'case', got '%s'", keyword))
                c = new();
                void'($fscanf(file, "%s", c.name));
                void'($fscanf(file, "%s %h", keyword, count));
                repeat (count) begin void'($fscanf(file, "%h", word)); c.instructions.push_back(word); end
                void'($fscanf(file, "%s %h", keyword, count));
                repeat (count) begin void'($fscanf(file, "%h", word)); c.data.push_back(word[31:0]); end
                void'($fscanf(file, "%s %h", keyword, count));
                repeat (count) begin void'($fscanf(file, "%h", word)); c.out.push_back(word[31:0]); end
                void'($fscanf(file, "%s %h %h %h %h %h %h", keyword, c.done, c.tag, c.error_code, c.error_sequence,
                              c.reads_empty_out, c.full_speed));
                cases.push_back(c);
            end
            $fclose(file);
        endfunction
    endclass

    // one Avalon-MM access; a read's data comes back in the same item
    class avalon_item extends uvm_sequence_item;
        `uvm_object_utils(avalon_item)
        bit          write;
        bit [3:0]    address;
        bit [31:0]   data;
        int unsigned idle_before;

        function new(string name = "avalon_item");
            super.new(name);
        endfunction
    endclass

    // what the monitor saw: an accepted write, or a read with its data
    class avalon_access extends uvm_sequence_item;
        `uvm_object_utils(avalon_access)
        bit          write;
        bit [3:0]    address;
        bit [31:0]   data;
        int unsigned stall_cycles;

        function new(string name = "avalon_access");
            super.new(name);
        endfunction
    endclass

    // writes hold until waitrequest drops; reads have a fixed latency of one cycle
    class avalon_driver extends uvm_driver #(avalon_item);
        `uvm_component_utils(avalon_driver)
        tpu_top_vif vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        task run_phase(uvm_phase phase);
            vif.avs_write   = 1'b0;
            vif.avs_read    = 1'b0;
            vif.avs_address = '0;
            vif.avs_writedata = '0;
            forever begin
                seq_item_port.get_next_item(req);
                repeat (req.idle_before) @(negedge vif.clk);
                @(negedge vif.clk);
                vif.avs_address = req.address;
                if (req.write) begin
                    vif.avs_write     = 1'b1;
                    vif.avs_writedata = req.data;
                    do @(posedge vif.clk); while (vif.avs_waitrequest);
                    @(negedge vif.clk);
                    vif.avs_write = 1'b0;
                end else begin
                    vif.avs_read = 1'b1;
                    @(negedge vif.clk);
                    vif.avs_read = 1'b0;
                    req.data     = vif.avs_readdata;
                end
                seq_item_port.item_done();
            end
        endtask
    endclass

    class avalon_monitor extends uvm_monitor;
        `uvm_component_utils(avalon_monitor)
        tpu_top_vif                        vif;
        uvm_analysis_port #(avalon_access) access_port;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            access_port = new("access_port", this);
        endfunction

        task run_phase(uvm_phase phase);
            bit          read_pending = 1'b0;
            bit [3:0]    read_address;
            int unsigned stall_cycles = 0;
            forever begin
                @(posedge vif.clk);
                if (read_pending) begin
                    avalon_access access = avalon_access::type_id::create("access");
                    access.write   = 1'b0;
                    access.address = read_address;
                    access.data    = vif.avs_readdata;
                    access_port.write(access);
                end
                read_pending = vif.avs_read;
                read_address = vif.avs_address;
                if (vif.avs_waitrequest && !(vif.avs_write && vif.avs_address inside {INSTRUCTION_HIGH, DATA}))
                    `uvm_error("AVALON", $sformatf("waitrequest with write=%0b address=%0d", vif.avs_write, vif.avs_address))
                if (vif.avs_read && vif.avs_write) `uvm_error("AVALON", "read and write in the same cycle")
                if (vif.avs_write && vif.avs_waitrequest) stall_cycles++;
                else if (vif.avs_write) begin
                    avalon_access access = avalon_access::type_id::create("access");
                    access.write        = 1'b1;
                    access.address      = vif.avs_address;
                    access.data         = vif.avs_writedata;
                    access.stall_cycles = stall_cycles;
                    access_port.write(access);
                    stall_cycles = 0;
                end
            end
        endtask
    endclass

    // every OUT word against the model, in order; coverage of what the cases and the bus did
    class tpu_scoreboard extends uvm_subscriber #(avalon_access);
        `uvm_component_utils(tpu_scoreboard)
        bit [31:0]    expected_out [$];
        string        case_name;
        bit           empty_read_expected;
        int unsigned  words_checked, cases_run;
        coverage_bins coverage;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            coverage = coverage_bins::type_id::create("coverage");
            coverage.add("opcode WR_WMEM");
            coverage.add("opcode WR_UB");
            coverage.add("opcode WR_BIAS");
            coverage.add("opcode WR_QUANT");
            coverage.add("opcode SET_WBASE");
            coverage.add("opcode MATMUL");
            coverage.add("MATMUL accumulating");
            coverage.add("ACTIVATE to the UB");
            coverage.add("ACTIVATE requantized to the host");
            coverage.add("ACTIVATE int32 to the host");
            coverage.add("opcode RD_UB");
            coverage.add("opcode WAIT");
            coverage.add("opcode SIGNAL");
            // 1-4; 5 (UNIMPL) has nothing left to raise it since the DDR3 instructions
            for (int code = 1; code <= 4; code++) coverage.add($sformatf("error code %0d", code));
            coverage.add("write stalled by waitrequest");
            coverage.add("data pushed between instruction halves");
            coverage.add("OUT read while the core runs");
            coverage.add("reading an empty OUT");
        endfunction

        function void begin_case(tpu_case c);
            if (expected_out.size() != 0)
                `uvm_error("TPU", $sformatf("%s: %0d OUT words never read", case_name, expected_out.size()))
            expected_out = c.out;
            case_name    = c.name;
            cases_run++;
            if (c.error_code != 0) coverage.hit($sformatf("error code %0d", c.error_code));
            foreach (c.instructions[i]) begin
                bit [5:0] opcode = c.instructions[i][63:58];
                case (opcode)
                    6'h01: coverage.hit("opcode WR_WMEM");
                    6'h02: coverage.hit("opcode WR_UB");
                    6'h03: coverage.hit("opcode WR_BIAS");
                    6'h04: coverage.hit("opcode WR_QUANT");
                    6'h06: coverage.hit("opcode SET_WBASE");
                    6'h10: begin
                        coverage.hit("opcode MATMUL");
                        if (c.instructions[i][57]) coverage.hit("MATMUL accumulating");
                    end
                    6'h18: if (c.instructions[i][54:53] == 2'd0)  coverage.hit("ACTIVATE to the UB");
                           else if (c.instructions[i][55])        coverage.hit("ACTIVATE requantized to the host");
                           else if (c.instructions[i][54:53] == 2'd1) coverage.hit("ACTIVATE int32 to the host");
                    6'h19: coverage.hit("opcode RD_UB");
                    6'h20: coverage.hit("opcode WAIT");
                    6'h21: coverage.hit("opcode SIGNAL");
                    default: ;
                endcase
            end
        endfunction

        function void write(avalon_access access);
            if (access.write && access.stall_cycles > 0) coverage.hit("write stalled by waitrequest");
            if (access.write || access.address != OUTPUT) return;
            if (empty_read_expected) begin
                if (access.data !== 32'd0) `uvm_error("TPU", $sformatf("%s: an empty OUT read returned %h", case_name, access.data))
                empty_read_expected = 1'b0;
                coverage.hit("reading an empty OUT");
            end else if (expected_out.size() == 0) begin
                `uvm_error("TPU", $sformatf("%s: an OUT word the model didn't produce: %h", case_name, access.data))
            end else begin
                bit [31:0] expected = expected_out.pop_front();
                if (access.data !== expected)
                    `uvm_error("TPU", $sformatf("%s: OUT word %0d = %h, expected %h", case_name, words_checked, access.data, expected))
                words_checked++;
            end
        endfunction

        function void check_phase(uvm_phase phase);
            if (expected_out.size() != 0)
                `uvm_error("TPU", $sformatf("%s: %0d OUT words never read", case_name, expected_out.size()))
            `uvm_info("TPU", $sformatf("%0d cases, %0d OUT words checked", cases_run, words_checked), UVM_MEDIUM)
            coverage.check("tpu_top");
        endfunction
    endclass

    class tpu_env extends uvm_env;
        `uvm_component_utils(tpu_env)
        uvm_sequencer #(avalon_item) sequencer;
        avalon_driver                driver;
        avalon_monitor               monitor;
        tpu_scoreboard               scoreboard;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            tpu_top_vif vif;
            if (!uvm_config_db #(tpu_top_vif)::get(this, "", "tpu_top_vif", vif)) `uvm_fatal("TPU", "no tpu_top_vif in the config db")
            sequencer  = uvm_sequencer #(avalon_item)::type_id::create("sequencer", this);
            driver     = avalon_driver::type_id::create("driver", this);
            monitor    = avalon_monitor::type_id::create("monitor", this);
            scoreboard = tpu_scoreboard::type_id::create("scoreboard", this);
            driver.vif  = vif;
            monitor.vif = vif;
        endfunction

        function void connect_phase(uvm_phase phase);
            driver.seq_item_port.connect(sequencer.seq_item_export);
            monitor.access_port.connect(scoreboard.analysis_export);
        endfunction
    endclass

    // replays every case like a careful host, with random timing:
    // CTRL.RESET, then instruction and data pushes interleaved (data only into free
    // space while instructions remain, so the bus can't deadlock), OUT drained as it
    // fills, then DONE (or the error) awaited and the status and levels checked
    class tpu_case_sequence extends uvm_sequence #(avalon_item);
        `uvm_object_utils(tpu_case_sequence)
        tpu_case_file  case_file;
        tpu_scoreboard scoreboard;
        int unsigned   gap_percent, drain_percent, data_percent;

        function new(string name = "tpu_case_sequence");
            super.new(name);
        endfunction

        task access(bit write, bit [3:0] address, inout bit [31:0] data);
            avalon_item item = avalon_item::type_id::create("item");
            item.write       = write;
            item.address     = address;
            item.data        = data;
            item.idle_before = ($urandom_range(99) < gap_percent) ? $urandom_range(1, 6) : 0;
            start_item(item);
            finish_item(item);
            data = item.data;
        endtask

        task write_register(bit [3:0] address, bit [31:0] value);
            access(1'b1, address, value);
        endtask

        task read_register(bit [3:0] address, output bit [31:0] value);
            bit [31:0] data = '0;
            access(1'b0, address, data);
            value = data;
        endtask

        task drain(output int unsigned drained);
            bit [31:0] levels, word;
            read_register(LEVELS, levels);
            drained = levels[31:21];
            repeat (levels[31:21]) read_register(OUTPUT, word);
        endtask

        task run_case(tpu_case c);
            int unsigned instruction_index = 0, data_index = 0, drained, polls = 0;
            bit [31:0]   status, levels, value;
            gap_percent   = c.full_speed ? 0 : $urandom_range(0, 40);
            drain_percent = c.full_speed ? 0 : $urandom_range(5, 40);
            data_percent  = $urandom_range(20, 80);
            scoreboard.begin_case(c);
            write_register(CONTROL, 32'h7);     // RESET | CLEAR_DONE | CLEAR_PERF
            while (instruction_index < c.instructions.size() || data_index < c.data.size()) begin
                bit instructions_left = instruction_index < c.instructions.size();
                bit push_data = data_index < c.data.size() && (!instructions_left || $urandom_range(99) < data_percent);
                if (push_data && instructions_left) begin
                    read_register(LEVELS, levels);
                    if (levels[20:10] == 0) push_data = 1'b0;
                end
                if (push_data) begin
                    write_register(DATA, c.data[data_index++]);
                end else begin
                    write_register(INSTRUCTION_LOW, c.instructions[instruction_index][31:0]);
                    if (data_index < c.data.size() && $urandom_range(99) < 10) begin
                        // the low half is latched; a data push in between must not disturb it
                        read_register(LEVELS, levels);
                        if (levels[20:10] != 0) begin
                            write_register(DATA, c.data[data_index++]);
                            scoreboard.coverage.hit("data pushed between instruction halves");
                        end
                    end
                    write_register(INSTRUCTION_HIGH, c.instructions[instruction_index][63:32]);
                    instruction_index++;
                end
                if ($urandom_range(99) < drain_percent) begin
                    drain(drained);
                    if (drained != 0) scoreboard.coverage.hit("OUT read while the core runs");
                end
            end
            forever begin
                read_register(STATUS, status);
                if (status[0] || status[1]) break;
                drain(drained);
                if (++polls > 200000) `uvm_fatal("TPU", $sformatf("%s: no DONE or error", c.name))
            end
            do drain(drained); while (drained != 0);
            read_register(STATUS, status);
            if (status[0] !== c.done || status[1] !== (c.error_code != 0) || status[15:8] !== c.error_code
                || (c.done && status[31:16] !== c.tag))
                `uvm_error("TPU", $sformatf("%s: STATUS %h, expected done=%0b tag=%0h error=%0d", c.name, status,
                                            c.done, c.tag, c.error_code))
            if (c.error_code != 0) begin
                read_register(ERROR_SEQUENCE, value);
                if (value !== c.error_sequence)
                    `uvm_error("TPU", $sformatf("%s: ERR_SEQ %0d, expected %0d", c.name, value, c.error_sequence))
            end else begin
                read_register(LEVELS, levels);
                if (levels !== {11'd0, 11'(DATA_DEPTH), 10'(INSTRUCTION_DEPTH)})
                    `uvm_error("TPU", $sformatf("%s: LEVELS %h after the run", c.name, levels))
            end
            if (c.reads_empty_out) begin
                scoreboard.empty_read_expected = 1'b1;
                read_register(OUTPUT, value);
                read_register(STATUS, status);
                if (!status[3]) `uvm_error("TPU", $sformatf("%s: UNDERFLOW not set", c.name))
            end
        endtask

        task body();
            bit [31:0] status;
            do read_register(STATUS, status); while (!status[2]);     // idle once the power-on reset ends
            foreach (case_file.cases[i]) begin
                run_case(case_file.cases[i]);
                `uvm_info("TPU", $sformatf("case %0d %s", i, case_file.cases[i].name), UVM_HIGH)
            end
        endtask
    endclass

    class tpu_top_test extends base_test;
        `uvm_component_utils(tpu_top_test)
        tpu_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            env = tpu_env::type_id::create("env", this);
            uvm_top.set_timeout(2s, 0);     // a hung bus fails instead of stalling make
        endfunction

        task run_phase(uvm_phase phase);
            string            path;
            tpu_case_sequence cases = tpu_case_sequence::type_id::create("cases");
            if (!$value$plusargs("cases=%s", path)) `uvm_fatal("TPU", "pass +cases=<gen_cases.py output>")
            cases.case_file  = new(path);
            cases.scoreboard = env.scoreboard;
            phase.raise_objection(this);
            cases.start(env.sequencer);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
