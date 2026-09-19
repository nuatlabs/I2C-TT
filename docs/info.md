<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

-->

## How it works

The **NUAT Labs I2C Controller** (`tt_um_nuatlabs_i2c`) is a high-reliability, open-drain I2C Master core engineered for the Tiny Tapeout ASIC shuttle. The core provides full hardware support for I2C communication with external sensors, memories, and peripherals.

### Key Architectural Features

1. **True Open-Drain Bus Interface**:
   - `uio[0]` (SCL) and `uio[1]` (SDA) operate in open-drain configuration.
   - When outputting a logic 0, the output driver actively pulls the line low (`uio_oe = 1`, `uio_out = 0`).
   - When outputting a logic 1, the output driver releases the line into high-impedance mode (`uio_oe = 0`), allowing external pull-up resistors to pull the bus line high.

2. **4-Phase Clock Engine**:
   - Each I2C bit period is subdivided into 4 distinct phases (Phase 00, Phase 01, Phase 10, Phase 11) generated from an internal prescaler counter (`DEFAULT_CLK_DIV = 8`).
   - Phase 00: SCL is low. Data transitions on SDA (data setup time).
   - Phase 01: SCL is released high.
   - Phase 10: SCL is held high. Sampling of data, ACK, and bus arbitration occurs.
   - Phase 11: SCL is driven low (data hold time).

3. **Protocol State Machine (FSM)**:
   - `STATE_IDLE`: Bus is released and controller waits for command strobe.
   - `STATE_START`: Generates standard START condition (SDA pulled low while SCL is high).
   - `STATE_REP_START`: Generates Repeated START (Sr) sequence while maintaining bus ownership.
   - `STATE_WRITE_BYTE`: Transmits 8 bits MSB first to slave device.
   - `STATE_WRITE_ACK`: Samples 9th bit from slave (0 = ACK, 1 = NACK).
   - `STATE_READ_BYTE`: Receives 8 bits MSB first from slave device.
   - `STATE_READ_ACK`: Drives Master ACK or NACK to slave.
   - `STATE_STOP`: Generates standard STOP condition (SDA released high while SCL is high).
   - `STATE_ARBLOST_EXIT`: Relinquishes bus immediately upon arbitration loss.
   - `STATE_DONE`: Pulses `irq_done` and clears `busy`.

4. **Hardware Clock Stretching**:
   - When SCL is released high, the controller monitors the actual line level on `scl_in`.
   - If a slow slave holds SCL low, the controller timer freezes until SCL rises, providing seamless synchronization.

5. **Multi-Master Arbitration Loss Detection**:
   - During write transfers, the controller checks whether `sda_in` matches the transmitted bit during Phase 10 (SCL high).
   - If the controller releases SDA high but detects `sda_in == 0`, arbitration loss is flagged (`arb_lost = 1`), and the bus is immediately released to prevent collisions.

6. **Multiplexed Telemetry and Output Register**:
   - When `ui_in[7] == 0`: `uo_out[7:0]` outputs the received byte (`rx_data`).
   - When `ui_in[7] == 1`: `uo_out[7:0]` outputs the internal telemetry word: `{bus_active, arb_lost, ack_error, rx_ack_bit, fsm_state[3:0]}`.

---

## How to test

### Pinout Mapping

| Pin Name | Function | Direction | Description |
| :--- | :--- | :--- | :--- |
| `ui_in[7:0]` | DATA_IN | Input | Transmit data byte or slave address + R/W bit |
| `uo_out[7:0]` | DATA_OUT / STATUS | Output | Received byte (`ui[7]=0`) or status word (`ui[7]=1`) |
| `uio[0]` | I2C_SCL | In/Out | Open-drain I2C clock line (requires pull-up) |
| `uio[1]` | I2C_SDA | In/Out | Open-drain I2C data line (requires pull-up) |
| `uio[2]` | CMD_START | Input | 1 = Generate START or Repeated START before byte |
| `uio[3]` | CMD_READ | Input | 1 = Read transfer from slave, 0 = Write to slave |
| `uio[4]` | CMD_STOP | Input | 1 = Generate STOP after byte transfer |
| `uio[5]` | CMD_VALID | Input | 1-cycle active high strobe to trigger command |
| `uio[6]` | BUSY | Output | 1 while transaction is in progress |
| `uio[7]` | IRQ_DONE | Output | 1-cycle active high pulse on byte completion |

### Test Procedure

1. Connect pull-up resistors (2.2k to 10k ohm) between `uio[0]` (SCL), `uio[1]` (SDA), and VDD.
2. Apply active-low reset (`rst_n = 0`) for at least 10 clock cycles, then deassert (`rst_n = 1`).
3. **Write Transfer**:
   - Set `ui_in[7:0]` to slave address with write bit (e.g., `0xA0`).
   - Assert `uio[2]` (`cmd_start`), `uio[4]` (`cmd_stop`), and pulse `uio[5]` (`cmd_valid`).
   - Wait for `uio[7]` (`irq_done`). Verify `uo_out[5]` (`ack_error`) is 0.
4. **Read Transfer**:
   - Set `ui_in[7:0]` with `ui_in[0] = 1` (NACK bit on final byte).
   - Assert `uio[2]` (`cmd_start`), `uio[3]` (`cmd_read`), `uio[4]` (`cmd_stop`), and pulse `uio[5]`.
   - Wait for `uio[7]` (`irq_done`). Read the received byte on `uo_out[7:0]`.

---

## External hardware

- Pull-up resistors: Two external resistors (2.2k ohm to 4.7k ohm recommended) on SCL (`uio[0]`) and SDA (`uio[1]`).
- Any standard I2C slave peripheral (e.g. 24LCxx EEPROM, BMP280 pressure sensor, AHT20 temperature sensor, or OLED display).
