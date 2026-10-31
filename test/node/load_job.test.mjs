// Load jobs: Table.load sends a local file as a multipart upload; a storage File becomes a
// gs:// source URI on jobs.insert.

import assert from 'node:assert/strict';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { test, uniqueDatasetId, useEmulator } from './emulator.mjs';

const emulator = useEmulator();

const SCHEMA = [
  { name: 'person_id', type: 'INTEGER' },
  { name: 'district', type: 'STRING' },
];

// Table.createLoadJob recognises a @google-cloud/storage File by its constructor names and its
// parent chain, and reads only bucket.name and name from it.
class Storage {}
class Bucket {
  constructor(name) {
    this.name = name;
    this.parent = new Storage();
  }
}
class File {
  constructor(bucket, name) {
    this.bucket = bucket;
    this.name = name;
    this.parent = bucket;
  }
}

async function emptyTable(prefix) {
  const [dataset] = await emulator.client.createDataset(uniqueDatasetId(prefix));
  const [table] = await dataset.createTable('people', { schema: SCHEMA });
  return table;
}

test('Table.load uploads a local CSV file', async () => {
  const table = await emptyTable('multipart');
  const path = join(await mkdtemp(join(tmpdir(), 'zigquery-node-')), 'people.csv');
  await writeFile(path, '1,NORTH\n2,SOUTH\n');

  const [job] = await table.load(path, { sourceFormat: 'CSV' });
  assert.equal(job.status.state, 'DONE');
  assert.equal(job.status.errorResult, undefined);
  const [rows] = await emulator.client.query(
    `SELECT person_id, district FROM ${table.dataset.id}.people ORDER BY person_id`,
  );
  assert.deepEqual(rows, [
    { person_id: 1, district: 'NORTH' },
    { person_id: 2, district: 'SOUTH' },
  ]);
});

test('createLoadJob accepts a gs:// source', async () => {
  const table = await emptyTable('gcs');
  const source = new File(new Bucket('zigquery-node-test'), 'people.csv');
  const [job] = await table.createLoadJob(source, { sourceFormat: 'CSV' });
  assert.equal(job.metadata.configuration.load.sourceUris[0], 'gs://zigquery-node-test/people.csv');
});
