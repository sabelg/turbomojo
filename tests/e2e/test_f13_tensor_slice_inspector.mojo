"""E2E Test Suite for Feature #13: Interactive Tensor & Memory Slice Inspector.
Covers:
- 5 Tier 1 (Isolated Happy Path) tests
- 5 Tier 2 (Boundary Value Analysis & Corner Cases) tests
Strictly conforming to Mojo 1.2 rules.
"""
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from std.collections import List
from std.memory import bitcast
from std.math import isnan, isinf
from cpuview import (
    SIMD_HEX32, SIMD_F32, SIMD_I32, SIMD_F16, SIMD_BF16,
    base64_decode, format_simd_half_lanes, render_tensor_2d_slice,
    SliceStats, calculate_slice_stats_f32, TensorSliceNavigator, render_unaligned_memory_slice,
)
from dbgview import base64, encode_value, encode_tensor_value, build_dap_write_memory_request


# ===========================================================================
# Tier 1: Happy Path Tests (5 tests)
# ===========================================================================

def test_f13_tier1_01_ieee754_f16_encode_decode_roundtrip() raises:
    """Verify IEEE-754 half-precision float (f16) encode and decode accuracy."""
    # Test vector values
    var v1 = Float16(1.5)
    var u1 = bitcast[DType.uint16](v1)
    assert_equal(u1, 0x3E00, "Float16(1.5) bitcast mismatch")

    var v2 = Float16(-2.0)
    var u2 = bitcast[DType.uint16](v2)
    assert_equal(u2, 0xC000, "Float16(-2.0) bitcast mismatch")

    var v3 = Float16(0.0)
    assert_equal(bitcast[DType.uint16](v3), 0x0000)

    var v4 = Float16(-1.0)
    assert_equal(bitcast[DType.uint16](v4), 0xBC00)

    # Fractional precision roundtrip
    var test_val = Float16(-2.5)
    var u_val = bitcast[DType.uint16](test_val)
    var dec = bitcast[DType.float16](u_val)
    assert_equal(Float64(dec), -2.5)


def test_f13_tier1_02_bfloat16_encode_decode_roundtrip() raises:
    """Verify Google BFloat16 (bf16) truncated float representation roundtrip."""
    var bf1 = BFloat16(2.5)
    var u1 = bitcast[DType.uint16](bf1)
    assert_equal(u1, 0x4020, "BFloat16(2.5) bitcast mismatch")

    # BFloat16 shares the 8-bit exponent of Float32, preserving dynamic range
    var large_val = BFloat16(1.0e20)
    assert_false(isinf(large_val), "BFloat16(1e20) should not overflow to Inf")

    var dec1 = bitcast[DType.bfloat16](u1)
    assert_equal(Float64(dec1), 2.5)


def test_f13_tier1_03_encode_value_supports_f16_and_bf16() raises:
    """Verify encode_value successfully encodes f16 and bf16 scalars into 2 bytes."""
    # 1. Float16 scalar: 1.5 -> 0x3E00 (LE: [0x00, 0x3E])
    var r1 = encode_tensor_value("__mlir_type.`!kgen.scalar<f16>`", "1.5")
    assert_equal(r1[1], "")
    assert_equal(len(r1[0]), 2)
    assert_equal(r1[0][0], 0x00)
    assert_equal(r1[0][1], 0x3E)

    # 2. BFloat16 scalar: 2.5 -> 0x4020 (LE: [0x20, 0x40])
    var r2 = encode_tensor_value("__mlir_type.`!kgen.scalar<bf16>`", "2.5")
    assert_equal(r2[1], "")
    assert_equal(len(r2[0]), 2)
    assert_equal(r2[0][0], 0x20)
    assert_equal(r2[0][1], 0x40)


def test_f13_tier1_04_simd_lane_cycling_f16_and_bf16() raises:
    """Verify format_simd_half_lanes formats 128-bit vector as 8 half-precision lanes."""
    var raw = List[UInt8]()
    for i in range(1, 9):
        var hf = Float16(Float64(i))
        var u16 = bitcast[DType.uint16](hf)
        raw.append(UInt8(u16 & 0xFF))
        raw.append(UInt8((u16 >> 8) & 0xFF))

    assert_equal(len(raw), 16)
    var res = format_simd_half_lanes(raw, SIMD_F16)
    assert_equal(res[1], 8, "Expected 8 SIMD lanes for half-precision")
    assert_true(res[0].startswith("[1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]"))


def test_f13_tier1_05_tensor_slice_2d_stride_formatting() raises:
    """Verify memory inspector renders a 2D matrix slice with configurable row stride."""
    var data = List[Float32]()
    for i in range(16):
        data.append(Float32(i))

    # 4x4 matrix with stride = 4
    var lines = render_tensor_2d_slice(data, stride=4, rows=4)
    assert_equal(len(lines), 4)

    assert_true(lines[0].startswith("[0, :]"))
    assert_true(lines[0].find("0.0") >= 0 and lines[0].find("3.0") >= 0)

    assert_true(lines[1].startswith("[1, :]"))
    assert_true(lines[1].find("4.0") >= 0 and lines[1].find("7.0") >= 0)

    assert_true(lines[2].startswith("[2, :]"))
    assert_true(lines[2].find("8.0") >= 0 and lines[2].find("11.0") >= 0)

    assert_true(lines[3].startswith("[3, :]"))
    assert_true(lines[3].find("12.0") >= 0 and lines[3].find("15.0") >= 0)


# ===========================================================================
# Tier 2: Boundary & Corner Cases Tests (5 tests)
# ===========================================================================

def test_f13_tier2_06_special_ieee754_values_nan_inf_detection() raises:
    """Verify IEEE-754 special values (+Inf, -Inf, quiet NaN, signaling NaN) are flagged."""
    var p_inf = bitcast[DType.float16](UInt16(0x7C00))
    assert_true(isinf(p_inf))
    assert_true(Float64(p_inf) > 0.0)

    var n_inf = bitcast[DType.float16](UInt16(0xFC00))
    assert_true(isinf(n_inf))
    assert_true(Float64(n_inf) < 0.0)

    var q_nan = bitcast[DType.float16](UInt16(0x7E00))
    assert_true(isnan(q_nan))

    var s_nan = bitcast[DType.float16](UInt16(0x7C01))
    assert_true(isnan(s_nan))

    # Bitcast preserves payload
    assert_equal(bitcast[DType.uint16](q_nan), 0x7E00)
    assert_equal(bitcast[DType.uint16](s_nan), 0x7C01)


def test_f13_tier2_07_slice_statistics_min_max_mean_and_nan_count() raises:
    """Verify calculate_slice_stats computes accurate min, max, mean, and NaN/Inf counts."""
    var slice_data = List[Float32]()
    slice_data.append(Float32(10.0))
    slice_data.append(Float32(-5.0))
    slice_data.append(Float32(25.0))
    slice_data.append(bitcast[DType.float32](UInt32(0x7FC00000))) # NaN
    slice_data.append(bitcast[DType.float32](UInt32(0x7F800000))) # +Inf
    slice_data.append(bitcast[DType.float32](UInt32(0xFF800000))) # -Inf
    slice_data.append(Float32(0.0))
    slice_data.append(bitcast[DType.float32](UInt32(0x7FA00000))) # NaN

    var stats = calculate_slice_stats_f32(slice_data)
    assert_equal(stats.min_val, -5.0)
    assert_equal(stats.max_val, 25.0)
    assert_equal(stats.nan_count, 2)
    assert_equal(stats.inf_count, 2)
    assert_equal(stats.valid_count, 4)
    # Mean of [10.0, -5.0, 25.0, 0.0] = 30.0 / 4.0 = 7.5
    assert_equal(stats.mean_val, 7.5)


def test_f13_tier2_08_paged_slice_navigation_bracket_keys() raises:
    """Verify bracket keys navigate forward/backward by slice page and clamp at 0."""
    var nav = TensorSliceNavigator(0x1000, 256)
    assert_equal(nav.mem_address, 0x1000)

    # Press ']' (next page)
    nav.next_page()
    assert_equal(nav.mem_address, 0x1100)

    # Press '[' twice (previous page)
    nav.prev_page()
    assert_equal(nav.mem_address, 0x1000)
    nav.prev_page()
    assert_equal(nav.mem_address, 0x0F00)

    # Near address 0: underflow clamp test
    var nav_zero = TensorSliceNavigator(0x0080, 256)
    nav_zero.prev_page()
    # Clamps cleanly at 0 without underflow
    assert_equal(nav_zero.mem_address, 0)


def test_f13_tier2_09_write_memory_inline_edit_dap_payload() raises:
    """Verify inline editing creates valid DAP writeMemory JSON with base64 payload."""
    var base_addr = 0x2000
    var elem_idx = 3 # Offset: 3 * 2 = 6 bytes -> address 0x2006
    var target_addr = base_addr + elem_idx * 2

    # Encode Float16(4.5) -> 0x4480 -> LE bytes [0x80, 0x44]
    var enc = encode_tensor_value("Float16", "4.5")
    assert_equal(enc[1], "")
    assert_equal(len(enc[0]), 2)
    assert_equal(enc[0][0], 0x80)
    assert_equal(enc[0][1], 0x44)

    var dap_req = build_dap_write_memory_request(target_addr, enc[0])
    assert_true(dap_req.find('"command":"writeMemory"') >= 0)
    assert_true(dap_req.find('"memoryReference":"0x0000000000002006"') >= 0)
    
    # Verify base64 decodes back to original bytes
    var decoded = base64_decode(base64(enc[0]))
    assert_equal(len(decoded), 2)
    assert_equal(decoded[0], 0x80)
    assert_equal(decoded[1], 0x44)


def test_f13_tier2_10_unaligned_memory_and_partial_unreadable_bytes() raises:
    """Verify inspector handles unaligned addresses and partial unreadable bytes."""
    var unaligned_addr = 0x1001 # Odd byte boundary
    var bytes_data = List[UInt8]()
    
    # 128 total bytes: 120 readable, 8 unreadable
    for i in range(120):
        bytes_data.append(UInt8(i % 256))
    for _ in range(8):
        bytes_data.append(0)

    var lines = render_unaligned_memory_slice(unaligned_addr, bytes_data, readable_count=120)
    assert_true(len(lines) > 0, "No lines rendered for unaligned memory")
    
    # First row is fully readable
    assert_true(lines[0].find("??") < 0)
    
    # Last row contains unreadable bytes marked with ??
    var last_idx = len(lines) - 1
    assert_true(lines[last_idx].find("??") >= 0, "Expected ?? for unreadable bytes: " + lines[last_idx])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
