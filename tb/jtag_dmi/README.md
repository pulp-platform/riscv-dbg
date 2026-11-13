# JTAG DMI regression

`tb_jtag_dmi` runs directed Capture tests, then the existing 2000 random DMI
transactions. Both phases use the same DTM, TAP, CDC and JTAG driver. A scripted
DMI endpoint controls backpressure and response status during the directed
phase. The existing random endpoint starts after that phase drains and resets.
The system period is 10 ns and the TCK period is 50 ns.

Run the test through the existing CI entry:

```sh
timeout 180 make -C ci jtag-dmi
```

The default mode is `all`. The same executable supports separate comparisons:

```sh
timeout 60 build/jtag-verilator/obj_dir/Vtb_jtag_dmi +JTAG_DMI_TEST=directed
timeout 60 build/jtag-verilator/obj_dir/Vtb_jtag_dmi +JTAG_DMI_TEST=random
timeout 60 build/jtag-verilator/obj_dir/Vtb_jtag_dmi +verilator+seed+1
timeout 60 build/jtag-verilator/obj_dir/Vtb_jtag_dmi +verilator+seed+2
```

For VCS, set `CC` and `TC` to the fixed dependency checkouts listed below.
Compile from a separate output directory:

```sh
DBG=$PWD
mkdir -p build/jtag-vcs
cd build/jtag-vcs
timeout 180 vcs -full64 -sverilog -timescale=1ns/1ps +lint=all \
  "+incdir+$CC/include" \
  "$TC/src/rtl/tc_clk.sv" "$CC/src/cf_math_pkg.sv" "$CC/src/sync.sv" \
  "$CC/src/cdc_reset_ctrlr_pkg.sv" "$CC/src/cdc_4phase.sv" \
  "$CC/src/cdc_reset_ctrlr.sv" "$CC/src/cdc_2phase_clearable.sv" \
  "$DBG/src/dm_pkg.sv" "$DBG/src/dmi_intf.sv" "$DBG/src/dmi_test.sv" \
  "$DBG/src/dmi_cdc.sv" "$DBG/src/dmi_jtag_tap.sv" \
  "$DBG/tb/jtag_dmi/jtag_dv.sv" "$DBG/tb/jtag_dmi/jtag_test.sv" \
  "$DBG/src/dmi_jtag.sv" "$DBG/tb/jtag_dmi/tb_jtag_dmi.sv" \
  -top tb_jtag_dmi -o simv -l compile.log
timeout 60 ./simv +JTAG_DMI_TEST=directed -l directed.log
```

## Driver status checks

A DMI scan captures the preceding operation's status before it updates the
request. `write_dmi_status` checks the request scan, waits, then sends a NOP to
check completion. It returns a non-success status without clearing it or
repeating a write. The two-argument `write_dmi` uses this method and fails on
any non-success status. `read_dmi` also checks the request scan and returns
read data only on SUCCESS.

The default delay remains ten TCK cycles. It covers this test's bounded random
endpoint. A longer operation can use the status method with a larger delay.
The driver reports BUSY when the delay is insufficient. It does not retry a
write that might already have taken effect. Directed tests complete the old
transaction before clearing sticky status and checking recovery.

This follows the DMI `op` and DTMCS `dmistat` rules in
[Debug 0.13.2](https://github.com/riscv/riscv-debug-spec/blob/4e0bb0f/xml/jtag_registers.xml).

## Directed coverage

The test retains the former standalone test's 17 transport and 18 boundary
cases. Six additional cases check the shared driver:

- Successful writes and read data.
- FAILED and BUSY completion status, and blocked write/read submissions.
- A request scanned while an earlier write is pending, without repeating it.
- A delayed response with a longer wait, and BUSY with an early completion scan.

Transport cases check request backpressure, response delay, status persistence,
blocked requests, reset cancellation, and recovery. Boundary cases place the
DTM's response consumption one TCK before, at, and after Capture. A passive
check verifies each placement. Expected status follows the current DTM's
existing precedence: a simultaneous failed response takes precedence over BUSY.
The test does not change that precedence or the RTL reset behavior.

Request, response and data checks remain active. Each directed case has a 1 ms
HDL deadline, and the complete test has a 50 ms HDL deadline. Any check error,
assertion error, timeout, missing PASS, or abnormal termination is a failure.
Deliberate reset cancellation accounts for the transport phase's 54 requests
and 48 responses. Boundary counts are 54/54, and driver counts are 15/15.

## Local validation

Base RTL: `643607e19df3435cfd77cc56143e2637f5900a6e`.
The same integrated test reports 15 check errors with that RTL and zero with
the Capture fix. It verifies all 18 response/Capture placements in both runs.
The original RTL also completes the 2000-transaction random-only control.

| Tool and input | Result |
| --- | --- |
| Verilator 5.050, default seed | 41 directed cases / 2497 checks, 2000 random transactions |
| Verilator 5.050, seeds 1 and 2 | Same counts in each run |
| VCS W-2024.09-SP1, directed | 41 cases / 2497 checks, no check or assertion errors |

All candidate runs finish normally. Repository Verible and license checks pass.
Verilator emits the same three dependency diagnostics as the earlier random
regression: one width diagnostic and two UNOPTFLAT diagnostics in common_cells.
VCS emits lint diagnostics, including constant-width assignments and assertion
style notices. These are not reported as zero lint. The official Verilator
entry retains its existing `COMMON_CELLS_ASSERTS_OFF` define. This revision
adds no assertion suppression. The testbench checks remain active.

Verilator used Bender 0.32.1, Z3 4.8.12, and these fixed revisions:

- common_cells 1.40.0 `1281545696eb3fcba50ec5b4275993476a3c710e`
- common_verification 0.2.5 `fb1885f48ea46164a10568aeff51884389f67ae3`
- tech_cells_generic 0.2.14 `3a3de73632a06826b1bd9c65a0a2e92b32016845`

VCS used the earlier directed-test dependency revisions: common_cells 1.39.0
`9ca8a7655f741e7dd5736669a20a301325194c28` and tech_cells_generic 0.2.13
`7968dd6e6180df2c644636bc6d2908a49f2190cf`.

For a before/after comparison, replace only `src/dmi_jtag.sv` with the base
version. Keep the integrated test, other sources, dependencies and options.
The directed failure returns a nonzero exit code. Use `+JTAG_DMI_TEST=random`
to run the random-only control on that RTL.

The original CI failure remains reproducible with the old test and Capture
fix: the scoreboard expects address `0x31` but later receives `0x5c` after an
ignored request. The retained failure log belongs to that earlier input.
The integrated test adds explicit status checks instead of relying on a delay
alone. Original RTL and test history remain in the PR commits.

These checks cover DMI transport and the test driver. They do not cover full
DM CSR/SBA or OpenOCD compliance. Production RTL is unchanged by this test
revision. The original structural checks retain their original scope.

The original testbench keeps its SHL-0.51 notice. Directed tests retain the
Apache-2.0 notice from the former `tb/dmi_capture` source.

AI assistance: OpenAI Codex assisted implementation, testing and validation.
