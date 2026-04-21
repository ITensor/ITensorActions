# ITensorActions

Shared workflows for the ITensors Julia packages

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
    uses: "ITensor/ITensorActions/.github/workflows/Tests.yml@main"
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
    uses: "ITensor/ITensorActions/.github/workflows/Tests.yml@main"
    with:
      run-all-on-draft: true
      # ...
```

### Compat upper-bound check

After `julia-actions/julia-buildpkg` instantiates the package, the Tests
workflow inspects the resolved `Manifest.toml` and fails if any workspace
compat entry is resolved to a version below its compat upper bound. This
flags the situation where a transitive dependency is holding the workspace
back from a compat upper bound the maintainer believes is being tested —
for example, a CompatHelper PR that bumps `[compat]` to a newer version
but the resolver cannot actually pick that version because another
dependency constrains it.

The check is enabled by default and walks the root `Project.toml` plus
every path listed in `[workspace].projects`. Standard library packages,
unregistered `[sources]` dependencies, and `[extras]`-only entries not in
the manifest are skipped.

| Input | Default | Description |
|---|---|---|
| `check-compat-bounds` | `true` | Enable or disable the check entirely. |
| `check-compat-bounds-mode` | `"always"` | `"always"` runs on every invocation. `"never"` skips the check. `"auto"` runs only when `$GITHUB_ACTOR` is a known dependency-update bot (`github-actions[bot]`, `dependabot[bot]`). |

Example — restrict the check to CompatHelper/Dependabot PRs only:

```yaml
    uses: "ITensor/ITensorActions/.github/workflows/Tests.yml@main"
    with:
      check-compat-bounds-mode: auto
```

#### Using the check outside GitHub Actions

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
| `check-compat-bounds` | bool | `true` | Enable or disable the compat upper-bound check (see above). |
| `check-compat-bounds-mode` | string | `"always"` | Mode of the compat upper-bound check: `"always"`, `"never"`, or `"auto"` (bots only). |

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
    uses: "ITensor/ITensorActions/.github/workflows/Documentation.yml@main"
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

### Secrets

| Secret | Required | Description |
|---|---|---|
| `CODECOV_TOKEN` | No | Upload token for Codecov (only needed if `coverage` is `true` and the repo is private). |

## Formatting

The formatting workflows allow you to customize which directories are checked, so you can specify only the directories you want. Use the `directory` input to set the directory or directories for formatting (default is the root directory `.`). You can specify multiple directories, e.g. `src test`, and all will be checked by the formatter.

There are three workflows available: one for simply verifying the formatting, one for additionally applying suggested changes, and one that makes a PR to the repository formatting the code in the repository.

### Format Check

```yaml
name: "Format Check"

on:
  push:
    branches:
      - 'main'
    tags: '*'
  pull_request:

permissions:
  contents: read
  actions: write
  pull-requests: write

jobs:
  format-check:
    name: "Format Check"
    uses: "ITensor/ITensorActions/.github/workflows/FormatCheck.yml@main"
    with:
      directory: "." # Customize this to check a specific directory
```

#### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `directory` | string | `"."` | Directory (or space-separated list of directories) to check with `ITensorFormatter`. |
| `julia-version` | string | `"1"` | Julia version passed to `julia-actions/setup-julia`. |
| `concurrent-jobs` | bool | `false` | When `true`, runs use `github.run_id` as the concurrency group (each run gets its own group). When `false`, runs share `github.ref` and older runs are cancelled. |
| `cancel-in-progress` | bool | `true` | Whether to cancel in-progress runs in the same concurrency group. Only effective when `concurrent-jobs` is `false`. |

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
    uses: "ITensor/ITensorActions/.github/workflows/FormatPullRequest.yml@main"
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
    uses: "ITensor/ITensorActions/.github/workflows/LiterateCheck.yml@main"
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
    uses: "ITensor/ITensorActions/.github/workflows/CompatHelper.yml@main"
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
repository URLs using the `localregisty` option,
which should be a string with registry URLs seperated by a newline character (`\n`).
Here is an example workflow:

```yaml
name: "IntegrationTest"

on:
  push:
    branches:
      - 'main'
    tags: '*'
    paths:
      - 'Project.toml'
  pull_request:
    paths:
      - 'Project.toml'

jobs:
  integration-test:
    name: "IntegrationTest"
    strategy:
       matrix:
         pkg:
           - 'BlockSparseArrays'
           - 'NamedDimsArrays'
           - 'TensorAlgebra'
    uses: "ITensor/ITensorActions/.github/workflows/IntegrationTest.yml@main"
    with:
      localregistry: "https://github.com/ITensor/ITensorRegistry.git"
      pkg: "${{ matrix.pkg }}"
```

### Private or unregistered packages

You can also test private or unregistered packages by passing a URL as the `pkg` value
instead of a package name. The workflow detects URLs (starting with `https://` or `git@`)
and installs the package directly from the URL, skipping the version-pinning logic that
only applies to registered packages.

For private repositories, pass a GitHub token via `secrets: inherit` — the workflow
expects it as a secret named `INTEGRATIONTEST_PAT`:

```yaml
jobs:
  integration-test:
    name: "IntegrationTest"
    strategy:
      matrix:
        pkg:
          - 'BlockSparseArrays'
          - 'https://github.com/MyOrg/MyPrivatePackage.jl'
    uses: "ITensor/ITensorActions/.github/workflows/IntegrationTest.yml@main"
    secrets: inherit
    with:
      localregistry: "https://github.com/ITensor/ITensorRegistry.git"
      pkg: "${{ matrix.pkg }}"
```

The workflow uses the `INTEGRATIONTEST_PAT` secret for authentication, configured at the
repository or organization level. When present, it is used to rewrite HTTPS clones of
GitHub repositories to authenticated URLs so private dependencies can be fetched.

### Draft PR behavior

By default, integration tests are skipped entirely for draft PRs. This is
controlled by the `run-on-draft` input (default: `false`). To run integration
tests even on draft PRs, set it to `true`:

```yaml
    uses: "ITensor/ITensorActions/.github/workflows/IntegrationTest.yml@main"
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
    uses: ITensor/ITensorActions/.github/workflows/IntegrationTestRequest.yml@main
    with:
      localregistry: https://github.com/ITensor/ITensorRegistry.git
```

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `julia-version` | string | `"1"` | Julia version passed to `julia-actions/setup-julia`. |
| `pkg` | string | **required** | Package name (without `.jl`, e.g. `ITensors` for `ITensors.jl`) or a URL (`https://...` or `git@...`) for private or unregistered packages. |
| `localregistry` | string | `""` | Newline-separated list of extra registry URLs to add before resolving. |
| `run-on-draft` | bool | `false` | Run integration tests on draft PRs. When `false`, draft PRs skip integration tests entirely. |

The companion `IntegrationTestRequest.yml` workflow (used for the `/integrationtest ...` comment trigger shown above) has its own inputs:

| Input | Type | Default | Description |
|---|---|---|---|
| `trigger` | string | `"/integrationtest"` | Comment trigger phrase. |
| `localregistry` | string | `""` | Newline-separated list of extra registry URLs to add before resolving. |

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
    uses: "ITensor/ITensorActions/.github/workflows/VersionCheck.yml@main"
    with:
      localregistry: https://github.com/ITensor/ITensorRegistry.git
```

### Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `julia-version` | string | `"1"` | Julia version passed to `julia-actions/setup-julia`. |
| `localregistry` | string | `""` | Newline-separated list of extra registry URLs to consult when determining the previously registered version. |

The check is automatically skipped on PRs classified as non-substantive (changes limited to `.github/**`, `.pre-commit-config.yaml`, `.gitignore`, or `LICENSE`); those PRs pass without requiring a version bump.

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
    uses: "ITensor/ITensorActions/.github/workflows/Registrator.yml@main"
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
is registered in a Julia registry. It runs two jobs in parallel — one scanning
[ITensorRegistry](https://github.com/ITensor/ITensorRegistry) and one scanning the
[General registry](https://github.com/JuliaRegistries/General) — so a package registered
in either registry is handled automatically.

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
jobs:
  TagBot:
    if: "github.event_name == 'workflow_dispatch' || github.actor == 'JuliaTagBot'"
    uses: "ITensor/ITensorActions/.github/workflows/TagBot.yml@main"
    secrets: inherit
```

### Secrets

| Secret | Required | Description |
|---|---|---|
| `TAGBOT_PAT` | No | Personal access token used to authenticate with GitHub. Falls back to the built-in `GITHUB_TOKEN` if not provided. |
