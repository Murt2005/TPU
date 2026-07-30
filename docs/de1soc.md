# DE1-SoC (Cyclone V) target

**Status: in progress.** The RTL and host transport are implemented and
simulation-tested; the Quartus build and on-board bring-up are not yet done.
Nothing on this page has run on a DE1-SoC.

## 1. What's different

Same board-neutral `tpu_core` as pico2-ice. The host is the board's own **ARM
HPS** instead of a serial link: the HPS reaches `hps_bridge` (an Avalon-MM
slave) over the **lightweight HPS→FPGA bridge** (`h2f_lw`, base
`0xFF200000`), and `tpu_host.py --link hps` — running *on the board's Linux* —
drives it through `/dev/mem`.

Your Mac only ever needs `ssh`/`scp`. Since the host driver runs on the board,
nothing board-facing happens locally at all.

| Thing | Value |
|---|---|
| Device | `5CSEMA5F31C6N` (Cyclone V SoC; ~85K LEs, ~87 DSP blocks, 397 M10K) |
| Fabric clock | `CLOCK_50` = `PIN_AF14`, 50 MHz |
| Reset | `KEY[0]` = `PIN_AA14`, active-low → `reset_n` |
| Host bridge | `h2f_lw`, base `0xFF200000`; `hps_bridge` at component offset `0x0` |

Build with **`USE_MAC16_PAIR=0`** — the `SB_MAC16` DSP-pair path is iCE40-only.
Cyclone V infers its own DSPs from `pe.sv`'s multiply.

## 2. State of play

| Piece | Status |
|---|---|
| `rtl/tpu_top_hps.sv`, `rtl/hps_bridge.sv` | Implemented, lint-clean, `make test-hps_bridge` passes |
| `tpu_host.py --link hps` (`MmioLink`) | Implemented |
| 8×8 scale-up shape | Sim-proven (`make verilate-test`, 64 PEs on generic-fabric multiply) — demonstrates the datapath parameterizes well past the iCE40's 8-DSP ceiling |
| `fpga/de1soc/` Quartus project | Scaffolded: `Makefile`, `.sdc`, `.qsf` skeleton |
| Qsys/GHRD integration | Not done |
| Cloud build infrastructure | Planned, not built (§4) |
| On-board bring-up | Not started |

## 3. Build and deploy (from `fpga/de1soc/README.md`)

Quartus Prime has no macOS build, so the `.rbf` is produced on x86-64 Linux.
The cleanest path reuses Terasic's **DE1-SoC GHRD**, which already
instantiates the HPS, exports `h2f_lw`, and has all the HPS/DDR3 pin
assignments — you add one component.

1. Open the GHRD Quartus project for your Quartus version.
2. Add `../../rtl/*.sv` (board-neutral) plus this directory's
   `tpu_top_hps.sdc`. The relevant module is `tpu_top_hps`.
3. In Platform Designer, add `tpu_top_hps` as a component:
   - Avalon-MM slave → the HPS `h2f_lw` master.
   - **Page-aligned** base address (offset `0x0` → `0xFF200000`, `MmioLink`'s
     default; any page-aligned base works with a matching `offset`).
   - Slave settings: **fixed read latency 1, no waitrequest** — matches
     `hps_bridge.sv`.
   - Clock `clk` from the same fabric clock `h2f_lw` uses. **`hps_bridge` does
     no CDC** — single clock domain only.
   - `reset_n` → system reset. Regenerate HDL.
4. `make` in `fpga/de1soc/` (wraps `quartus_map`/`fit`/`asm` + `.sof`→`.rbf`)
   with `PROJECT`/`REVISION` set to match the GHRD project. Confirm timing
   closes at 50 MHz.

Then:

```sh
scp output_files/<project>.rbf root@<board>:/root/tpu.rbf
# on the board: configure via u-boot `fpga load` from the SD FAT partition,
# or at runtime through the FPGA Manager (device depends on your kernel/overlay)
scp ../../tpu_host.py ../../requirements.txt root@<board>:/root/
# on the board (needs numpy + root for /dev/mem):
python3 tpu_host.py --port /dev/mem --link hps --rows 2 --cols 2 --selftest
```

`tests/hw_regression.py` and `mnist/infer.py` take the same `--link hps
--port /dev/mem` and also run on the board.

## 4. Cloud Quartus build (planned)

Rather than keeping a Linux box around, the intent is to build on **ephemeral
EC2**: a durable AWS CDK stack plus a self-terminating build instance.

```
  Mac                          AWS
  ───                          ───
  cdk deploy  ──────────────►  durable stack
                                 • S3 bucket (source in, .rbf out)
                                 • IAM instance profile (S3 + SSM)
                                 • security group — SSM only, no SSH
                                 • references a pre-baked Quartus AMI

  ./build.sh  ──────────────►  ephemeral EC2 from that AMI
     │                           user-data: pull source → quartus compile
     │                                      → .rbf → S3 → terminate
     ▼
  aws s3 cp  ◄──────────────  s3://…/out/tpu.rbf
```

The key idea is **baking Quartus into an AMI once**. After that every build
starts in ~60 s instead of a ~40-minute install, with no Intel-account login
on the critical path. The one-time Qsys/GHRD integration is baked in too, so
per-build instances stay fully headless. Spot instances cut the cost further.

## 5. Remaining steps

1. **Qsys/GHRD integration** — §3 step 3, done once and baked into the AMI.
2. **Cloud build infra** — CDK stack + launch script (§4).
3. **On-board bring-up** — `scp` the `.rbf`, let the HPS configure the FPGA,
   then run `tests/hw_regression.py --link hps --port /dev/mem` *on the board*
   to validate the bridge against the same vectors sim and pico2-ice use.
4. **Scale up** — raise `ARRAY_ROWS`/`NUM_COLS` to the largest shape that
   closes timing at 50 MHz. The 8×8 sim shape is the proof that the RTL is
   ready for it; the Cyclone V's ~87 DSPs and ~85K LEs leave far more room
   than the UP5K did.

See [`backlog.md`](backlog.md) for how this sits against other open work.
