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


if __name__ == "__main__":
    unittest.main()
