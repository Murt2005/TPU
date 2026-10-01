// shared helpers for the self-checking unit benches, included inside a bench module:
// named tests, checks that report file:line, and a summary whose exit status fails make
int    tb_checks = 0, tb_fails = 0, tb_test_fails = 0, tb_tests = 0;
string tb_test = "";

function automatic void tb_end_test();
    if (tb_test != "")
        $display("[%s] %s", tb_test_fails == 0 ? "PASS" : "FAIL", tb_test);
endfunction

function automatic void tb_begin(string name);
    tb_end_test();
    tb_test       = name;
    tb_test_fails = 0;
    tb_tests++;
endfunction

function automatic void tb_fail(string msg, string file, int line);
    $display("  [FAIL] %s: %s (%s:%0d)", tb_test, msg, file, line);
    tb_fails++;
    tb_test_fails++;
endfunction

task automatic tb_done();
    tb_end_test();
    $display("%0d tests, %0d checks, %0d failed", tb_tests, tb_checks + tb_fails, tb_fails);
    if (tb_fails != 0) $fatal(1, "FAILED");
    $display("PASSED");
    $finish;
endtask

`define TEST(name)           tb_begin(name);
`define CHECK(cond, msg)     if (!(cond)) tb_fail(msg, `__FILE__, `__LINE__); else tb_checks++;
`define CHECK_EQ(got, want, msg) \
    if ((got) !== (want)) tb_fail($sformatf("%s: got %0d (0x%0h), want %0d (0x%0h)", msg, got, got, want, want), `__FILE__, `__LINE__); \
    else tb_checks++;
