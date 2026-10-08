<p align="center">
  <img src="docs/kloia-logo.svg" alt="kloia" width="200">
</p>

<h1 align="center">Kloia RV32IM</h1>

<p align="center">
  A 32-bit RISC-V (RV32IM) core on the Tiny Tapeout sky130 shuttle.
</p>

<p align="center">
  <img src="../../workflows/gds/badge.svg" alt="gds">
  <img src="../../workflows/docs/badge.svg" alt="docs">
  <img src="../../workflows/test/badge.svg" alt="test">
</p>

---

## Overview

Kloia RV32IM puts a complete RISC-V CPU into a Tiny Tapeout tile. The core is the open-source
[ultraembedded RISC-V core](https://github.com/ultraembedded/riscv) — RV32IM + Zicsr, machine
mode, in-order pipeline with hardware multiply and divide — configured without the MMU and
supervisor mode so it fits the 8×2 tile budget. Program and data memory live on the host side:
the tile exposes a byte-serial memory bus over the Tiny Tapeout pins, and a testbench, FPGA or
microcontroller services every fetch, load and store.

The project is Kloia's first silicon. We build and modernise software platforms for a living;
this chip walks the same path our customers walk — from RTL to GDS with an open PDK, an open
flow and a CI pipeline that hardens every push.

## Features

| Area | Detail |
|---|---|
| ISA | RV32I base + M extension (`MUL`, `MULH*`, `DIV*`, `REM*`) + Zicsr |
| Privilege | Machine mode (supervisor/user and MMU disabled) |
| Pipeline | In-order (result bypass paths disabled to save routing) |
| Multiply / divide | Shared iterative unit, 32 cycles per operation (see *Core changes*) |
| Memory interface | Byte-serial bus over the TT pins; instruction and data ports arbitrated, one outstanding request |
| Reset / boot | Active-low reset; fetches from `0x0000_0000` |
| Interrupt | External interrupt on `uio[3]` |
| Process | SkyWater sky130A, hardened with LibreLane |
| Tile size | 8 × 2, 20 MHz timing target |

## Pinout

| Pin | Direction | Function |
|---|---|---|
| `ui[7:0]` | in | `BUS_IN` — read data byte from the host |
| `uo[7:0]` | out | `BUS_OUT` — header, address and write-data bytes |
| `uio[0]` | out | `BUS_VALID` — `uo` carries a byte this cycle |
| `uio[1]` | out | `BUS_BUSY` — a transaction is in flight |
| `uio[2]` | in | `BUS_IN_VALID` — host presents a byte on `ui`, or acks a write |
| `uio[3]` | in | `IRQ` — external interrupt |
| `uio[7:4]` | — | unused |
| `clk` | in | Core clock |
| `rst_n` | in | Active-low reset |

## Bus protocol

Every memory request is streamed out on `uo`, one byte per clock while `BUS_VALID` is high:

| Byte | Content |
|---|---|
| 0 | header: `[7]` write, `[6]` instruction fetch, `[3:0]` byte enables |
| 1–4 | address, LSB first |
| 5–8 | write data, LSB first (writes only) |

The host replies on `ui` with `BUS_IN_VALID` high: four data bytes (LSB first) for a read, or a
single pulse to acknowledge a write. `BUS_BUSY` drops once the core has received the response.
The wrapper lives in [`src/tt_um_kloia_rv32im.v`](src/tt_um_kloia_rv32im.v); the core sources
are the upstream `riscv_*.v` files with the changes listed below.

## Core changes

The upstream core did not fit the 8×2 tile: its pipelined 32×32 array multiplier alone was about
30 % of the cell area, and placement failed at 83 % utilisation. Two files are changed, each
marked with a `Kloia change` comment:

- `riscv_divider.v` — also executes `MUL`, `MULH`, `MULHSU` and `MULHU` as a 32-cycle
  shift-and-add, reusing the divider's step counter and operand registers.
- `riscv_decoder.v` — issues the multiply instructions on the divide path, so the array
  multiplier (`riscv_multiplier.v`, still in the tree) is never selected and is removed by
  synthesis.

Multiplies therefore take ~34 cycles instead of 2; everything else, including the result
bypass for loads, is unchanged. Flattened generic synthesis drops from ~45 k to ~32 k cells.

## How to test

```bash
pip install -r test/requirements.txt
cd test && make
```

The cocotb testbench models the host side of the bus and runs a short RV32IM program that
exercises `add`, `sub`, `mul`, `divu`, `remu`, `lw` and `sw`, checking the values the program
stores to `0x8000_0000` onward. Run `make GATES=yes` after a GDS build to repeat the test on the
gate-level netlist. See [test/README.md](test/README.md) for the harness details.

On the demo board, drive the bus from a controller with fast GPIO (the RP2040's PIO is a good
fit), hold `rst_n` low while the program image is loaded, then release it.

## Building the ASIC

Every push runs the full flow in GitHub Actions:

- **test** — cocotb regression with Icarus Verilog
- **gds** — LibreLane hardening, precheck, gate-level test and an interactive GDS viewer on
  GitHub Pages
- **docs** — datasheet PDF from `info.yaml` and `docs/info.md`
- **fpga** — ICE40UP5K bitstream for the TT ASIC Sim board (manual trigger). The full core
  needs more logic cells than the UP5K has, so this flow does not complete for this design.

To harden locally, follow the
[Tiny Tapeout local hardening guide](https://www.tinytapeout.com/guides/local-hardening/).

## Repository layout

```
src/        tt_um_kloia_rv32im.v (wrapper + bus bridge), riscv_*.v (core), config.json
test/       cocotb testbench, bus host model, mini assembler and test program
docs/       datasheet source (info.md) and images
info.yaml   Tiny Tapeout project metadata and pinout
```

## About Kloia

[Kloia](https://www.kloia.com) is a technology partner for cloud, DevOps, application
modernisation, QA and observability. We work hands-on inside our customers' teams, and we take
the same approach to hardware: open tools, automated pipelines and shipping real things.

## License

The wrapper, testbench and documentation are Apache-2.0 ([LICENSE](LICENSE)). The RISC-V core
(`src/riscv_*.v`) is © ultraembedded, BSD-3-Clause ([src/LICENSE.riscv-core](src/LICENSE.riscv-core)).
