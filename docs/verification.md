# Verification

What checks the core, what each check can and can't see, and what to run
before trusting a change. The reference for everything is
`host/tpu/isa_model.py`, which executes a program in order with the core's
exact arithmetic. The RTL and the board must match it **word for word**, and
the model is itself checked against independent references.

## The ladder

| Tier | Command | Sees | Can't see |
|---|---|---|---|
| unit | `make test` | each datapath module on its own: 9 self-checking benches | how the engines sequence them |
| UVM | `make uvm` | blocks under random stimulus, checked cycle by cycle against a model, with coverage bins (so far: `fifo`) | how the engines sequence them |
| model | `make model-test` | the model against `tpu.golden`, `hw_layer` and host rounding | anything about the RTL |
| RTL vs model | `make sim-test` | the whole core through its real bridge registers, at N = 8 and N = 4 | synthesis, timing, the board |
| lint | `make lint` | width, unused and latch issues at both sizes and in the self-test top | behaviour |
| self-test, sim | `make selftest-sim` | the exact transcript the FPGA will replay, with its perf captures | the netlist |
| self-test, board | the self-test bitstream | **the netlist**, with no host at all: the tests and the tile rate, checked on chip | the HPS path |
| suite, board | `tests/isa/test_isa_rtl.py serial:<port>` | the GHRD build from the ARM: every functional test | exact cycle counts (the link's latency is in them) |
| application, board | `mnist_tpu bench` | 10,000 MNIST images end to end, preprocessing included | — |

`make check` runs the first six. The last three need the board
([`de1soc.md`](de1soc.md)).

## Unit benches (`make test`)

Plain SystemVerilog in `tests/unit/`, built with `verilator --binary` against
the core's files. `check.svh` gives named tests, `CHECK`/`CHECK_EQ` that
report file and line, and a summary whose exit status fails `make`.
`make unit-<name>` runs one.

| Bench | Checks |
|---|---|
| `pe` | the flip uses the loaded weight; the next weight loads under the current one; a write in the flip's own cycle belongs to the next tile; int8 extremes; an invalid activation neither computes nor flips |
| `mmu` | three back-to-back tiles on `matmul_engine`'s overlap schedule at m = 1, N and 2N+1, every column against a plain matmul |
| `weight_fifo` | ping-pong order, the same-cycle refill, wrap-around |
| `accumulator` | column-skewed rows re-aligned; overwrite vs accumulate; 32-bit wrap; the same row N rows later |
| `activation` | ReLU/identity; the requantizer against 21,240 vectors from `tpu.golden.requant` (`gen_requant.py`) over 67 quant words |
| `bias`, `unified_buffer`, `fifo`, `systolic_data_setup` | add and pass-through; port priorities; show-ahead order and full/empty; per-lane delay |

Each bench has been mutation-checked: one real bug injected per module (the
flip ignored, the column skew off, no same-cycle refill, always overwrite,
rounding removed, read priority lost, …), and each was caught. SVUnit was
considered, but its Verilator support is tied to 5.024; it faults on 5.032
and fails on 5.052.

## UVM (`make uvm`)

The UVM environments in `tests/uvm/` are replacing the unit benches, one block
at a time. They run on Verilator 5.052 with CHIPS Alliance's patched UVM
2020-3.2 (a pinned submodule, built with `UVM_NO_DPI`). Every block test is
one binary, `uvm_blocks_top`, and `+UVM_TESTNAME` picks the test; a test
passes when it prints `PASSED` with no UVM errors.

Verilator doesn't collect covergroups, so each scoreboard counts named bins
by hand (`coverage_bins` in `common/uvm-common-pkg.sv`), and any bin never hit
fails the test.

| Test | Checks |
|---|---|
| `fifo_random_test` | fill-, drain- and balanced phases of random pushes and pops against a queue model every cycle: show-ahead data, full/empty, dropped writes when full, ignored reads when empty; 11 bins, including wrap-around and simultaneous read and write when full |

`fifo_random_test` was mutation-checked: writes accepted when full, `full`
one entry early, a read pointer that never advances, and a simultaneous read
and write that counts up each fail it.

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
| a datapath module | `make unit-<name>`, then `make check` |
| an engine, the dispatcher, the ISA, `host/tpu/` | `make check` |
| anything that could move a cycle | `make check`, and compare `make selftest-sim ST_SLOTS=21` with the previous captures |
| synthesis, memory inference, timing | `make check` + both Quartus builds (DSPs, RAM blocks, slack) + the self-test **PASS** on the board + the suite from the ARM |
| ARM programs (`boards/de1soc/sw`, `software/mnist/de1soc`) | `make -C software/mnist/de1soc sim-bench`, then on the board |

**Board results (2026-10-01):**
- self-test PASS, with the perf captures equal to Verilator;
- all 30 checks of the suite from the ARM;
- MNIST: 10,000/10,000 equal to the model, preprocessing byte-identical.

Gates are local `make` targets. There's no hosted CI, by choice.
