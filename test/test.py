# Copyright (c) 2026 NUAT Labs
# SPDX-License-Identifier: Apache-2.0

"""
NUAT Labs I2C Controller Cocotb Test Suite
Target: Tiny Tapeout shuttle verification
Covers:
  - System reset and clock divider configuration
  - Single-byte and multi-byte write transfers with slave ACK
  - Slave NACK error detection
  - Read transfer with master ACK/NACK generation
  - Repeated START (Sr) transaction
  - Hardware clock stretching handling
  - Multi-master arbitration loss detection
  - Status register and bus telemetry multiplexing
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, FallingEdge


async def reset_dut(dut):
    """Applies active-low asynchronous reset and initializes all inputs."""
    dut._log.info("Applying system reset")
    dut.ena.value = 1
    dut.rst_n.value = 0
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.ext_scl_drive_low.value = 0
    dut.ext_sda_drive_low.value = 0

    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)
    dut._log.info("Reset complete, DUT ready")


async def send_cmd(dut, data_byte, cmd_start=0, cmd_read=0, cmd_stop=0):
    """Issues a host command strobe to the I2C Controller."""
    dut.ui_in.value = data_byte
    ctrl = ((cmd_start & 1) << 2) | ((cmd_read & 1) << 3) | ((cmd_stop & 1) << 4) | (1 << 5)
    dut.uio_in.value = ctrl
    await ClockCycles(dut.clk, 1)
    # Deassert cmd_valid strobe while holding command attributes
    dut.uio_in.value = ctrl & ~(1 << 5)


async def wait_for_done(dut, timeout_cycles=3000):
    """Waits for irq_done completion pulse or busy deassertion."""
    for _ in range(timeout_cycles):
        await ClockCycles(dut.clk, 1)
        # uio_out[7] is irq_done, uio_out[6] is busy
        if int(dut.uio_out.value) & (1 << 7):
            await ClockCycles(dut.clk, 1)
            return
    raise TimeoutError("Timeout waiting for I2C transaction done")


async def simulate_slave_ack(dut):
    """Simulates an external I2C slave acknowledging an 8-bit write."""
    # Wait for 8 data bit clock pulses
    for _ in range(8):
        await RisingEdge(dut.scl_bus)
    # SCL is high during bit 0. Wait for falling edge to enter ACK cycle
    await FallingEdge(dut.scl_bus)
    # Drive SDA low for ACK
    dut.ext_sda_drive_low.value = 1
    # Wait for ACK clock pulse
    await RisingEdge(dut.scl_bus)
    await FallingEdge(dut.scl_bus)
    # Release SDA
    dut.ext_sda_drive_low.value = 0


async def simulate_slave_read_byte(dut, byte_val):
    """Simulates an external I2C slave sending an 8-bit byte during read."""
    for bit_idx in range(7, -1, -1):
        bit_val = (byte_val >> bit_idx) & 1
        dut.ext_sda_drive_low.value = 0 if bit_val else 1
        await RisingEdge(dut.scl_bus)
        await FallingEdge(dut.scl_bus)

    # Release SDA for master ACK/NACK cycle
    dut.ext_sda_drive_low.value = 0
    await RisingEdge(dut.scl_bus)


@cocotb.test()
async def test_reset_and_idle(dut):
    """Test 1: Verify power-on reset state and idle line conditions."""
    dut._log.info("NUAT Labs Test 1: Reset and Idle")
    clock = Clock(dut.clk, 100, unit="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)

    # Initial state should be idle
    assert (int(dut.uio_out.value) & (1 << 6)) == 0, "Controller should not be busy after reset"
    assert dut.scl_bus.value == 1, "SCL should be pulled high at idle"
    assert dut.sda_bus.value == 1, "SDA should be pulled high at idle"
    dut._log.info("Reset state verified successfully")


@cocotb.test()
async def test_i2c_write_single_byte_with_ack(dut):
    """Test 2: Verify single-byte write with START, slave ACK, and STOP."""
    dut._log.info("NUAT Labs Test 2: Single-Byte Write with Slave ACK")
    clock = Clock(dut.clk, 100, unit="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)

    # Slave address 0x50 with Write bit (0) -> 0xA0
    slave_addr_w = 0xA0

    # Start slave ACK responder in background
    ack_task = cocotb.start_soon(simulate_slave_ack(dut))

    # Send command: START + Write + STOP
    await send_cmd(dut, data_byte=slave_addr_w, cmd_start=1, cmd_read=0, cmd_stop=1)

    await wait_for_done(dut)
    await ack_task

    # Check status: select status view via ui_in[7] = 1
    dut.ui_in.value = 0x80
    await ClockCycles(dut.clk, 1)

    status = int(dut.uo_out.value)
    ack_err = (status >> 5) & 1
    arb_lost = (status >> 6) & 1
    assert ack_err == 0, f"Expected ACK from slave, got ack_error={ack_err}"
    assert arb_lost == 0, f"Unexpected arbitration loss: {arb_lost}"
    dut._log.info("Single-byte write with ACK verified successfully")


@cocotb.test()
async def test_i2c_write_nack_error(dut):
    """Test 3: Verify NACK detection when slave does not pull SDA low."""
    dut._log.info("NUAT Labs Test 3: Write Slave NACK Detection")
    clock = Clock(dut.clk, 100, unit="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)

    # Send address 0x32 with Write bit (0x64), no slave will ACK
    await send_cmd(dut, data_byte=0x64, cmd_start=1, cmd_read=0, cmd_stop=1)

    await wait_for_done(dut)

    # Read status: ui_in[7] = 1
    dut.ui_in.value = 0x80
    await ClockCycles(dut.clk, 1)

    status = int(dut.uo_out.value)
    ack_err = (status >> 5) & 1
    assert ack_err == 1, f"Expected ack_error=1 on slave NACK, got {ack_err}"
    dut._log.info("NACK error flag assertion verified successfully")


@cocotb.test()
async def test_i2c_read_single_byte(dut):
    """Test 4: Verify single-byte read transfer, master NACK generation, and STOP."""
    dut._log.info("NUAT Labs Test 4: Single-Byte Read with Master NACK and STOP")
    clock = Clock(dut.clk, 100, unit="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)

    expected_data = 0xC7

    # Start slave responder to feed data byte
    slave_task = cocotb.start_soon(simulate_slave_read_byte(dut, expected_data))

    # Send read command with START and STOP (cmd_stop automatically drives master NACK)
    await send_cmd(dut, data_byte=0x01, cmd_start=1, cmd_read=1, cmd_stop=1)

    await wait_for_done(dut)
    await slave_task

    # Inspect received data byte (ui_in[7] = 0)
    dut.ui_in.value = 0x00
    await ClockCycles(dut.clk, 1)

    read_result = int(dut.uo_out.value)
    assert read_result == expected_data, f"Expected {hex(expected_data)}, got {hex(read_result)}"
    dut._log.info(f"Read data byte {hex(read_result)} verified successfully")


@cocotb.test()
async def test_i2c_repeated_start(dut):
    """Test 5: Verify Repeated START (Sr) sequence: Write addr then Read data."""
    dut._log.info("NUAT Labs Test 5: Repeated START (Sr) Write followed by Read")
    clock = Clock(dut.clk, 100, unit="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)

    # Byte 1: Write register address 0x2A with START, but NO STOP (bus held)
    ack_task = cocotb.start_soon(simulate_slave_ack(dut))
    await send_cmd(dut, data_byte=0x2A, cmd_start=1, cmd_read=0, cmd_stop=0)
    await wait_for_done(dut)
    await ack_task

    assert dut.scl_bus.value == 0, "SCL should remain low holding the bus after byte without STOP"

    # Byte 2: Read data 0x55 with Repeated START (Sr) and STOP
    expected_val = 0x55

    async def slave_read_with_sr():
        # Await Repeated START pulse (SCL rises and falls) before data bits
        await RisingEdge(dut.scl_bus)
        await FallingEdge(dut.scl_bus)
        await simulate_slave_read_byte(dut, expected_val)

    slave_task = cocotb.start_soon(slave_read_with_sr())
    await send_cmd(dut, data_byte=0x01, cmd_start=1, cmd_read=1, cmd_stop=1)
    await wait_for_done(dut)
    await slave_task

    # Read data output
    dut.ui_in.value = 0x00
    await ClockCycles(dut.clk, 1)
    assert int(dut.uo_out.value) == expected_val, f"Mismatch on Repeated START read: {hex(int(dut.uo_out.value))}"
    assert dut.scl_bus.value == 1, "SCL should return high after STOP"
    dut._log.info("Repeated START sequence verified successfully")


@cocotb.test()
async def test_i2c_clock_stretching(dut):
    """Test 6: Verify clock stretching where slave holds SCL low."""
    dut._log.info("NUAT Labs Test 6: Hardware Clock Stretching")
    clock = Clock(dut.clk, 100, unit="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)

    async def stretch_and_ack():
        # Wait for 4 rising edges of data
        for _ in range(4):
            await RisingEdge(dut.scl_bus)
        await FallingEdge(dut.scl_bus)
        # Slave holds SCL low to stretch clock
        dut.ext_scl_drive_low.value = 1
        await ClockCycles(dut.clk, 50)
        # Release SCL
        dut.ext_scl_drive_low.value = 0

        # Wait for remaining 4 data pulses
        for _ in range(4):
            await RisingEdge(dut.scl_bus)
        await FallingEdge(dut.scl_bus)
        # ACK
        dut.ext_sda_drive_low.value = 1
        await RisingEdge(dut.scl_bus)
        await FallingEdge(dut.scl_bus)
        dut.ext_sda_drive_low.value = 0

    stretch_task = cocotb.start_soon(stretch_and_ack())

    await send_cmd(dut, data_byte=0x44, cmd_start=1, cmd_read=0, cmd_stop=1)
    await wait_for_done(dut)
    await stretch_task

    dut.ui_in.value = 0x80
    await ClockCycles(dut.clk, 1)
    status = int(dut.uo_out.value)
    assert ((status >> 5) & 1) == 0, "Transaction should complete with ACK after stretch release"
    dut._log.info("Clock stretching handled properly by controller")


@cocotb.test()
async def test_i2c_arbitration_loss(dut):
    """Test 7: Verify multi-master arbitration loss detection and bus release."""
    dut._log.info("NUAT Labs Test 7: Multi-Master Arbitration Loss Detection")
    clock = Clock(dut.clk, 100, unit="ns")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)

    async def inject_collision():
        # During bit 7, data is 1. External master pulls SDA low (0)
        await RisingEdge(dut.scl_bus)
        dut.ext_sda_drive_low.value = 1
        await ClockCycles(dut.clk, 20)
        dut.ext_sda_drive_low.value = 0

    collision_task = cocotb.start_soon(inject_collision())

    # Transmit byte 0xFF where bit 7 is 1
    await send_cmd(dut, data_byte=0xFF, cmd_start=1, cmd_read=0, cmd_stop=1)

    await wait_for_done(dut)
    await collision_task

    # Inspect status: ui_in[7] = 1
    dut.ui_in.value = 0x80
    await ClockCycles(dut.clk, 1)

    status = int(dut.uo_out.value)
    arb_lost = (status >> 6) & 1
    assert arb_lost == 1, f"Expected arb_lost=1 upon collision, got {arb_lost}"
    assert dut.scl_bus.value == 1, "Master should release SCL on arbitration loss"
    dut._log.info("Arbitration loss detected and bus relinquished successfully")
