# NUAT Labs I2C Controller

![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

A high-reliability I2C Master Controller design targeted for the **Tiny Tapeout** ASIC shuttle, developed by **NUAT Labs**.

## Overview

The NUAT Labs I2C Controller implements a robust, fully compliant I2C master protocol engine featuring:
- **Open-drain interface**: True bidirectional open-drain pads on SCL and SDA.
- **Protocol finite state machine (FSM)**: 4-phase timing generator for clean setup and hold times.
- **START, Repeated START (Sr), and STOP**: Full framing control for single-byte and multi-byte transfers.
- **7-bit addressing and ACK/NACK**: Automatic acknowledgement evaluation and generation.
- **Hardware clock stretching**: Automatic detection and pause when slaves stretch SCL low.
- **Arbitration loss detection**: Multi-master collision detection with immediate bus release.
- **Telemetry multiplexing**: Real-time status register and received data output via dedicated pins.

Detailed datasheet documentation is available in [docs/info.md](docs/info.md).

## Pinout Summary

| Pin | Name | Type | Description |
| :--- | :--- | :--- | :--- |
| `ui[7:0]` | `DATA_IN[7:0]` | Input | Transmit data byte or slave address / NACK control |
| `uo[7:0]` | `DATA_OUT[7:0]` | Output | Received data byte (`ui[7]=0`) or status word (`ui[7]=1`) |
| `uio[0]` | `I2C_SCL` | Bidir | I2C Serial Clock (open-drain, external pull-up required) |
| `uio[1]` | `I2C_SDA` | Bidir | I2C Serial Data (open-drain, external pull-up required) |
| `uio[2]` | `CMD_START` | Input | Generate START or Repeated START before byte transfer |
| `uio[3]` | `CMD_READ` | Input | 1 = Read byte from slave, 0 = Write byte to slave |
| `uio[4]` | `CMD_STOP` | Input | Generate STOP condition after byte transfer |
| `uio[5]` | `CMD_VALID` | Input | Command execute strobe (active high pulse) |
| `uio[6]` | `BUSY` | Output | Controller busy indicator |
| `uio[7]` | `IRQ_DONE` | Output | Transaction completion interrupt pulse |

## Verification

The core includes a comprehensive Cocotb test suite verified against Icarus Verilog:
- Power-on reset state and bus idle verification
- Single-byte and multi-byte write operations with slave ACK
- Slave NACK error detection
- Read operations with master ACK/NACK and STOP
- Repeated START (Sr) sequence execution
- Hardware clock stretching handling
- Multi-master arbitration loss detection

To run the verification suite locally:

```bash
# Using Python runner
python test/run_tests.py

# Using pytest
pytest test/run_tests.py

# Using Makefile
cd test && make
```
