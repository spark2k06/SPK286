import csv
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools import capture_timing_calibration
from tools.capture_timing_calibration import (
    CALIBRATION_CASES,
    CALIBRATION_COLUMNS,
    EXPECTED_FINAL_BUS,
    EXPECTED_FINAL_FLAGS,
    read_calibration,
    validate_calibration,
    validate_simulator_captures,
)


FIXTURES = Path(__file__).parent / "fixtures" / "phase9b"


def calibration_rows():
    rows = []
    for case, start_ip, end_ip in CALIBRATION_CASES:
        rows.append({
            "policy": 0,
            "case": case,
            "start_ip": start_ip,
            "end_ip": end_ip,
            "final_flags": EXPECTED_FINAL_FLAGS[case],
            "cycles": 4,
            "biu_busy_cycles": 1,
            "accepted_transfers": 1,
            "ready_wait_cycles": 0,
            "prefetch_requests": 1,
            "prefetch_responses": 0,
            "queue_consumes": 1,
            "operand_wait_cycles": 1 if case in {"mov_mem_read", "mov_mem_write", "odd_word_read"} else 0,
            "saw_lock": 0,
            "final_phase": EXPECTED_FINAL_BUS[case][0],
            "final_status": EXPECTED_FINAL_BUS[case][1],
            "final_owner": EXPECTED_FINAL_BUS[case][2],
        })
    return rows


class TimingCalibrationTests(unittest.TestCase):
    def test_immediate_mov_can_end_with_next_code_request(self):
        rows = calibration_rows()
        rows[1].update(cycles=3, prefetch_responses=1, queue_consumes=2,
                       final_phase=1, final_status=13, final_owner=1)
        validate_calibration(rows)
        for field, value in (('final_owner', 2), ('final_status', 5),
                             ('accepted_transfers', 0), ('operand_wait_cycles', 1)):
            invalid = [dict(row) for row in rows]
            invalid[1][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_calibration(invalid)

    def test_prefetched_register_alu_needs_no_bus_transfer(self):
        rows = calibration_rows()
        rows[2].update(cycles=2, biu_busy_cycles=0, accepted_transfers=0,
                       prefetch_requests=0, prefetch_responses=1,
                       final_phase=1, final_status=13, final_owner=1)
        validate_calibration(rows)
        for field, value in (('cycles', 0), ('final_owner', 2), ('final_status', 5),
                             ('biu_busy_cycles', 1), ('operand_wait_cycles', 1)):
            invalid = [dict(row) for row in rows]
            invalid[2][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_calibration(invalid)

    def test_accepts_complete_normalized_baseline(self):
        rows = calibration_rows()
        for row in rows:
            if row["case"] in {"near_ret", "rep_movsb"}:
                row["queue_consumes"] = 0
        validate_calibration(rows)

    def test_accepts_complete_normalized_baseline_with_all_rows(self):
        validate_calibration(calibration_rows())

    def test_rejects_wrong_case_order(self):
        rows = calibration_rows()
        rows[0]["case"] = "wrong"
        with self.assertRaisesRegex(ValueError, "expected case order"):
            validate_calibration(rows)

    def test_rejects_ready_wait_in_baseline(self):
        rows = calibration_rows()
        rows[0]["ready_wait_cycles"] = 1
        with self.assertRaisesRegex(ValueError, "READY waits"):
            validate_calibration(rows)

    def test_accepts_biu_busy_partition(self):
        # The normalized calibration workload has no READY waits, so its
        # positive control is the accepted-transfer-only partition.
        validate_calibration(calibration_rows())

    def test_rejects_biu_busy_partition_mismatch(self):
        rows = calibration_rows()
        rows[0]["biu_busy_cycles"] = 2
        rows[0]["accepted_transfers"] = 1
        rows[0]["ready_wait_cycles"] = 0
        with self.assertRaisesRegex(ValueError, "BIU busy counter is inconsistent"):
            validate_calibration(rows)

    def test_requires_memory_operand_observation(self):
        rows = calibration_rows()
        rows[3]["operand_wait_cycles"] = 0
        with self.assertRaisesRegex(ValueError, "memory baseline"):
            validate_calibration(rows)

    def test_rejects_dependency_counter_longer_than_interval(self):
        rows = calibration_rows()
        rows[0]["biu_busy_cycles"] = rows[0]["cycles"] + 1
        with self.assertRaisesRegex(ValueError, "exceeds elapsed cycles"):
            validate_calibration(rows)

    def test_rejects_out_of_range_instruction_ip(self):
        rows = calibration_rows()
        rows[0]["start_ip"] = 0x10000
        with self.assertRaisesRegex(ValueError, "outside 16 bits"):
            validate_calibration(rows)

    def test_rejects_add_flags_mismatch(self):
        rows = calibration_rows()
        rows[2]["final_flags"] = 0x0002
        with self.assertRaisesRegex(ValueError, "FLAGS do not match alu_reg"):
            validate_calibration(rows)

    def test_rejects_incoherent_terminal_bus_fields(self):
        rows = calibration_rows()
        rows[5]["final_phase"] = 0
        with self.assertRaisesRegex(ValueError, "final bus fields"):
            validate_calibration(rows)

    def test_rejects_lock_marker_in_these_classes(self):
        rows = calibration_rows()
        rows[0]["saw_lock"] = 1
        with self.assertRaisesRegex(ValueError, "LOCK marker"):
            validate_calibration(rows)

    def test_rejects_counter_above_published_width(self):
        rows = calibration_rows()
        rows[0]["prefetch_requests"] = (1 << 64)
        with self.assertRaisesRegex(ValueError, "exceeds 64 bits"):
            validate_calibration(rows)

    def test_rejects_counter_above_elapsed_cycles(self):
        rows = calibration_rows()
        rows[0]["prefetch_responses"] = rows[0]["cycles"] + 1
        with self.assertRaisesRegex(ValueError, "exceeds elapsed cycles"):
            validate_calibration(rows)

    def test_identical_simulator_records_are_each_validated(self):
        rows = calibration_rows()
        rows[2]["final_flags"] = 0x0002
        with self.assertRaisesRegex(ValueError, "FLAGS do not match alu_reg"):
            validate_simulator_captures({"verilator": rows, "iverilog": rows})

    def test_read_calibration_rejects_extra_csv_fields(self):
        for extra_value in ("", "unexpected"):
            with self.subTest(extra_value=extra_value), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "invalid.csv"
                rows = calibration_rows()
                with path.open("w", newline="", encoding="utf-8") as stream:
                    writer = csv.writer(stream)
                    writer.writerow(CALIBRATION_COLUMNS)
                    for index, row in enumerate(rows):
                        values = [row[column] for column in CALIBRATION_COLUMNS]
                        if index == 0:
                            values.append(extra_value)
                        writer.writerow(values)
                with self.assertRaisesRegex(ValueError, "has 18 fields"):
                    read_calibration(path)

    @staticmethod
    def read_fixture(name):
        with (FIXTURES / name).open(newline="", encoding="utf-8") as stream:
            reader = csv.DictReader(stream)
            if reader.fieldnames != list(CALIBRATION_COLUMNS):
                raise AssertionError(f"fixture schema mismatch: {name}")
            rows = []
            for fields in reader:
                row = {"case": fields["case"]}
                row.update({
                    key: int(fields[key], 10)
                    for key in CALIBRATION_COLUMNS
                    if key != "case"
                })
                rows.append(row)
            return rows

    def test_main_rejects_each_preserved_negative_fixture_when_simulators_agree(self):
        for fixture in (
            "b2_add_flags_mismatch.csv",
            "b3_terminal_bus_mismatch.csv",
            "b3_counter_exceeds_interval.csv",
        ):
            with self.subTest(fixture=fixture), tempfile.TemporaryDirectory() as directory:
                rows = self.read_fixture(fixture)
                with mock.patch.object(capture_timing_calibration, "git_status", return_value=""):
                    with self.assertRaises(ValueError):
                        capture_timing_calibration.main(
                            ["--simulator", "both", "--build-dir", directory],
                            simulator_rows_override={"verilator": rows, "iverilog": rows},
                        )
                self.assertFalse(
                    (Path(directory) / "timing" / "spk286_timing_calibration.json").exists()
                )

    def test_main_rejects_identical_biu_partition_invalid_simulators(self):
        rows = calibration_rows()
        rows[0]["biu_busy_cycles"] = 2
        rows[0]["accepted_transfers"] = 1
        rows[0]["ready_wait_cycles"] = 0
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(capture_timing_calibration, "git_status", return_value=""):
                with self.assertRaisesRegex(ValueError, "BIU busy counter is inconsistent"):
                    capture_timing_calibration.main(
                        ["--simulator", "both", "--build-dir", directory],
                        simulator_rows_override={"verilator": rows, "iverilog": rows},
                    )
            self.assertFalse(
                (Path(directory) / "timing" / "spk286_timing_calibration.json").exists()
            )

    @staticmethod
    def write_calibration(path, rows):
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=CALIBRATION_COLUMNS)
            writer.writeheader()
            writer.writerows(rows)

    def run_evidence_scenario(self, simulator_mode):
        rows = calibration_rows()
        for row in rows:
            if row["case"] in {"near_ret", "rep_movsb"}:
                row["queue_consumes"] = 0
        raw_paths = {}

        def fake_capture(simulator, capture_build_dir):
            baseline_path = capture_build_dir / "timing" / "spk286_timing_calibration.csv"
            extra_path = capture_build_dir / "timing" / "spk286_timing_calibration_extra.csv"
            self.write_calibration(baseline_path, rows[:6])
            self.write_calibration(extra_path, rows[6:])
            raw_paths[simulator] = (baseline_path, extra_path)
            return [baseline_path, extra_path]

        def fake_run(command, *, env=None):
            if command[:2] == ["git", "rev-parse"]:
                return "test-revision"
            if command[:2] == ["git", "branch"]:
                return "codex/test"
            return "Verilator 5.020 test"

        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(capture_timing_calibration, "git_status", return_value=""), \
                 mock.patch.object(capture_timing_calibration, "run", side_effect=fake_run), \
                 mock.patch.object(capture_timing_calibration, "capture_simulator", side_effect=fake_capture):
                self.assertEqual(
                    capture_timing_calibration.main(
                        ["--simulator", simulator_mode, "--build-dir", directory]
                    ),
                    0,
                )
            for simulator, paths in raw_paths.items():
                self.assertEqual(
                    [
                        len(read_calibration(path, expected))
                        for path, expected in zip(
                            paths,
                            (
                                capture_timing_calibration.CALIBRATION_BANKS[0][1],
                                capture_timing_calibration.CALIBRATION_BANKS[1][1],
                            ),
                        )
                    ],
                    [6, 6],
                )
            manifest_path = Path(directory) / "timing" / "spk286_timing_calibration.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            for simulator in raw_paths:
                self.assertEqual(
                    [entry["records"] for entry in manifest["simulator_outputs"][simulator]],
                    [6, 6],
                )
                self.assertEqual(
                    [entry["bank"] for entry in manifest["simulator_outputs"][simulator]],
                    ["baseline", "extra"],
                )
                for entry, path in zip(
                    manifest["simulator_outputs"][simulator], raw_paths[simulator]
                ):
                    self.assertEqual(
                        entry["path"],
                        capture_timing_calibration.manifest_relative(path, manifest_path),
                    )
                    self.assertEqual(
                        entry["sha256"], capture_timing_calibration.sha256_file(path)
                    )
            self.assertEqual(manifest["calibration"]["records"], 12)

    def test_single_simulator_preserves_each_six_row_raw_bank(self):
        self.run_evidence_scenario("verilator")

    def test_both_simulators_preserve_each_six_row_raw_bank(self):
        self.run_evidence_scenario("both")

    def test_main_parses_both_identical_simulator_outputs_before_rejecting_extra_field(self):
        rows = calibration_rows()

        def fake_capture(simulator, capture_build_dir):
            paths = (
                capture_build_dir / "timing" / "spk286_timing_calibration.csv",
                capture_build_dir / "timing" / "spk286_timing_calibration_extra.csv",
            )
            for path, bank_rows in zip(paths, (rows[:6], rows[6:])):
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("w", newline="", encoding="utf-8") as stream:
                    writer = csv.writer(stream)
                    writer.writerow(CALIBRATION_COLUMNS)
                    for index, row in enumerate(bank_rows):
                        values = [row[column] for column in CALIBRATION_COLUMNS]
                        if index == 0:
                            values.append("")
                        writer.writerow(values)
            return list(paths)

        def fake_run(command, *, env=None):
            if command[:2] == ["git", "rev-parse"]:
                return "test-revision"
            if command[:2] == ["git", "branch"]:
                return "codex/test"
            return "Verilator 5.020 test"

        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(capture_timing_calibration, "git_status", return_value=""), \
                 mock.patch.object(capture_timing_calibration, "run", side_effect=fake_run), \
                 mock.patch.object(capture_timing_calibration, "capture_simulator", side_effect=fake_capture):
                with self.assertRaisesRegex(ValueError, "has 18 fields"):
                    capture_timing_calibration.main(
                        ["--simulator", "both", "--build-dir", directory]
                    )
            self.assertFalse(
                (Path(directory) / "timing" / "spk286_timing_calibration.json").exists()
            )


if __name__ == "__main__":
    unittest.main()
