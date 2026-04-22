#!/usr/bin/env julia

# Checks that every package with a compat entry across this workspace is
# resolved to the highest registry version satisfying its compat spec. Fails
# (exit 1) if any resolved version is below the maximum allowed by compat,
# which typically indicates a transitive dependency is holding the workspace
# back from its declared upper bound.
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

function workspace_projects(root)
    root_toml = joinpath(root, "Project.toml")
    isfile(root_toml) || error("No Project.toml at $root")
    proj = TOML.parsefile(root_toml)
    tomls = [root_toml]
    for rel in get(get(proj, "workspace", Dict{String,Any}()), "projects", String[])
        candidate = joinpath(root, rel, "Project.toml")
        if isfile(candidate)
            push!(tomls, candidate)
        elseif isfile(joinpath(root, rel))
            push!(tomls, joinpath(root, rel))
        else
            @warn "Workspace project path does not exist: $rel"
        end
    end
    return tomls
end

function collect_uuids(projects)
    uuids = Dict{String,Base.UUID}()
    for path in projects
        proj = TOML.parsefile(path)
        for key in ("deps", "weakdeps", "extras")
            for (name, uuid_str) in get(proj, key, Dict{String,String}())
                uuids[name] = Base.UUID(uuid_str)
            end
        end
    end
    return uuids
end

# Versions declared by the workspace itself. A package bumping its own version
# in a PR won't appear in the registry yet, so we merge these into the set of
# candidate versions so in-workspace compat entries (e.g. a test/Project.toml
# pinning the root package) don't spuriously fail the check.
function workspace_versions(projects)
    versions = Dict{Base.UUID,VersionNumber}()
    for path in projects
        proj = TOML.parsefile(path)
        uuid_str = get(proj, "uuid", nothing)
        version_str = get(proj, "version", nothing)
        uuid_str === nothing && continue
        version_str === nothing && continue
        versions[Base.UUID(uuid_str)] = VersionNumber(version_str)
    end
    return versions
end

function collect_compat(projects, uuids)
    entries = NamedTuple[]
    for path in projects
        proj = TOML.parsefile(path)
        for (name, spec_str) in get(proj, "compat", Dict{String,String}())
            name == "julia" && continue
            uuid = get(uuids, name, nothing)
            if uuid === nothing
                @warn "Compat entry for '$name' in $path has no matching UUID in any workspace project's deps/weakdeps/extras; skipping."
                continue
            end
            push!(entries, (; name, spec = spec_str, source = path, uuid))
        end
    end
    return entries
end

function read_manifest(root)
    manifest = joinpath(root, "Manifest.toml")
    isfile(manifest) || error("No Manifest.toml at $root — run Pkg.instantiate() first.")
    return TOML.parsefile(manifest)
end

function manifest_version(manifest, uuid::Base.UUID)
    uuid_str = string(uuid)
    # Julia 1.7+ manifest format nests packages under "deps"; older nests at top.
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

function main(args)
    root = parse_args(args)
    println("Checking compat upper bounds for workspace at: $root")

    projects = workspace_projects(root)
    println("Workspace projects:")
    for p in projects
        println("  - $(relpath(p, root))")
    end

    uuids = collect_uuids(projects)
    entries = collect_compat(projects, uuids)
    manifest = read_manifest(root)
    ws_versions = workspace_versions(projects)

    issues = NamedTuple[]
    for entry in entries
        is_stdlib(entry.uuid) && continue

        spec = try
            Pkg.Types.semver_spec(entry.spec)
        catch err
            @warn "Could not parse compat spec '$(entry.spec)' for $(entry.name) in $(entry.source): $err"
            continue
        end

        resolved = manifest_version(manifest, entry.uuid)
        resolved === nothing && continue  # extras-only packages may not be resolved here

        versions = registry_versions(entry.uuid)
        ws_version = get(ws_versions, entry.uuid, nothing)
        ws_version === nothing || ws_version in versions || push!(versions, ws_version)
        isempty(versions) && continue  # unregistered (e.g. local [sources] deps)

        max_allowed = max_satisfying(versions, spec)
        if max_allowed === nothing
            push!(issues, (; entry..., resolved, max_allowed, kind = :no_match))
        elseif resolved < max_allowed
            push!(issues, (; entry..., resolved, max_allowed, kind = :outdated))
        end
    end

    if isempty(issues)
        println()
        println("All workspace compat entries are resolved to their highest allowed version.")
        return 0
    end

    println()
    println("Found $(length(issues)) compat entr$(length(issues) == 1 ? "y" : "ies") not matching the latest allowed version:")
    println()
    for i in issues
        if i.kind == :outdated
            println("  - $(i.name): resolved $(i.resolved), compat \"$(i.spec)\" allows up to $(i.max_allowed)")
        else
            println("  - $(i.name): compat \"$(i.spec)\" matches no registered version (resolved $(i.resolved))")
        end
        println("      declared in $(relpath(i.source, root))")
    end
    println()
    println("This usually means a transitive dependency is pinning one of these packages to an older")
    println("version than the compat entry allows. Either update the transitive dependency's compat,")
    println("or tighten this package's compat to reflect what is actually being tested.")

    return 1
end

exit(main(ARGS))
