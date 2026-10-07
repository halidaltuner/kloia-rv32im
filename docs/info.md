<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

The design is a combinational 8-bit adder. It adds operand A (`ui_in`) and operand B (`uio_in`)
and drives the low 8 bits of the result on `uo_out`. The carry-out is discarded, so the sum wraps
modulo 256. All bidirectional pins are configured as inputs (`uio_oe = 0`).

## How to test

Set operand A on `ui[7:0]` and operand B on `uio[7:0]`, then read the sum on `uo[7:0]`.
For example, A = 20 and B = 30 gives SUM = 50. The clock and reset are not used.

## External hardware

None.
