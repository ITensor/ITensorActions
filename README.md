# ITensorActions

Shared workflows for the ITensors Julia packages.

## Versioning

Callers should pin to a major-version tag rather than to `@main`:

```yaml
uses: "ITensor/ITensorActions/.github/workflows/Tests.yml@v1"
```

Releases follow `vMAJOR.MINOR.PATCH` (e.g. `v1.0.0`, `v1.0.1`,
`v1.1.0`). A mutable major-version tag (`v1`) is updated to point at
the latest `v1.x.y` after each release, mirroring the convention
used by `actions/checkout`, `julia-actions/setup-julia`, and similar
third-party reusable actions. Callers should reference `@v1` for
"latest in major version 1"; SHA-pinning to a specific `v1.x.y`
release is also supported when extra rigor is needed.

SemVer release decision rule:

- Patch (`v1.0.x`): bug fixes, docs-only improvements, or internal
  hardening that does not change caller-facing workflow interfaces.
- Minor (`v1.x.0`): backward-compatible new inputs, new reusable
  workflows, or additive behavior.
- Major (`v2.0.0`): breaking caller-facing changes (renamed/removed
  inputs, changed required secrets/permissions, incompatible behavior).

Each released commit should be assigned exactly one of the three bump
types above. Keep `v1.0.0`, `v1.1.0`, etc. immutable; move the mutable
`v1` tag to the newest `v1.x.y` release.

Docs-only PRs (for example README clarifications that do not change
workflow behavior) do not require a SemVer release, do not require a
new `v1.x.y` tag, and should not move `v1`.

Breaking changes (e.g. a renamed input) bump the major version. The
old major tag stays in place so existing callers keep working until
they migrate.

To cut a release, run `.scripts/release.sh vX.Y.Z` from a clean
`main` checkout. The script rewrites internal `@main` references in
the released commit to the current SHA so the tagged release is a
fully snapshot-stable bundle (its workflows reference its own
companion actions at a fixed commit, not at moving `@main`).

## Tests

The Tests workflow is designed to run the tests suite for Julia packages.
The workflow works best with a `runtests.jl` script that looks like this:

```julia
using Test

# check if user supplied args
pat = r"(?:--group=)(\w+)"
arg_id = findfirst(contains(pat), ARGS)
const GROUP = if isnothing(arg_id)
    uppercase(get(ENV, "GROUP", "ALL"))
else
    uppercase(only(match(pat, ARGS[arg_id]).captures))
end

@time begin
    if GROUP == "ALL" || GROUP == "CORE"
        @time include("test_core1.jl")
        @time include("test_core2.jl")
        # ...
    end
    if GROUP == "ALL" || GROUP == "OPTIONAL"
        @time include("test_optional1.jl")
        @time include("test_optional2.jl")
        # ...
    end
    # ...
end
```

An example workflow that uses this script is:

```yaml
name: Tests
on:
  push:
    branches:
      - 'master'
      - 'main'
      - 'release-'
    tags: '*'
    paths-ignore:
      - 'docs/**'
  pull_request:
  workflow_dispatch:

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  # Cancel intermediate builds: only if it is a pull request build.
  cancel-in-progress: ${{ startsWith(github.ref, 'refs/pull/') }}

jobs:
  tests:
    name: "Tests"
    strategy:
      fail-fast: false
      matrix:
        version:
          - 'lts' # minimal supported version
          - '1' # latest released Julia version
        # optionally, you can specify the group of tests to run
        # this uses multiple jobs to run the tests in parallel
        # if not specified, all tests will be run
        group:
          - 'core'
          - 'optional'
        os:
          - ubuntu-latest
          - macOS-latest
          - windows-latest
    uses: "ITensor/ITensorActions/.github/workflows/Tests.yml@v1"
    with:
      group: "${{ matrix.group }}"
      julia-version: "${{ matrix.version }}"
      os: "${{ matrix.os }}"
    secrets:
      CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}
```

### Draft PR behavior

By default, when a pull request is a draft, the Tests workflow only runs the
`ubuntu-latest` / Julia `1` (latest version) combination and skips all other
matrix entries. This gives fast feedback while saving CI minutes.

This is controlled by the `run-all-on-draft` input (default: `false`). To run
the full matrix even on draft PRs, set it to `true`:

```yaml
    uses: "ITensor/ITensorActions/.github/workflows/Tests.yml@v1"
    with:
      run-all-on-draft: true
      # ...
```

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `julia-version` | string | `"1"` | Julia version passed to `julia-actions/setup-julia`. |
| `julia-arch` | string | runner arch | Architecture of Julia to be used. |
| `project` | string | `"@."` | Value passed to Julia's `--project` flag. |
| `group` | string | `""` | Test group selector. Exposed to tests via the `GROUP` environment variable so a `runtests.jl` can selectively run a subset. |
| `self-hosted` | bool | `false` | Run on a self-hosted runner instead of `os`. |
| `os` | string | `"ubuntu-latest"` | Runner image used when `self-hosted` is `false`. |
| `nthreads` | number | `1` | Value of `JULIA_NUM_THREADS`. |
| `cache` | bool | `true` | Use `julia-actions/cache`. |
| `buildpkg` | bool | `true` | Run `julia-actions/julia-buildpkg` before testing. |
| `localregistry` | string | `""` | Newline-separated list of extra registry URLs to add before resolving (forwarded to `julia-actions/julia-buildpkg`). |
| `coverage` | bool | `true` | Collect coverage and upload via Codecov. |
| `coverage-directories` | string | `"src,ext"` | Comma-separated list of directories scanned by `julia-actions/julia-processcoverage`. |
| `julia-runtest-depwarn` | string | `"yes"` | Value passed to `julia-runtest`'s `--depwarn` flag. |
| `continue-on-error` | bool | `false` | Prevent the job from failing when tests fail. Also implicitly true for `julia-version: nightly`. |
| `timeout-minutes` | number | `60` | Maximum job runtime. |
| `run-all-on-draft` | bool | `false` | Run the full matrix on draft PRs. When `false`, draft PRs run only the `ubuntu-latest` / Julia `1` combination. |
| `apt-packages` | string | `""` | Space-separated apt packages to install on Ubuntu runners before Julia setup (e.g. `xvfb libgl1`). Ignored on non-Linux runners. |
| `test-prefix` | string | `""` | Prefix inserted in front of the `julia` invocation that runs the tests. Example: `xvfb-run -a -s "-screen 0 1024x768x24" ` for GUI-dependent tests. |
| `extra-env` | string | `""` | Multi-line `KEY=VALUE` pairs exported into the job's environment (via `$GITHUB_ENV`) before the test step. |
| `upload-artifacts-path` | string | `""` | When set, uploads the given file or directory as a per-matrix-cell artifact after tests run (on success or failure). |

### Secrets

| Secret | Required | Description |
|---|---|---|
| `CODECOV_TOKEN` | Yes | Upload token for Codecov. |

## Documentation

The documentation workflow is designed to build and deploy the documentation for Julia packages.
The workflow works best with a `docs/make.jl` script that looks like this:

```julia
using MyPackage
using Documenter

makedocs(; kwargs...)
deploydocs(; kwargs...)
```

An example workflow that uses this script is:

```yaml
name: "Documentation"

on:
  push:
    branches:
      - main
    tags: '*'
  pull_request:
  schedule:
    - cron: '1 4 * * 4'

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.ref_name != github.event.repository.default_branch || github.ref != 'refs/tags/v*' }}

jobs:
  build-and-deploy-docs:
    name: "Documentation"
    uses: "ITensor/ITensorActions/.github/workflows/Documentation.yml@v1"
    secrets: "inherit"
```

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `debug-documenter` | bool | `false` | Run Julia with `JULIA_DEBUG=Documenter` for extra debug output. |
| `github-token` | string | — | GitHub token used for authentication with the SSH deploy key. |
| `julia-version` | string | `"1"` | Julia version passed to `julia-actions/setup-julia`. |
| `localregistry` | string | `""` | Newline-separated list of extra registry URLs to add before resolving. |
| `self-hosted` | bool | `false` | Run on a self-hosted runner instead of `os`. |
| `os` | string | `"ubuntu-latest"` | Runner image used when `self-hosted` is `false`. |
| `cache` | bool | `true` | Use `julia-actions/cache`. |
| `coverage` | bool | `true` | Collect coverage from doctests and upload to Codecov. |
| `coverage-directories` | string | `"src,ext"` | Comma-separated list of directories scanned by `julia-actions/julia-processcoverage`. |
| `continue-on-error` | bool | `false` | Prevent the job from failing if the docs build fails. |
| `apt-packages` | string | `""` | Space-separated apt packages to install on Ubuntu runners before Julia setup (e.g. `xvfb libgl1`). Ignored on non-Linux runners. |
| `doc-prefix` | string | `""` | Prefix prepended to each `julia` invocation (both the project-setup step and the docs build step). Example: `xvfb-run -a -s "-screen 0 1024x768x24" ` for packages whose precompile workload requires a display. |
| `extra-env` | string | `""` | Multi-line `KEY=VALUE` pairs exported into the job's environment (via `$GITHUB_ENV`) before the setup and build steps. |

### Secrets

| Secret | Required | Description |
|---|---|---|
| `CODECOV_TOKEN` | No | Upload token for Codecov (only needed if `coverage` is `true` and the repo is private). |

## Formatting

The formatting workflows allow you to customize which directories are checked, so you can specify only the directories you want. Use the `directory` input to set the directory or directories for formatting (default is the root directory `.`). You can specify multiple directories, e.g. `src test`, and all will be checked by the formatter.

There are three workflows available: one for simply verifying the formatting, one for additionally applying suggested changes, and one that makes a PR to the repository formatting the code in the repository.

### Format Check

Format Check is split into two reusable workflows for security: a
**parse phase** that runs the formatter on the PR head with no
secrets in scope, and a **comment phase** that runs in the trusted
base-repo context and posts the format-suggestion comment. Branch
protection should require the parse phase's check
(`Format Check / Check Formatting`); the comment workflow exists only to
update the comment.

The split uses GitHub's standard `pull_request:` + `workflow_run:`
pattern. See [Securing your GitHub Actions](https://docs.github.com/en/actions/reference/security/secure-use)
for the rationale: running PR-controlled code (a formatter parsing
PR source) with `FORMATPULLREQUEST_PAT` in scope would be the same
risky shape as the IntegrationTest pre-fix configuration.

Add two downstream workflow files:

```yaml
# .github/workflows/FormatCheck.yml
name: "Format Check"

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]

jobs:
  format-check:
    name: "Format Check"
    uses: "ITensor/ITensorActions/.github/workflows/FormatCheck.yml@v1"
    with:
      directory: "." # Customize this to check a specific directory
```

```yaml
# .github/workflows/FormatCheckComment.yml
name: "Format Check Comment"

on:
  workflow_run:
    workflows: ["Format Check"]
    types: [completed]

jobs:
  comment:
    name: "Format Check Comment"
    if: >-
      github.event.workflow_run.event == 'pull_request'
    permissions:
      pull-requests: write
      actions: read
    uses: "ITensor/ITensorActions/.github/workflows/FormatCheckComment.yml@v1"
    secrets: inherit
```

The parse-phase workflow uploads the formatter's diff and the PR
metadata as an artifact named `format-check`; the comment workflow
downloads it from a separate `workflow_run` event after the parse run
completes and posts or updates the suggestion comment.

#### Format Check inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `directory` | string | `"."` | Directory (or space-separated list of directories) to check with `ITensorFormatter`. |
| `julia-version` | string | `"1"` | Julia version passed to `julia-actions/setup-julia`. |
| `concurrent-jobs` | bool | `false` | When `true`, runs use `github.run_id` as the concurrency group (each run gets its own group). When `false`, runs share `github.ref` and older runs are cancelled. |
| `cancel-in-progress` | bool | `true` | Whether to cancel in-progress runs in the same concurrency group. Only effective when `concurrent-jobs` is `false`. |

#### Format Check Comment inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `check-name` | string | `"Format Check"` | Name of the parse-phase workflow whose `workflow_run` events trigger the comment workflow. Override only if the parse-phase workflow's `name:` differs. |

### Format Pull Request

The Format Pull Request workflow has two modes depending on the trigger event:

- **Schedule / dispatch mode**: runs the formatter and opens a new pull request with the
  changes (bumping the patch version).
- **On-demand mode** (`issue_comment`): comment `/format` (configurable via the `trigger`
  input) on a pull request to apply formatting directly to that PR branch. The bot reacts
  with 👍 to confirm.

```yaml
name: "Format Pull Request"

on:
  schedule:
    - cron: '0 0 * * *'
  workflow_dispatch:
  # Optional: allow on-demand formatting by commenting "/format" on a PR.
  issue_comment:
    types: [created]

permissions:
  contents: write
  pull-requests: write

jobs:
  format-pull-request:
    name: "Format Pull Request"
    uses: "ITensor/ITensorActions/.github/workflows/FormatPullRequest.yml@v1"
    with:
      directory: "." # Customize this to check a specific directory
      # trigger: "/format" # Customize the on-demand trigger phrase (default: "/format")
```

#### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `directory` | string | `"."` | Directory (or space-separated list of directories) that `ITensorFormatter` should format. |
| `julia-version` | string | `"1"` | Julia version passed to `julia-actions/setup-julia`. |
| `trigger` | string | `"/format"` | Comment trigger phrase for on-demand formatting (only used when the workflow is invoked on `issue_comment`). |

## LiterateCheck

The LiterateCheck workflow is designed to keep the README of Julia packages up to date.
The workflow would look like:

```yaml
name: "Literate Check"

on:
  push:
    branches:
      - 'main'
    tags: '*'
  pull_request:

jobs:
  format-check:
    name: "Literate Check"
    uses: "ITensor/ITensorActions/.github/workflows/LiterateCheck.yml@v1"
```

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `julia-version` | string | `"1"` | Julia version passed to `julia-actions/setup-julia`. |
| `localregistry` | string | `""` | Newline-separated list of extra registry URLs to add before resolving. |

### Outputs

| Output | Description |
|---|---|
| `up_to_date` | `"true"` if `README.md` is up-to-date with its Literate source, `"false"` otherwise. |
| `literate-diff-patch` | A patch that can be applied to the repo to bring `README.md` in sync with its Literate source. Only set when `up_to_date` is `"false"`. |

## CompatHelper

The CompatHelper workflow is designed to periodically check dependencies for breaking
releases, and if so make PRs to bump the compat versions. By default this workflow
checks the Julia [General registry](https://github.com/JuliaRegistries/General)
for breaking releases of dependencies, but you can add other registries
by specifying the registry URLs with the `localregistry` option,
which should be strings with registry URLs seperated by a newline character (`\n`).
Here is an example workflow:

```yaml
name: "CompatHelper"

on:
  schedule:
    - cron: '0 0 * * *'
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

jobs:
  compat-helper:
    name: "CompatHelper"
    uses: "ITensor/ITensorActions/.github/workflows/CompatHelper.yml@v1"
    with:
      localregistry: "https://github.com/ITensor/ITensorRegistry.git"
    secrets: inherit
```

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `julia-version` | string | `"1"` | Julia version passed to `julia-actions/setup-julia`. |
| `localregistry` | string | `""` | Newline-separated list of extra registry URLs (besides General) to scan for dependency updates. |

### Secrets

| Secret | Required | Description |
|---|---|---|
| `COMPATHELPER_PAT` | No | A fine-grained PAT with `contents: write` and `pull-requests: write` scoped to the target repos. When provided, PRs created by CompatHelper will trigger CI workflows. Without it, CompatHelper falls back to `GITHUB_TOKEN` and PRs will not trigger CI. |

## IntegrationTest

Test a set of dependencies of the package against the current PR branch
to check if changes in the branch break any downstream tests. If the version
is bumped to indicate a breaking change according to semver, the test passes
since it is safe to register the changes without breaking downstream
packages if they follow semver in their compat versions.
Additionally, if some dependent packages being tested are registered in one or more
local registry, you can specify a list of local registries using their
repository URLs using the `localregistry` option,
which should be a string with registry URLs separated by a newline character (`\n`).
The reusable workflow expands its own matrix internally — callers pass the list of
packages to test as a JSON array via the `pkgs` input. Here is an example:

```yaml
name: "IntegrationTest"

on:
  push:
    branches: ["main"]
  pull_request:
    types: ["opened", "synchronize", "reopened", "ready_for_review", "converted_to_draft"]

jobs:
  integration-test:
    name: "IntegrationTest"
    uses: "ITensor/ITensorActions/.github/workflows/IntegrationTest.yml@v1"
    secrets: "inherit"
    with:
      localregistry: "https://github.com/ITensor/ITensorRegistry.git"
      pkgs: |
        [
          "BlockSparseArrays",
          "NamedDimsArrays",
          "TensorAlgebra"
        ]
```

The workflow does not run `julia-actions/julia-buildpkg` before testing. It
tests downstream packages in a separate `downstream` project, where the package
under test is developed from the PR checkout before the downstream tests run.
The package's own test workflow should be responsible for checking that the
package itself builds and tests successfully.

### Developing additional local package paths

Some repositories contain multiple packages that should be developed together
when testing downstream packages. For example, a parent package may depend on
an in-repository subpackage whose new version has not been registered yet. Use
`extra-dev-paths` to develop additional local package paths alongside the
repository root:

```yaml
jobs:
  integration-test:
    name: "IntegrationTest"
    uses: "ITensor/ITensorActions/.github/workflows/IntegrationTest.yml@v1"
    with:
      localregistry: "https://github.com/ITensor/ITensorRegistry.git"
      pkgs: |
        [
          "ITensorMPS",
          "ITensorNetworks"
        ]
      extra-dev-paths: |
        NDTensors
```

For multiple extra paths, use a newline-separated string.

The workflow also emits a single `IntegrationTest` check that aggregates the matrix
result, suitable for use as a required status check in branch protection.

Use `pkgs: '[]'` if no downstream tests are configured; the aggregate check passes.

### Trigger choice: `pull_request` not `pull_request_target`

Use `on: pull_request:` so that fork PRs run without access to repository secrets.
`pull_request_target:` would expose `INTEGRATIONTEST_PAT` and a write-scope
`GITHUB_TOKEN` to PR-controlled Julia code (via `Pkg.test`), which is the pattern
exploited in the 2025 Trivy compromise.

Internal PRs (same-repo branches) still receive secrets under `pull_request:`, so
no behavior changes for the day-to-day workflow.

### Private or unregistered packages

`pkgs` entries may be either registered package names (e.g. `"BlockSparseArrays"`)
or git URLs (e.g. `"https://github.com/MyOrg/MyPrivatePackage.jl"`,
`"git@github.com:..."`). The workflow:

- Runs registered-name entries normally.
- Probes URL entries anonymously to detect whether they need authentication.
  Public URLs run normally on every PR.
- Skips URL entries that need authentication when the event is a fork
  `pull_request` (no secrets in scope). The skipped leg emits a notice
  pointing the maintainer at `/integrationtest <url>` (see below).

For private GitHub repos, configure the `INTEGRATIONTEST_PAT` secret at the
repository or organization level and pass `secrets: "inherit"`. Internal PRs and
push events use the PAT to clone; fork PRs do not see the PAT.

```yaml
jobs:
  integration-test:
    name: "IntegrationTest"
    uses: "ITensor/ITensorActions/.github/workflows/IntegrationTest.yml@v1"
    secrets: "inherit"
    with:
      localregistry: "https://github.com/ITensor/ITensorRegistry.git"
      pkgs: |
        [
          "BlockSparseArrays",
          "https://github.com/MyOrg/MyPrivatePackage.jl"
        ]
```

When a fork PR's matrix is **entirely** private URLs (every leg skipped), the
aggregate `IntegrationTest` check fails with a message instructing the maintainer
to run `/integrationtest <url>` for each private dep before merging. The companion
`IntegrationTestRequest.yml` workflow posts a passing `IntegrationTest` check on
success, satisfying the gate.

### Draft PR behavior

By default, integration tests are skipped entirely for draft PRs. This is
controlled by the `run-on-draft` input (default: `false`). To run integration
tests even on draft PRs, set it to `true`:

```yaml
    uses: "ITensor/ITensorActions/.github/workflows/IntegrationTest.yml@v1"
    with:
      run-on-draft: true
      # ...
```

Additionally, it is possible to run these tests dynamically, whenever a comment on a PR is detected.
For example, a workflow that detects `/integrationtest Repo/Package.jl` (the default trigger) looks like:

```yaml
name: "Integration Request"

on:
  issue_comment:
    types: [created]

jobs:
  integrationrequest:
    if: |
      github.event.issue.pull_request &&
      contains(fromJSON('["OWNER", "COLLABORATOR", "MEMBER"]'), github.event.comment.author_association)
    uses: ITensor/ITensorActions/.github/workflows/IntegrationTestRequest.yml@v1
    with:
      localregistry: https://github.com/ITensor/ITensorRegistry.git
```

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `julia-version` | string | `"1"` | Julia version passed to `julia-actions/setup-julia`. |
| `pkgs` | string | **required** | JSON-array string of registered package names and/or git URLs. Use `'[]'` to configure no downstream tests. |
| `localregistry` | string | `""` | Newline-separated list of extra registry URLs to add before resolving. |
| `extra-dev-paths` | string | `""` | Newline-separated list of additional local package paths to develop alongside the repository root before testing downstream packages. |
| `run-on-draft` | bool | `false` | Run integration tests on draft PRs. When `false`, draft PRs skip integration tests entirely. |

The companion `IntegrationTestRequest.yml` workflow (used for the `/integrationtest ...` comment trigger shown above) has its own inputs:

| Input | Type | Default | Description |
|---|---|---|---|
| `trigger` | string | `"/integrationtest"` | Comment trigger phrase. |
| `localregistry` | string | `""` | Newline-separated list of extra registry URLs to add before resolving. |
| `extra-dev-paths` | string | `""` | Newline-separated list of additional local package paths to develop alongside the repository root before resolving downstream tests. |

### Secrets

| Secret | Required | Description |
|---|---|---|
| `INTEGRATIONTEST_PAT` | For private deps | GitHub PAT used to authenticate HTTPS clones of private GitHub repositories. Not needed if every dependency under test is public. |

## Version Check

The `VersionCheck` workflow is designed to check if the package version has been increased with respect to the latest release.
The workflow would look like:

```yaml
name: "Version Check"

on:
  pull_request:

jobs:
  version-check:
    name: "Version Check"
    uses: "ITensor/ITensorActions/.github/workflows/VersionCheck.yml@v1"
    with:
      localregistry: https://github.com/ITensor/ITensorRegistry.git
```

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `julia-version` | string | `"1"` | Julia version passed to `julia-actions/setup-julia`. |
| `localregistry` | string | `""` | Newline-separated list of extra registry URLs to consult when determining the previously registered version. |

The check is automatically skipped on PRs classified as non-substantive (changes limited to `.github/**`, `.pre-commit-config.yaml`, `.gitignore`, or `LICENSE`); those PRs pass without requiring a version bump.

## Check Compat Bounds

The `CheckCompatBounds` workflow instantiates the package and fails if any
workspace compat entry is resolved to a version below its compat upper
bound. This flags the situation where a transitive dependency is holding
the workspace back from a compat upper bound the maintainer believes is
being tested — for example, a CompatHelper PR that bumps `[compat]` to a
newer version but the resolver cannot actually pick that version because
another dependency constrains it.

The check walks the root `Project.toml` plus every path listed in
`[workspace].projects`. Standard library packages, unregistered
`[sources]` dependencies, and `[extras]`-only entries not in the
manifest are skipped. A compat entry referring to a workspace project's
own package is checked against the workspace version, not only the
registry, so a PR bumping the root `version` does not spuriously fail
because the new version is not yet registered.

The workflow runs once per PR on `ubuntu-latest` and produces its own
status check, independent of the `Tests` workflow.

```yaml
name: "Check Compat Bounds"

on:
  pull_request:

jobs:
  check-compat-bounds:
    name: "Check Compat Bounds"
    uses: "ITensor/ITensorActions/.github/workflows/CheckCompatBounds.yml@v1"
    with:
      localregistry: https://github.com/ITensor/ITensorRegistry.git
```

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `julia-version` | string | `"1"` | Julia version passed to `julia-actions/setup-julia`. |
| `project` | string | `"@."` | Value passed to Julia's `--project` flag during `julia-actions/julia-buildpkg`. |
| `cache` | bool | `true` | Use `julia-actions/cache`. |
| `buildpkg` | bool | `true` | Run `julia-actions/julia-buildpkg` before the check. Disable only if the workspace is instantiated some other way. |
| `localregistry` | string | `""` | Newline-separated list of extra registry URLs to add before resolving (forwarded to `julia-actions/julia-buildpkg`). |
| `timeout-minutes` | number | `30` | Maximum job runtime. |
| `run-on-draft` | bool | `false` | Run the check on draft PRs. |
| `mode` | string | `"always"` | `"always"` runs on every invocation. `"never"` skips the check. `"auto"` runs only when `$GITHUB_ACTOR` is a known dependency-update bot (`github-actions[bot]`, `dependabot[bot]`). |
| `workspace-root` | string | `"."` | Path to the workspace root (containing `Project.toml` and `Manifest.toml`). |

Example — restrict the check to CompatHelper/Dependabot PRs only:

```yaml
    uses: "ITensor/ITensorActions/.github/workflows/CheckCompatBounds.yml@v1"
    with:
      mode: auto
```

### Using the check outside GitHub Actions

The underlying script is a standalone Julia script; it can be invoked from
Jenkins or any other CI after the workspace is instantiated:

```bash
curl -sSL https://raw.githubusercontent.com/ITensor/ITensorActions/main/.github/actions/check-compat-bounds/check_compat_bounds.jl \
  -o check_compat_bounds.jl
julia --color=yes check_compat_bounds.jl <workspace-root>
```

Exit code `0` means every workspace compat entry is resolved to its maximum
allowed version; exit code `1` means at least one entry is outdated, with a
per-entry message identifying the package, resolved version, and allowed
ceiling.

## Registrator

The Registrator workflow registers a new package version whenever the version in
`Project.toml` is bumped on the main branch. It automatically routes to the
[General registry](https://github.com/JuliaRegistries/General) for packages
already registered there, or to a local registry otherwise.

### Automatic registration on push

When a commit is pushed to `main`/`master` that changes `Project.toml`, the workflow
checks whether the version has increased and, if so, triggers registration. The version
bump must follow semver (patch, minor, or major increment by exactly 1).

### On-demand registration via comment

Comment `/register` on any issue to force registration of the current `HEAD` of the
default branch. You can also specify a particular commit SHA to register a non-latest
commit:

```
/register
/register abc1234
```

The bot reacts with 👍 to confirm the trigger. On-demand registration bypasses the
version-change check, so it works even if the version was not bumped in the most
recent commit.

### Example workflow

```yaml
name: "Register Package"

on:
  workflow_dispatch: ~
  push:
    branches:
      - "master"
      - "main"
    paths:
      - "Project.toml"
  # Optional: allow on-demand registration by commenting "/register" on an issue.
  issue_comment:
    types:
      - "created"

permissions:
  contents: "write"
  pull-requests: "write"
  issues: "write"

jobs:
  Register:
    uses: "ITensor/ITensorActions/.github/workflows/Registrator.yml@v1"
    with:
      localregistry: "ITensor/ITensorRegistry" # omit if package is in General
    secrets: "inherit"
```

### Inputs

| Input | Description | Default |
|---|---|---|
| `localregistry` | Local registry repo (`owner/name`) for packages not in General | `""` |
| `trigger` | Comment trigger phrase for on-demand registration | `/register` |
| `julia-version` | Julia version used by the workflow | `1` |

### Secrets

| Secret | Required | Description |
|---|---|---|
| `REGISTRATOR_PAT` | For local registry only | A PAT with write access to the local registry repo, used to check it out and open a registration PR |

## TagBot

The TagBot workflow creates GitHub releases and tags whenever a new version of a package
is registered in a Julia registry. It runs separate jobs in parallel — one scanning
[ITensorRegistry](https://github.com/ITensor/ITensorRegistry) and one scanning the
[General registry](https://github.com/JuliaRegistries/General) — so a package registered
in either registry is handled automatically. For repositories that contain additional
Julia packages in subdirectories (for example a monorepo layout), an opt-in `subdirs`
input adds matrix jobs that tag those subdir packages from the General registry.

### How triggering works

- **General registry**: The General registry has its own
  [TagBotTriggers workflow](https://github.com/JuliaRegistries/General/blob/master/.github/workflows/TagBotTriggers.yml)
  that posts a comment as `JuliaTagBot` on a trigger issue in each package repo whenever
  a new version is merged. This fires the `issue_comment` event that starts TagBot.

- **ITensorRegistry**: The ITensorRegistry has a matching
  [TagBotTriggers workflow](https://github.com/ITensor/ITensorRegistry/blob/main/.github/workflows/TagBotTriggers.yml)
  that fires `workflow_dispatch` on the package's `TagBot.yml` directly after each
  registration PR is merged. This requires a `TAGBOT_PAT` secret in ITensorRegistry
  with `actions: write` permission on the ITensor package repos.

### Example workflow

```yaml
name: "TagBot"
on:
  issue_comment:
    types:
      - "created"
  workflow_dispatch: ~
env:
  REGISTRY_TAGBOT_ACTION: "JuliaRegistries/TagBot"
jobs:
  TagBot:
    if: "github.event_name == 'workflow_dispatch' || github.actor == 'JuliaTagBot'"
    uses: "ITensor/ITensorActions/.github/workflows/TagBot.yml@v1"
    secrets: inherit
```

#### Why the `env:` marker

The General registry's
[TagBotTriggers workflow](https://github.com/JuliaRegistries/General/blob/master/.github/workflows/TagBotTriggers.yml)
runs `RegistryCI.TagBot.maybe_notify`, which only treats TagBot as enabled on a package
repo if the literal substring `JuliaRegistries/TagBot` appears in some file under
`.github/workflows/`
([source](https://github.com/JuliaRegistries/RegistryCI.jl/blob/master/AutoMerge/src/TagBot/TagBot.jl#L62-L77)).
After delegating to this reusable workflow, the caller no longer contains that string —
the actual `JuliaRegistries/TagBot` invocation lives inside the reusable workflow, which
the substring check does not follow `uses:` references to find. Without the marker the
General registry never posts a `JuliaTagBot` trigger comment and tagging silently
stops working for any package registered only in General.

The unused `env:` variable above contains the literal substring so the check passes.
It has no runtime effect and does not propagate into the reusable workflow. A YAML
comment would be simpler, but [ITensorFormatter](https://github.com/ITensor/ITensorFormatter.jl)
(`itpkgfmt`) strips comments when reformatting YAML — a consequence of writing through
[YAML.jl](https://github.com/JuliaData/YAML.jl), whose writer does not preserve
comments (tracked upstream at
[YAML.jl#245](https://github.com/JuliaData/YAML.jl/issues/245)). So the marker has to
live in a structural element instead of a `#` line.

### Tagging packages in subdirectories

Some repositories ship more than one Julia package — for example, a top-level
package plus one or more sub-packages under their own subdirectories. Each
sub-package is registered separately in the General registry and gets its own
tag namespace (`SubPkgName-vX.Y.Z`).

The reusable workflow handles these via the optional `subdirs` input, which
takes a JSON-encoded array of subdirectory package names and runs an additional
matrix job per entry, passing each name to TagBot's `subdir` parameter:

```yaml
name: "TagBot"
on:
  issue_comment:
    types:
      - "created"
  workflow_dispatch: ~
env:
  REGISTRY_TAGBOT_ACTION: "JuliaRegistries/TagBot"
jobs:
  TagBot:
    if: "github.event_name == 'workflow_dispatch' || github.actor == 'JuliaTagBot'"
    uses: "ITensor/ITensorActions/.github/workflows/TagBot.yml@v1"
    with:
      subdirs: '["NDTensors"]'
    secrets: inherit
```

When `subdirs` is left at its default of `'[]'`, the matrix job is skipped and
the workflow behaves exactly as before — only top-level packages are tagged.

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `subdirs` | string | `"[]"` | JSON-encoded array of subdirectory package names to tag from the General registry, e.g. `'["NDTensors"]'`. Each entry is passed as the `subdir` parameter to a matrix job invoking `JuliaRegistries/TagBot`. Leave at the default to skip subdir tagging. |

### Secrets

| Secret | Required | Description |
|---|---|---|
| `TAGBOT_PAT` | No | Personal access token used to authenticate with GitHub. Falls back to the built-in `GITHUB_TOKEN` if not provided. |
