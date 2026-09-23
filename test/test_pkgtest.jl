# The documented entry point, end to end: a package whose `test/runtests.jl` is
# `using YATF; YATF.runtests()`, run the way a user runs it and the way `Pkg.test`
# runs it. The test environment deliberately declares only YATF — not `Test` —
# because a test item's `@test` has to work without it.
using Pkg: Pkg

@testset "Pkg.test entry point" begin
    yatf_root = dirname(@__DIR__)
    work = mktempdir()
    pkg = joinpath(work, "Standalone.jl")
    cp(fixture("Standalone.jl"), pkg)
    testenv = joinpath(pkg, "test")
    runs = joinpath(work, "runs")

    io = IOBuffer()
    Pkg.activate(testenv; io)
    Pkg.develop([Pkg.PackageSpec(path=yatf_root), Pkg.PackageSpec(path=pkg)]; io)
    deps = sort!(collect(keys(Pkg.project().dependencies)))
    Pkg.activate(; temp=true, io)
    @test deps == ["Standalone", "YATF"]     # no Test, on purpose

    function run_script(cmd, logname)
        out = joinpath(work, logname)
        ok = success(pipeline(ignorestatus(addenv(cmd, "YATF_RUNSTATE_DIR" => runs,
                                                  "JULIA_LOAD_PATH" => nothing));
                              stdout=out, stderr=out))
        log = read(out, String)
        echo_captured(log)
        return ok, log
    end

    @testset "run directly, with the test environment active" begin
        ok, log = run_script(`$(Base.julia_cmd()) --startup-file=no --project=$testenv
                              $(joinpath(testenv, "runtests.jl"))`, "direct.log")
        @test ok
        @test occursin("Test Summary", log)
        @test !occursin("not found in current path", log)
    end

    @testset "run through Pkg.test, whose environment is a temporary one" begin
        script = joinpath(work, "viapkg.jl")
        write(script, """
        using Pkg
        Pkg.activate($(repr(pkg)); io=devnull)
        Pkg.test("Standalone")
        """)
        ok, log = run_script(`$(Base.julia_cmd()) --startup-file=no $script`, "viapkg.log")
        @test ok
        @test occursin("Test Summary", log)
        @test occursin("tests passed", log)
        # It found the package under test, not the temporary environment Pkg built.
        @test !occursin("no test files found", log)
    end
end
