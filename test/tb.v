`default_nettype none
`timescale 1ns / 1ps

/*
 * Copyright (c) 2026 NUAT Labs
 * SPDX-License-Identifier: Apache-2.0
 *
 * Testbench for tt_um_nuatlabs_i2c Master Controller.
 * Models realistic open-drain bus lines with pull-ups and external slave control.
 */
module tb ();

  // Dump signals to FST file for GTKWave / Surfer
  initial begin
    $dumpfile("tb.fst");
    $dumpvars(0, tb);
    #1;
  end

  // Registers for inputs
  reg clk;
  reg rst_n;
  reg ena;
  reg [7:0] ui_in;
  reg [7:0] uio_in;
  reg ext_scl_drive_low;
  reg ext_sda_drive_low;

  // Output wires from DUT
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;

  // Realistic open-drain I2C bus resolution:
  // Pulled high to 1'b1 unless DUT or external device pulls low to 1'b0
  wire scl_bus = ((uio_oe[0] && !uio_out[0]) || ext_scl_drive_low) ? 1'b0 : 1'b1;
  wire sda_bus = ((uio_oe[1] && !uio_out[1]) || ext_sda_drive_low) ? 1'b0 : 1'b1;

  wire [7:0] uio_in_eff;
  assign uio_in_eff[0]   = scl_bus;
  assign uio_in_eff[1]   = sda_bus;
  assign uio_in_eff[7:2] = uio_in[7:2];

  // Instantiate NUAT Labs I2C Controller
  tt_um_nuatlabs_i2c user_project (
      .ui_in  (ui_in),
      .uo_out (uo_out),
      .uio_in (uio_in_eff),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (ena),
      .clk    (clk),
      .rst_n  (rst_n)
  );

endmodule
