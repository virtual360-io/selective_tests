# selective_tests

Selective test execution for the V360 monorepo, inspired by Stripe's
[Selective test execution at Stripe: Fast CI for a 50M-line Ruby monorepo](https://stripe.dev/blog/selective-test-execution-at-stripe-fast-ci-for-a-50m-line-ruby-monorepo).

The gem does two things:

1. **Tracks, while the Minitest suite runs, which files each test touches**
   (using stdlib `Coverage`) and writes a manifest at the project root.
2. **Ships a `selective-tests` CLI** that, given a list of changed files
   (e.g., a PR diff), returns the tests that need to run.

## Workflow

```
┌──────────────────────┐    ┌─────────────────────────────┐    ┌────────────────────────────┐    ┌────────────────────────┐
│  run suite on main   │ -> │ .selective_tests/run-*.ndjson│ -> │ selective-tests consolidate│ -> │ selective-tests select │
│ TRACK_TEST_FILES=true│    │  (raw, per-process)          │    │  --> .selective_tests/     │    │  --> tests for the PR  │
│                      │    │                              │    │      manifest.json         │    │                        │
└──────────────────────┘    └─────────────────────────────┘    └────────────────────────────┘    └────────────────────────┘
```

End-to-end flow:

```bash
# 1) Once (or periodically, in develop's CI): collect raw run files
TRACK_TEST_FILES=true bundle exec rails test

# 2) Consolidate the per-process NDJSONs into a deduplicated manifest.json
bundle exec selective-tests consolidate --prune

# 3) On any PR: run only the tests affected by the diff
git diff --name-only origin/develop...HEAD \
  | bundle exec selective-tests select \
  | xargs -r bundle exec rails test
```

Step (1) populates `.selective_tests/run-*.ndjson` (one per worker
process, with the per-test file lists). Step (2) merges them into a
single `manifest.json` shaped as an inverted index `file -> [tests]`,
which is what gets versioned. Step (3) reads `manifest.json` and prints
only the tests that touch any file in the diff. A test file in the
input is returned as-is; files unknown to the manifest are reported on
`stderr`.

## Collecting the manifest

```bash
TRACK_TEST_FILES=true bundle exec rails test
```

Each worker (the suite runs parallelized via `:processes`) writes an
NDJSON file at `.selective_tests/run-<pid>.ndjson`. Each line:

```json
{"test":"test/models/user_test.rb","files":["app/models/user.rb","..."],"recorded_at":1714502400}
```

Recommended setup: collect on `develop`'s CI (or on a daily cron),
run `selective-tests consolidate --prune` to turn the run files into
`manifest.json`, and version that single JSON file. Consumer PRs only
need `manifest.json` — the `run-*.ndjson` are intermediate artifacts.

## Selecting tests for a diff

```bash
git diff --name-only origin/develop...HEAD | bundle exec selective-tests select
```

Output: one test per line, ready for `xargs`/`bundle exec rails test`:

```bash
git diff --name-only origin/develop...HEAD \
  | bundle exec selective-tests select \
  | xargs -r bundle exec rails test
```

Rules:
- a test file in the input (matches `*_test.rb`) is always returned;
- a file known to the manifest yields every test that touches it;
- a file unknown to the manifest is reported on `stderr` and skipped
  (use `--strict` to fail).

## Commands

```
selective-tests select [files...]   Print the affected tests (one per line)
selective-tests consolidate         Merge run-*.ndjson into manifest.json
                                    (file -> [tests]). Pass --prune to delete
                                    the run files after writing.
selective-tests info                Print manifest statistics
selective-tests clear               Delete the manifest files
```

Main flags for `select`:

- `--manifest-dir DIR` — manifest directory (default: `.selective_tests`)
- `--root DIR` — project root (default: `pwd`)
- `--test-pattern REGEXP` — regex that identifies test files (default: `_test\.rb\z`)
- `--strict` — exit with code 2 if any input file is unknown
- `-0`, `--null` — use `\0` as the output separator (for `xargs -0`)

## Architecture

Source layout:

```
lib/
├── selective_tests.rb              # entry point
└── selective_tests/
    ├── version.rb
    ├── configuration.rb            # paths and defaults
    ├── coverage_tracker.rb         # stdlib Coverage wrapper
    ├── manifest.rb                 # reads/writes .selective_tests/
    ├── selector.rb                 # maps diff -> tests to run
    ├── minitest.rb                 # Minitest plugin (hooks + install)
    └── cli.rb                      # OptionParser + subcommands
exe/
└── selective-tests                 # CLI entry point
```

### `lib/selective_tests.rb`
Entry point. Defines `SelectiveTests.config` / `SelectiveTests.configure`,
`SelectiveTests.tracking_enabled?` (returns `true` when
`TRACK_TEST_FILES=true`) and the `TRACKING_ENV` constant. **It does not
install hooks** — Minitest tracking is wired up by `selective_tests/minitest`.

### `Configuration`
Three attributes: `project_root`, `manifest_dir`, `test_pattern`. Resolves
the root automatically (`SELECTIVE_TESTS_ROOT` -> `Rails.root` -> `Dir.pwd`)
and `manifest_dir` to `<root>/.selective_tests` (overridable via
`SELECTIVE_TESTS_MANIFEST_DIR`). The `test_pattern` (`/_test\.rb\z/`) is
queried by the `Selector` to decide whether a path is a test file.

### `CoverageTracker`
Thin wrapper over stdlib `Coverage`:

- `start` — calls `Coverage.start` if it isn't already running. **Must run
  before `config/environment`**, otherwise files already loaded by
  Bundler/Rails won't be instrumented.
- `consume!` — uses `Coverage.result(stop: false, clear: true)` to read
  **and** zero the counters in a single atomic step. The return value is
  the list of paths with at least one line executed since the previous
  call.

That's what enables per-test tracking: `consume!` in `before_setup`
discards leftover counters, `consume!` in `after_teardown` returns the
exact set of files touched by that test.

### `Manifest`
Two on-disk shapes coexist under `<manifest_dir>`:

1. **Raw**, written during a run, NDJSON one-per-line at
   `run-<pid>.ndjson`:

   ```json
   {"test":"test/models/user_test.rb","files":["app/models/user.rb",...],"recorded_at":1714502400}
   ```

2. **Consolidated**, the canonical artifact, a single
   `manifest.json` shaped as an inverted index `file -> [tests]`:

   ```json
   {
     "app/models/user.rb": ["test/models/user_test.rb", ...],
     "lib/shared.rb":      ["test/a_test.rb", "test/b_test.rb"],
     ...
   }
   ```

The consolidated form is what gets committed; the NDJSONs are
intermediate, written in parallel during the run.

Classes:

- `Manifest`: points at `dir` + `project_root`. Public methods:
  - `reverse_index` — reads `manifest.json` if present, otherwise
    builds the index from the `run-*.ndjson` files. Returns
    `file -> [tests]`.
  - `entries` — backward-compat view derived from `reverse_index`,
    returns `test -> [files]`. The latest line wins on duplicates.
  - `consolidate(prune: false)` — writes `manifest.json` from the run
    files. With `prune: true`, deletes the NDJSONs after the write.
  - `consolidated?` — `true` if `manifest.json` exists.
  - `clear!` — removes both the NDJSONs and `manifest.json`.
- `Manifest::Writer`: opens `run-<Process.pid>.ndjson` in append mode
  per worker. Since each forked worker has a distinct PID, **no
  locking is required** — different files, no contention. The writer
  normalizes paths to be relative to the project root and drops
  anything outside it (gems, `/usr/lib`, etc.).

NDJSON was chosen for the raw shape because it is append-friendly (no
need to re-read and rewrite the whole JSON for each test) and pairs
nicely with the PID-based filename for trivial parallelism.
`manifest.json` is what consumers actually read — deduplicated and
small.

### `Selector`
Pure in-memory operation over `Manifest#entries`. Builds a reverse index
`file -> [tests...]` on the first call and returns a `Result` with:

- `tests` — union of the tests affected by the input files plus any
  input file that already is a test (matches `test_pattern`);
- `unknown` — inputs that are neither in the manifest nor a test file
  (the gem can't say anything about them);
- `test_inputs` — subset of the input that was already a test, useful
  for debugging.

The "test file in the input is returned as-is" rule covers two cases: a
PR that modifies an existing test, or a PR that introduces a brand-new
test that hasn't shown up in any manifest yet.

### `MinitestIntegration` (`selective_tests/minitest`)
The integration point. `require 'selective_tests/minitest'` calls
`MinitestIntegration.install!` automatically when
`SelectiveTests.tracking_enabled?` is `true`, doing three things:

1. `CoverageTracker.start` — make sure `Coverage` is on;
2. `::Minitest::Test.prepend(TestHooks)` — inject `before_setup` and
   `after_teardown` into **every** test class;
3. `::Minitest.after_run { writer.close }` — close the NDJSON handle at
   the end of the suite.

`TestHooks#after_teardown` resolves the test's source file via
`self.class.instance_method(name).source_location.first` — works with
any Rails test class (including subclasses of
`ActionDispatch::IntegrationTest`, `ActionMailer::TestCase`, etc.).

Tracking works with `parallelize(workers: N, with: :processes)`:

- `Coverage.start` is called **in the parent**, before forking, so all
  boot-time files are instrumented;
- after `fork`, each worker has its own Coverage counters
  (copy-on-write), so a test in worker A doesn't pollute worker B;
- each worker writes to `run-<Process.pid>.ndjson` (distinct PID =
  distinct file = no contention);
- the first test's `before_setup` in each worker discards the noise from
  `parallelize_setup` (initialize_tenants, webdriver copy, etc.).

It does **not** work with `with: :threads` — `Coverage` is process-global
and concurrent threads would share counters. V360 uses `:processes`, so
this is fine.

### `CLI`
`OptionParser`-based, no external dependency. Subcommands: `select`,
`consolidate`, `info`, `clear`, `help`. `stdout` / `stderr` / `stdin`
are injected for testing — no subprocess required. Returns an exit code
(`EXIT_OK`, `EXIT_USAGE`, `EXIT_STRICT_UNKNOWN`); `exe/selective-tests`
is just `exit(SelectiveTests::CLI.run(ARGV))`.

### Collection flow, step by step

1. `test_helper.rb` checks `TRACK_TEST_FILES=true` and calls
   `Coverage.start` **before** `require '../config/environment'`.
2. After the environment loads, `require 'selective_tests/minitest'`
   installs `TestHooks` on `Minitest::Test`.
3. Rails forks N workers via `parallelize`.
4. For each test:
   1. `before_setup` -> `consume!` (discards everything since the previous test);
   2. `setup` + body + `teardown` run normally;
   3. `after_teardown` -> `consume!` returns the paths touched by the test;
      `Writer` appends a single NDJSON line.
5. End of suite -> `Minitest.after_run` closes the file handle.

### Selection flow, step by step

1. `selective-tests select <files...>` instantiates a `Manifest` rooted
   at `<root>/.selective_tests`.
2. `Selector#select` builds the reverse index once and iterates over the
   inputs, bucketing each into `tests` / `test_inputs` / `unknown`.
3. The CLI prints the tests on STDOUT (one per line, or `\0`-separated
   with `-0`) and the unknown files on STDERR.
4. Exit = 0 always, except for `--strict` with unknown input (= 2).

## Setup in V360

The gem ships in the `:test` group of the `Gemfile`. `test/test_helper.rb`
loads `selective_tests/minitest` when `TRACK_TEST_FILES=true`.

To collect the manifest locally:

```bash
TRACK_TEST_FILES=true bundle exec rails test
ls .selective_tests/
```

To select:

```bash
git diff --name-only origin/develop \
  | bundle exec selective-tests select
```

## SimpleCov compatibility

`selective_tests` uses `Coverage.result(stop: false, clear: true)`
between tests, which zeros the counters. If the suite is also running
with `REPORT_TEST_COVERAGE=true` (SimpleCov), SimpleCov's final report
will come out empty. Use one flag at a time.

## Reusable GitHub Action

The repository ships a composite Action at the root (`action.yml`) that
encapsulates the "compute affected tests for a PR" step. Consumers add a
single step to their PR workflow:

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0   # required for `git diff origin/<base>...HEAD`

- id: selective
  uses: virtual360-io/selective_tests@main
  with:
    base-ref: develop

- name: Run only the affected tests
  if: steps.selective.outputs.test-count != '0' && steps.selective.outputs.manifest-found == 'true'
  run: bundle exec rails test ${{ steps.selective.outputs.tests }}

- name: Fall back to full suite when manifest is missing
  if: steps.selective.outputs.manifest-found == 'false'
  run: bundle exec rails test
```

### Inputs

| Input            | Default                        | Description                                                              |
|------------------|--------------------------------|--------------------------------------------------------------------------|
| `base-ref`       | `develop`                      | Branch to diff against; the action runs `git diff origin/<base>...HEAD`. |
| `changed-files`  | (empty)                        | Newline-separated diff override; bypasses the git diff when set.         |
| `manifest-dir`   | `.selective_tests`             | Manifest path relative to the repo root.                                 |
| `bundler-cmd`    | `bundle exec selective-tests`  | Command used to invoke the CLI.                                          |
| `strict`         | `false`                        | When `true`, fail if any input file is unknown to the manifest.          |
| `output-file`    | (empty)                        | Optional file path to dump the selected tests, one per line.             |

### Outputs

| Output            | Description                                                                                           |
|-------------------|-------------------------------------------------------------------------------------------------------|
| `tests`           | Newline-separated list of selected test files (empty if none).                                        |
| `test-count`      | Number of test files selected. `0` means no tests are affected.                                       |
| `manifest-found`  | `true` if `manifest.json` or at least one `run-*.ndjson` is present; `false` means the caller falls back. |
| `unknown-count`   | Number of diff files unknown to the manifest (conservatively skipped).                                |
| `diff-file-count` | Number of files in the diff after applying `changed-files` or running `git diff`.                     |

### Behavior

- `manifest-found=false` → the action emits empty `tests`, `test-count=0`,
  and a workflow warning. The caller decides whether to skip or run the full
  suite.
- Empty diff → `test-count=0` and a notice; nothing to run.
- Test files in the input (matching `*_test.rb`) are returned verbatim, so
  PRs that introduce a brand-new test still pick it up.
- Unknown files (not in the manifest, not a test) are listed in the job
  log inside a `Files unknown to the manifest` group. They do not fail the
  step unless `strict: true`.

## Daily manifest refresh via cron

The [`selective-tests-cache.yml`](../../.github/workflows/selective-tests-cache.yml)
workflow runs daily at 06:00 UTC, executes the full suite with
`TRACK_TEST_FILES=true`, and pushes the resulting `.selective_tests/`
back to `develop`. On every run it:

1. checks out `develop`;
2. wipes `.selective_tests/run-*.ndjson` and `manifest.json` to start clean;
3. builds the test image (same pipeline as the `Rails Tests` workflow);
4. runs `resources/tests/run_all_tests.sh` with `TRACK_TEST_FILES=true`;
5. runs `bundle exec selective-tests consolidate --prune` to fold the
   NDJSONs into `manifest.json` and delete the raw run files;
6. runs `git add .selective_tests/`, commits and pushes (with
   `pull --rebase` and retry, in case `develop` moved while the suite
   was running).

`workflow_dispatch` is enabled for manual refreshes.

### Gem environment variables

| ENV                              | Default                      | Description                                                |
|----------------------------------|------------------------------|------------------------------------------------------------|
| `TRACK_TEST_FILES`               | (off)                        | Enables collection in Minitest                             |
| `SELECTIVE_TESTS_MANIFEST_DIR`   | `<root>/.selective_tests`    | Manifest directory                                         |
| `SELECTIVE_TESTS_ROOT`           | `Rails.root` or `pwd`        | Project root used to relativize paths                      |
