import Pkg
using TOML

function package_project_path(subdir::AbstractString)
    return isempty(subdir) ? "Project.toml" : joinpath(subdir, "Project.toml")
end

function parse_version(s::AbstractString, label::AbstractString)
    try
        return VersionNumber(s)
    catch err
        error("Invalid $label version '$s' in Project.toml: $err")
    end
end

function valid_bump(o::VersionNumber, n::VersionNumber)
    if n.major == o.major &&
            n.minor == o.minor &&
            n.patch == o.patch &&
            !isempty(o.prerelease) &&
            isempty(n.prerelease)
        return true, "stripping pre-release suffix"
    end
    if n.major == o.major && n.minor == o.minor
        return (n.patch == o.patch + 1), "expected patch bump by 1"
    elseif n.major == o.major
        return (n.minor == o.minor + 1 && n.patch == 0),
            "expected minor bump by 1 with patch reset to 0"
    else
        return (n.major == o.major + 1 && n.minor == 0 && n.patch == 0),
            "expected major bump by 1 with minor/patch reset to 0"
    end
end

function register_route(
        uuid::AbstractString;
        general_registry_toml::AbstractString = get(ENV, "GENERAL_REGISTRY_TOML", "")
    )
    if isempty(general_registry_toml)
        ENV["JULIA_PKG_SERVER"] = ""
        Pkg.Registry.add("General")
        general_registry_toml =
            joinpath(first(DEPOT_PATH), "registries", "General", "Registry.toml")
    end
    general = TOML.parsefile(general_registry_toml)
    return haskey(get(general, "packages", Dict{String, Any}()), uuid) ? "general" : "local"
end

function find_last_released_version(
        repo_path::AbstractString, project_path::AbstractString;
        before_ref::AbstractString = "HEAD"
    )
    history_ref = isempty(before_ref) ? "HEAD" : string(before_ref, "^")
    log_output = try
        readlines(`git -C $repo_path log --pretty=%H $history_ref -- $project_path`)
    catch
        return nothing
    end
    for sha in log_output
        try
            toml_text = read(`git -C $repo_path show $sha:$project_path`, String)
            v_str = get(TOML.parse(toml_text), "version", "")
            isempty(v_str) && continue
            v = VersionNumber(v_str)
            isempty(v.prerelease) && return v
        catch
            continue
        end
    end
    return nothing
end

function output_value!(outputs::Dict{String, String}, key::AbstractString, value)
    outputs[String(key)] = string(value)
    return outputs
end

function write_outputs(outputs::Dict{String, String})
    output_file = get(ENV, "GITHUB_OUTPUT", "")
    isempty(output_file) && return nothing
    open(output_file, "a") do io
        for (key, value) in sort(collect(outputs))
            println(io, "$key=$value")
        end
    end
    return nothing
end

function check_version_bump(;
        package_path::AbstractString,
        subdir::AbstractString,
        base_ref::AbstractString
    )
    isempty(base_ref) && error("base-ref input is required in version-check mode")

    project_path = package_project_path(subdir)
    project_file = joinpath(package_path, project_path)

    base_project_text = try
        read(`git -C $package_path show $base_ref:$project_path`, String)
    catch err
        println("Could not read $project_path on $base_ref ($err); skipping check.")
        return Dict(
            "base_ref" => base_ref,
            "project_path" => project_path,
            "skip_reason" => "could not read $project_path on $base_ref"
        )
    end
    base_project = TOML.parse(base_project_text)
    current_project = TOML.parsefile(project_file)

    if !haskey(base_project, "version")
        println("Base branch $project_path has no version field; skipping check.")
        return Dict(
            "base_ref" => base_ref,
            "project_path" => project_path,
            "skip_reason" => "base branch $project_path has no version field"
        )
    end
    if !haskey(current_project, "version")
        error(
            "$project_path on this branch has no version field, but the base branch ($base_ref) does. " *
                "Restore the version field and bump it."
        )
    end

    base_version = VersionNumber(base_project["version"])
    current_version = VersionNumber(current_project["version"])

    outputs = Dict(
        "base_ref" => base_ref,
        "base_version" => string(base_version),
        "project_path" => project_path,
        "new_version" => string(current_version)
    )

    if !isempty(current_version.prerelease) &&
            !isempty(base_version.prerelease) &&
            current_version == base_version
        println(
            "OK: $project_path version $current_version unchanged from base " *
                "(both carry pre-release suffix; accumulating breaking changes)."
        )
    elseif current_version > base_version
        ok, why = valid_bump(base_version, current_version)
        ok || error(
            "Invalid version bump in $project_path: $base_version ($base_ref) -> " *
                "$current_version (PR head): $why."
        )
        println(
            "OK: $project_path version bumped from $base_version ($base_ref) to " *
                "$current_version (PR head)."
        )
        output_value!(outputs, "bump_reason", why)
    else
        error(
            "$project_path version was not bumped. Current version $current_version is not greater " *
                "than the version $base_version on the base branch ($base_ref). Bump the version in " *
                "$project_path."
        )
    end

    return outputs
end

function registrator_metadata(;
        package_path::AbstractString, subdir::AbstractString, old_ref::AbstractString,
        force::Bool
    )
    project_path = package_project_path(subdir)
    new = TOML.parsefile(joinpath(package_path, project_path))
    name = get(new, "name", "")
    uuid = get(new, "uuid", "")
    newv_str = get(new, "version", "")

    isempty(name) && error("$project_path is missing name")
    isempty(uuid) && error("$project_path is missing uuid")
    isempty(newv_str) && error("$project_path is missing version")

    newv = parse_version(newv_str, "new")
    subject = replace(
        readchomp(`git -C $package_path log -1 --pretty=%s HEAD`),
        ['\n', '\r'] => ' '
    )

    if isempty(old_ref) || old_ref == "0000000000000000000000000000000000000000"
        old_ref = try
            readchomp(`git -C $package_path rev-parse HEAD^`)
        catch
            ""
        end
    end

    oldv_str = ""
    if !isempty(old_ref)
        try
            old_toml = read(`git -C $package_path show $old_ref:$project_path`, String)
            oldv_str = get(TOML.parse(old_toml), "version", "")
        catch err
            println(
                stderr,
                "Warning: could not read $project_path at ref '$old_ref' " *
                    "(treating as no prior version): $err"
            )
            oldv_str = ""
        end
    end

    oldv = isempty(oldv_str) ? nothing : parse_version(oldv_str, "old")
    route = "none"
    is_breaking = false
    skip_reason = ""

    if !isempty(newv.prerelease) && !force
        if oldv !== nothing && newv > oldv
            ok, why = valid_bump(oldv, newv)
            ok || error("Invalid version bump: $oldv_str -> $newv_str ($why)")
        end
        skip_reason = "pre-release version $newv_str; not registering during accumulation"
    elseif oldv !== nothing
        if newv == oldv && !force
            skip_reason = "Project.toml version unchanged ($newv_str)"
        elseif newv < oldv && !force
            skip_reason = "Project.toml version decreased ($oldv_str -> $newv_str); skipping registration"
        else
            if newv > oldv
                ok, why = valid_bump(oldv, newv)
                force || ok || error("Invalid version bump: $oldv_str -> $newv_str ($why)")

                oldv_compare = if !isempty(oldv.prerelease) && isempty(newv.prerelease)
                    something(
                        find_last_released_version(
                            package_path,
                            project_path;
                            before_ref = "HEAD"
                        ),
                        oldv
                    )
                else
                    oldv
                end
                is_breaking =
                    (newv.major > oldv_compare.major) ||
                    (
                    oldv_compare.major == 0 && newv.major == 0 &&
                        newv.minor > oldv_compare.minor
                )
            end

            route = register_route(uuid)
        end
    else
        route = register_route(uuid)
    end

    return Dict(
        "route" => route,
        "pkg_name" => name,
        "uuid" => uuid,
        "new_version" => newv_str,
        "is_breaking" => string(is_breaking),
        "subject" => subject,
        "skip_reason" => skip_reason
    )
end

function main()
    mode = get(ENV, "VERSION_HELPERS_MODE", "")
    package_path = get(ENV, "PACKAGE_PATH", ".")
    subdir = get(ENV, "SUBDIR", "")
    outputs = if mode == "version-check"
        check_version_bump(;
            package_path = package_path, subdir = subdir,
            base_ref = get(ENV, "BASE_REF", "")
        )
    elseif mode == "registrator-meta"
        registrator_metadata(;
            package_path = package_path,
            subdir = subdir,
            old_ref = get(ENV, "OLD_REF", ""),
            force = lowercase(get(ENV, "FORCE", "false")) == "true"
        )
    else
        error("Unknown version-helpers mode '$mode'")
    end
    write_outputs(outputs)
    return outputs
end
