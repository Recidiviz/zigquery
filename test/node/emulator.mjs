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

/** Polls ready, running probe first on each round when one is given. */
async function waitFor(ready, describe, probe = async () => {}) {
  const deadline = Date.now() + STARTUP_TIMEOUT_MS;
  while (Date.now() < deadline) {
    await probe();
    if (ready()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`container did not start within ${STARTUP_TIMEOUT_MS} ms:\n${describe()}`);
}

// fake-gcs-server 1.56.1, pinned by its multi-platform index digest.
const FAKE_GCS_IMAGE = 'fsouza/fake-gcs-server@sha256:' +
  '797ce226d62f947c009dc40246b30cfb456b8473d8241407f9d6f2c04e4d69ef';
const FAKE_GCS_PORT = 4443;

function containerLogs(name) {
  const out = spawnSync('docker', ['logs', name], { encoding: 'utf8' });
  return out.stdout + out.stderr;
}

/**
 * Starts fake-gcs-server over plain HTTP, publishing its port so the tests can seed it.
 *
 * Args:
 *   network: the Docker network an emulator container reaches it on, or null when the
 *     emulator runs as a local process and reaches it through the published port.
 *
 * Returns the URL the tests use, the STORAGE_EMULATOR_HOST the emulator uses, and a stop
 * function.
 */
async function startFakeGcs(network) {
  const name = `zigquery-node-gcs-${randomUUID()}`;
  const port = await freePort();
  execFileSync('docker', [
    'run', '--rm', '--detach', '--name', name,
    ...(network ? ['--network', network] : []),
    '--publish', `${port}:${FAKE_GCS_PORT}`,
    FAKE_GCS_IMAGE, '-scheme', 'http', '-port', String(FAKE_GCS_PORT),
  ]);
  const url = `http://127.0.0.1:${port}`;
  let ready = false;
  await waitFor(() => ready, () => containerLogs(name), async () => {
    ready = await fetch(`${url}/storage/v1/b`).then((r) => r.ok, () => false);
  });
  return {
    url,
    emulatorHost: network ? `http://${name}:${FAKE_GCS_PORT}` : url,
    stop: () => execFileSync('docker', ['rm', '--force', name], { stdio: 'ignore' }),
  };
}

async function startProcess(port, grpcPort, env) {
  const child = spawn(BINARY, emulatorArgs(port, grpcPort), {
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, ...env },
  });
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

async function startContainer(port, grpcPort, env, network) {
  const name = `zigquery-node-${randomUUID()}`;
  execFileSync('docker', [
    'run', '--rm', '--detach', '--name', name,
    ...(network ? ['--network', network] : []),
    ...Object.entries(env).flatMap(([key, value]) => ['--env', `${key}=${value}`]),
    '--publish', `${port}:${port}`,
    '--publish', `${grpcPort}:${grpcPort}`,
    IMAGE, ...emulatorArgs(port, grpcPort),
  ]);
  await waitFor(() => containerLogs(name).includes(READY_LOG_LINE), () => containerLogs(name));
  return () => {
    execFileSync('docker', ['rm', '--force', name], { stdio: 'ignore' });
  };
}

/**
 * Registers hooks that start an emulator before the file's tests and stop it after them.
 *
 * Returns an object whose url and client fields are filled in once the emulator is up. The
 * client neither retries nor authenticates, so an emulator error fails the test at once.
 *
 * Args:
 *   options.gcs: also start fake-gcs-server and point the emulator's STORAGE_EMULATOR_HOST at
 *     it; the returned object's gcsUrl is then where the tests seed objects.
 */
export function useEmulator({ gcs = false } = {}) {
  const emulator = { url: '', gcsUrl: '', client: /** @type {BigQuery} */ (undefined) };
  const stops = [];
  before(async () => {
    const env = {};
    let network = null;
    if (gcs) {
      if (!BINARY) {
        network = `zigquery-node-${randomUUID()}`;
        execFileSync('docker', ['network', 'create', network], { stdio: 'ignore' });
        stops.push(() => execFileSync('docker', ['network', 'rm', network], { stdio: 'ignore' }));
      }
      const storage = await startFakeGcs(network);
      stops.push(storage.stop);
      emulator.gcsUrl = storage.url;
      env.STORAGE_EMULATOR_HOST = storage.emulatorHost;
    }
    const port = await freePort();
    const grpcPort = await freePort();
    stops.push(BINARY
      ? await startProcess(port, grpcPort, env)
      : await startContainer(port, grpcPort, env, network));
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
  after(() => {
    for (const stop of stops.reverse()) stop();
  });
  return emulator;
}

/** Creates a bucket in fake-gcs-server through the JSON API. */
export async function createBucket(gcsUrl, bucket) {
  const response = await fetch(`${gcsUrl}/storage/v1/b`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ name: bucket }),
  });
  assert.equal(response.status, 200, await response.text());
}

/** Writes one object into fake-gcs-server through the JSON API's media upload. */
export async function putObject(gcsUrl, bucket, name, body) {
  const response = await fetch(
    `${gcsUrl}/upload/storage/v1/b/${bucket}/o?uploadType=media&name=${encodeURIComponent(name)}`,
    { method: 'POST', body },
  );
  assert.equal(response.status, 200, await response.text());
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
