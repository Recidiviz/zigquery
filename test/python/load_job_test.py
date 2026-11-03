"""Load jobs, driven through the client a caller actually uses.

csv_autodetect_test.py sends one configuration and varies the data, so it is a schema
detection suite. This one varies the configuration: dispositions, bad records, an explicit
schema, newline-delimited JSON, and the refusals.

Where a behaviour was measured against real BigQuery the case carries the date.
"""

import io
import json

import requests
from google.api_core import exceptions
from google.cloud import bigquery
from google.cloud.bigquery import LoadJobConfig, SchemaField, SourceFormat

from utils.big_query_emulator_container import BQ_EMULATOR_PROJECT_ID
from utils.big_query_emulator_test_case import BigQueryEmulatorTestCase

_DATASET = "load_jobs"


class TestLoadJobs(BigQueryEmulatorTestCase):
    """Load jobs through google-cloud-bigquery."""

    def setUp(self) -> None:
        super().setUp()
        self.client.create_dataset(_DATASET, exists_ok=True)

    def _table_ref(self, table_id: str) -> bigquery.TableReference:
        return bigquery.TableReference(
            bigquery.DatasetReference(BQ_EMULATOR_PROJECT_ID, _DATASET), table_id
        )

    def _load(self, table_id: str, data: str, **config) -> bigquery.LoadJob:
        job_config = LoadJobConfig(source_format=SourceFormat.CSV, **config)
        job = self.client.load_table_from_file(
            io.StringIO(data), self._table_ref(table_id), job_config=job_config
        )
        job.result()
        return job

    def _rows(self, table_id: str) -> list[dict]:
        job = self.client.query(
            f"SELECT * FROM `{BQ_EMULATOR_PROJECT_ID}.{_DATASET}.{table_id}` ORDER BY 1"
        )
        return [{key: row.get(key) for key in row.keys()} for row in job.result()]

    # ---- dispositions ----

    def test_a_load_appends_by_default(self) -> None:
        """WRITE_APPEND is the default for a load job, where a copy job defaults to
        WRITE_EMPTY. rest/v2/Job#jobconfigurationload"""
        self._load("appended", "name,age\nAlice,30\n", autodetect=True)
        job = self._load("appended", "name,age\nBob,25\n", autodetect=True)

        self.assertIsNone(job.error_result)
        self.assertEqual(
            [{"name": "Alice", "age": 30}, {"name": "Bob", "age": 25}],
            self._rows("appended"),
        )

    def test_write_truncate_replaces_what_was_there(self) -> None:
        self._load("truncated", "name,age\nAlice,30\n", autodetect=True)
        self._load(
            "truncated",
            "name,age\nBob,25\n",
            autodetect=True,
            write_disposition="WRITE_TRUNCATE",
        )
        self.assertEqual([{"name": "Bob", "age": 25}], self._rows("truncated"))

    def test_write_empty_refuses_a_destination_holding_rows(self) -> None:
        self._load("occupied", "name,age\nAlice,30\n", autodetect=True)

        job_config = LoadJobConfig(
            source_format=SourceFormat.CSV,
            autodetect=True,
            write_disposition="WRITE_EMPTY",
        )
        job = self.client.load_table_from_file(
            io.StringIO("name,age\nBob,25\n"),
            self._table_ref("occupied"),
            job_config=job_config,
        )
        with self.assertRaises(exceptions.GoogleAPICallError):
            job.result()

        self.assertEqual("duplicate", job.error_result["reason"])
        self.assertEqual([{"name": "Alice", "age": 30}], self._rows("occupied"))

    def test_create_never_requires_the_destination_to_exist(self) -> None:
        job_config = LoadJobConfig(
            source_format=SourceFormat.CSV,
            autodetect=True,
            create_disposition="CREATE_NEVER",
        )
        job = self.client.load_table_from_file(
            io.StringIO("name,age\nAlice,30\n"),
            self._table_ref("never_created"),
            job_config=job_config,
        )
        with self.assertRaises(exceptions.GoogleAPICallError):
            job.result()

        self.assertEqual("notFound", job.error_result["reason"])

    # ---- schemas ----

    def test_an_explicit_schema_is_used_instead_of_detection(self) -> None:
        job = self._load(
            "declared",
            "a,b\n1,2024-01-15\n",
            schema=[SchemaField("a", "STRING"), SchemaField("b", "STRING")],
            autodetect=True,
        )
        self.assertIsNone(job.error_result)

        table = self.client.get_table(self._table_ref("declared"))
        self.assertEqual(
            {"a": "STRING", "b": "STRING"},
            {f.name: f.field_type for f in table.schema},
        )

    def test_autodetect_finds_the_header_even_when_a_schema_is_given(self) -> None:
        """Autodetect does two things, and a supplied schema only replaces one of them.

        Measured against real BigQuery (recidiviz-bigquery-sandbox, 2026-09-24): with a
        schema and autodetect on, the header is detected and skipped; with autodetect off it
        is read as data.
        """
        self._load(
            "with_detect",
            "a,b\n1,2\n",
            schema=[SchemaField("a", "STRING"), SchemaField("b", "STRING")],
            autodetect=True,
        )
        self.assertEqual([{"a": "1", "b": "2"}], self._rows("with_detect"))

        self._load(
            "without_detect",
            "a,b\n1,2\n",
            schema=[SchemaField("a", "STRING"), SchemaField("b", "STRING")],
        )
        self.assertEqual(
            [{"a": "1", "b": "2"}, {"a": "a", "b": "b"}],
            self._rows("without_detect"),
        )

    # ---- bad records ----

    def test_bad_records_within_the_allowance_are_skipped(self) -> None:
        job = self._load(
            "tolerant",
            "1\nnot a number\n3\n",
            schema=[SchemaField("a", "INTEGER")],
            skip_leading_rows=0,
            max_bad_records=1,
        )
        self.assertIsNone(job.error_result)
        self.assertEqual([{"a": 1}, {"a": 3}], self._rows("tolerant"))
        self.assertEqual(
            "1", job._properties["statistics"]["load"]["badRecords"]
        )

    def test_too_many_bad_records_fails_the_job_and_writes_nothing(self) -> None:
        job_config = LoadJobConfig(
            source_format=SourceFormat.CSV,
            schema=[SchemaField("a", "INTEGER")],
            skip_leading_rows=0,
        )
        job = self.client.load_table_from_file(
            io.StringIO("1\nnot a number\n3\n"),
            self._table_ref("intolerant"),
            job_config=job_config,
        )
        with self.assertRaises(exceptions.GoogleAPICallError):
            job.result()

        self.assertEqual("invalid", job.error_result["reason"])
        # The destination is left as it was, which for a table that did not exist is absent.
        with self.assertRaises(exceptions.NotFound):
            self.client.get_table(self._table_ref("intolerant"))

    def test_a_row_missing_trailing_columns_needs_permission(self) -> None:
        job_config = LoadJobConfig(
            source_format=SourceFormat.CSV,
            schema=[SchemaField("a", "STRING"), SchemaField("b", "STRING")],
            skip_leading_rows=0,
            allow_jagged_rows=True,
        )
        job = self.client.load_table_from_file(
            io.StringIO("1,2\n3\n"),
            self._table_ref("jagged"),
            job_config=job_config,
        )
        job.result()
        self.assertIsNone(job.error_result)
        self.assertEqual(2, len(self._rows("jagged")))

    # ---- newline-delimited JSON ----

    def test_newline_delimited_json(self) -> None:
        lines = "\n".join(
            json.dumps(row) for row in [{"name": "Alice", "id": 12}, {"name": "Bob", "id": 13}]
        )
        job_config = LoadJobConfig(
            source_format=SourceFormat.NEWLINE_DELIMITED_JSON, autodetect=True
        )
        job = self.client.load_table_from_file(
            io.StringIO(lines + "\n"), self._table_ref("ndjson"), job_config=job_config
        )
        job.result()

        self.assertIsNone(job.error_result)
        table = self.client.get_table(self._table_ref("ndjson"))
        self.assertEqual(
            {"name": "STRING", "id": "INTEGER"},
            {f.name: f.field_type for f in table.schema},
        )

    def test_nested_json_is_refused_rather_than_half_read(self) -> None:
        job_config = LoadJobConfig(
            source_format=SourceFormat.NEWLINE_DELIMITED_JSON, autodetect=True
        )
        with self.assertRaises(exceptions.BadRequest):
            self.client.load_table_from_file(
                io.StringIO('{"a":{"b":1}}\n'),
                self._table_ref("nested"),
                job_config=job_config,
            )

    # ---- refusals ----

    def test_a_format_this_emulator_cannot_read_is_refused(self) -> None:
        job_config = LoadJobConfig(source_format=SourceFormat.PARQUET)
        with self.assertRaises(exceptions.BadRequest) as caught:
            self.client.load_table_from_file(
                io.BytesIO(b"PAR1"),
                self._table_ref("parquet"),
                job_config=job_config,
            )
        # The emulator's own refusal, rather than anything the client decided locally.
        self.assertIn("sourceFormat", str(caught.exception))

    # ---- the job resource ----

    def test_the_job_reports_what_it_read_and_wrote(self) -> None:
        job = self._load("counted", "name,age\nAlice,30\nBob,25\n", autodetect=True)

        self.assertEqual(1, job.input_files)
        self.assertEqual(len("name,age\nAlice,30\nBob,25\n"), job.input_file_bytes)
        self.assertEqual(2, job.output_rows)
        # outputBytes measures BigQuery's own storage format, which has no analogue here.
        self.assertIsNone(job.output_bytes)

    def test_a_load_job_is_replayable_and_is_not_a_query_job(self) -> None:
        job = self._load("replayed", "name,age\nAlice,30\n", autodetect=True)

        replayed = self.client.get_job(job.job_id)
        self.assertIsInstance(replayed, bigquery.LoadJob)
        self.assertEqual("DONE", replayed.state)


_BUCKET = "zigquery-python-staging"


class TestLoadJobsFromCloudStorage(BigQueryEmulatorTestCase):
    """Load jobs that read gs:// objects from fake-gcs-server."""

    with_cloud_storage = True

    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        storage = cls.cloud_storage.get_url()
        requests.post(f"{storage}/storage/v1/b", json={"name": _BUCKET}).raise_for_status()
        objects = {
            "single/people.csv": "1,NORTH\n2,SOUTH\n",
            "shards/part-000.csv": "person_id,district\n1,NORTH\n",
            "shards/part-001.csv": "person_id,district\n2,SOUTH\n",
            "shards/manifest.json": '{"files":2}\n',
        }
        for name, body in objects.items():
            requests.post(
                f"{storage}/upload/storage/v1/b/{_BUCKET}/o",
                params={"uploadType": "media", "name": name},
                data=body.encode(),
            ).raise_for_status()

    def setUp(self) -> None:
        super().setUp()
        self.client.create_dataset(_DATASET, exists_ok=True)

    def _load_uri(self, table_id: str, uri: str, **config) -> bigquery.LoadJob:
        table = self.client.create_table(
            bigquery.Table(
                bigquery.TableReference(
                    bigquery.DatasetReference(BQ_EMULATOR_PROJECT_ID, _DATASET), table_id
                ),
                schema=[
                    SchemaField("person_id", "INTEGER"),
                    SchemaField("district", "STRING"),
                ],
            )
        )
        job = self.client.load_table_from_uri(
            uri,
            table,
            job_config=LoadJobConfig(source_format=SourceFormat.CSV, **config),
        )
        job.result()
        return job

    def _rows(self, table_id: str) -> list[tuple]:
        job = self.client.query(
            f"SELECT person_id, district FROM `{BQ_EMULATOR_PROJECT_ID}.{_DATASET}.{table_id}` "
            "ORDER BY person_id"
        )
        return [tuple(row.values()) for row in job.result()]

    def test_a_gs_uri_loads_its_object(self) -> None:
        job = self._load_uri("from_gcs", f"gs://{_BUCKET}/single/people.csv")
        self.assertEqual(1, job.input_files)
        self.assertEqual([(1, "NORTH"), (2, "SOUTH")], self._rows("from_gcs"))

    def test_a_wildcard_loads_every_match_skipping_each_header(self) -> None:
        job = self._load_uri(
            "from_shards", f"gs://{_BUCKET}/shards/part-*.csv", skip_leading_rows=1
        )
        self.assertEqual(2, job.input_files)
        self.assertEqual([(1, "NORTH"), (2, "SOUTH")], self._rows("from_shards"))

    def test_a_missing_object_fails_the_job_as_not_found(self) -> None:
        with self.assertRaises(exceptions.NotFound):
            self._load_uri("from_absent", f"gs://{_BUCKET}/single/absent.csv")
