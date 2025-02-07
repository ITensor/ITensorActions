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
There are two workflows available, one for simply verifying the formatting and one for additionally applying suggested changes.

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
    uses: "ITensor/ITensorActions/workflows/FormatCheck.yml@main"
```

```yaml
name: "Format Suggestions"

on:
  pull_request:

jobs:
  format-suggestions:
    name: "Format Suggestions"
    uses: "ITensor/ITensorActions/workflows/FormatSuggest.yml@main"
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
    uses: "ITensor/ITensorActions/workflows/LiterateCheck.yml@main"
```

## CompatHelper

The CompatHelper workflow is designed to periodically check dependencies for breaking
releases, and if so make PRs to bump the compat versions. The workflow would look like:
Note this workflow checks both the Julia [General registry](https://github.com/JuliaRegistries/General)
and the [ITensorRegistry](https://github.com/ITensor/ITensorRegistry) for breaking releases
of dependencies.

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
  CompatHelper:
    name: "CompatHelper"
    uses: "ITensor/ITensorActions/.github/workflows/CompatHelper.yml@main"
```
