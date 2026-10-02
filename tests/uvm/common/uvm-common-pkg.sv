`include "uvm_macros.svh"

// shared pieces for every UVM environment: hand-counted coverage bins (Verilator
// doesn't collect covergroups) and a base test that prints one pass/fail line
package uvm_common_pkg;
    import uvm_pkg::*;

    // named hit counters; check() fails the test for any bin never hit
    class coverage_bins extends uvm_object;
        `uvm_object_utils(coverage_bins)
        int unsigned hits [string];
        string       order [$];

        function new(string name = "coverage_bins");
            super.new(name);
        endfunction

        function void add(string bin_name);
            hits[bin_name] = 0;
            order.push_back(bin_name);
        endfunction

        function void hit(string bin_name);
            if (!hits.exists(bin_name)) `uvm_fatal("COVERAGE", $sformatf("unknown bin '%s'", bin_name))
            hits[bin_name]++;
        endfunction

        function void check(string owner);
            foreach (order[i]) begin
                if (hits[order[i]] == 0)
                    `uvm_error("COVERAGE", $sformatf("%s: bin '%s' never hit", owner, order[i]))
                else
                    `uvm_info("COVERAGE", $sformatf("%s: %-28s %0d", owner, order[i], hits[order[i]]), UVM_MEDIUM)
            end
        endfunction
    endclass

    class base_test extends uvm_test;
        `uvm_component_utils(base_test)

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void report_phase(uvm_phase phase);
            uvm_report_server server = uvm_report_server::get_server();
            int failures = server.get_severity_count(UVM_ERROR) + server.get_severity_count(UVM_FATAL);
            `uvm_info("RESULT", $sformatf("%s %s", get_type_name(), failures == 0 ? "PASSED" : "FAILED"), UVM_NONE)
        endfunction
    endclass
endpackage
