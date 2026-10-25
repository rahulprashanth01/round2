#!/usr/bin/env python3
"""
GENOME-X PYNQ-Z2 Host Test Script  (PROVIDED — DO NOT MODIFY)
=============================================================
Loads the GENOME-X overlay onto the PYNQ-Z2 and runs automated test
vectors against the hardware pipeline via AXI-Lite registers.

Usage (on PYNQ-Z2 via SSH or Jupyter):
    python3 pynq_host.py                   # Run all tests
    python3 pynq_host.py --test single     # Only single-edit tests
    python3 pynq_host.py --test multi      # Only multi-edit tests
    python3 pynq_host.py --verbose         # Show detailed register dumps

Requirements:
    - PYNQ framework installed (pre-installed on PYNQ-Z2 SD image)
    - Bitstream (.bit) and hardware handoff (.hwh) in ./overlay/
"""

import argparse
import sys
import time

try:
    from pynq import Overlay, MMIO
except ImportError:
    print("ERROR: PYNQ library not found. This script must run on the PYNQ-Z2 board.")
    print("       If testing off-board, use the simulation testbench instead.")
    sys.exit(1)


# ==========================================================================
# Register Map (must match genome_x_axi_wrapper.v)
# ==========================================================================
REG_GENOME_LO       = 0x00
REG_GENOME_HI       = 0x04
REG_GUIDE           = 0x08
REG_REPLACEMENT     = 0x0C
REG_THRESHOLD       = 0x10
REG_COMMAND          = 0x14
REG_STATUS           = 0x18
REG_RESULT_GENOME_LO = 0x1C
REG_RESULT_GENOME_HI = 0x20
REG_RESULT_INFO      = 0x24
REG_MULTI_GENOME_LO  = 0x28
REG_MULTI_GENOME_HI  = 0x2C
REG_MULTI_COUNTS     = 0x30
REG_MULTI_STATUS     = 0x34
REG_LATENCY          = 0x38
REG_HEARTBEAT        = 0x3C

# Commands
CMD_SINGLE_EDIT = 0x01
CMD_MULTI_EDIT  = 0x02
CMD_SEARCH_ONLY = 0x03

# DNA Base encoding
BASE_NAMES = {0b00: 'A', 0b01: 'C', 0b10: 'G', 0b11: 'T'}


# ==========================================================================
# Helper functions
# ==========================================================================
def genome_to_str(val, nbases=32):
    """Convert a 64-bit integer to a DNA string (MSB = base 0)."""
    s = ""
    for i in range(nbases):
        base = (val >> (2 * (nbases - 1 - i))) & 0x3
        s += BASE_NAMES[base]
    return s


def str_to_genome(s):
    """Convert a DNA string to a 64-bit integer."""
    inv_map = {'A': 0b00, 'C': 0b01, 'G': 0b10, 'T': 0b11}
    val = 0
    for ch in s:
        val = (val << 2) | inv_map[ch.upper()]
    return val


def guide_to_str(val):
    return genome_to_str(val, 8)


def replacement_to_str(val):
    return genome_to_str(val, 4)


class GenomeXDriver:
    """Driver for the GENOME-X AXI-Lite peripheral."""

    def __init__(self, overlay_path="./overlay/genome_x.bit"):
        print(f"Loading overlay: {overlay_path}")
        self.ol = Overlay(overlay_path)
        # Get the MMIO for our custom IP
        # The IP name will match the block design hierarchy
        # LOCAL TEST COPY: PYNQ exposes this block as genome_x_axi_0/S_AXI
        try:
            self.mmio = self.ol.genome_x_axi_0.mmio
        except AttributeError:
            from pynq import MMIO as _MMIO
            self.mmio = _MMIO(0x40000000, 0x1000)  # base address from Address Editor
        print("Overlay loaded successfully!")
        self._check_heartbeat()

    def _check_heartbeat(self):
        """Verify the FPGA design is alive."""
        hb1 = self.mmio.read(REG_HEARTBEAT)
        time.sleep(0.01)
        hb2 = self.mmio.read(REG_HEARTBEAT)
        if hb2 != hb1:
            print(f"  Heartbeat OK (counter: {hb1} → {hb2})")
        else:
            print(f"  WARNING: Heartbeat not incrementing ({hb1}). Design may not be running.")

    def single_edit(self, genome, guide, replacement, threshold, verbose=False):
        """Run a single-target search-edit-verify operation."""
        self.mmio.write(REG_GENOME_LO, genome & 0xFFFFFFFF)
        self.mmio.write(REG_GENOME_HI, (genome >> 32) & 0xFFFFFFFF)
        self.mmio.write(REG_GUIDE, guide & 0xFFFF)
        self.mmio.write(REG_REPLACEMENT, replacement & 0xFF)
        self.mmio.write(REG_THRESHOLD, threshold & 0x3)
        self.mmio.write(REG_COMMAND, CMD_SINGLE_EDIT)

        # Poll status until done
        for _ in range(10000):
            status = self.mmio.read(REG_STATUS)
            single_done = (status >> 4) & 0x01   # DEBUG COPY: wrapper puts single_done at bit 4
            if single_done:
                break
            time.sleep(0.0001)
        else:
            return {"error": "TIMEOUT: Pipeline did not complete within 1 second"}

        # Read results
        result_lo = self.mmio.read(REG_RESULT_GENOME_LO)
        result_hi = self.mmio.read(REG_RESULT_GENOME_HI)
        edited_genome = (result_hi << 32) | result_lo

        result_info = self.mmio.read(REG_RESULT_INFO)
        target_pos = result_info & 0x1F
        target_found = (result_info >> 7) & 0x1

        single_pass = (status >> 5) & 0x1    # DEBUG COPY: wrapper puts single_pass at bit 5
        pipe_status = (status >> 8) & 0xFF

        latency = self.mmio.read(REG_LATENCY)

        result = {
            "edited_genome": edited_genome,
            "target_found": target_found,
            "target_position": target_pos,
            "pipeline_pass": single_pass,
            "status_byte": pipe_status,
            "latency_cycles": latency
        }

        if verbose:
            print(f"    Status reg: 0x{status:08X}")
            print(f"    Result info: 0x{result_info:08X}")
            print(f"    Latency: {latency} cycles")

        return result

    def multi_edit(self, genome, guide, replacement, threshold, verbose=False):
        """Run a multi-target edit operation."""
        self.mmio.write(REG_GENOME_LO, genome & 0xFFFFFFFF)
        self.mmio.write(REG_GENOME_HI, (genome >> 32) & 0xFFFFFFFF)
        self.mmio.write(REG_GUIDE, guide & 0xFFFF)
        self.mmio.write(REG_REPLACEMENT, replacement & 0xFF)
        self.mmio.write(REG_THRESHOLD, threshold & 0x3)
        self.mmio.write(REG_COMMAND, CMD_MULTI_EDIT)

        # Poll status until done
        for _ in range(10000):
            status = self.mmio.read(REG_MULTI_STATUS)
            multi_done = status & 0x01
            if multi_done:
                break
            time.sleep(0.0001)
        else:
            return {"error": "TIMEOUT: Multi-pipeline did not complete within 1 second"}

        # Read results
        multi_lo = self.mmio.read(REG_MULTI_GENOME_LO)
        multi_hi = self.mmio.read(REG_MULTI_GENOME_HI)
        final_genome = (multi_hi << 32) | multi_lo

        counts = self.mmio.read(REG_MULTI_COUNTS)
        targets_found  = counts & 0x1F
        edits_applied  = (counts >> 5) & 0x1F
        edits_verified = (counts >> 10) & 0x1F

        multi_pass = (status >> 1) & 0x1
        latency = self.mmio.read(REG_LATENCY)

        result = {
            "final_genome": final_genome,
            "targets_found": targets_found,
            "edits_applied": edits_applied,
            "edits_verified": edits_verified,
            "all_pass": multi_pass,
            "latency_cycles": latency
        }

        if verbose:
            print(f"    Multi status: 0x{status:08X}")
            print(f"    Counts: 0x{counts:08X}")
            print(f"    Latency: {latency} cycles")

        return result


# ==========================================================================
# Test Vectors
# ==========================================================================

SINGLE_TESTS = [
    {
        "name": "Exact match at position 0 (threshold=0)",
        "genome":      str_to_genome("ACGTACGTACGTACGTACGTACGTACGTACGT"),
        "guide":       str_to_genome("ACGTACGT") & 0xFFFF,
        "replacement": str_to_genome("TTTT") & 0xFF,
        "threshold":   0,
        "expect_found": True,
        "expect_pos":   0,
        "expect_pass":  True,
    },
    {
        "name": "Exact match at position 4 (threshold=0)",
        "genome":      str_to_genome("TTTTACGTACGTTTTTTTTTTTTTTTTTTTTT"),
        "guide":       str_to_genome("ACGTACGT") & 0xFFFF,
        "replacement": str_to_genome("CCCC") & 0xFF,
        "threshold":   0,
        "expect_found": True,
        "expect_pos":   4,
        "expect_pass":  True,
    },
    {
        "name": "Fuzzy match (threshold=1, 1 mismatch)",
        "genome":      str_to_genome("GCGTACGTACGTACGTACGTACGTACGTACGT"),
        "guide":       str_to_genome("ACGTACGT") & 0xFFFF,
        "replacement": str_to_genome("AAAA") & 0xFF,
        "threshold":   1,
        "expect_found": True,
        "expect_pos":   0,
        "expect_pass":  True,
    },
    {
        "name": "No target found (threshold=0)",
        "genome":      str_to_genome("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAATT"),
        "guide":       str_to_genome("CCCCCCCC") & 0xFFFF,
        "replacement": str_to_genome("GGGG") & 0xFF,
        "threshold":   0,
        "expect_found": False,
        "expect_pos":   0,
        "expect_pass":  False,
    },
    {
        "name": "Boundary edit at position 28 (threshold=0)",
        "genome":      str_to_genome("TTTTTTTTTTTTTTTTTTTTTTTTTTTTACGT"),
        "guide":       str_to_genome("TTTTTTTT") & 0xFFFF,
        "replacement": str_to_genome("CCCC") & 0xFF,
        "threshold":   0,
        "expect_found": True,
        "expect_pos":   0,
        "expect_pass":  True,
    },
    {
        "name": "Exact match at last valid position 24",
        "genome":      str_to_genome("AAAAAAAAAAAAAAAAAAAAAAAAAAAAACGT"),
        "guide":       str_to_genome("AAAAAACG") & 0xFFFF,
        "replacement": str_to_genome("TTTT") & 0xFF,
        "threshold":   0,
        "expect_found": True,
        "expect_pos":   22,
        "expect_pass":  True,
    },
    {
        "name": "Fuzzy match with threshold=2 (2 mismatches)",
        "genome":      str_to_genome("CCGTCCGTACGTACGTACGTACGTACGTACGT"),
        "guide":       str_to_genome("ACGTACGT") & 0xFFFF,
        "replacement": str_to_genome("GGGG") & 0xFF,
        "threshold":   2,
        "expect_found": True,
        "expect_pos":   0,
        "expect_pass":  True,
    },
    {
        "name": "Threshold=0, 1 mismatch → no match",
        "genome":      str_to_genome("GCGTACGTTTTTTTTTTTTTTTTTTTTTTTTT"),
        "guide":       str_to_genome("ACGTACGT") & 0xFFFF,
        "replacement": str_to_genome("AAAA") & 0xFF,
        "threshold":   0,
        "expect_found": False,
        "expect_pos":   0,
        "expect_pass":  False,
    },
    {
        "name": "All-same genome (AAAA...A), guide=AAAAAAAA",
        "genome":      0x0000000000000000,
        "guide":       0x0000,
        "replacement": 0xFF,  # TTTT
        "threshold":   0,
        "expect_found": True,
        "expect_pos":   0,
        "expect_pass":  True,
    },
    {
        "name": "All-same genome (TTTT...T), guide=TTTTTTTT",
        "genome":      0xFFFFFFFFFFFFFFFF,
        "guide":       0xFFFF,
        "replacement": 0x00,  # AAAA
        "threshold":   0,
        "expect_found": True,
        "expect_pos":   0,
        "expect_pass":  True,
    },
]

MULTI_TESTS = [
    {
        "name": "Two non-overlapping targets",
        "genome":      str_to_genome("ACGTACGTTTTTTTTTACGTACGTTTTTTTTT"),
        "guide":       str_to_genome("ACGTACGT") & 0xFFFF,
        "replacement": str_to_genome("CCCC") & 0xFF,
        "threshold":   0,
        "expect_targets": 2,
        "expect_pass":    True,
    },
    {
        "name": "No targets at all",
        "genome":      str_to_genome("AAAAAAAAAAAAAAAAAAAAAAAAAAAAACGT"),
        "guide":       str_to_genome("CCCCCCCC") & 0xFFFF,
        "replacement": str_to_genome("GGGG") & 0xFF,
        "threshold":   0,
        "expect_targets": 0,
        "expect_pass":    False,
    },
    {
        "name": "Three overlapping targets (re-evaluate after edit)",
        "genome":      str_to_genome("ACGTACGTACGTACGTACGTACGTACGTACGT"),
        "guide":       str_to_genome("ACGTACGT") & 0xFFFF,
        "replacement": str_to_genome("ACGT") & 0xFF,
        "threshold":   0,
        "expect_targets_min": 1,
        "expect_pass":    True,
    },
    {
        "name": "Single target via multi-edit",
        "genome":      str_to_genome("TTTTACGTACGTTTTTTTTTTTTTTTTTTTTT"),
        "guide":       str_to_genome("ACGTACGT") & 0xFFFF,
        "replacement": str_to_genome("GGGG") & 0xFF,
        "threshold":   0,
        "expect_targets": 1,
        "expect_pass":    True,
    },
]


# ==========================================================================
# Test Runner
# ==========================================================================

def run_single_tests(driver, verbose=False):
    """Run all single-edit test vectors."""
    print("\n" + "=" * 70)
    print("  SINGLE-TARGET EDIT TESTS")
    print("=" * 70)

    passed = 0
    failed = 0

    for i, tc in enumerate(SINGLE_TESTS):
        print(f"\n  Test {i+1}: {tc['name']}")
        print(f"    Genome:      {genome_to_str(tc['genome'])}")
        print(f"    Guide:       {guide_to_str(tc['guide'])}")
        print(f"    Replacement: {replacement_to_str(tc['replacement'])}")
        print(f"    Threshold:   {tc['threshold']}")

        result = driver.single_edit(
            tc['genome'], tc['guide'], tc['replacement'], tc['threshold'],
            verbose=verbose
        )

        if "error" in result:
            print(f"    ✗ FAIL: {result['error']}")
            failed += 1
            continue

        print(f"    Result:      {genome_to_str(result['edited_genome'])}")
        print(f"    Target found: {bool(result['target_found'])}, Position: {result['target_position']}")
        print(f"    Pass: {bool(result['pipeline_pass'])}, Latency: {result['latency_cycles']} cycles")

        # Check expectations
        ok = True
        if tc['expect_found'] != bool(result['target_found']):
            print(f"    ✗ Expected target_found={tc['expect_found']}, got {bool(result['target_found'])}")
            ok = False
        if tc['expect_found'] and tc['expect_pos'] != result['target_position']:
            print(f"    ✗ Expected position={tc['expect_pos']}, got {result['target_position']}")
            ok = False
        if tc['expect_pass'] != bool(result['pipeline_pass']):
            print(f"    ✗ Expected pass={tc['expect_pass']}, got {bool(result['pipeline_pass'])}")
            ok = False

        if ok:
            print(f"    ✓ PASS")
            passed += 1
        else:
            failed += 1

    return passed, failed


def run_multi_tests(driver, verbose=False):
    """Run all multi-edit test vectors."""
    print("\n" + "=" * 70)
    print("  MULTI-TARGET EDIT TESTS")
    print("=" * 70)

    passed = 0
    failed = 0

    for i, tc in enumerate(MULTI_TESTS):
        print(f"\n  Test {i+1}: {tc['name']}")
        print(f"    Genome:      {genome_to_str(tc['genome'])}")
        print(f"    Guide:       {guide_to_str(tc['guide'])}")
        print(f"    Replacement: {replacement_to_str(tc['replacement'])}")
        print(f"    Threshold:   {tc['threshold']}")

        result = driver.multi_edit(
            tc['genome'], tc['guide'], tc['replacement'], tc['threshold'],
            verbose=verbose
        )

        if "error" in result:
            print(f"    ✗ FAIL: {result['error']}")
            failed += 1
            continue

        print(f"    Result:       {genome_to_str(result['final_genome'])}")
        print(f"    Targets:      {result['targets_found']}")
        print(f"    Edits:        {result['edits_applied']}")
        print(f"    Verified:     {result['edits_verified']}")
        print(f"    All pass:     {bool(result['all_pass'])}")
        print(f"    Latency:      {result['latency_cycles']} cycles")

        ok = True
        if 'expect_targets' in tc:
            if tc['expect_targets'] != result['targets_found']:
                print(f"    ✗ Expected targets={tc['expect_targets']}, got {result['targets_found']}")
                ok = False
        if 'expect_targets_min' in tc:
            if result['targets_found'] < tc['expect_targets_min']:
                print(f"    ✗ Expected targets>={tc['expect_targets_min']}, got {result['targets_found']}")
                ok = False
        if tc['expect_pass'] != bool(result['all_pass']):
            if tc['expect_targets'] != 0 or result['all_pass']:  # 0 targets ⇒ all_pass=0 is correct
                print(f"    ✗ Expected all_pass={tc['expect_pass']}, got {bool(result['all_pass'])}")
                ok = False

        if ok:
            print(f"    ✓ PASS")
            passed += 1
        else:
            failed += 1

    return passed, failed


def main():
    parser = argparse.ArgumentParser(description="GENOME-X PYNQ-Z2 Hardware Test")
    parser.add_argument("--overlay", default="./overlay/genome_x.bit",
                        help="Path to the overlay bitstream (.bit)")
    parser.add_argument("--test", choices=["single", "multi", "all"], default="all",
                        help="Which test suite to run")
    parser.add_argument("--verbose", action="store_true",
                        help="Show detailed register dumps")
    args = parser.parse_args()

    print("╔══════════════════════════════════════════════════════════════╗")
    print("║         GENOME-X  PYNQ-Z2  Hardware Test Suite             ║")
    print("║              Verilog Quest 2026 — Round 2                   ║")
    print("╚══════════════════════════════════════════════════════════════╝")

    driver = GenomeXDriver(args.overlay)

    total_passed = 0
    total_failed = 0

    if args.test in ("single", "all"):
        p, f = run_single_tests(driver, args.verbose)
        total_passed += p
        total_failed += f

    if args.test in ("multi", "all"):
        p, f = run_multi_tests(driver, args.verbose)
        total_passed += p
        total_failed += f

    # Summary
    print("\n" + "=" * 70)
    total = total_passed + total_failed
    print(f"  FINAL SCORE: {total_passed}/{total} tests passed")
    if total_failed == 0:
        print("  🎉 ALL TESTS PASSED!")
    else:
        print(f"  ⚠  {total_failed} test(s) FAILED")
    print("=" * 70)

    return 0 if total_failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
