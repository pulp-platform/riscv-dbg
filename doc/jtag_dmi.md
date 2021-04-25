# JTAG Debug Module Interface

The RISC-V specification does not mandate a specific transport mode for the
debug module. While theoratially debug could be facilitate over any
memory-mapped protocol the debug specification standardizes the access via a
IEEE 1149.1 JTAG TAP (Test Access Port) - see [debug spec 0.13 chapter
6](https://riscv.org/wp-content/uploads/2019/03/riscv-debug-release.pdf).

The JTAG DMI takes care of translating JTAG signals into the custom DMI protocol
on the debug module's
[interface](https://github.com/pulp-platform/riscv-dbg/blob/master/doc/debug-system.md#the-debug-module-interface-dmi).

The JTAG DMI TAP contains four registers (so called instruction registers), by
default the IR register is 5 bits long, but the implementation is parameterized.

- `BYPASS`: TAP is in BYPASS mode.
- `IDCODE`: Default after reset. Vendor specific ID. The LSB must be `1`, the
  exact value can be set during implementation via a parameter:
  ```systemverilog
  module dmi_jtag_tap #(
  parameter int unsigned IrLength = 5,
  // JTAG IDCODE Value
  parameter logic [31:0] IdcodeValue = 32'h00000001
  // xxxx             version
  // xxxxxxxxxxxxxxxx part number
  // xxxxxxxxxxx      manufacturer id
  // 1                required by standard
  ) (
  ```
- `DTMCSR`: RISC-V specific control and status register of the JTAG DMI.
  Currently `dmihardreset` is not implemented.
- `DMIACCESS`: Access the debug module's register.
    - `abits+33:34`: Address
    - `33:2`: Data
    - `1:0`: Operation (0 = NOP, 1 = Read from address, 2 = Write data to
      address)

The implementation is split between:

- `dmi_jtag_tap.sv` which contains the JTAG TAP logic. This implementation can
  generally be used for any implementation target. Any IEEE 1149.1 compliant
  device can be attached.
- `dmi_jtag.sv` which contains the TAP agnostic logic, `IDCODE`, `DTMCSR`, and
  `DMIACCESS` registers.

## Xilinx Implementation

For Xilinx FPGA implementation which do not have a dedicated user JTAG pins
exposed, we provide an alternative implementation using `BSCANE2` primitives.
Those primitives hook into the existing FPGA scan chain (normally used to
program bitstreams or debug Arm cores) and provide instruction registers which
are user programmable. The implementation uses three of those user registers to
make the `IDCODE`, `DTMCSR`, and `DMIACCESS` registers accessible.

- `IDCODE` is mapped to the FPGA ID Code register
- `DTMCSR` is mapped to user IR 3
- `DMIACCESS` is mapped to user IR 4

OpenOCD can remap the registers using the config script.

```
set _CHIPNAME riscv
jtag newtap $_CHIPNAME cpu -irlen 6 -expected-id 0x13631093
set _TARGETNAME $_CHIPNAME.cpu
target create $_TARGETNAME riscv -chain-position $_TARGETNAME -rtos riscv

riscv set_ir idcode 0x09
riscv set_ir dtmcs 0x22
riscv set_ir dmi 0x23
```

### FPGA IR Lengths

The IR length is different between FPGA families. Here is a non exhaustive list should be up-to-date (April 2021):


| Device                                                                                                                                                            | IR Length | `IDCODE`   | `DTMCS`    | `DMI`      |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---------- | ---------- | ---------- |
| `xcku3p`, `xcku9p`, `xcku11p`, `xcku13eg`, `xcku15p`, `xcku5p`, `xcvu3p`, `ku025`, `ku035`, `ku040`, `ku060`, `ku095`, `vu065`, `vu080`, `vu095`                  | 6         | `0x9`      | `0x22`     | `0x23`     |
| `7a15t`, `7a25t`, `7s15`, `7s100, `, `7a35t`, `7a50t`, `7a75t`, `7a100t`, `7a200t`, `7k70t`, `7k160t`, `7k325t`, `7k355t`, `7k410t`, `7k420t`, `7k480t`, `7v585t` | 6         | `0x9`      | `0x22`     | `0x23`     |
| `7vx330t`, `7vx415t`, `7vx485t`, `7vx550t`, `7vx690t`, `7vx980t`, `7z010`, `7z015`, `7z020`, `7z030`, `7z035`, `7z045`, `7z007s`, `7z012s`, `7z014s`, `7z100`     | 6         | `0x9`      | `0x22`     | `0x23`     |
| `xczu9eg`, `xcvu5p`, `xcvu7p`, `ku085`, `ku115`, `vu125`                                                                                                          | 12        | `0x249`    | `0x8a4`    | `0x8e4`    |
| `xczu3eg`, `xczu4eg`, `xczu5eg`, `xczu7eg`, `xczu2cg`, `xczu3cg`, `xczu4cg`, `xczu5cg`, `xczu6cg`, `xczu7cg`, `xczu9cg`, `xczu5ev`, `xczu11eg`                    | 16        | `0x2492`   | `0x8a49`   | `0x8e49`   |
| `xczu15eg`, `xczu19eg`, `xczu7ev`, `xczu2eg`, `xczu4ev`, `xczu6eg`, `xczu17eg`                                                                                    | 16        | `0x2492`   | `0x8a49`   | `0x8e49`   |
| `7vh580t`                                                                                                                                                         | 22        | `0x92492`  | `0x229249` | `0x239249` |
| `xcvu13p`, `7v2000t`, `7vx1140t`, `xcvu9p`, `xcvu11p`, `vu160`, `vu190`, `vu440`                                                                                  | 24        | `0x249249` | `0x8a4924` | `0x8e4924` |
| `7vh870t`                                                                                                                                                         | 38        | ?          | ?          | ?          |

FPGA ID are as follows:

| Part Nr.   | FPGA ID Code   |     | Part Nr.   | FPGA ID Code   |
| ---------- | -------------- | --- | ---------- | -------------- |
| `7a15t`    | `32'h0362E093` |     | `ku095`    | `32'h03844093` |
| `7a25t`    | `32'h037C2093` |     | `ku115`    | `32'h0390D093` |
| `7a35t`    | `32'h0362D093` |     | `vu065`    | `32'h03939093` |
| `7a50t`    | `32'h0362C093` |     | `vu080`    | `32'h03843093` |
| `7a75t`    | `32'h03632093` |     | `vu095`    | `32'h03842093` |
| `7a100t`   | `32'h03631093` |     | `vu125`    | `32'h0392D093` |
| `7a200t`   | `32'h03636093` |     | `vu160`    | `32'h03933093` |
| `7k70t`    | `32'h03647093` |     | `vu190`    | `32'h03931093` |
| `7k160t`   | `32'h0364C093` |     | `vu440`    | `32'h0396D093` |
| `7k325t`   | `32'h03651093` |     | `xcku3p`   | `32'h04A46093` |
| `7k355t`   | `32'h03747093` |     | `xcku9p`   | `32'h0484A093` |
| `7k410t`   | `32'h03656093` |     | `xcku11p`  | `32'h04A4E093` |
| `7k420t`   | `32'h03752093` |     | `xcku13eg` | `32'h04A52093` |
| `7k480t`   | `32'h03751093` |     | `xcku15p`  | `32'h04A56093` |
| `7s15`     | `32'h03620093` |     | `xcku5p`   | `32'h04A62093` |
| `7s100`    | `32'h037C7093` |     | `xcvu3p`   | `32'h04B39093` |
| `7v585t`   | `32'h03671093` |     | `xczu9eg`  | `32'h04738093` |
| `7v2000t`  | `32'h036B3093` |     | `xcvu5p`   | `32'h04B2B093` |
| `7vh580t`  | `32'h036D9093` |     | `xcvu7p`   | `32'h04B29093` |
| `7vh870t`  | `32'h036DB093` |     | `xczu3eg`  | `32'h04710093` |
| `7vx330t`  | `32'h03667093` |     | `xczu4eg`  | `32'h04A47093` |
| `7vx415t`  | `32'h03682093` |     | `xczu5eg`  | `32'h04A46093` |
| `7vx485t`  | `32'h03687093` |     | `xczu7eg`  | `32'h04A5A093` |
| `7vx550t`  | `32'h03692093` |     | `xczu2cg`  | `32'h04A43093` |
| `7vx690t`  | `32'h03691093` |     | `xczu3cg`  | `32'h04A42093` |
| `7vx980t`  | `32'h03696093` |     | `xczu4cg`  | `32'h04A47093` |
| `7vx1140t` | `32'h036D5093` |     | `xczu5cg`  | `32'h04A46093` |
| `7z010`    | `32'h03722093` |     | `xczu6cg`  | `32'h0484B093` |
| `7z015`    | `32'h0373B093` |     | `xczu7cg`  | `32'h04A5A093` |
| `7z020`    | `32'h03727093` |     | `xczu9cg`  | `32'h0484A093` |
| `7z030`    | `32'h0372C093` |     | `xczu5ev`  | `32'h04720093` |
| `7z035`    | `32'h03732093` |     | `xczu11eg` | `32'h04740093` |
| `7z045`    | `32'h03731093` |     | `xczu15eg` | `32'h04750093` |
| `7z100`    | `32'h03736093` |     | `xczu19eg` | `32'h04758093` |
| `7z007s`   | `32'h03723093` |     | `xczu7ev`  | `32'h04730093` |
| `7z012s`   | `32'h0373C093` |     | `xczu2eg`  | `32'h04A43093` |
| `7z014s`   | `32'h03728093` |     | `xczu4ev`  | `32'h04A47093` |
| `ku025`    | `32'h03824093` |     | `xczu6eg`  | `32'h04A4B093` |
| `ku035`    | `32'h03823093` |     | `xczu17eg` | `32'h04A57093` |
| `ku040`    | `32'h03822093` |     | `xcvu9p`   | `32'h04B31093` |
| `ku060`    | `32'h03919093` |     | `xcvu11p`  | `32'h04B42093` |
| `ku085`    | `32'h0390F093` |     | `xcvu13p`  | `32'h04B51093` |
