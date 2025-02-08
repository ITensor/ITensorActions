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
releases, and if so make PRs to bump the compat versions. By default this workflow
checks the Julia [General registry](https://github.com/JuliaRegistries/General)
for breaking releases of dependencies, but you can add other registries
by specifying the registry URLs with the `local-registy-urls` option,
which should be strings with registry URLs seperated by a newline character (`\n`).
Registry names will be guess from the URLs, for example if a registry URL
is "https://github.com/ITensor/ITensorRegistry.git" we will guess that the
registry name is "ITensorRegistry". If that is not the case for one or more registry,
you will need to specify all of the registry names as well using the `local-registry-names`
in the same format. Here is an example workflow:

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
    with:
      local-registry-urls: "https://github.com/ITensor/ITensorRegistry.git"
```

## IntegrationTest

Test a set of dependencies of the package against the current PR branch
to check if changes in the branch break any downstream tests. If the version
is bumped to indicate a breaking change according to semver, the test passes
since it is safe to register the changes without breaking downstream
packages if they follow semver in their compat versions.
Additionally, if some dependent packages being tested are registered in one or more
local registry, you can specify a list of local registries using their
repository URLs using the `local-registy-urls` option,
which should be a string with registry URLs seperated by a newline character (`\n`).
Here is an example workflow:

```yaml
name: "IntegrationTest"

on:
  push:
    branches:
      - 'main'
    tags: '*'
  pull_request:

jobs:
  integration-test:
    name: "IntegrationTest"
    strategy:
       matrix:
         repo:
           - 'ITensor/BlockSparseArrays.jl'
           - 'ITensor/NamedDimsArrays.jl'
           - 'ITensor/TensorAlgebra.jl'
    uses: "ITensor/ITensorActions/.github/workflows/IntegrationTest.yml@main"
    with:
      local-registry-urls: "https://github.com/ITensor/ITensorRegistry.git"
      repo: "${{ matrix.repo }}"
```
