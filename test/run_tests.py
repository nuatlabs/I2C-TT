# Copyright (c) 2026 NUAT Labs
# SPDX-License-Identifier: Apache-2.0

"""
NUAT Labs Cocotb Test Runner Script
Executes full regression test suite with Icarus Verilog and generates FST waveforms.
"""

from pathlib import Path
from cocotb_tools.runner import get_runner


def run_tests():
    test_dir = Path(__file__).resolve().parent
    proj_dir = test_dir.parent

    sources = [
        proj_dir / "src" / "project.v",
        test_dir / "tb.v",
    ]

    runner = get_runner("icarus")

    runner.build(
        sources=sources,
        hdl_toplevel="tb",
        build_args=["-Wall", "-g2012"],
        always=True,
        waves=True,
    )

    runner.test(
        hdl_toplevel="tb",
        test_module="test",
        test_dir=test_dir,
        waves=True,
    )


def test_i2c_controller():
    run_tests()


if __name__ == "__main__":
    run_tests()
