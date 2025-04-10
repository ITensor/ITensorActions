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
    uses: "ITensor/ITensorActions/workflows/Tests.yml@main"
    with:
      group: "${{ matrix.group }}"
      julia-version: "${{ matrix.version }}"
      os: "${{ matrix.os }}"
    secrets:
      CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}
```

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
    uses: "ITensor/ITensorActions/workflows/Documentation.yml@main"
    secrets: "inherit"
```

## Formatting

The formatting workflow is designed to run the `JuliaFormatter` on Julia packages.
There are three workflows available: one for simply verifying the formatting, one for additionally applying suggested changes, and one that makes a PR to the repository formatting the code in the repository.

```yaml
name: "Format Check"

on:
  push:
    branches:
      - 'main'
    tags: '*'
  pull_request:

jobs:
  format-check:
    name: "Format Check"
    uses: "ITensor/ITensorActions/.github/workflows/FormatCheck.yml@main"
```

```yaml
name: "Format Suggestions"

on:
  pull_request:

jobs:
  format-suggestions:
    name: "Format Suggestions"
    uses: "ITensor/ITensorActions/.github/workflows/FormatSuggest.yml@main"
```

```yaml
name: "Format Pull Request"

on:
  schedule:
    - cron: '0 0 * * *'

jobs:
  format-pull-request:
    name: "Format Pull Request"
    uses: "ITensor/ITensorActions/.github/workflows/FormatPullRequest.yml@main"
```

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
    - cron: 0 0 * * *
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
```

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

Additionally, it is possible to run these tests dynamically, whenever a comment on a PR is detected.
For example, a workflow that detects `@integrationtests Repo/Package.jl` looks like:

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
    uses: ITensor/ITensorActions/.github/workflows/IntegrationRequest.yml@main
    with:
      localregistry: https://github.com/ITensor/ITensorRegistry.git
```

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
