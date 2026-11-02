// Starts one emulator per test file, as a Docker container or a local binary.
//
// By default the emulator runs from its published Docker image, the way downstream
// docker-compose files consume it. Setting BIGQUERY_EMULATOR_BINARY to a zigquery-server
// executable runs that binary as a child process instead, which needs no Docker daemon:
//
//     BIGQUERY_EMULATOR_BINARY=../../zig-out/dist/bin/zigquery-server npm test

import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:net';
import { randomUUID } from 'node:crypto';
import { after, before, test as nodeTest } from 'node:test';
import assert from 'node:assert/strict';

import { BigQuery } from '@google-cloud/bigquery';
import { PassThroughClient } from 'google-auth-library';

import { KNOWN_FAILURES } from './known_failures.mjs';

export const PROJECT_ID = 'bigquery-emulator-test';

// The server prints this only after both the REST and gRPC listeners are bound.
const READY_LOG_LINE = 'REST server listening at';

const IMAGE = `${process.env.BIGQUERY_EMULATOR_REPOSITORY ?? 'ghcr.io/recidiviz/zigquery-emulator'}:${
  process.env.BIGQUERY_EMULATOR_VERSION ?? 'latest'
}`;
const BINARY = process.env.BIGQUERY_EMULATOR_BINARY;
const STARTUP_TIMEOUT_MS = 30_000;

/** Returns a TCP port nothing is listening on right now. */
async function freePort() {
  const server = createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

function emulatorArgs(port, grpcPort) {
  return [
    `--project=${PROJECT_ID}`,
    '--log-level=info',
    '--database=:memory:',
    `--port=${port}`,
    `--grpc-port=${grpcPort}`,
  ];
}

async function waitFor(ready, describe) {
  const deadline = Date.now() + STARTUP_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (ready()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`emulator did not start within ${STARTUP_TIMEOUT_MS} ms:\n${describe()}`);
}

async function startProcess(port, grpcPort) {
  const child = spawn(BINARY, emulatorArgs(port, grpcPort), { stdio: ['ignore', 'pipe', 'pipe'] });
  let logs = '';
  child.stdout.on('data', (chunk) => (logs += chunk));
  child.stderr.on('data', (chunk) => (logs += chunk));
  await waitFor(() => {
    if (child.exitCode !== null) throw new Error(`emulator exited early:\n${logs}`);
    return logs.includes(READY_LOG_LINE);
  }, () => logs);
  return () => {
    child.kill();
  };
}

async function startContainer(port, grpcPort) {
  const name = `zigquery-node-${randomUUID()}`;
  execFileSync('docker', [
    'run', '--rm', '--detach', '--name', name,
    '--publish', `${port}:${port}`,
    '--publish', `${grpcPort}:${grpcPort}`,
    IMAGE, ...emulatorArgs(port, grpcPort),
  ]);
  const logs = () => {
    const out = spawnSync('docker', ['logs', name], { encoding: 'utf8' });
    return out.stdout + out.stderr;
  };
  await waitFor(() => logs().includes(READY_LOG_LINE), logs);
  return () => {
    execFileSync('docker', ['rm', '--force', name], { stdio: 'ignore' });
  };
}

/**
 * Registers hooks that start an emulator before the file's tests and stop it after them.
 *
 * Returns an object whose url and client fields are filled in once the emulator is up. The
 * client neither retries nor authenticates, so an emulator error fails the test at once.
 */
export function useEmulator() {
  const emulator = { url: '', client: /** @type {BigQuery} */ (undefined) };
  let stop = () => {};
  before(async () => {
    const port = await freePort();
    const grpcPort = await freePort();
    stop = BINARY ? await startProcess(port, grpcPort) : await startContainer(port, grpcPort);
    emulator.url = `http://127.0.0.1:${port}`;
    emulator.client = new BigQuery({
      projectId: PROJECT_ID,
      apiEndpoint: emulator.url,
      autoRetry: false,
      // Sends requests without credentials, so the suite never reads the machine's
      // Application Default Credentials.
      authClient: new PassThroughClient(),
    });
  });
  after(() => stop());
  return emulator;
}

/** Returns a dataset name no other test in the run uses. */
export function uniqueDatasetId(prefix) {
  return `${prefix}_${randomUUID().replaceAll('-', '')}`;
}

/**
 * Defines a test, inverted when KNOWN_FAILURES lists its name.
 *
 * A listed test passes while its body fails and fails once its body passes, so an entry has
 * to be removed as soon as the emulator gains what it was waiting on.
 */
export function test(name, fn) {
  const reason = KNOWN_FAILURES[name];
  if (reason === undefined) return nodeTest(name, fn);
  return nodeTest(`${name} [known failure: ${reason}]`, async (t) => {
    try {
      await fn(t);
    } catch (err) {
      t.diagnostic(`fails as expected: ${err.message}`);
      return;
    }
    assert.fail(`"${name}" passes now; remove it from KNOWN_FAILURES in known_failures.mjs`);
  });
}
