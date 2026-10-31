// jobs.insert through createQueryJob, which names its job before the request is sent and keeps
// using that name for every later call on the returned Job.

import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

import { test, uniqueDatasetId, useEmulator } from './emulator.mjs';

const emulator = useEmulator();

test('createQueryJob results are readable through the returned job', async () => {
  const [job] = await emulator.client.createQueryJob({ query: 'SELECT 17 AS n' });
  const [rows] = await job.getQueryResults();
  assert.deepEqual(rows, [{ n: 17 }]);
});

test('createQueryJob reports the rows a DML statement changed', async () => {
  const datasetId = uniqueDatasetId('dml');
  await emulator.client.createDataset(datasetId);
  await emulator.client.query(`CREATE TABLE ${datasetId}.people (person_id INT64)`);

  const [job] = await emulator.client.createQueryJob({
    query: `INSERT INTO ${datasetId}.people (person_id) VALUES (101), (102), (103)`,
  });
  await job.getQueryResults();
  const [metadata] = await job.getMetadata();
  assert.equal(metadata.statistics.query.numDmlAffectedRows, '3');
});

test('jobs.insert keeps the jobId the client chose', async () => {
  const jobId = `chosen_${randomUUID()}`;
  const [job, response] = await emulator.client.createQueryJob({ query: 'SELECT 1', jobId });
  assert.equal(response.jobReference.jobId, jobId);
  const [metadata] = await job.getMetadata();
  assert.equal(metadata.jobReference.jobId, jobId);
});

test('jobs.insert rejects a jobId already in use', async () => {
  const jobId = `reused_${randomUUID()}`;
  await emulator.client.createQueryJob({ query: 'SELECT 1', jobId });
  await assert.rejects(
    emulator.client.createQueryJob({ query: 'SELECT 2', jobId }),
    (err) => err.code === 409,
  );
});
