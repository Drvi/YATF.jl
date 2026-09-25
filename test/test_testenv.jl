using YATF.Private: prepare, execute, test_env, with_test_env, TEST_ENVS, Target, PASSED, nitems

@testset "test environment" begin
    @testset "a test-only dependency is loadable" begin
        # TestDeps declares Random in [extras]/[targets] only: without a generated
        # test environment, the item cannot load it.
        pkg = fixture("TestDeps.jl")
        for workers in (0, 1)
            p, target = prepare((pkg,); workers, logs=:issues, monitor=false)
            run = execute(p, target)
            rm(run.logdir; force=true, recursive=true)
            @test all(==(PASSED), run.statuses.state)
            # One item imports the test-only dependency itself; the other reaches it
            # through a setup module, which resolves its own imports against the
            # environment the run built.
            @test nitems(p) == 3
        end
    end

    @testset "building the environment is announced, hitting the cache is not" begin
        # Resolving takes seconds and is the longest pause a run has before it
        # prints anything else, so it says what it is waiting for. A cache hit is
        # immediate, and at the REPL — where the cache is the point — a line about
        # it would be noise on every call.
        pkg = fixture("TestDeps.jl")
        delete!(TEST_ENVS, abspath(joinpath(pkg, "Project.toml")))
        _, cold = capture_run() do
            p, target = prepare((pkg,); workers=1, logs=:issues, monitor=false)
            run = execute(p, target)
            rm(run.logdir; force=true, recursive=true)
        end
        @test occursin("resolving the test environment", cold)
        _, warm = capture_run() do
            p, target = prepare((pkg,); workers=1, logs=:issues, monitor=false)
            run = execute(p, target)
            rm(run.logdir; force=true, recursive=true)
        end
        @test !occursin("resolving the test environment", warm)
    end

    @testset "the environment is cached across runs in a session" begin
        pkg = fixture("Basic.jl")
        target = Target(pkg, joinpath(pkg, "Project.toml"), joinpath(pkg, "test"), String[], Int32(0))
        first_env = test_env(target)
        @test isfile(first_env)
        @test test_env(target) == first_env          # no rebuild, no re-resolve
        @test test_env(target) == first_env
    end

    @testset "the cache is rebuilt when the project changes" begin
        # A throwaway package rather than a copy of a fixture: two packages sharing
        # a UUID make Julia warn about a different version being loaded.
        work = mktempdir()
        pkg = joinpath(work, "Ephemeral")
        mkpath(joinpath(pkg, "src")); mkpath(joinpath(pkg, "test"))
        write(joinpath(pkg, "Project.toml"),
              "name = \"Ephemeral\"\nuuid = \"$(Base.UUID(rand(UInt128)))\"\nversion = \"0.1.0\"\n")
        write(joinpath(pkg, "src", "Ephemeral.jl"), "module Ephemeral end\n")
        write(joinpath(pkg, "test", "a_test.jl"), """@testitem "x" begin\n @test true\n end\n""")
        target = Target(pkg, joinpath(pkg, "Project.toml"), joinpath(pkg, "test"), String[], Int32(0))
        before = test_env(target)
        @test test_env(target) == before
        sleep(0.01)
        touch(joinpath(pkg, "Project.toml"))         # e.g. a test dependency was added
        after = test_env(target)
        @test after != before
    end

    @testset "a JULIA_PROJECT in the caller's environment does not reach the items" begin
        # A worker inherits this process's environment. If the variable came
        # through, every item would resolve against the caller's project instead of
        # the test environment the run built, and the package under test would be
        # the one thing it could not load.
        other = mktempdir()
        write(joinpath(other, "Project.toml"), "[deps]\n")
        pkg = fixture("TestDeps.jl")
        states, _, _ = withenv("JULIA_PROJECT" => other) do
            run_states(pkg; workers=1, logs=:issues, monitor=false)
        end
        @test all(==(PASSED), values(states))
    end

    @testset "the caller's environment is restored" begin
        pkg = fixture("Basic.jl")
        before = Base.active_project()
        p, target = prepare((pkg,); workers=1, logs=:issues, monitor=false)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        @test Base.active_project() == before
    end

    @testset "an already-active test/Project.toml is respected" begin
        work = mktempdir()
        pkg = joinpath(work, "WithTestProj")
        mkpath(joinpath(pkg, "src")); mkpath(joinpath(pkg, "test"))
        write(joinpath(pkg, "Project.toml"),
              "name = \"WithTestProj\"\nuuid = \"1a2b3c4d-0000-4000-8000-000000000008\"\n")
        write(joinpath(pkg, "src", "WithTestProj.jl"), "module WithTestProj end\n")
        write(joinpath(pkg, "test", "Project.toml"), "[deps]\n")
        target = Target(pkg, joinpath(pkg, "Project.toml"), joinpath(pkg, "test"), String[], Int32(0))
        testproj = joinpath(pkg, "test", "Project.toml")
        original = Base.active_project()
        try
            Base.set_active_project(testproj)
            seen = with_test_env(target) do
                Base.active_project()
            end
            @test abspath(seen) == abspath(testproj)     # not rebuilt behind the user's back
        finally
            Base.set_active_project(original)
        end
    end
end
