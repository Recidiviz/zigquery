"""Additive schema updates, driven the way a pipeline evolves its tables.

A writer appends NULLABLE fields with `client.update_table(table, ["schema"])`, which is a
tables.patch carrying the whole schema, and then streams rows that carry them. Rows written
before the update read NULL for every new field.
"""

from google.api_core import exceptions
from google.cloud.bigquery import SchemaField

from utils.big_query_emulator_test_case import (
    BigQueryAddress,
    BigQueryEmulatorTestCase,
)

_DATASET = "schema_updates"


class TestSchemaUpdates(BigQueryEmulatorTestCase):
    """tables.patch schema changes through google-cloud-bigquery."""

    def _name(self, table_id: str) -> str:
        return f"{self.project_id}.{_DATASET}.{table_id}"

    def test_appended_fields_take_streamed_rows(self) -> None:
        address = BigQueryAddress(dataset_id=_DATASET, table_id="events")
        table = self.create_mock_table(
            address,
            schema=[
                SchemaField("id", "INTEGER", mode="REQUIRED"),
                SchemaField("detail", "RECORD", fields=[SchemaField("kind", "STRING")]),
            ],
        )
        self.assertEqual(
            [], self.client.insert_rows_json(table, [{"id": 1, "detail": {"kind": "open"}}])
        )

        table.schema = [
            SchemaField("id", "INTEGER", mode="NULLABLE"),
            SchemaField(
                "detail",
                "RECORD",
                fields=[SchemaField("kind", "STRING"), SchemaField("source", "STRING")],
            ),
            SchemaField("note", "STRING"),
        ]
        updated = self.client.update_table(table, ["schema"])
        self.assertEqual(
            ["id", "detail", "note"], [field.name for field in updated.schema]
        )
        self.assertEqual("NULLABLE", updated.schema[0].mode)

        self.assertEqual(
            [],
            self.client.insert_rows_json(
                updated,
                [{"detail": {"kind": "close", "source": "batch"}, "note": "late"}],
            ),
        )
        rows = self.client.query(
            f"SELECT id, detail.kind, detail.source, note FROM `{self._name('events')}`"
            " ORDER BY detail.kind DESC"
        ).result()
        self.assertEqual(
            [(1, "open", None, None), (None, "close", "batch", "late")],
            [tuple(row.values()) for row in rows],
        )

    def test_removing_a_field_is_refused(self) -> None:
        address = BigQueryAddress(dataset_id=_DATASET, table_id="fixed")
        table = self.create_mock_table(
            address, schema=[SchemaField("a", "INTEGER"), SchemaField("b", "STRING")]
        )
        table.schema = [SchemaField("a", "INTEGER")]
        with self.assertRaises(exceptions.BadRequest) as raised:
            self.client.update_table(table, ["schema"])
        self.assertIn(
            f"Provided Schema does not match Table {self.project_id}:{_DATASET}.fixed."
            " Field b is missing in new schema",
            raised.exception.message,
        )

    def test_alter_table_add_and_drop_column(self) -> None:
        address = BigQueryAddress(dataset_id=_DATASET, table_id="altered")
        self.create_mock_table(
            address, schema=[SchemaField("a", "INTEGER"), SchemaField("b", "STRING")]
        )
        self.client.query(
            f"ALTER TABLE `{self._name('altered')}` ADD COLUMN c DATE, DROP COLUMN b"
        ).result()
        table = self.client.get_table(self._name("altered"))
        self.assertEqual(
            [("a", "INTEGER"), ("c", "DATE")],
            [(field.name, field.field_type) for field in table.schema],
        )

        with self.assertRaises(exceptions.BadRequest) as raised:
            self.client.query(
                f"ALTER TABLE `{self._name('altered')}` DROP COLUMN a, DROP COLUMN c"
            ).result()
        self.assertIn("Cannot DROP last column from the table.", raised.exception.message)

    def test_alter_table_rename_column(self) -> None:
        address = BigQueryAddress(dataset_id=_DATASET, table_id="renamed")
        self.create_mock_table(
            address,
            schema=[SchemaField("a", "INTEGER"), SchemaField("b", "STRING", description="kept")],
        )
        self.load_rows_into_table(address, [{"a": 1, "b": "x"}])
        self.client.query(
            f"ALTER TABLE `{self._name('renamed')}` RENAME COLUMN b TO label"
        ).result()

        table = self.client.get_table(self._name("renamed"))
        self.assertEqual(["a", "label"], [field.name for field in table.schema])
        self.assertEqual("kept", table.schema[1].description)
        rows = self.client.query(f"SELECT label FROM `{self._name('renamed')}`").result()
        self.assertEqual(["x"], [row["label"] for row in rows])
