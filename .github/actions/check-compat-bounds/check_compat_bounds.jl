#!/usr/bin/env julia

# Checks that the root package's `[compat]` entries don't claim support for
# versions the resolver can't actually reach. Resolves against the root
# package in isolation — `[weakdeps]`, `[extras]`, and workspace sub-projects
# (test/, docs/, examples/) are ignored. The primary claim a package makes is
# about its core deps when installed on its own; if an extension or test-only
# dep happens to constrain the workspace manifest, that's a secondary concern
# that shouldn't block the core claim from being honest.
#
# Usage:
#   julia check_compat_bounds.jl [workspace-root]
#
#   workspace-root : defaults to pwd()

using Pkg
using TOML

function parse_args(args)
    length(args) > 1 && error("Expected at most one argument; got $(length(args)): $args")
    return abspath(isempty(args) ? pwd() : args[1])
end

const STDLIB_UUIDS = Set(keys(Pkg.Types.stdlibs()))
is_stdlib(uuid::Base.UUID) = uuid in STDLIB_UUIDS

# Build a standalone "core-only" copy of the root Project.toml at `dest`:
# keep `[deps]` and `[compat]` (filtered to deps entries + `julia`); drop
# `[weakdeps]`, `[extensions]`, `[extras]`, `[targets]`, and `[workspace]`.
# Returns the parsed root project dict.
function write_core_project(root, dest)
    root_toml = joinpath(root, "Project.toml")
    isfile(root_toml) || error("No Project.toml at $root")
    proj = TOML.parsefile(root_toml)
    deps = get(proj, "deps", Dict{String, Any}())
    compat = Dict{String, Any}()
    for (name, spec) in get(proj, "compat", Dict{String, Any}())
        if name == "julia" || haskey(deps, name)
            compat[name] = spec
        end
    end
    # Intentionally omit name/uuid/version so Pkg treats this as an anonymous
    # environment, not a full package it should try to precompile.
    core = Dict{String, Any}(
        "deps" => deps,
        "compat" => compat,
    )
    mkpath(dest)
    open(joinpath(dest, "Project.toml"), "w") do io
        return TOML.print(io, core; sorted = true)
    end
    return proj
end

function instantiate_core(core_dir)
    cmd = `$(Base.julia_cmd()) --color=no --startup-file=no --project=$(core_dir)
           -e "using Pkg; Pkg.instantiate()"`
    run(cmd)
    return TOML.parsefile(joinpath(core_dir, "Manifest.toml"))
end

function manifest_version(manifest, uuid::Base.UUID)
    uuid_str = string(uuid)
    pkg_groups = get(manifest, "deps", manifest)
    for (_, entries) in pkg_groups
        entries isa AbstractVector || continue
        for e in entries
            e isa AbstractDict || continue
            if get(e, "uuid", nothing) == uuid_str
                v = get(e, "version", nothing)
                return v === nothing ? nothing : VersionNumber(v)
            end
        end
    end
    return nothing
end

function registry_versions(uuid::Base.UUID)
    versions = VersionNumber[]
    for reg in Pkg.Registry.reachable_registries()
        entry = get(reg.pkgs, uuid, nothing)
        entry === nothing && continue
        info = Pkg.Registry.registry_info(entry)
        for (v, vinfo) in info.version_info
            vinfo.yanked && continue
            push!(versions, v)
        end
    end
    return versions
end

function max_satisfying(versions, spec::Pkg.Types.VersionSpec)
    m = nothing
    for v in versions
        v in spec || continue
        (m === nothing || v > m) && (m = v)
    end
    return m
end

# Best-effort explanation for an :outdated entry: in the already-prepared
# core-only temp project, force-pin the target version and return whatever
# the resolver prints (minus the Julia stacktrace).
function explain_outdated(core_dir, dep_name, target::VersionNumber)
    try
        cmd = `$(Base.julia_cmd()) --color=no --startup-file=no --project=$(core_dir)
               -e "using Pkg; Pkg.add(Pkg.PackageSpec(name=\"$dep_name\", version=v\"$target\"))"`
        buf = IOBuffer()
        run(pipeline(ignorestatus(cmd); stdout = buf, stderr = buf))
        output = String(take!(buf))
        return strip(split(output, "\nStacktrace:"; limit = 2)[1])
    catch
        ""
    end
end

function main(args)
    root = parse_args(args)
    println("Checking compat upper bounds (core only) for: $root")

    return mktempdir() do tmp
        core_dir = joinpath(tmp, "core")
        proj = write_core_project(root, core_dir)
        manifest = instantiate_core(core_dir)

        deps = get(proj, "deps", Dict{String, Any}())
        compat = get(proj, "compat", Dict{String, Any}())

        issues = NamedTuple[]
        for (name, spec_str) in compat
            name == "julia" && continue
            uuid_str = get(deps, name, nothing)
            uuid_str === nothing && continue
            uuid = Base.UUID(uuid_str)
            is_stdlib(uuid) && continue

            spec = try
                Pkg.Types.semver_spec(spec_str)
            catch err
                @warn "Could not parse compat spec '$spec_str' for $name: $err"
                continue
            end

            resolved = manifest_version(manifest, uuid)
            resolved === nothing && continue

            versions = registry_versions(uuid)
            isempty(versions) && continue

            max_allowed = max_satisfying(versions, spec)
            if max_allowed === nothing
                push!(issues, (; name, spec = spec_str, resolved, max_allowed, kind = :no_match))
            elseif resolved < max_allowed
                push!(issues, (; name, spec = spec_str, resolved, max_allowed, kind = :outdated))
            end
        end

        if isempty(issues)
            println()
            println("All core compat entries are resolved to their highest allowed version.")
            return 0
        end

        println()
        println("Found $(length(issues)) compat entr$(length(issues) == 1 ? "y" : "ies") not matching the latest allowed version:")
        println()
        for i in issues
            if i.kind == :outdated
                println("  - $(i.name): resolved $(i.resolved), compat \"$(i.spec)\" allows up to $(i.max_allowed)")
                explanation = explain_outdated(core_dir, i.name, i.max_allowed)
                if !isempty(explanation)
                    println("      resolver output when forcing $(i.name) = $(i.max_allowed):")
                    for line in split(explanation, '\n')
                        println("        ", line)
                    end
                end
            else
                println("  - $(i.name): compat \"$(i.spec)\" matches no registered version (resolved $(i.resolved))")
            end
        end
        println()
        println("Narrow the package's own `[compat]` to match what the resolver reaches,")
        println("or widen the upstream constraint that is holding it back.")

        return 1
    end
end

exit(main(ARGS))
