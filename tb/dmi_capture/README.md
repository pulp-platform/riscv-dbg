# DMI Capture status regression

A pending write must not appear successful at Capture-DR. A failed operation
must return FAILED, including later captures before dmireset. The change covers
both cases. It retains the existing error precedence and reset behavior.
This follows the DMI `op` status and sticky error rules in RISC-V Debug 0.13.2.
Source: [Debug 0.13.2 register definitions](https://github.com/riscv/riscv-debug-spec/blob/4e0bb0f/xml/jtag_registers.xml), section 8.2, `dmi.op` and `dtmcs.dmistat`.
The pending-write case relates to [issue #163](https://github.com/pulp-platform/riscv-dbg/issues/163).
The clock ratio remains within the current README limit: system 5 ns, TCK 20 ns.
A scripted DMI endpoint supplies backpressure and SUCCESS/ERR/BUSY responses.
The real DTM, TAP, CDC and official JTAG driver execute each transaction.
The endpoint is a protocol peer. It does not replace the DTM under test.

Base: `643607e19df3435cfd77cc56143e2637f5900a6e` (master).
Dependencies: common_cells 1.39.0 `9ca8a7655f741e7dd5736669a20a301325194c28`
and tech_cells_generic 0.2.13 `7968dd6e6180df2c644636bc6d2908a49f2190cf`.
These versions satisfy the repository declarations. There is no repository lock file.

The same test input produced these VCS W-2024.09-SP1 results:

| Profile | Cases | Checks | Before errors | After errors |
| --- | ---: | ---: | ---: | ---: |
| transport | 17 | 1858 | 3 | 0 |
| boundary | 18 | 150 | 10 | 0 |

Checks include DMI requests/responses, sticky status, blocked requests,
reset recovery, and Capture one TCK before, at, and after a response boundary.
Both versions reached the single DONE and normal finish, with no assertion errors.
The transport profile observes 54 requests/48 responses, including deliberate
reset cancellation. The boundary profile observes 54 requests/54 responses.
An HDL deadline of 10 ms and wall limit of 60 s apply to each run.
DONE with a nonzero error count is an expected baseline failure, even if simv exits 0.
Treat any control/deadline marker, assertion error, missing DONE, or timeout as failure.

Compile with the existing official dependencies. Set `CC` and `TC` to their checkouts.
From this repository root, in a separate output directory:

```bash
DBG=$PWD
mkdir run-dmi-capture
cd run-dmi-capture
timeout 180 vcs -full64 -sverilog -timescale=1ns/1ps +lint=all \
  "+incdir+$CC/include" \
  "$TC/src/rtl/tc_clk.sv" "$CC/src/cf_math_pkg.sv" "$CC/src/sync.sv" \
  "$CC/src/cdc_reset_ctrlr_pkg.sv" "$CC/src/cdc_4phase.sv" \
  "$CC/src/cdc_reset_ctrlr.sv" "$CC/src/cdc_2phase_clearable.sv" \
  "$DBG/src/dm_pkg.sv" "$DBG/src/dmi_cdc.sv" "$DBG/src/dmi_jtag_tap.sv" \
  "$DBG/tb/jtag_dmi/jtag_dv.sv" "$DBG/tb/jtag_dmi/jtag_test.sv" \
  "$DBG/src/dmi_jtag.sv" "$DBG/tb/dmi_capture/tb_dmi_capture.sv" \
  -top tb_dmi_capture -o simv -l compile.log
mkdir transport boundary
(cd transport; timeout 60 ../simv +E_DEBUG_PROFILE=transport -l run.log)
(cd boundary; timeout 60 ../simv +E_DEBUG_PROFILE=boundary -l run.log)
```

For the original comparison, use only `src/dmi_jtag.sv` from the stated base.
Keep the same test, remaining sources, dependencies and options.
The VCS lint category counts were identical before/after.
Separate full-DTM generic DC `compile -no_map` checks found 416 flip-flops,
zero latches, combinational loops, multiple drivers or final blackboxes in both
versions (3562/3563 total cells). This is a structure check, not technology timing.
The regression does not claim DM CSR/SBA, arbitrary clock ratios, or the separate
DM-internal BUSY policy in issue #202.

AI assistance: OpenAI Codex assisted implementation, test and validation.
