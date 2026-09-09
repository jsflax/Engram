"""Harness-only regressions; these never launch Engram or compile shaders."""

from contextlib import closing
from pathlib import Path
import sqlite3
import tempfile
import unittest

from profile_app_loading import FrameReader, REQUIRED_COLUMNS, prepare_fixture


class FixtureTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="engram-app-load-fixture-test-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.source = self.directory / "source.sqlite"
        self.destination = self.directory / "copy.sqlite"
        with closing(sqlite3.connect(self.source)) as database:
            database.executescript("""
                CREATE TABLE Memory(globalId TEXT, content TEXT);
                INSERT INTO Memory VALUES ('a', 'first memory'), ('b', 'second memory');
                CREATE TABLE VisualizerConfig(selectedTab TEXT, layoutMode TEXT,
                    hiddenProjects TEXT, hiddenRelations TEXT, soundEnabled INTEGER,
                    notificationsEnabled INTEGER, showMascots INTEGER);
                INSERT INTO VisualizerConfig
                    VALUES ('Account', 'Semantic', '["hidden"]', '["related"]', 1, 1, 0);
                CREATE TABLE SyncConfig(project TEXT, policy TEXT, exposedTeams TEXT);
                INSERT INTO SyncConfig VALUES
                    ('synced-project', 'sync', '["team-id"]'), ('local-project', 'local', '[]');
                CREATE TABLE AuditLog(message TEXT);
                INSERT INTO AuditLog VALUES ('existing event');
                CREATE TRIGGER config_audit AFTER UPDATE ON VisualizerConfig
                    WHEN sync_disabled() = 0
                    BEGIN INSERT INTO AuditLog VALUES ('config changed'); END;
                CREATE TRIGGER sync_config_audit AFTER UPDATE ON SyncConfig
                    WHEN sync_disabled() = 0
                    BEGIN INSERT INTO AuditLog VALUES ('sync config changed'); END;
            """)

    def test_backup_preserves_source_and_normalizes_only_fixture_config(self):
        before = self.source.read_bytes()
        count, configuration = prepare_fixture(self.source, self.destination)

        self.assertEqual(count, 2)
        self.assertEqual(configuration, [('Graph', 'Force', '[]', '[]', 0, 0, 0)])
        self.assertEqual(self.source.read_bytes(), before)
        with closing(sqlite3.connect(self.source)) as source:
            self.assertEqual(source.execute("SELECT * FROM VisualizerConfig").fetchone(),
                             ('Account', 'Semantic', '["hidden"]', '["related"]', 1, 1, 0))
            self.assertEqual(source.execute("SELECT * FROM SyncConfig ORDER BY project").fetchall(),
                             [('local-project', 'local', '[]'),
                              ('synced-project', 'sync', '["team-id"]')])
        with closing(sqlite3.connect(self.destination)) as fixture:
            self.assertEqual(fixture.execute("SELECT * FROM Memory ORDER BY globalId").fetchall(),
                             [('a', 'first memory'), ('b', 'second memory')])
            self.assertEqual(fixture.execute("SELECT * FROM SyncConfig ORDER BY project").fetchall(),
                             [('local-project', 'local', '[]'),
                              ('synced-project', 'local', '[]')])
            self.assertEqual(fixture.execute("SELECT * FROM AuditLog").fetchall(),
                             [('existing event',)])

    def test_rejects_empty_or_nonunique_memory_ids(self):
        for rows in ([], [(None,)], [('duplicate',), ('duplicate',)]):
            with self.subTest(rows=rows):
                with closing(sqlite3.connect(self.source)) as source:
                    source.execute("DELETE FROM Memory")
                    source.executemany("INSERT INTO Memory(globalId) VALUES (?)", rows)
                    source.commit()
                destination = self.directory / f"invalid-{len(rows)}.sqlite"
                with self.assertRaisesRegex(ValueError, "uniquely identified"):
                    prepare_fixture(self.source, destination)


class FrameReaderTests(unittest.TestCase):
    columns = sorted(REQUIRED_COLUMNS)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="engram-app-load-reader-test-")
        self.addCleanup(temporary.cleanup)
        self.path = Path(temporary.name) / "frames.csv"

    def header(self, columns=None):
        return ",".join(columns or self.columns) + "\n"

    def row(self, **changes):
        values = dict.fromkeys(self.columns, 0)
        values.update(frame=1, dt_ms=16.667, total_ms=5, nodes=31674)
        values.update(changes)
        return ",".join(str(values[column]) for column in self.columns) + "\n"

    def test_missing_file_is_not_yet_ready(self):
        reader = FrameReader(self.path)
        self.assertEqual(reader.poll(), [])
        self.assertIsNone(reader.columns)

    def test_partial_header_and_row_wait_for_complete_records(self):
        reader = FrameReader(self.path)
        header = self.header()
        row = self.row()
        self.path.write_text("# refresh_hz=60\n" + header[:10])
        self.assertEqual(reader.poll(), [])
        self.assertIsNone(reader.columns)
        with self.path.open("a") as destination:
            destination.write(header[10:] + row[:-3])
        self.assertEqual(reader.poll(), [])
        self.assertEqual(reader.columns, self.columns)
        with self.path.open("a") as destination:
            destination.write(row[-3:])
        frames = reader.poll()
        self.assertEqual(len(frames), 1)
        self.assertEqual(frames[0]["nodes"], 31674)
        self.assertEqual(reader.poll(), [])
        self.assertEqual(reader.frames, frames)

    def test_later_flush_appends_without_replaying_previous_frames(self):
        self.path.write_text(self.header() + self.row(frame=1))
        reader = FrameReader(self.path)
        self.assertEqual([row["frame"] for row in reader.poll()], [1])
        with self.path.open("a") as destination:
            destination.write(self.row(frame=2) + self.row(frame=3))
        self.assertEqual([row["frame"] for row in reader.poll()], [2, 3])
        self.assertEqual([row["frame"] for row in reader.frames], [1, 2, 3])

    def test_missing_and_duplicate_named_columns_are_rejected(self):
        for columns in (self.columns[:-1], self.columns + [self.columns[0]],
                        ["frame", "wall_dt_ms", "total_ms"]):
            with self.subTest(columns=columns):
                self.path.write_text(self.header(columns))
                with self.assertRaisesRegex(ValueError, "columns"):
                    FrameReader(self.path).poll()

    def test_complete_malformed_row_is_rejected(self):
        for row in ("1,16,5\n", self.row().rstrip() + ",1\n"):
            with self.subTest(row=row):
                self.path.write_text(self.header() + row)
                with self.assertRaisesRegex(ValueError, "Malformed"):
                    FrameReader(self.path).poll()

    def test_nonfinite_negative_and_nonnumeric_values_are_rejected(self):
        for value in ("nan", "inf", "-inf", -1, "invalid"):
            with self.subTest(value=value):
                self.path.write_text(self.header() + self.row(total_ms=value))
                with self.assertRaises(ValueError):
                    FrameReader(self.path).poll()

    def test_duplicate_or_decreasing_frame_numbers_are_rejected(self):
        for next_frame in (2, 1):
            with self.subTest(next_frame=next_frame):
                self.path.write_text(self.header() + self.row(frame=2) + self.row(frame=next_frame))
                with self.assertRaisesRegex(ValueError, "increase"):
                    FrameReader(self.path).poll()


if __name__ == "__main__":
    unittest.main()
