// tabledata.list through Table.getRows.

import assert from 'node:assert/strict';

import { test, uniqueDatasetId, useEmulator } from './emulator.mjs';

const emulator = useEmulator();

const ROWS = [
  { person_id: 1, district: 'NORTH' },
  { person_id: 2, district: 'SOUTH' },
  { person_id: 3, district: 'EAST' },
  { person_id: 4, district: 'WEST' },
  { person_id: 5, district: 'CENTRAL' },
];

let created;

/** Returns the table holding ROWS, creating it on first use. */
function peopleTable() {
  created ??= (async () => {
    const [dataset] = await emulator.client.createDataset(uniqueDatasetId('tabledata'));
    const [table] = await dataset.createTable('people', {
      schema: [
        { name: 'person_id', type: 'INTEGER' },
        { name: 'district', type: 'STRING' },
      ],
    });
    await table.insert(ROWS);
    return table;
  })();
  return created;
}

const byPersonId = (a, b) => a.person_id - b.person_id;

test('getRows returns every row of a table', async () => {
  const table = await peopleTable();
  const [rows] = await table.getRows();
  assert.deepEqual(rows.sort(byPersonId), ROWS);
});

test('getRows pages with maxResults and pageToken', async () => {
  const table = await peopleTable();
  const [first, next] = await table.getRows({ maxResults: 2, autoPaginate: false });
  assert.equal(first.length, 2);
  assert.ok(next?.pageToken, 'a partial page carries a pageToken');

  const rest = [];
  let query = next;
  while (query) {
    const [page, following] = await table.getRows({ ...query, autoPaginate: false });
    rest.push(...page);
    query = following;
  }
  assert.deepEqual([...first, ...rest].sort(byPersonId), ROWS);
});

test('getRows returns only selectedFields', async () => {
  const table = await peopleTable();
  const [rows] = await table.getRows({ selectedFields: 'district' });
  assert.deepEqual(rows.map((row) => Object.keys(row)), ROWS.map(() => ['district']));
});

test('getRows starts at startIndex', async () => {
  const table = await peopleTable();
  const [rows] = await table.getRows({ startIndex: '3' });
  assert.equal(rows.length, 2);
});

test('getRows on a missing table is a 404', async () => {
  const table = await peopleTable();
  await assert.rejects(
    table.dataset.table('no_such_table').getRows(),
    (err) => err.code === 404,
  );
});
