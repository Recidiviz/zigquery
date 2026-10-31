// The resumable upload protocol, spoken directly: the Node client only sends multipart uploads,
// while the Python client and the bq tool open a session and send the bytes to the session URI
// the server returns. api-uploads

import assert from 'node:assert/strict';

import { PROJECT_ID, test, uniqueDatasetId, useEmulator } from './emulator.mjs';

const emulator = useEmulator();

async function openSession(datasetId) {
  const response = await fetch(
    `${emulator.url}/upload/bigquery/v2/projects/${PROJECT_ID}/jobs?uploadType=resumable`,
    {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-upload-content-type': 'text/csv' },
      body: JSON.stringify({
        configuration: {
          load: {
            destinationTable: { projectId: PROJECT_ID, datasetId, tableId: 'people' },
            sourceFormat: 'CSV',
            schema: {
              fields: [
                { name: 'person_id', type: 'INTEGER' },
                { name: 'district', type: 'STRING' },
              ],
            },
          },
        },
      }),
    },
  );
  assert.equal(response.status, 200);
  return response.headers.get('location');
}

test('a resumable upload session URI names the host the client used', async () => {
  const datasetId = uniqueDatasetId('resumable');
  await emulator.client.createDataset(datasetId);
  const location = await openSession(datasetId);
  assert.equal(new URL(location).origin, emulator.url);
});

test('a resumable upload completes through its session URI', async () => {
  const datasetId = uniqueDatasetId('resumable');
  await emulator.client.createDataset(datasetId);
  const location = await openSession(datasetId);

  // The emulator's own URL rather than the one it advertised, so this exercises the upload
  // protocol whatever host the session URI names.
  const session = new URL(location);
  const target = new URL(session.pathname + session.search, emulator.url);
  const response = await fetch(target, { method: 'PUT', body: '1,NORTH\n2,SOUTH\n' });
  assert.equal(response.status, 200);
  const job = await response.json();
  assert.equal(job.status.state, 'DONE');

  const [rows] = await emulator.client.query(`SELECT COUNT(*) AS n FROM ${datasetId}.people`);
  assert.deepEqual(rows, [{ n: 2 }]);
});
