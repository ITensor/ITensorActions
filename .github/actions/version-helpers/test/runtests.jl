using Test

const ACTION_DIR = normpath(joinpath(@__DIR__, ".."))
include(joinpath(ACTION_DIR, "version_helpers.jl"))

@testset "valid_bump" begin
    @test valid_bump(v"0.1.0", v"0.1.1") == (true, "expected patch bump by 1")
    @test valid_bump(v"0.1.0", v"0.2.0-DEV") ==
        (true, "expected minor bump by 1 with patch reset to 0")
    @test valid_bump(v"1.2.3", v"2.0.0") ==
        (true, "expected major bump by 1 with minor/patch reset to 0")
    @test valid_bump(v"0.2.0-DEV", v"0.2.0") == (true, "stripping pre-release suffix")
    @test valid_bump(v"0.1.0", v"0.3.0-DEV") ==
        (false, "expected minor bump by 1 with patch reset to 0")
end

@testset "register_route" begin
    mktempdir() do dir
        registry_toml = joinpath(dir, "Registry.toml")
        write(
            registry_toml,
            """
            [packages]
            "11111111-1111-1111-1111-111111111111" = { name = "InGeneral", path = "I/InGeneral" }
            """
        )

        @test register_route(
            "11111111-1111-1111-1111-111111111111"; general_registry_toml = registry_toml
        ) == "general"
        @test register_route(
            "22222222-2222-2222-2222-222222222222"; general_registry_toml = registry_toml
        ) == "local"
    end
end

@testset "find_last_released_version" begin
    mktempdir() do repo
        project_path = "Project.toml"
        run(`git -C $repo init --quiet`)
        run(`git -C $repo config user.email test@example.com`)
        run(`git -C $repo config user.name "Test User"`)

        write(
            joinpath(repo, project_path),
            """
            name = "Example"
            uuid = "33333333-3333-3333-3333-333333333333"
            version = "0.1.0"
            """
        )
        run(`git -C $repo add $project_path`)
        run(`git -C $repo commit --quiet -m "release 0.1.0"`)

        write(
            joinpath(repo, project_path),
            """
            name = "Example"
            uuid = "33333333-3333-3333-3333-333333333333"
            version = "0.2.0-DEV"
            """
        )
        run(`git -C $repo commit --quiet -am "start 0.2.0 development"`)

        write(
            joinpath(repo, project_path),
            """
            name = "Example"
            uuid = "33333333-3333-3333-3333-333333333333"
            version = "0.2.0"
            """
        )
        run(`git -C $repo commit --quiet -am "release 0.2.0"`)

        @test find_last_released_version(repo, project_path; before_ref = "HEAD") ==
            v"0.1.0"
    end
end

@testset "registrator_metadata strip-suffix release" begin
    mktempdir() do dir
        repo = joinpath(dir, "package")
        mkdir(repo)
        registry_toml = joinpath(dir, "Registry.toml")
        write(registry_toml, "[packages]\n")

        project_path = "Project.toml"
        run(`git -C $repo init --quiet`)
        run(`git -C $repo config user.email test@example.com`)
        run(`git -C $repo config user.name "Test User"`)

        write(
            joinpath(repo, project_path),
            """
            name = "Example"
            uuid = "33333333-3333-3333-3333-333333333333"
            version = "0.1.0"
            """
        )
        run(`git -C $repo add $project_path`)
        run(`git -C $repo commit --quiet -m "release 0.1.0"`)

        write(
            joinpath(repo, project_path),
            """
            name = "Example"
            uuid = "33333333-3333-3333-3333-333333333333"
            version = "0.2.0-DEV"
            """
        )
        run(`git -C $repo commit --quiet -am "start 0.2.0 development"`)
        old_ref = readchomp(`git -C $repo rev-parse HEAD`)

        write(
            joinpath(repo, project_path),
            """
            name = "Example"
            uuid = "33333333-3333-3333-3333-333333333333"
            version = "0.2.0"
            """
        )
        run(`git -C $repo commit --quiet -am "release 0.2.0"`)

        old_registry = get(ENV, "GENERAL_REGISTRY_TOML", nothing)
        ENV["GENERAL_REGISTRY_TOML"] = registry_toml
        try
            metadata = registrator_metadata(;
                package_path = repo, subdir = "", old_ref = old_ref, force = false
            )
            @test metadata["route"] == "local"
            @test metadata["new_version"] == "0.2.0"
            @test metadata["is_breaking"] == "true"
            @test metadata["skip_reason"] == ""
        finally
            if old_registry === nothing
                delete!(ENV, "GENERAL_REGISTRY_TOML")
            else
                ENV["GENERAL_REGISTRY_TOML"] = old_registry
            end
        end
    end
end
