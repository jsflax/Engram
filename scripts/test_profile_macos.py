import io
import unittest
from unittest.mock import patch

from profile_macos import REQUIRED_COLUMNS, analyze


class TimingValidationTests(unittest.TestCase):
    columns = sorted(REQUIRED_COLUMNS)
    header = ",".join(columns) + "\n"

    def row(self, frame, dt=16, total=5):
        values = dict.fromkeys(self.columns, 0)
        values.update(frame=frame, dt_ms=dt, total_ms=total, nodes=4000, edges=5000)
        return ",".join(str(values[key]) for key in self.columns) + "\n"

    def parse(self, content, warmup=0):
        with patch("pathlib.Path.open", return_value=io.StringIO(content)):
            return analyze("unused.csv", warmup=warmup)

    def test_requires_current_schema(self):
        with self.assertRaisesRegex(ValueError, "columns"):
            self.parse("frame,wall_dt_ms,total_ms\n1,16,5\n")

    def test_empty_and_malformed_samples_fail(self):
        for csv in [self.header, self.header + "1,16,5\n",
                    self.header + self.row(1, dt=float("nan"))]:
            with self.subTest(csv=csv), self.assertRaises(ValueError):
                self.parse(csv)

    def test_numeric_gate_uses_frame_interval_not_cpu_time(self):
        rows = "".join(self.row(i, dt=40) for i in range(100))
        report = self.parse("# refresh_hz=60\n" + self.header + rows)
        self.assertEqual(report["frames"], 100)
        self.assertFalse(report["frame_p95_under_33ms"])
        self.assertTrue(report["update_max_under_100ms"])

    def test_duplicate_columns_and_frames_fail(self):
        with self.assertRaisesRegex(ValueError, "columns"):
            self.parse(self.header.rstrip() + ",frame\n")
        with self.assertRaisesRegex(ValueError, "increase"):
            self.parse(self.header + self.row(1) + self.row(1))
        with self.assertRaisesRegex(ValueError, "integers"):
            self.parse(self.header + self.row(1.5))

    def test_empty_startup_frames_are_recorded_but_not_analyzed(self):
        empty = dict.fromkeys(self.columns, 0)
        empty.update(frame=1, dt_ms=16)
        startup = ",".join(str(empty[key]) for key in self.columns) + "\n"
        report = self.parse(self.header + startup + "".join(self.row(i) for i in range(2, 102)))
        self.assertEqual(report["recorded_frames"], 101)
        self.assertEqual(report["frames"], 100)

    def test_cold_stall_is_not_waived_by_warmup(self):
        content = self.header + self.row(1, total=150) + "".join(self.row(i) for i in range(2, 102))
        report = self.parse(content, warmup=1)
        self.assertTrue(report["update_max_under_100ms"])
        self.assertFalse(report["all_updates_under_100ms"])
        self.assertEqual(report["startup_update_max_ms"], 150)

    def test_optional_tick_details_preserve_existing_metrics_and_budgets(self):
        details = ["tick_callback_ms", "tick_force_prepare_ms", "tick_drain_ms",
                   "tick_sim_ms", "tick_merge_ms", "tick_snapshot_ms", "tick_cache_ms"]
        columns = self.columns + details + ["tick_detail_flags"]
        rows = [self.row(i, dt=40, total=5).strip() for i in range(100)]
        original = self.parse(self.header + "\n".join(rows) + "\n")
        # Deliberately large nested details must never be added to total_ms or
        # substituted for the real frame interval by an older analyzer.
        extended = self.parse(",".join(columns) + "\n" + "".join(
            row + "," + ",".join(["500"] * len(details) + ["7"]) + "\n" for row in rows))
        for key, value in original.items():
            if key != "timings_ms":
                self.assertEqual(extended[key], value, key)
        for key, value in original["timings_ms"].items():
            self.assertEqual(extended["timings_ms"][key], value, key)
        for key in details:
            self.assertEqual(extended["timings_ms"][key]["max"], 500)
        self.assertNotIn("tick_detail_flags", extended["timings_ms"])

    def test_optional_tick_details_still_require_valid_numeric_values(self):
        header = self.header.strip() + ",tick_cache_ms,tick_detail_flags\n"
        for value in ("nan", "inf", "-inf", "-1", "invalid"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.parse(header + "".join(
                    self.row(frame).strip() + "," + value + ",7\n" for frame in range(100)))

    def test_gap_details_exclude_unknown_without_replacing_existing_gates(self):
        columns = ["gap_flags", "callback_entry_dt_ms", "previous_logger_tail_ms",
                   "load_apply_ms", "load_queue_samples", "load_queue_ms",
                   "force_apply_ms", "force_queue_samples", "force_queue_ms"]
        base = [self.row(frame, dt=40, total=5).strip() for frame in range(100)]
        old = self.parse(self.header + "\n".join(base) + "\n")
        # Unknown first/foreign-owner rows contain zero placeholders; completed
        # intervals with no queue timestamp must not dilute queue statistics.
        suffixes = ["1,0,0,0,0,0,0,0,0", "0,0,0,0,0,0,0,0,0",
                    "3,16,2,700,0,0,800,0,0"] + ["3,16,2,700,1,900,800,1,1000"] * 97
        report = self.parse(self.header.strip() + "," + ",".join(columns) + "\n" + "".join(
            row + "," + suffix + "\n" for row, suffix in zip(base, suffixes)))
        for key, value in old.items():
            if key != "timings_ms":
                self.assertEqual(report[key], value, key)
        for key, value in old["timings_ms"].items():
            self.assertEqual(report["timings_ms"][key], value, key)
        self.assertFalse(report["frame_p95_under_33ms"])
        self.assertTrue(report["update_max_under_100ms"])
        self.assertEqual(report["gap_timing_samples"]["callback_entry_dt_ms"], 98)
        self.assertEqual(report["timings_ms"]["previous_logger_tail_ms"]["mean"], 2)
        self.assertEqual(report["gap_timing_samples"]["load_queue_ms"], 97)
        self.assertEqual(report["timings_ms"]["force_queue_ms"]["mean"], 1000)
        unavailable = self.parse(self.header.strip() + "," + ",".join(columns) + "\n" + "".join(
            row + ",0,0,0,0,0,0,0,0,0\n" for row in base))
        self.assertEqual(unavailable["gap_timing_samples"]["callback_entry_dt_ms"], 0)
        self.assertNotIn("callback_entry_dt_ms", unavailable["timings_ms"])


if __name__ == "__main__":
    unittest.main()
