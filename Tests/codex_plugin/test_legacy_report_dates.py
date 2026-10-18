"""Known retained report dates normalize without weakening exact SQL row pins."""
import datetime as dt
import copy
import json
import math
import unittest
from unittest import mock

from legacy_fixture import LegacyFixture, load_runtime, digest, write_json

L = load_runtime()


class LegacyReportDateTests(unittest.TestCase):
    def fixture(self):
        fixture = LegacyFixture(L)
        self.addCleanup(fixture.close)
        return fixture

    def iso_report(self, fixture, *, delta=0):
        path = fixture.evidence / "legacy-residual-duplicate-target.private.json"
        report = json.loads(path.read_bytes())
        for key in ("createdAt", "modifiedAt", "expiresAt"):
            report["row"][key] = dt.datetime.fromtimestamp(
                report["row"][key] + delta, dt.timezone.utc).isoformat()
        write_json(path, report)
        fixture.review["artifacts"][path.name] = digest(path.read_bytes())
        fixture.write_review()
        return path, report

    def links(self, fixture):
        return L._assessment_links(fixture.review, {name: L._sealed((fixture.evidence / name).read_bytes())
            for name in fixture.review["artifacts"]})

    def test_iso_report_roundtrip_uses_pinned_numeric_sql_rows(self):
        f = self.fixture()
        self.iso_report(f)
        before, database = f.current(), f.store.read_bytes()
        plan = f.prepare()
        self.assertEqual(f.current(), before)
        self.assertEqual(f.store.read_bytes(), database)
        review = L._json(L._raw(plan["review"]))
        for row in review["rows"]:
            self.assertTrue(all(type(row[key]) in (int, float) for key in ("createdAt", "modifiedAt", "expiresAt")))
        self.assertEqual(review["rows"], f.review["rows"])

    def test_one_microsecond_roundtrip_is_allowed(self):
        f = self.fixture()
        self.iso_report(f, delta=0.000001)
        self.links(f)

    def test_changed_iso_date_outside_roundtrip_precision_refuses(self):
        f = self.fixture()
        self.iso_report(f, delta=0.001)
        with self.assertRaises(ValueError):
            self.links(f)

    def test_missing_timezone_or_invalid_iso_refuses(self):
        f = self.fixture()
        path, report = self.iso_report(f)
        for invalid in ("2026-01-03T08:00:00", "invalid", True):
            with self.subTest(value=invalid):
                report["row"]["createdAt"] = invalid
                write_json(path, report)
                f.review["artifacts"][path.name] = digest(path.read_bytes())
                with self.assertRaises(ValueError):
                    self.links(f)

    def test_sql_numeric_pin_stays_exact_despite_report_tolerance(self):
        f = self.fixture()
        self.iso_report(f)
        plan = f.prepare()
        expected = f.review["rows"][0]["modifiedAt"]
        f.update_row("modifiedAt=?", (expected + 0.000001,))
        with self.assertRaisesRegex(ValueError, "readback_changed"):
            L._rows(f.paths, f.review["rows"])
        self.assertEqual(L._json(L._raw(plan["review"]))["rows"], f.review["rows"])

    def test_integer_json_dates_match_exact_sql_real_values_without_repinning(self):
        f = self.fixture()
        values = {"createdAt": 1767427200, "modifiedAt": 1767427201,
                  "expiresAt": 64092211200}
        for key, value in values.items():
            f.update_row(key + "=?", (float(value),))
            f.review["rows"][0][key] = value
        pinned, database, state = copy.deepcopy(f.review["rows"]), f.store.read_bytes(), f.current()
        L._rows(f.paths, f.review["rows"])
        self.assertEqual(f.review["rows"], pinned)
        self.assertEqual(f.store.read_bytes(), database)
        self.assertEqual(f.current(), state)

    def test_adjacent_representable_expiry_is_still_a_changed_row(self):
        f = self.fixture()
        expiry = 64092211200
        f.review["rows"][0]["expiresAt"] = expiry
        f.update_row("expiresAt=?", (math.nextafter(float(expiry), math.inf),))
        with self.assertRaisesRegex(ValueError, "readback_changed"):
            L._rows(f.paths, f.review["rows"])

    def test_invalid_numeric_date_types_and_privacy_coercion_refuse(self):
        f = self.fixture()
        f.update_row("createdAt=?", (1.0,))
        for invalid in (True, "1", None, math.inf, math.nan):
            with self.subTest(date=invalid):
                f.review["rows"][0]["createdAt"] = invalid
                with self.assertRaisesRegex(ValueError, "readback_changed"):
                    L._rows(f.paths, f.review["rows"])
        f.review["rows"][0]["createdAt"] = 1
        f.review["rows"][0]["isPrivate"] = True
        with self.assertRaisesRegex(ValueError, "readback_changed"):
            L._rows(f.paths, f.review["rows"])


if __name__ == "__main__":
    unittest.main()
