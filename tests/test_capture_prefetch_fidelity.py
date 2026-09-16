import csv
import tempfile
import unittest
from pathlib import Path

from tools.capture_prefetch_fidelity import (
    TRACE_COLUMNS,
    compare_captures,
    read_capture,
    validate_capture_rows,
    validate_workload,
)


def row(cycle, **updates):
    values = {name: 0 for name in TRACE_COLUMNS}
    values.update({
        "scenario": 1,
        "epoch": 0,
        "cycle": cycle,
        "reset": 0,
        "queue_count": 0,
        "model_queue_count": 0,
        "model_queue_count_after": 0,
        "model_pending_count": 0,
        "model_pending_count_after": 0,
        "bus_status": 15,
        "response_count": 0,
        "expected_consume": -1,
    })
    values.update(updates)
    return values


def minimal_valid_rows():
    reset = row(0, reset=1)
    idle = row(1)
    code = row(
        2,
        bus_valid=1,
        bus_status=13,
        address=0x0100,
        bhe_n=0,
        ready=1,
        code_accept=1,
        model_code_accept=1,
        model_pending_count_after=2,
    )
    response = row(
        3,
        model_queue_count_after=2,
        model_pending_count=2,
        fetch_response_valid=1,
        fetch_response_ready=1,
        response_accept=1,
        response_count=2,
        response_data=0x1234,
        queue_empty_fetch_activity=1,
    )
    consume = row(
        4,
        queue_count=2,
        model_queue_count=2,
        model_queue_count_after=1,
        consume_valid=1,
        consume_accept=1,
        consume_data=0x34,
        expected_consume=0x34,
    )
    return [reset, idle, code, response, consume]


def hlt_resume_rows():
    rows = minimal_valid_rows()
    rows.extend([
        row(5, queue_count=1, model_queue_count=1, model_queue_count_after=1,
            halted=1, bus_status=4, event_request=1),
        row(6, queue_count=1, model_queue_count=1,
            restart=1, event_active=1, hlt_resume=1),
        row(7, event_active=1),
        row(8, halted=1, bus_status=4),
    ])
    return rows


def workload_rows():
    rows = minimal_valid_rows()
    rows[1].update({
        "queue_count": 6,
        "instruction_wait": 1,
        "queue_empty_fetch_activity": 1,
        "operand_wait": 1,
        "data_wait": 1,
        "invalidated_pending": 1,
    })
    rows.extend([
        row(5, scenario=4, halted=1),
        row(6, scenario=4, event_active=1, hlt_resume=1),
        row(7, scenario=4, event_active=1),
        row(8, scenario=4, halted=1),
    ])
    return rows


def write_capture(path: Path, rows, *, extra_field=False):
    header = list(TRACE_COLUMNS)
    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        writer.writerow(header)
        for values in rows:
            fields = [values[name] for name in TRACE_COLUMNS]
            if extra_field:
                fields.append(0)
            writer.writerow(fields)


class PrefetchCaptureValidationTests(unittest.TestCase):
    def test_accepts_reference_model_transitions(self):
        validate_capture_rows(minimal_valid_rows())

    def test_rejects_extra_csv_field_before_normalization(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.csv"
            write_capture(path, minimal_valid_rows(), extra_field=True)
            with self.assertRaisesRegex(ValueError, f"has {len(TRACE_COLUMNS) + 1} fields"):
                read_capture(path)

    def test_rejects_lost_or_duplicated_consumed_byte(self):
        rows = minimal_valid_rows()
        rows[-1]["consume_data"] = 0x35
        with self.assertRaisesRegex(ValueError, "different from the reference"):
            validate_capture_rows(rows)

    def test_rejects_inconsistent_reference_queue_transition(self):
        rows = minimal_valid_rows()
        rows[3]["model_queue_count_after"] = 1
        with self.assertRaisesRegex(ValueError, "queue transition"):
            validate_capture_rows(rows)

    def test_rejects_stale_invalidation_without_restart(self):
        rows = minimal_valid_rows()
        rows[1]["invalidated_pending"] = 1
        with self.assertRaisesRegex(ValueError, "invalidated bytes"):
            validate_capture_rows(rows)

    def test_rejects_expected_byte_without_a_consume(self):
        rows = minimal_valid_rows()
        rows[1]["expected_consume"] = 0x90
        with self.assertRaisesRegex(ValueError, "unused expected byte"):
            validate_capture_rows(rows)

    def test_accepts_effective_byte_demand(self):
        rows = minimal_valid_rows()
        rows.append(row(
            5,
            scenario=2,
            epoch=1,
            queue_empty_fetch_activity=1,
            fetch_request_internal=1,
            execution_allowed=1,
            decode_ready=1,
            byte_demand=1,
            instruction_wait=1,
        ))
        validate_capture_rows(rows)

    def test_rejects_queue_activity_without_real_byte_demand(self):
        rows = minimal_valid_rows()
        rows.append(row(
            5,
            scenario=2,
            epoch=1,
            queue_empty_fetch_activity=1,
            fetch_request_internal=1,
            instruction_wait=1,
        ))
        with self.assertRaisesRegex(ValueError, "effective byte demand"):
            validate_capture_rows(rows)

    def test_accepts_hlt_resume_transition_with_restart(self):
        validate_capture_rows(hlt_resume_rows())

    def test_rejects_spurious_hlt_resume_without_prior_halt(self):
        rows = minimal_valid_rows()
        rows[3]["hlt_resume"] = 1
        with self.assertRaisesRegex(ValueError, "HLT resume marker"):
            validate_capture_rows(rows)

    def test_rejects_missing_hlt_resume_transition(self):
        rows = hlt_resume_rows()
        rows[6]["hlt_resume"] = 0
        with self.assertRaisesRegex(ValueError, "HLT resume marker"):
            validate_capture_rows(rows)

    def test_rejects_duplicate_hlt_resume_marker(self):
        rows = hlt_resume_rows()
        rows[7]["hlt_resume"] = 1
        with self.assertRaisesRegex(ValueError, "HLT resume marker"):
            validate_capture_rows(rows)

    def test_rejects_hlt_resume_across_scenario_boundary(self):
        rows = minimal_valid_rows()
        rows.append(row(5, scenario=1, queue_count=1, model_queue_count=1,
                        model_queue_count_after=1,
                        halted=1, bus_status=4))
        rows.append(row(6, scenario=2, queue_count=1, model_queue_count=1,
                        event_active=1, hlt_resume=1))
        with self.assertRaisesRegex(ValueError, "HLT resume marker"):
            validate_capture_rows(rows)

    def test_workload_requires_scenario_four_resume(self):
        rows = workload_rows()
        validate_workload(rows)
        without_resume_scenario = [row for row in rows if row["scenario"] != 4]
        with self.assertRaisesRegex(ValueError, "scenario 4"):
            validate_workload(without_resume_scenario)

    def test_workload_requires_second_hlt(self):
        rows = workload_rows()
        rows.pop()
        with self.assertRaisesRegex(ValueError, "second HLT"):
            validate_workload(rows)

    def test_compares_only_validated_normalized_captures(self):
        with tempfile.TemporaryDirectory() as directory:
            left = Path(directory) / "left.csv"
            right = Path(directory) / "right.csv"
            write_capture(left, minimal_valid_rows())
            write_capture(right, minimal_valid_rows())
            left_rows, right_rows = compare_captures(left, right)
            self.assertEqual(left_rows, right_rows)
            altered = minimal_valid_rows()
            altered[-1]["consume_data"] = 0x35
            write_capture(right, altered)
            with self.assertRaisesRegex(ValueError, "different from the reference"):
                compare_captures(left, right)


if __name__ == "__main__":
    unittest.main()
