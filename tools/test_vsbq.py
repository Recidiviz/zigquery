#!/usr/bin/env python3
"""Tests for the vsbq.py comparator itself (issue #43).

The comparator used to read the CLI's TSV with `l.split("\\t")`, so a value
containing a tab split a row and the case was flagged as a divergence that did
not exist. The CLI now has a `--json` mode and vsbq.py reads that; these tests
cover the tab case end to end and the type handling the JSON mode exists for.

Run from the repo root, with a built CLI binary for the tests that shell out
to it:

    python3 tools/test_vsbq.py

The tests that need the binary skip when `zig-out/bin/zigquery-cli` is absent;
the pure comparator test always runs. `google-cloud-bigquery` is only needed
to talk to real BigQuery, which no test here does, so the import is stubbed
when the package is not installed.
"""
import os
import sys
import types
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))

try:
    import google.cloud.bigquery  # noqa: F401  (only used by run_bq, not here)
except ImportError:  # pragma: no cover - developer machines have it installed
    google = types.ModuleType("google")
    google_cloud = types.ModuleType("google.cloud")
    bigquery = types.ModuleType("google.cloud.bigquery")
    bigquery.Client = object
    google.cloud = google_cloud
    google_cloud.bigquery = bigquery
    sys.modules["google"] = google
    sys.modules["google.cloud"] = google_cloud
    sys.modules["google.cloud.bigquery"] = bigquery

import vsbq  # noqa: E402

# The ltrim case from issue #43: LTRIM('\t\tapple\t\t') returns 'apple\t\t',
# a value containing tabs. In TSV that split the row; in JSON it must not.
LTRIM_SQL = (
    "SELECT LTRIM('   apple   '), LTRIM('\\t\\tapple\\t\\t'), "
    "LTRIM('***apple***', '*'), LTRIM(NULL), LTRIM(' . ', NULL)"
)
LTRIM_VALUES = ["apple   ", "apple\t\t", "apple***", None, None]


def engine_available():
    return os.path.exists(os.path.join(ROOT, "zig-out", "bin", "zigquery-cli"))


class ComparatorTests(unittest.TestCase):
    def test_tab_value_agrees_without_a_binary(self):
        """align() + classify() on hand-built rows: the tab never splits."""
        engine_rows = [{"$col2": "apple\t\t"}]
        bq_rows = [{"f0_": "apple\t\t"}]
        ours, theirs, names_differ = vsbq.align(engine_rows, bq_rows)
        self.assertFalse(names_differ)
        self.assertEqual(vsbq.classify(ours, theirs), "agree")

    def test_string_that_looks_numeric_stays_a_string(self):
        """A STRING cell is compared as text, not re-read as a number.

        (canon() still number-parses a string when BigQuery's side is a
        number — that fuzz is load-bearing for NUMERIC cells, which the engine
        returns as text — so this only pins the string-against-string case.)
        """
        engine_rows = [{"$col1": "1e+14"}]
        bq_rows = [{"f0_": "1e+14"}]
        ours, theirs, _ = vsbq.align(engine_rows, bq_rows)
        self.assertEqual(vsbq.classify(ours, theirs), "agree")


@unittest.skipUnless(engine_available(), "zig-out/bin/zigquery-cli not built")
class EngineJsonTests(unittest.TestCase):
    def test_ltrim_tab_value_survives_json_round_trip(self):
        rows, err = vsbq.run_engine(LTRIM_SQL)
        self.assertIsNone(err, err)
        self.assertEqual(len(rows), 1)
        self.assertEqual(
            [rows[0][f"$col{i}"] for i in range(1, 6)], LTRIM_VALUES)

    def test_ltrim_case_agrees_with_bigquery(self):
        """The issue's 'done when': the ltrim case comes back agree."""
        rows, err = vsbq.run_engine(LTRIM_SQL)
        self.assertIsNone(err, err)
        bq_rows = [{f"f{i}_": v for i, v in enumerate(LTRIM_VALUES)}]
        ours, theirs, names_differ = vsbq.align(rows, bq_rows)
        self.assertFalse(names_differ)
        self.assertEqual(vsbq.classify(ours, theirs), "agree")

    def test_json_cells_keep_their_types(self):
        rows, err = vsbq.run_engine(
            "SELECT 1 AS i, 1.5 AS f, TRUE AS b, 'x' AS s, NULL AS n, "
            "[1, 2] AS a, STRUCT(1 AS x, 'y' AS z) AS st")
        self.assertIsNone(err, err)
        row = rows[0]
        self.assertIsInstance(row["i"], int)
        self.assertIsInstance(row["f"], float)
        self.assertIsInstance(row["b"], bool)
        self.assertIsInstance(row["s"], str)
        self.assertIsNone(row["n"])
        self.assertEqual(row["a"], [1, 2])
        self.assertEqual(row["st"], {"x": 1, "z": "y"})

    def test_engine_error_is_reported(self):
        rows, err = vsbq.run_engine("SELECT * FROM no_such_table_xyz")
        self.assertIsNone(rows)
        self.assertIsInstance(err, str)
        self.assertTrue(err)


if __name__ == "__main__":
    os.chdir(ROOT)  # ENGINE is a relative path from the repo root
    unittest.main()
