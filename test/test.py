# SPDX-FileCopyrightText: © 2026 Kloia
# SPDX-License-Identifier: Apache-2.0
"""
cocotb test for the Kloia RV32IM Tiny Tapeout project.

The testbench plays the role of the host on the byte-serial memory bus: it
decodes every request the chip sends, serves instruction fetches and loads from
a small memory image, and records stores. A short RV32IM program exercises the
ALU, the multiplier/divider and the load/store path, and writes its results to
a memory-mapped "I/O" region that the test checks.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

IO_BASE = 0x8000_0000
BOOT_TIMEOUT_CYCLES = 20_000


# ---------------------------------------------------------------------------
# Minimal RV32IM assembler (just enough for the test program)
# ---------------------------------------------------------------------------
def r_type(funct7, rs2, rs1, funct3, rd, opcode):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def i_type(imm, rs1, funct3, rd, opcode):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def s_type(imm, rs2, rs1, funct3, opcode):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | ((imm & 0x1F) << 7) | opcode


def u_type(imm, rd, opcode):
    return (imm & 0xFFFFF000) | (rd << 7) | opcode


def j_type(imm, rd):
    imm &= 0x1FFFFF
    enc = ((imm >> 20) & 1) << 31
    enc |= ((imm >> 1) & 0x3FF) << 21
    enc |= ((imm >> 11) & 1) << 20
    enc |= ((imm >> 12) & 0xFF) << 12
    return enc | (rd << 7) | 0x6F


def addi(rd, rs1, imm):  return i_type(imm, rs1, 0b000, rd, 0x13)
def lui(rd, imm):        return u_type(imm, rd, 0x37)
def add(rd, rs1, rs2):   return r_type(0b0000000, rs2, rs1, 0b000, rd, 0x33)
def sub(rd, rs1, rs2):   return r_type(0b0100000, rs2, rs1, 0b000, rd, 0x33)
def mul(rd, rs1, rs2):   return r_type(0b0000001, rs2, rs1, 0b000, rd, 0x33)
def mulh(rd, rs1, rs2):  return r_type(0b0000001, rs2, rs1, 0b001, rd, 0x33)
def mulhsu(rd, rs1, rs2):return r_type(0b0000001, rs2, rs1, 0b010, rd, 0x33)
def mulhu(rd, rs1, rs2): return r_type(0b0000001, rs2, rs1, 0b011, rd, 0x33)
def divu(rd, rs1, rs2):  return r_type(0b0000001, rs2, rs1, 0b101, rd, 0x33)
def remu(rd, rs1, rs2):  return r_type(0b0000001, rs2, rs1, 0b111, rd, 0x33)
def lw(rd, rs1, imm):    return i_type(imm, rs1, 0b010, rd, 0x03)
def sw(rs2, rs1, imm):   return s_type(imm, rs2, rs1, 0b010, 0x23)
def jal(rd, imm):        return j_type(imm, rd)


DATA_ADDR = 0x100
DATA_VALUE = 0xDEADBEEF

PROGRAM = [
    addi(1, 0, 20),          # x1 = 20
    addi(2, 0, 30),          # x2 = 30
    add(3, 1, 2),            # x3 = 50
    mul(4, 1, 2),            # x4 = 600
    addi(5, 0, 7),           # x5 = 7
    divu(6, 4, 5),           # x6 = 85
    remu(7, 4, 5),           # x7 = 5
    sub(10, 1, 2),           # x10 = -10
    lui(8, IO_BASE),         # x8 = 0x8000_0000
    sw(3, 8, 0),             # IO[0]  = 50
    sw(4, 8, 4),             # IO[4]  = 600
    sw(6, 8, 8),             # IO[8]  = 85
    sw(7, 8, 12),            # IO[12] = 5
    sw(10, 8, 16),           # IO[16] = 0xFFFFFFF6
    lw(9, 0, DATA_ADDR),     # x9 = mem[0x100]
    sw(9, 8, 20),            # IO[20] = 0xDEADBEEF
    mulh(11, 10, 2),         # x11 = (-10 * 30) >> 32        = -1
    mulhsu(12, 10, 2),       # x12 = (-10 * 30u) >> 32       = -1
    mulhu(13, 10, 2),        # x13 = (0xFFFFFFF6 * 30) >> 32 = 29
    mul(14, 10, 2),          # x14 = -300
    sw(11, 8, 24),           # IO[24] = 0xFFFFFFFF
    sw(12, 8, 28),           # IO[28] = 0xFFFFFFFF
    sw(13, 8, 32),           # IO[32] = 29
    sw(14, 8, 36),           # IO[36] = 0xFFFFFED4
    jal(0, 0),               # spin forever
]

EXPECTED_IO = {
    IO_BASE + 0: 50,
    IO_BASE + 4: 600,
    IO_BASE + 8: 85,
    IO_BASE + 12: 5,
    IO_BASE + 16: 0xFFFF_FFF6,
    IO_BASE + 20: DATA_VALUE,
    IO_BASE + 24: 0xFFFF_FFFF,
    IO_BASE + 28: 0xFFFF_FFFF,
    IO_BASE + 32: 29,
    IO_BASE + 36: 0xFFFF_FED4,
}


# ---------------------------------------------------------------------------
# Host-side model of the byte-serial bus
# ---------------------------------------------------------------------------
class BusHost:
    def __init__(self, dut, memory):
        self.dut = dut
        self.memory = memory          # word address -> 32-bit value
        self.stores = {}              # word address -> 32-bit value
        self.fetches = 0
        self.loads = 0

    def read_word(self, addr):
        return self.memory.get(addr & ~3, 0)

    def write_word(self, addr, data, be):
        addr &= ~3
        old = self.memory.get(addr, 0)
        new = old
        for lane in range(4):
            if be & (1 << lane):
                mask = 0xFF << (8 * lane)
                new = (new & ~mask) | (data & mask)
        self.memory[addr] = new
        self.stores[addr] = new

    async def run(self):
        dut = self.dut
        while True:
            # Collect one transaction's outgoing bytes.
            await RisingEdge(dut.clk)
            if not dut.uio_out.value[0]:
                continue
            payload = [int(dut.uo_out.value)]
            while True:
                await RisingEdge(dut.clk)
                if not dut.uio_out.value[0]:
                    break
                payload.append(int(dut.uo_out.value))

            header = payload[0]
            is_write = bool(header & 0x80)
            is_instr = bool(header & 0x40)
            be = header & 0x0F
            addr = int.from_bytes(bytes(payload[1:5]), "little")

            if is_write:
                assert len(payload) == 9, f"write payload length {len(payload)}"
                data = int.from_bytes(bytes(payload[5:9]), "little")
                self.write_word(addr, data, be)
                dut._log.debug(f"ST  [{addr:08x}] <= {data:08x} be={be:04b}")
                dut.uio_in.value = 1 << 2
                await RisingEdge(dut.clk)
                dut.uio_in.value = 0
            else:
                assert len(payload) == 5, f"read payload length {len(payload)}"
                data = self.read_word(addr)
                if is_instr:
                    self.fetches += 1
                else:
                    self.loads += 1
                    dut._log.debug(f"LD  [{addr:08x}] => {data:08x}")
                for lane in range(4):
                    dut.ui_in.value = (data >> (8 * lane)) & 0xFF
                    dut.uio_in.value = 1 << 2
                    await RisingEdge(dut.clk)
                dut.uio_in.value = 0
                dut.ui_in.value = 0


# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_rv32im_program(dut):
    dut._log.info("Start")

    clock = Clock(dut.clk, 40, unit="ns")
    cocotb.start_soon(clock.start())

    memory = {4 * i: insn for i, insn in enumerate(PROGRAM)}
    memory[DATA_ADDR] = DATA_VALUE
    host = BusHost(dut, memory)

    dut._log.info("Reset")
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1

    cocotb.start_soon(host.run())

    dut._log.info("Running program")
    for _ in range(BOOT_TIMEOUT_CYCLES // 100):
        await ClockCycles(dut.clk, 100)
        if all(addr in host.stores for addr in EXPECTED_IO):
            break
    else:
        raise AssertionError(
            f"program did not finish within {BOOT_TIMEOUT_CYCLES} cycles; "
            f"stores so far: { {hex(a): hex(v) for a, v in host.stores.items()} }"
        )

    for addr, expected in EXPECTED_IO.items():
        got = host.stores[addr]
        assert got == expected, f"IO[{addr:08x}] = {got:08x}, expected {expected:08x}"

    dut._log.info(
        f"OK: {host.fetches} instruction fetches, {host.loads} loads, "
        f"{len(host.stores)} stores"
    )
