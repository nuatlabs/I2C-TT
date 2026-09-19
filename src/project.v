/*
 * Copyright (c) 2026 NUAT Labs
 * SPDX-License-Identifier: Apache-2.0
 *
 * Project Name: NUAT Labs I2C Controller
 * Description: High-reliability I2C Master Controller for Tiny Tapeout shuttle.
 * Features:
 *   - Open-drain SCL and SDA bus interface
 *   - 4-phase protocol timing engine
 *   - Standard START, Repeated START (Sr), and STOP generation
 *   - 7-bit slave addressing with ACK and NACK detection
 *   - Bidirectional read and write byte transfers
 *   - Hardware clock stretching detection and synchronization
 *   - Multi-master arbitration loss detection and bus release
 *   - Multiplexed status and received byte output
 */

`default_nettype none
`timescale 1ns / 1ps

module tt_um_nuatlabs_i2c #(
    parameter [7:0] DEFAULT_CLK_DIV = 8'd8
) (
    input  wire [7:0] ui_in,    // Dedicated inputs: Data byte / Slave Address / Config
    output wire [7:0] uo_out,   // Dedicated outputs: Received byte or status
    input  wire [7:0] uio_in,   // Bidirectional IOs: Input path
    output wire [7:0] uio_out,  // Bidirectional IOs: Output path
    output wire [7:0] uio_oe,   // Bidirectional IOs: Enable path (1=drive, 0=Hi-Z)
    input  wire       ena,      // Tiny Tapeout enable signal (active high)
    input  wire       clk,      // System clock
    input  wire       rst_n     // Active-low asynchronous reset
);

  // FSM State Encoding
  localparam [3:0] STATE_IDLE         = 4'd0;
  localparam [3:0] STATE_START        = 4'd1;
  localparam [3:0] STATE_REP_START    = 4'd2;
  localparam [3:0] STATE_WRITE_BYTE   = 4'd3;
  localparam [3:0] STATE_WRITE_ACK    = 4'd4;
  localparam [3:0] STATE_READ_BYTE    = 4'd5;
  localparam [3:0] STATE_READ_ACK     = 4'd6;
  localparam [3:0] STATE_STOP         = 4'd7;
  localparam [3:0] STATE_ARBLOST_EXIT = 4'd8;
  localparam [3:0] STATE_DONE         = 4'd9;

  // Internal registers
  reg [3:0] state;
  reg [1:0] phase;
  reg [7:0] clk_cnt;
  reg [7:0] clk_div_reg;

  reg [7:0] tx_shift;
  reg [7:0] rx_shift;
  reg [7:0] rx_data;
  reg [2:0] bit_cnt;

  reg is_read;
  reg do_start;
  reg do_stop;
  reg send_nack_bit;

  reg busy;
  reg irq_done;
  reg ack_error;
  reg arb_lost;
  reg rx_ack_bit;
  reg bus_active;

  reg scl_drive_low;
  reg sda_drive_low;

  // Bus input signals
  wire scl_in;
  wire sda_in;
  assign scl_in = uio_in[0];
  assign sda_in = uio_in[1];

  // Command inputs from host
  wire cmd_start;
  wire cmd_read;
  wire cmd_stop;
  wire cmd_valid;
  assign cmd_start = uio_in[2];
  assign cmd_read  = uio_in[3];
  assign cmd_stop  = uio_in[4];
  assign cmd_valid = uio_in[5];

  // Clock stretching detection:
  // Slave stretches clock by pulling SCL low when controller releases SCL high.
  wire clock_stretching;
  assign clock_stretching = (!scl_drive_low && !scl_in);

  // Phase tick generator
  wire phase_tick;
  assign phase_tick = (!clock_stretching) && (clk_cnt >= clk_div_reg - 1'b1);

  // Dedicated Output Mapping:
  // ui_in[7] selects output view when idle:
  // 0: Received data byte (rx_data)
  // 1: Controller status flags: {bus_active, arb_lost, ack_error, rx_ack_bit, state}
  assign uo_out = (ui_in[7]) ? {bus_active, arb_lost, ack_error, rx_ack_bit, state} : rx_data;

  // Bidirectional IO Mapping (Open-Drain for SCL and SDA):
  // When driving low: output = 0, oe = 1
  // When releasing (float high via external pull-up): output = 0, oe = 0
  assign uio_out[0] = 1'b0;
  assign uio_oe[0]  = scl_drive_low;

  assign uio_out[1] = 1'b0;
  assign uio_oe[1]  = sda_drive_low;

  // uio[5:2] are dedicated command inputs
  assign uio_out[5:2] = 4'b0000;
  assign uio_oe[5:2]  = 4'b0000;

  // uio[6] is busy output
  assign uio_out[6] = busy;
  assign uio_oe[6]  = 1'b1;

  // uio[7] is completion interrupt/pulse output
  assign uio_out[7] = irq_done;
  assign uio_oe[7]  = 1'b1;

  // Prevent synthesis warnings for unused signals
  wire _unused = &{ena, uio_in[7:6], 1'b0};

  // Main Protocol and Timing FSM
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state          <= STATE_IDLE;
      phase          <= 2'b00;
      clk_cnt        <= 8'd0;
      clk_div_reg    <= DEFAULT_CLK_DIV;
      tx_shift       <= 8'h00;
      rx_shift       <= 8'h00;
      rx_data        <= 8'h00;
      bit_cnt        <= 3'd0;
      is_read        <= 1'b0;
      do_start       <= 1'b0;
      do_stop        <= 1'b0;
      send_nack_bit  <= 1'b0;
      busy           <= 1'b0;
      irq_done       <= 1'b0;
      ack_error      <= 1'b0;
      arb_lost       <= 1'b0;
      rx_ack_bit     <= 1'b0;
      bus_active     <= 1'b0;
      scl_drive_low  <= 1'b0;
      sda_drive_low  <= 1'b0;
    end else begin
      // Default 1-cycle pulses
      irq_done <= 1'b0;

      // Prescaler counter
      if (state == STATE_IDLE) begin
        clk_cnt <= 8'd0;
        phase   <= 2'b00;
      end else begin
        if (clock_stretching) begin
          // Hold counter while slave stretches SCL
          clk_cnt <= clk_cnt;
        end else if (clk_cnt >= clk_div_reg - 1'b1) begin
          clk_cnt <= 8'd0;
          phase   <= phase + 1'b1;
        end else begin
          clk_cnt <= clk_cnt + 1'b1;
        end
      end

      // State Machine Transitions and Bus Control
      case (state)
        STATE_IDLE: begin
          scl_drive_low <= bus_active;
          sda_drive_low <= 1'b0;

          if (cmd_valid) begin
            busy          <= 1'b1;
            ack_error     <= 1'b0;
            arb_lost      <= 1'b0;
            tx_shift      <= ui_in;
            is_read       <= cmd_read;
            do_start      <= cmd_start;
            do_stop       <= cmd_stop;
            send_nack_bit <= ui_in[0] | cmd_stop;
            phase         <= 2'b00;
            clk_cnt       <= 8'd0;

            if (cmd_start) begin
              if (bus_active) begin
                state <= STATE_REP_START;
              end else begin
                state <= STATE_START;
              end
            end else if (cmd_stop && !cmd_read && (ui_in == 8'h00)) begin
              // Standalone STOP request
              state <= STATE_STOP;
            end else begin
              // Direct byte continuation
              bit_cnt <= 3'd7;
              if (cmd_read) begin
                state <= STATE_READ_BYTE;
              end else begin
                state <= STATE_WRITE_BYTE;
              end
            end
          end
        end

        STATE_START: begin
          // Standard START condition from idle bus (SCL high, SDA high)
          case (phase)
            2'b00: begin
              scl_drive_low <= 1'b0;
              sda_drive_low <= 1'b0;
            end
            2'b01: begin
              scl_drive_low <= 1'b0;
              sda_drive_low <= 1'b1; // SDA pulled low while SCL is high
            end
            2'b10: begin
              scl_drive_low <= 1'b0;
              sda_drive_low <= 1'b1; // Hold START
            end
            2'b11: begin
              scl_drive_low <= 1'b1; // SCL pulled low to complete START
              sda_drive_low <= 1'b1;
            end
          endcase

          if (phase_tick && (phase == 2'b11)) begin
            bus_active <= 1'b1;
            bit_cnt    <= 3'd7;
            if (is_read) begin
              state <= STATE_READ_BYTE;
            end else begin
              state <= STATE_WRITE_BYTE;
            end
          end
        end

        STATE_REP_START: begin
          // Repeated START condition when bus is already held (SCL was low)
          case (phase)
            2'b00: begin
              scl_drive_low <= 1'b1;
              sda_drive_low <= 1'b0; // Release SDA while SCL is low
            end
            2'b01: begin
              scl_drive_low <= 1'b0; // Release SCL high
              sda_drive_low <= 1'b0;
            end
            2'b10: begin
              scl_drive_low <= 1'b0;
              sda_drive_low <= 1'b1; // Pull SDA low while SCL is high (Sr)
            end
            2'b11: begin
              scl_drive_low <= 1'b1; // Pull SCL low to prepare for bit transfer
              sda_drive_low <= 1'b1;
            end
          endcase

          if (phase_tick && (phase == 2'b11)) begin
            bit_cnt <= 3'd7;
            if (is_read) begin
              state <= STATE_READ_BYTE;
            end else begin
              state <= STATE_WRITE_BYTE;
            end
          end
        end

        STATE_WRITE_BYTE: begin
          // Transmit 8 bits MSB first
          case (phase)
            2'b00: begin
              scl_drive_low <= 1'b1;
              sda_drive_low <= ~tx_shift[bit_cnt];
            end
            2'b01: begin
              scl_drive_low <= 1'b0; // SCL rising / high
            end
            2'b10: begin
              scl_drive_low <= 1'b0; // SCL high: sample for arbitration
              if (!sda_drive_low && !sda_in) begin
                arb_lost <= 1'b1;
              end
            end
            2'b11: begin
              scl_drive_low <= 1'b1; // SCL falling to low
            end
          endcase

          if (phase_tick && (phase == 2'b11)) begin
            if (arb_lost || (!sda_drive_low && !sda_in)) begin
              arb_lost <= 1'b1;
              state    <= STATE_ARBLOST_EXIT;
            end else if (bit_cnt > 3'd0) begin
              bit_cnt <= bit_cnt - 1'b1;
            end else begin
              state <= STATE_WRITE_ACK;
            end
          end
        end

        STATE_WRITE_ACK: begin
          // Sample slave ACK / NACK on 9th clock cycle
          case (phase)
            2'b00: begin
              scl_drive_low <= 1'b1;
              sda_drive_low <= 1'b0; // Release SDA so slave can ACK
            end
            2'b01: begin
              scl_drive_low <= 1'b0; // SCL high
            end
            2'b10: begin
              scl_drive_low <= 1'b0;
              rx_ack_bit    <= sda_in;
              if (sda_in) begin
                ack_error <= 1'b1; // Slave did not assert ACK
              end
            end
            2'b11: begin
              scl_drive_low <= 1'b1; // SCL falling
            end
          endcase

          if (phase_tick && (phase == 2'b11)) begin
            if (do_stop) begin
              state <= STATE_STOP;
            end else begin
              state <= STATE_DONE;
            end
          end
        end

        STATE_READ_BYTE: begin
          // Receive 8 bits from slave, MSB first
          case (phase)
            2'b00: begin
              scl_drive_low <= 1'b1;
              sda_drive_low <= 1'b0; // Release SDA for slave data
            end
            2'b01: begin
              scl_drive_low <= 1'b0; // SCL high
            end
            2'b10: begin
              scl_drive_low <= 1'b0; // Sample slave data bit
              rx_shift[bit_cnt] <= sda_in;
            end
            2'b11: begin
              scl_drive_low <= 1'b1; // SCL falling
            end
          endcase

          if (phase_tick && (phase == 2'b11)) begin
            if (bit_cnt > 3'd0) begin
              bit_cnt <= bit_cnt - 1'b1;
            end else begin
              state <= STATE_READ_ACK;
            end
          end
        end

        STATE_READ_ACK: begin
          // Master drives ACK (0) or NACK (1) to slave
          case (phase)
            2'b00: begin
              scl_drive_low <= 1'b1;
              sda_drive_low <= send_nack_bit ? 1'b0 : 1'b1;
            end
            2'b01: begin
              scl_drive_low <= 1'b0; // SCL high
            end
            2'b10: begin
              scl_drive_low <= 1'b0; // Hold ACK/NACK
            end
            2'b11: begin
              scl_drive_low <= 1'b1; // SCL falling
            end
          endcase

          if (phase_tick && (phase == 2'b11)) begin
            rx_data       <= rx_shift;
            sda_drive_low <= 1'b0; // Release SDA
            if (do_stop) begin
              state <= STATE_STOP;
            end else begin
              state <= STATE_DONE;
            end
          end
        end

        STATE_STOP: begin
          // Generate STOP condition: SDA goes low -> high while SCL is high
          case (phase)
            2'b00: begin
              scl_drive_low <= 1'b1;
              sda_drive_low <= 1'b1; // Pull SDA low while SCL is low
            end
            2'b01: begin
              scl_drive_low <= 1'b0; // Release SCL high
              sda_drive_low <= 1'b1; // SDA remains low
            end
            2'b10: begin
              scl_drive_low <= 1'b0;
              sda_drive_low <= 1'b0; // Release SDA high while SCL is high (STOP)
            end
            2'b11: begin
              scl_drive_low <= 1'b0;
              sda_drive_low <= 1'b0; // Bus is now idle
            end
          endcase

          if (phase_tick && (phase == 2'b11)) begin
            bus_active <= 1'b0;
            state      <= STATE_DONE;
          end
        end

        STATE_ARBLOST_EXIT: begin
          // Release bus immediately upon arbitration loss
          scl_drive_low <= 1'b0;
          sda_drive_low <= 1'b0;
          bus_active    <= 1'b0;
          state         <= STATE_DONE;
        end

        STATE_DONE: begin
          busy     <= 1'b0;
          irq_done <= 1'b1;
          state    <= STATE_IDLE;
        end

        default: begin
          state <= STATE_IDLE;
        end
      endcase
    end
  end

endmodule
