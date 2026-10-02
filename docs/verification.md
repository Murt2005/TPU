# Verification

What checks the core, what each check can and can't see, and what to run
before trusting a change. The reference for everything is
`host/tpu/isa_model.py`, which executes a program in order with the core's
exact arithmetic. The RTL and the board must match it **word for word**, and
the model is itself checked against independent references.

## The ladder

| Tier | Command | Sees | Can't see |
|---|---|---|---|
| UVM blocks | `make test` | each datapath block under random stimulus, checked every cycle against a model, with coverage bins | how the engines sequence them |
| UVM `tpu_top` | `make test` | the whole core through its Avalon slave at N = 8 and 4, with random bus timing, every OUT word, status and level against the model | cycle counts and perf counters (`sim-test` and the self-test check those) |
| model | `make model-test` | the model against `tpu.golden`, `hw_layer` and host rounding | anything about the RTL |
| RTL vs model | `make sim-test` | the whole core through its real bridge registers, at N = 8 and N = 4 | synthesis, timing, the board |
| lint | `make lint` | width, unused and latch issues at both sizes and in the self-test top | behaviour |
| self-test, sim | `make selftest-sim` | the exact transcript the FPGA will replay, with its perf captures | the netlist |
| self-test, board | the self-test bitstream | **the netlist**, with no host at all: the tests and the tile rate, checked on chip | the HPS path |
| suite, board | `tests/isa/test_isa_rtl.py serial:<port>` | the GHRD build from the ARM: every functional test | exact cycle counts (the link's latency is in them) |
| application, board | `mnist_tpu bench` | 10,000 MNIST images end to end, preprocessing included | — |

`make check` runs the first six. The last three need the board
([`de1soc.md`](de1soc.md)).

## UVM block tests (`make test`)

`tests/uvm/` holds one UVM environment per datapath block: an interface and a
package with the item, sequence, driver, monitor, scoreboard, env and test. They
run on Verilator 5.052 with CHIPS Alliance's patched UVM 2020-3.2 (a pinned
submodule, built with `UVM_NO_DPI`). All nine tests share one binary,
`uvm_blocks_top`, which instantiates every block on its own interface;
`+UVM_TESTNAME` picks the test, and `make uvm-<test>` runs one. A test passes
when it prints `PASSED` with no UVM errors.

Each scoreboard is a model of the block's contract, not of its implementation,
and checks every cycle (or every row, tile or job). Verilator doesn't collect
covergroups, so each scoreboard counts named bins by hand (`coverage_bins` in
`common/uvm-common-pkg.sv`), and a bin never hit fails the test.

| Test | Stimulus | Checks |
|---|---|---|
| `fifo_random_test` | fill-, drain- and balanced phases of random pushes and pops | a queue model every cycle: show-ahead data, full/empty, dropped writes when full, ignored reads when empty, wrap-around |
| `pe_random_test` | 3,000 cycles that keep the scheduler's rules (one weight write per flip, none without one) | a two-register weight model: the flip uses the loaded weight, a write in the flip's cycle is the next tile's, an invalid activation neither computes nor flips, 32-bit wrap, int8 extremes |
| `systolic_data_setup_random_test` | bursts, sparse stretches and gaps | lane *i* shows the row from *i* cycles earlier, data and valid |
| `weight_fifo_random_test` | tiles filled the weight engine's way (a row only when `fill_ready_out`, advance on the last row) with random stalls and takes | every taken tile is the next one filled; `fill_ready_out` and `tile_full_out` follow the two-slot rule, including the same-cycle refill |
| `accumulator_random_test` | 1,500 skewed rows (column *c* of a row *c* cycles after its tag), overwrite or accumulate, into a 16-row ACC, plus a random read every cycle | an ACC model: rows written in order, 32-bit wrap, the read blocked exactly for each accumulated row, every unblocked read (including the row being written) |
| `bias_random_test` | rows and bias rows with 32-bit extremes | `row_in + bias`, wrapping, or `row_in` when disabled |
| `activation_test` | random rows, then the requantizer over 21,240 vectors from `tpu.golden.requant` (`gen_requant.py`), 67 quant words | ReLU/identity every cycle; every requantized lane against the host reference |
| `unified_buffer_random_test` | both write ports and both read sources at random over 16 entries | activate write beats load write, matmul read beats activate read, a read during a write returns the old entry |
| `mmu_random_test` | 60 jobs of 1–4 back-to-back tiles on `matmul_engine`'s overlap schedule, m from 1 to 3N | every output column against a plain matrix multiply, in order, with nothing missing or extra |

Every test was mutation-checked by injecting one real bug per block into a
copy of the RTL: the flip ignored, the column skew off, no same-cycle refill,
always overwrite, the bias enable ignored, rounding removed, the read priority
lost, the weight rows reversed, and, for the FIFO, writes accepted when full,
`full` one entry early, a stuck read pointer and a wrong count on a
simultaneous read and write. Each test failed on its bug.

Two Verilator behaviours to know when writing stimulus. A `dist` is a hard
pick: combined with another constraint on the same variable (an inline
`with`, an implication) it makes `randomize()` fail rather than solving both,
so the PE's control bits are chosen in its sequence and the accumulator's
sweep turns its rate constraints off. And a `//` comment that starts with
the word "Verilator" is read as a pragma.

## UVM `tpu_top` test (`make test`, or `make uvm-top [N=4]`)

`tests/uvm/top/gen_cases.py` turns the core's tests into cases: every
instruction, data word, expected OUT word and final status comes from the
reference model, which keeps its memories across cases as the core does. It
reuses the RTL suite's builders, so the cases are: the UB round trip; all 13
decode errors and recovery with `CTRL.RESET`; 40 random single layers, a third
with K split across two `MATMUL`s; the requantizer over three quant tables;
MNIST load and inference at m = 8 and 1, layers chained through the UB (N = 8
only); 40 random concurrent programs with `WAIT`s from `isa_waits`; data
backpressure; and reading an empty OUT. 107 cases and 8,122 OUT words at N = 8,
103 and 4,313 at N = 4.

The sequence replays each case like a careful host with random timing:
instruction and data pushes interleaved (data only into free space while
instructions remain, read from LEVELS, so the bus can't deadlock), sometimes a
data push between an instruction's two halves, idle gaps, OUT drained while the
core runs. One case holds LD behind a `WAIT` on a 3,200-cycle `MATMUL` while
1,100 data words arrive at full speed, so the host's writes stall on
`waitrequest`. The monitor checks the Avalon rules (`waitrequest` only on a
write to a full FIFO, never a read and a write together); the scoreboard checks
every OUT word in order, and the sequence checks each case's STATUS, `ERR_SEQ`
and drained LEVELS. Coverage bins: every opcode and `MATMUL`/`ACTIVATE`
variant, every error code, a stalled write, a data push between instruction
halves, OUT read mid-run, the empty-OUT read.

Mutation-checked with five control-path bugs, each failing the test: `WAIT`
never waits, no `waitrequest` (writes into a full FIFO lost), `MATMUL`'s
accumulate flag ignored, `ERR_SEQ` off by one, UNDERFLOW never set.

`make rtl-test` stays: it adds the full requantizer sweep, the perf counters and
the tile rate (cycle-exact over the Verilator link), and it's the same suite the
board runs.

SVUnit was considered before UVM; its Verilator support is tied to 5.024, and
it faults on 5.032 and fails on 5.052.

## The model and the RTL (`make sim-test`)

`make model-test` checks the model against independent references:
- random layers against `tpu.golden`;
- MNIST layer 1 against `hw_layer` at 32 bits;
- the requantizer against host rounding, with exactly one difference, at the
  tie v = 10,450;
- the compiled MNIST program is hazard-free with every `WAIT` necessary.

Then `make rtl-test` (run at N = 8 and 4 by `sim-test`) drives `tpu_top`
through `tests/verilator/tb-isa.cpp` and requires every output word to equal
the model's:
- every decode error, `CTRL.RESET`, `UNDERFLOW`, `IDLE`;
- 40 random single layers, including K split across `MATMUL`s;
- MNIST layer 1, and the two-layer program chained through the UB, on 20
  images at m = 1 and 8;
- the requantizer over every int16 input, the edges and random int32
  (`ISA_RQ_RANDOM`) for three quant tables;
- 40 random concurrent programs (`ISA_RANDOM_PROGS`; 400 per size has been
  run).

The concurrent programs are random but legal, with `WAIT`s inserted by
`host/tpu/isa_waits.py`. Run without their `WAIT`s, 39 of 40 diverge, which
shows the engines really overlap and the `WAIT`s carry the ordering.

There's also a **tile rate** check: T extra tiles must cost exactly
`T · max(m, N)` cycles with no extra WSTALL. It runs only on a cycle-exact
link: in Verilator the clock advances only on register accesses. Over the
board's serial link it checks beats and WSTALL instead, and the self-test
checks the rate on chip.

`pe.sv`'s simulation-only invariants (`$fatal` on a weight overwritten before
its flip, or a flip with none pending) are live in every simulation.

## The self-test (`make selftest-sim`, then the board)

`boards/de1soc/fpga/selftest/gen_selftest.py` turns the tests into a register
transcript, with every expected word from the model, not the RTL. `replay.sv`
plays it into `tpu_top` on the FPGA and checks every read; the result shows on
the LEDs and HEX displays. The ROM also captures the perf counters and bounds
the tile rate on chip.

The replay is cycle-exact, so each capture, read off the displays with SW9 and
SW4–0, must equal `make selftest-sim ST_SLOTS=21`. Two sanity checks: a wrong
expected word fails with the right test number and a count of 1, and an empty
ROM fails instead of hanging.

The captures also make refactors checkable. When the core moved from
`rtl/isa/` into `rtl/core/`, all 21 captures and the total cycle counts
(51,062 at N = 8, 19,588 at N = 4) came out identical, in Verilator and on the
board.

## From the ARM

On the GHRD build, `IsaSerialLink` logs into the board's console, starts
`isa_mmio` (an ARM `/dev/mem` register server), and drives the real core with
the same Python suite. `mnist_tpu bench` runs MNIST end to end. It checks every
prediction against the model's and the host's, and the ARM's quantized input
against the host's. `make -C software/mnist/de1soc sim-bench` runs the same C
against Verilator first.

## Before trusting a change

| Changed | Run |
|---|---|
| a datapath module | `make uvm-<test>`, then `make check` |
| an engine, the dispatcher, the ISA, `host/tpu/` | `make check` |
| anything that could move a cycle | `make check`, and compare `make selftest-sim ST_SLOTS=21` with the previous captures |
| synthesis, memory inference, timing | `make check` + both Quartus builds (DSPs, RAM blocks, slack) + the self-test **PASS** on the board + the suite from the ARM |
| ARM programs (`boards/de1soc/sw`, `software/mnist/de1soc`) | `make -C software/mnist/de1soc sim-bench`, then on the board |

**Board results (2026-10-01):**
- self-test PASS, with the perf captures equal to Verilator;
- all 30 checks of the suite from the ARM;
- MNIST: 10,000/10,000 equal to the model, preprocessing byte-identical.
- after the renames, the `rtl/` reorganization and the move to Verilator 5.052:
  self-test PASS again, with the perf captures equal to Verilator.

Gates are local `make` targets. There's no hosted CI, by choice.
