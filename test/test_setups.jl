# Test setups are ordinary modules under `test/testsetups/`, loaded through
# LOAD_PATH. That is the whole mechanism, and it is what lets a setup use anything
# the package declares for testing — including another setup.

using YATF: PASSED, ERRORED, ConfigError, prepare, execute, nitems, setup_modules

@testset "test setups" begin
    @testset "a setup may use any of the package's test-time dependencies" begin
        pkg = fixture("TestDeps.jl")
        for workers in (0, 1)
            states, _, _ = run_states(pkg; workers, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
            @test length(states) == 3
        end
    end

    @testset "the setups an item names are the ones the run arranges for" begin
        pkg = fixture("TestDeps.jl")
        p, _ = prepare((pkg,); workers=1, logs=:issues, monitor=false)
        @test Set(p.setups) == Set([:DepSetup, :TimeSetup])
    end

    @testset "setups are precompiled once, before any worker starts" begin
        dir = make_pkg("PrecompiledSetup")
        # A module nothing has compiled before. Julia caches a setup under its own
        # name, so a fixed one would be warm from whichever earlier run of this
        # suite happened to compile it.
        setup = string("Once", string(hash(dir); base=16))
        write(joinpath(dir, "test", "a_test.jl"), """
        @testitem "uses it" begin
            using $setup
            @test $setup.value() == 7
        end
        """)
        mkpath(joinpath(dir, "test", "testsetups"))
        write(joinpath(dir, "test", "testsetups", setup * ".jl"), "module $setup\nvalue() = 7\nend\n")

        (states, _, p), out = capture_run() do
            run_states(dir; workers=2, logs=:issues, monitor=false)
        end
        @test states["uses it"] === PASSED
        @test p.setups == [Symbol(setup)]
        # One process does it, before the workers exist: without this, N workers
        # hit the same cold cache at once and serialize on Julia's precompile lock.
        @test occursin("precompiling " * setup, out)
        _, again = capture_run() do
            run_states(dir; workers=2, logs=:issues, monitor=false)
        end
        @test !occursin("precompiling", again)
    end

    @testset "setups are found as a file or as a directory" begin
        dir = make_pkg(
            "SetupShapes",
            "test/a_test.jl" => """
            @testitem "uses both" begin
                using Flat
                using Nested
                @test Flat.value() + Nested.value() == 3
            end
            """,
            "test/testsetups/Flat.jl" => "module Flat\nvalue() = 1\nend\n",
            "test/testsetups/Nested/src/Nested.jl" => "module Nested\nvalue() = 2\nend\n",
        )
        setups = setup_modules(joinpath(dir, "test"))
        @test sort(collect(keys(setups))) == [:Flat, :Nested]
        states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
        @test states["uses both"] === PASSED
    end

    @testset "a setup that will not precompile stops the run and names itself" begin
        dir = make_pkg(
            "BrokenSetup",
            "test/a_test.jl" => """
            @testitem "needs it" begin
                using Broken
                @test true
            end
            """,
            "test/testsetups/Broken.jl" => "module Broken\nerror(\"this setup is broken\")\nend\n",
        )
        err = try
            run_states(dir; workers=1, logs=:issues, monitor=false)
            nothing
        catch e
            e
        end
        @test err isa ConfigError
        msg = sprint(showerror, err)
        @test occursin("Broken", msg)
        @test occursin("failed to precompile", msg)
        # The reason, not just the fact.
        @test occursin("this setup is broken", msg)
    end

    @testset "a module that is not a setup is an ordinary load failure" begin
        # Nothing under `testsetups/` is named `Absent`, so this is not a setup the
        # run has to arrange for: it is the item asking for a package it has not got.
        dir = make_pkg("NoSuchSetup", "test/a_test.jl" => """
        @testitem "asks for a package it has not got" begin
            using Absent
            @test true
        end
        """)
        p, target = prepare((dir,); workers=1, logs=:issues, monitor=false)
        @test isempty(p.setups)
        states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
        @test states["asks for a package it has not got"] === ERRORED
    end

    @testset "the setups directory is left off LOAD_PATH afterwards" begin
        before = copy(LOAD_PATH)
        run_states(fixture("TestDeps.jl"); workers=1, logs=:issues, monitor=false)
        @test LOAD_PATH == before
    end
end
