# NUAT Labs I2C Controller Verification Testbench

This directory contains the verification environment for the NUAT Labs I2C Master Controller (`tt_um_nuatlabs_i2c`) targeted for the Tiny Tapeout shuttle. The testbench uses [cocotb](https://docs.cocotb.org/en/stable/) and Icarus Verilog to thoroughly verify open-drain protocol compliance, arbitration loss, clock stretching, and addressing.

## Test Suite Coverage

The test suite in [test.py](test.py) validates:
1. **test_reset_and_idle**: Verifies power-on reset state and high-impedance pull-up line levels.
2. **test_i2c_write_single_byte_with_ack**: Verifies START generation, 8-bit addressing/data, slave ACK detection, and STOP.
3. **test_i2c_write_nack_error**: Verifies NACK detection and `ack_error` telemetry flag assertion when slave does not ACK.
4. **test_i2c_read_single_byte**: Verifies single-byte read transfer, master NACK generation on last byte, STOP, and received data output.
5. **test_i2c_repeated_start**: Verifies Repeated START (Sr) sequence: address write without STOP followed by data read.
6. **test_i2c_clock_stretching**: Simulates an external slave holding SCL low and verifies controller timer pause and recovery.
7. **test_i2c_arbitration_loss**: Injects an external bus collision during bit transmission and validates immediate arbitration loss detection and bus release.

## How to Run the Tests

### Option 1: Python Test Runner

```sh
python test/run_tests.py
```

### Option 2: Pytest

```sh
pytest test/run_tests.py
```

### Option 3: Makefile (Linux / WSL)

```sh
make -B
```

## Viewing Waveforms

The testbench generates `tb.fst` which can be inspected using:

- **GTKWave**:
  ```sh
  gtkwave tb.fst
  ```
- **Surfer**:
  ```sh
  surfer tb.fst
  ```
