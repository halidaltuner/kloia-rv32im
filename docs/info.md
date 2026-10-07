<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

Kloia RV32IM wraps the open-source [ultraembedded RISC-V core](https://github.com/ultraembedded/riscv)
(RV32IM + Zicsr, machine mode, in-order pipeline) in a Tiny Tapeout tile. To fit the 8×2 tile,
multiply and divide share one iterative 32-cycle unit instead of the upstream array multiplier.
The core's instruction and data ports are arbitrated onto one byte-serial memory bus that runs over
the Tiny Tapeout pins, so program and data memory live on the host side (testbench, FPGA or
microcontroller) and the tile only holds the CPU.

Every memory request is streamed out on `uo[7:0]`, one byte per clock while `BUS_VALID` is high:

| Byte | Content |
|---|---|
| 0 | header: `[7]` write, `[6]` instruction fetch, `[3:0]` byte enables |
| 1–4 | address, LSB first |
| 5–8 | write data, LSB first (writes only) |

The host answers on `ui[7:0]` with `BUS_IN_VALID` high: four data bytes (LSB first) for a read,
or a single pulse to acknowledge a write. `BUS_BUSY` stays high from the header until the core has
been given the response. The core boots from address `0x0000_0000`; `IRQ` drives the external
interrupt input.

## How to test

The cocotb testbench in `test/` models the host: it decodes each transaction, serves instruction
fetches and loads from a small memory image and records stores. The bundled program exercises
`add`, `sub`, `mul`, `divu`, `remu`, `lw` and `sw`, writing its results to `0x8000_0000` onward,
which the test checks. Run it with:

```
cd test
pip install -r requirements.txt
make
```

On the demo board, connect a controller that speaks the bus protocol above to `ui`, `uo` and
`uio[3:0]`, hold `rst_n` low while it loads the program image, then release reset.

## External hardware

A host that implements the byte-serial memory bus — an FPGA or a microcontroller with fast GPIO
(for example the RP2040 on the Tiny Tapeout demo board, using PIO).
