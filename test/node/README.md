# Node integration tests

End-to-end tests that drive the emulator through the official
[`@google-cloud/bigquery`](https://www.npmjs.com/package/@google-cloud/bigquery)
client, with Node's built-in test runner. They cover the client paths
downstream Node services rely on that the Python suite does not reach:
jobs.insert with a client-chosen job id, tabledata.list, load jobs, and the
resumable upload session URI.

## Running

Needs Node 22 or newer.

### Against a local build (no Docker)

```bash
# from the repo root
zig build dist --release=fast \
    -Dshim-dylib=bazel-bin/shim/libgooglesql_shim.dylib \
    -Dshim-static-obj=bazel-bin/shim/libgooglesql_shim_static_macos.o \
    --prefix zig-out/dist

cd test/node
npm ci
BIGQUERY_EMULATOR_BINARY=$PWD/../../zig-out/dist/bin/zigquery-server npm test
```

### Against the Docker image (what CI runs)

```bash
cd test/node
npm ci
npm test                             # ghcr.io/recidiviz/zigquery-emulator:latest

# a locally built image
BIGQUERY_EMULATOR_REPOSITORY=zigquery-emulator BIGQUERY_EMULATOR_VERSION=ci npm test
```

Each test file starts its own emulator on free ports, so files run in
parallel.

## Known failures

`known_failures.mjs` lists tests the emulator does not pass yet. A listed test
passes while it fails and fails once it passes, so an entry has to be removed
in the change that fixes it.
