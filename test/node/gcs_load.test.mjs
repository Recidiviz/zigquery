// Load jobs that read gs:// objects from fake-gcs-server, the way a service under docker-compose
// loads files its pipeline staged in a bucket.

import assert from 'node:assert/strict';

import {
  createBucket,
  putObject,
  test,
  uniqueDatasetId,
  useEmulator,
} from './emulator.mjs';

const emulator = useEmulator({ gcs: true });

const BUCKET = 'zigquery-node-staging';

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

const staged = (name) => new File(new Bucket(BUCKET), name);

let seeded;

/** Stages the objects the tests load, once, on first use. */
function seed() {
  seeded ??= (async () => {
    const put = (name, body) => putObject(emulator.gcsUrl, BUCKET, name, body);
    await createBucket(emulator.gcsUrl, BUCKET);
    await put('single/people.csv', '1,NORTH\n2,SOUTH\n');
    await put('shards/part-000.csv', 'person_id,district\n1,NORTH\n');
    await put('shards/part-001.csv', 'person_id,district\n2,SOUTH\n');
    await put('shards/manifest.json', '{"files":2}\n');
    await put(
      'json/people.json',
      '{"person_id":3,"district":"EAST"}\n{"person_id":4,"district":"WEST"}\n',
    );
  })();
  return seeded;
}

async function emptyTable(prefix) {
  await seed();
  const [dataset] = await emulator.client.createDataset(uniqueDatasetId(prefix));
  const [table] = await dataset.createTable('people', { schema: SCHEMA });
  return table;
}

async function rowsOf(table) {
  const [rows] = await emulator.client.query(
    `SELECT person_id, district FROM ${table.dataset.id}.people ORDER BY person_id`,
  );
  return rows;
}

test('createLoadJob loads a gs:// CSV object', async () => {
  const table = await emptyTable('gcs_csv');
  const [job] = await table.createLoadJob(staged('single/people.csv'), { sourceFormat: 'CSV' });
  assert.equal(job.metadata.status.state, 'DONE');
  assert.equal(String(job.metadata.statistics.load.inputFiles), '1');
  assert.deepEqual(await rowsOf(table), [
    { person_id: 1, district: 'NORTH' },
    { person_id: 2, district: 'SOUTH' },
  ]);
});

test('a gs:// wildcard loads every match, skipping each file header', async () => {
  const table = await emptyTable('gcs_wildcard');
  const [job] = await table.createLoadJob(staged('shards/part-*.csv'), {
    sourceFormat: 'CSV',
    skipLeadingRows: 1,
  });
  assert.equal(String(job.metadata.statistics.load.inputFiles), '2');
  assert.deepEqual(await rowsOf(table), [
    { person_id: 1, district: 'NORTH' },
    { person_id: 2, district: 'SOUTH' },
  ]);
});

test('a gs:// load reads NEWLINE_DELIMITED_JSON', async () => {
  const table = await emptyTable('gcs_json');
  await table.createLoadJob(staged('json/people.json'), {
    sourceFormat: 'NEWLINE_DELIMITED_JSON',
  });
  assert.deepEqual(await rowsOf(table), [
    { person_id: 3, district: 'EAST' },
    { person_id: 4, district: 'WEST' },
  ]);
});

test('a missing gs:// object fails the load job as not found', async () => {
  const table = await emptyTable('gcs_missing');
  await assert.rejects(
    table.createLoadJob(staged('single/absent.csv'), { sourceFormat: 'CSV' }),
    (err) => err.errors?.[0]?.reason === 'notFound',
  );
});

test('a gs:// wildcard that matches nothing fails the load job as not found', async () => {
  const table = await emptyTable('gcs_nomatch');
  await assert.rejects(
    table.createLoadJob(staged('shards/none-*.csv'), { sourceFormat: 'CSV' }),
    (err) => err.errors?.[0]?.reason === 'notFound',
  );
});
