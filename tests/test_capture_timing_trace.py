import csv
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

from tools import capture_timing_trace
from tools.capture_timing_trace import (
    TRACE_COLUMNS,
    manifest_relative,
    read_trace,
    validate_trace_rows,
)


def idle_row(cycle=0):
    row = {name: 0 for name in TRACE_COLUMNS}
    row.update({
        "schema_version": 1,
        "trace_valid": 1,
        "trace_cycle": cycle,
        "status": 15,
        "cpu_cycles": cycle,
        "queue_count": 0,
    })
    return row


def active_row(cycle=0, *, phase=1):
    row = idle_row(cycle)
    row.update({
        "phase": phase,
        "address": 0x0100,
        "status": 0xD,
        "lane_mask": 3,
        "owner": 1,
        "ready": int(phase == 2),
    })
    return row


def write_trace(path: Path, rows, header=TRACE_COLUMNS):
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        writer.writerow(header)
        for row in rows:
            writer.writerow([row[name] for name in header])


def fake_capture_run(command, *, env=None):
    if command[:2] == ["git", "status"]:
        return ""
    if command[:3] == ["git", "rev-parse", "HEAD"]:
        return "deadbeef"
    if command[:3] == ["git", "branch", "--show-current"]:
        return "test-branch"
    if command[:3] == ["bash", "scripts/test_units.sh", "iverilog"]:
        return "TIMING CAPTURE PASS"
    if command == ["iverilog", "-V"]:
        return "Icarus Verilog version 12.0"
    raise AssertionError(f"unexpected command: {command}")


class TimingTraceValidationTests(unittest.TestCase):
    def test_external_manifest_path_is_relative_to_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "capture" / "spk286_timing_capture.json"
            trace = root / "capture" / "spk286_timing_capture.csv"
            self.assertEqual(manifest_relative(trace, manifest), "spk286_timing_capture.csv")

    def test_rejects_incomplete_header(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.csv"
            write_trace(path, [idle_row()], TRACE_COLUMNS[:-1])
            with self.assertRaisesRegex(ValueError, "header mismatch"):
                read_trace(path)

    def test_rejects_negative_counters(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.csv"
            first = idle_row(0)
            second = idle_row(1)
            second["accepted_transfers"] = -1
            write_trace(path, [first, second])
            with self.assertRaisesRegex(ValueError, "negative"):
                read_trace(path)

    def test_rejects_non_contiguous_cycles(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.csv"
            write_trace(path, [idle_row(0), idle_row(2)])
            with self.assertRaisesRegex(ValueError, "not contiguous"):
                read_trace(path)

    def test_rejects_incoherent_bus_counter_delta(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.csv"
            first = idle_row(0)
            first.update({"phase": 1, "status": 13, "owner": 1, "lane_mask": 1})
            second = idle_row(1)
            write_trace(path, [first, second])
            with self.assertRaisesRegex(ValueError, "BIU busy"):
                read_trace(path)

    def test_rejects_status_owner_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.csv"
            row = active_row()
            row["owner"] = 3
            write_trace(path, [row])
            with self.assertRaisesRegex(ValueError, "expected 1"):
                read_trace(path)

    def test_rejects_odd_address_low_lane(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.csv"
            row = active_row()
            row["address"] = 0x0101
            row["lane_mask"] = 1
            write_trace(path, [row])
            with self.assertRaisesRegex(ValueError, "odd address"):
                read_trace(path)

    def test_enforces_complete_lane_parity_table(self):
        valid = {(0, 1), (0, 3), (1, 2)}
        for parity in (0, 1):
            for lane_mask in (0, 1, 2, 3):
                with self.subTest(parity=parity, lane_mask=lane_mask):
                    row = active_row()
                    row["address"] = 0x0100 | parity
                    row["lane_mask"] = lane_mask
                    if (parity, lane_mask) in valid:
                        validate_trace_rows([row])
                    else:
                        with self.assertRaises(ValueError):
                            validate_trace_rows([row])

    def test_rejects_nonzero_idle_data(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.csv"
            row = idle_row()
            row["data"] = 0x1234
            write_trace(path, [row])
            with self.assertRaisesRegex(ValueError, "idle bus fields"):
                read_trace(path)

    def test_rejects_event_counter_jump(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.csv"
            first = idle_row(0)
            second = idle_row(1)
            # The preceding sample establishes a valid zero increment; a
            # jump of two is impossible for one sampled edge.
            third = idle_row(2)
            third["operand_wait_cycles"] = 2
            write_trace(path, [first, second, third])
            with self.assertRaisesRegex(ValueError, "increments by 2"):
                read_trace(path)

    def test_rejects_baseline_compatibility_delay(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.csv"
            row = idle_row()
            row["compatibility_delay_cycles"] = 1
            write_trace(path, [row])
            with self.assertRaisesRegex(ValueError, "compatibility delay"):
                read_trace(path)

    def test_rejects_counter_wider_than_64_bits(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.csv"
            row = idle_row()
            row["trace_cycle"] = 1 << 64
            row["cpu_cycles"] = 1 << 64
            write_trace(path, [row])
            with self.assertRaisesRegex(ValueError, "exceeds 64 bits"):
                read_trace(path)

    def test_rejects_transaction_identity_change_during_ready_wait(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.csv"
            first = active_row(0, phase=1)
            second = active_row(1, phase=2)
            second["status"] = 6
            second["owner"] = 2
            second["ready"] = 1
            second["biu_busy_cycles"] = 1
            second["ready_wait_cycles"] = 1
            write_trace(path, [first, second])
            with self.assertRaisesRegex(ValueError, "transaction status"):
                read_trace(path)

    def test_rejects_ready_wait_disappearing_to_idle(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.csv"
            first = active_row(0, phase=1)
            second = idle_row(1)
            second["biu_busy_cycles"] = 1
            second["ready_wait_cycles"] = 1
            write_trace(path, [first, second])
            with self.assertRaisesRegex(ValueError, "disappears before completion"):
                read_trace(path)

    def test_rejects_write_data_change_during_ready_wait(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.csv"
            first = active_row(0, phase=1)
            first.update({"status": 6, "owner": 2, "write": 1, "data": 0x1234})
            second = active_row(1, phase=1)
            second.update({"status": 6, "owner": 2, "write": 1, "data": 0x5678})
            second["biu_busy_cycles"] = 1
            second["ready_wait_cycles"] = 1
            write_trace(path, [first, second])
            with self.assertRaisesRegex(ValueError, "write data"):
                read_trace(path)

    def test_rejects_write_data_change_at_ready_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.csv"
            first = active_row(0, phase=1)
            first.update({"status": 6, "owner": 2, "write": 1, "data": 0x1234})
            second = active_row(1, phase=2)
            second.update({"status": 6, "owner": 2, "write": 1, "data": 0x5678})
            second["biu_busy_cycles"] = 1
            second["ready_wait_cycles"] = 1
            write_trace(path, [first, second])
            with self.assertRaisesRegex(ValueError, "write data"):
                read_trace(path)

    def test_accepts_read_data_change_before_ready(self):
        first = active_row(0, phase=1)
        first.update({"data": 0x1234})
        second = active_row(1, phase=2)
        second.update({"data": 0x5678})
        second["biu_busy_cycles"] = 1
        second["ready_wait_cycles"] = 1
        validate_trace_rows([first, second])

    def test_accepts_new_identity_after_completed_transfer(self):
        first = active_row(0, phase=2)
        second = active_row(1, phase=1)
        second.update({"address": 0x0200, "status": 6, "owner": 2})
        second["biu_busy_cycles"] = 1
        second["accepted_transfers"] = 1
        validate_trace_rows([first, second])

    def test_accepts_capture_ending_during_ready_wait(self):
        validate_trace_rows([active_row(0, phase=1)])

    def test_main_does_not_publish_rejected_capture(self):
        self.assert_main_rejects([dict(idle_row(), data=0x1234)], "idle bus fields")

    def assert_main_rejects(self, rows, message):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            timing = root / "timing"
            timing.mkdir()
            trace = timing / "spk286_timing_capture.csv"
            write_trace(trace, rows)

            argv = [
                "capture_timing_trace.py", "--simulator", "iverilog",
                "--build-dir", str(root),
            ]
            with mock.patch.object(capture_timing_trace, "run", side_effect=fake_capture_run):
                with mock.patch.object(sys, "argv", argv):
                    with self.assertRaisesRegex(ValueError, message):
                        capture_timing_trace.main()
            self.assertFalse((timing / "spk286_timing_capture.json").exists())

    def test_main_rejects_remaining_h4_invalid_traces(self):
        disappearing_first = active_row(0, phase=1)
        disappearing_second = idle_row(1)
        disappearing_second["biu_busy_cycles"] = 1
        disappearing_second["ready_wait_cycles"] = 1

        write_first = active_row(0, phase=1)
        write_first.update({"status": 6, "owner": 2, "write": 1, "data": 0x1234})
        write_second = active_row(1, phase=2)
        write_second.update({"status": 6, "owner": 2, "write": 1, "data": 0x5678})
        write_second["biu_busy_cycles"] = 1
        write_second["ready_wait_cycles"] = 1

        even_bad = active_row()
        even_bad["lane_mask"] = 2
        for rows, message in (
            ([disappearing_first, disappearing_second], "disappears before completion"),
            ([write_first, write_second], "write data"),
            ([even_bad], "even address"),
        ):
            with self.subTest(message=message):
                self.assert_main_rejects(rows, message)


if __name__ == "__main__":
    unittest.main()
