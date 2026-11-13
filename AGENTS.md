# AGENTS.md

zigquery is a BigQuery emulator: a Zig engine and REST/gRPC server over a C++ googlesql
analyzer shim (built with Bazel) and SQLite. The product is answering exactly what BigQuery
answers, so every change is judged against BigQuery's observable behavior.

## Before opening a pull request

1. Start from an open GitHub issue that a maintainer filed, or one where a maintainer has
   commented to accept it or assigned it. If no such issue exists, open one (or comment on
   the existing one) describing the BigQuery behavior and the emulator's behavior, and stop
   there until a maintainer responds.
2. Search open PRs and recent `main` commits for the same fix. Duplicates get closed.
3. Keep one issue per PR, and reference it in the body with `Fixes #N`.
4. Run the commands under "Commands" and confirm each one passes.

## Pull requests, issues, and comments

- Title in conventional-commit form, matching `git log`: `fix(driver): …`, `feat(server): …`,
  `refactor: …`, `docs: …`. The title states the behavior, not the issue number.
- Fill in `.github/pull_request_template.md`. Lead with what BigQuery does and what the
  emulator did instead, then list the spec cases added and the commands run.
- Keep comments short and lead with the conclusion or the action needed. Post results, not
  work logs.

## Setup

`docs/BUILD.md` covers setup and every `zig build` step. The quickest path skips the
googlesql build: download the shim dylib from the latest GitHub release into
`bazel-bin/shim/` and pass `-Dshim-dylib=./bazel-bin/shim/libgooglesql_shim.dylib` (`.so` on
Linux) to each build. A full Bazel build of the shim takes over an hour; it is only needed
when you change `shim/` or `MODULE.bazel`.

## Commands

CI runs these on every PR; append `-Dshim-dylib=<path>` to the `zig build` steps.

```sh
zig build test                     # engine unit tests
zig build test-server              # server unit tests
zig build spec -- --strict         # conformance corpus
zig fmt --check build.zig entrypoints tools
zig build --build-file tools/ephor/build.zig run -- --summary --fail-on=note
```

Run `zig build gen-proto` after touching anything under `proto/`; CI fails if its outputs
drift. Narrow a spec run with `-- --filter <path substring> --case <description substring>`.
The Python client suite in `test/python` is described in `test/python/README.md`.

## Structure

| Path                                           | Contents                                                          |
|------------------------------------------------|-------------------------------------------------------------------|
| `src/`                                         | Engine: `driver.zig`, `analyzer_ffi.zig`, `sqlite.zig`            |
| `src/server/`                                  | Emulator: REST handlers, router, Storage Read gRPC service        |
| `entrypoints/`                                 | `cli.zig`, `server.zig`, spec runner, benches                     |
| `shim/`                                        | C++ googlesql analyzer shim, built by Bazel                       |
| `testdata/specs/{bigquery,googlesql,zigquery}` | Conformance corpus, one `.zon` file per area                      |
| `third_party/googlesql/docs/`                  | Vendored BigQuery SQL reference, cited by spec cases and comments |
| `tools/`                                       | ephor static analysis and helper scripts                          |

## Rules

- Every behavior change carries a spec case in `testdata/specs/**/*.zon`. The specs are the
  truth; implementation comments name the behavior briefly and point at the spec.
- Expected values come from BigQuery: the vendored reference, the REST reference, or a
  measured query against real BigQuery. Record a measurement's provenance in a comment on the
  `.zon` case, for example `// (my-project, 2026-08-07)`.
- `src/proto/resolved_ast.zig`, `src/server/proto/bigquery.zig`, and
  `src/server/proto/storage.zig` are generated; change them through `zig build gen-proto`.
- ephor must report zero findings. Lines wrap at 100 columns, comments included; wrap at
  100, not 72 or 80.
- `testdata/spec_baseline.txt` and `testdata/spec_known_failures.txt` change only when the
  issue is about those lists themselves.

## Code style

Write Zig by `zig zen`: communicate intent precisely, edge cases matter, favor reading code
over writing it, one obvious way to do things, compile errors over runtime crashes over bugs,
resource deallocation must succeed, and memory is a resource.

- Declare `?T` only when null is a state the caller handles. `bool` fields default to `false`.
- Assert impossible states with `std.debug.assert` or `unreachable`; handle only the cases
  the input can produce.
- Return an error or log it, once, at the layer that can act on it.
- Add log lines only for errors and security events.

## Comments

Clear names carry the what; a comment carries the why: the BigQuery rule, the invariant, the
non-obvious reason. Self-evident operations, getters, and standard Zig idioms go uncommented.

- Write each comment so it reads true the day it lands and ten years later. If it needed
  deleting once the change stops being news, it belongs in the commit message. That covers
  refactor justifications and any phrasing that describes a diff ("used to", "instead",
  "already", "as this did", "before").
  - Bad: `// Anchoring on Jan 1 instead, as this did, lands a week early`
  - Good: `// The Monday on or before January 4th`
- Cite BigQuery's reference by file and anchor instead of quoting its prose or its output.
  Use the bare filename; the vendored copy is in `third_party/googlesql/docs/`.
  - Bad: `// "If the JSON value isn't a string, an error is produced" (json_functions.md)`
  - Good: `// STRING(JSON): JSON strings only; LAX_STRING is the renderer.`
    `// json_functions.md#string_for_json`
- Specs hold the expectations. The implementation comment gives the brief name, for example
  `// 'J': ISO day of the year (format-elements.md#format_elements_date_time)`.
- State the rule rather than listing the cases it covers.
  - Bad: `// %H %I %l %s %X are clock elements; %z %Ez %Z carry a zone. None has a DATE field.`
  - Good: `// Elements a DATE has no field for.`
- Write plain statements of what is: no emphasis markup, no rhetorical contrast ("that is the
  opposite of…").
- Provenance such as a measurement date belongs on the `.zon` case beside the value it
  supports; dates in source rot.

`.zon` spec comments follow the same rules, except that a spec comment carries the expected
value and the reasoning that picks it.
