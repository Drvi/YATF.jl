# The runner that runs these files. It decides whether the suite passed, so the
# one thing it may never do is call a failure a pass.

@testset "parallel test runner" begin
    runner = joinpath(@__DIR__, "runtests.jl")

    function run_snippet(code::AbstractString)
        dir = mktempdir()
        file = joinpath(dir, "snippet_test_file.jl")
        write(file, code)
        try
            return run_file_in_subprocess(runner, file)
        finally
            rm(dir; force=true, recursive=true)
        end
    end

    @testset "a file whose tests pass is a pass" begin
        r = run_snippet("""@testset "fine" begin\n    @test 1 == 1\nend\n""")
        @test r.ok
        @test r.status == ""
        @test occursin("Test Summary", r.output)
    end

    @testset "a file whose tests fail is a failure, with the detail kept" begin
        r = run_snippet("""@testset "not fine" begin\n    @test 1 == 2\nend\n""")
        @test !r.ok
        @test occursin("exit code", r.status)
        # The reason has to survive the trip: a summary saying "failed" without
        # saying what failed is not a test report.
        @test occursin("Test Failed", r.output)
        @test occursin("1 == 2", r.output)
    end

    @testset "a file that errors outside a test is a failure" begin
        r = run_snippet("""error("something went wrong before any test ran")\n""")
        @test !r.ok
        @test occursin("something went wrong before any test ran", r.output)
    end

    @testset "a process killed by a signal is a failure" begin
        # A signalled process reports an exit code of zero. Asking only for that
        # would report a segfault or an `abort` as a pass, which is how a suite
        # goes green on a test that never finished running.
        r = run_snippet("""@testset "aborts" begin\n    @test true\n    ccall(:abort, Cvoid, ())\nend\n""")
        @test !r.ok
        @test occursin("killed by signal", r.status)
    end

    @testset "the summary names every file that failed, and throws" begin
        results = [
            FileResult("good_test.jl", true, "", 1.0, ""),
            FileResult("bad_test.jl", false, "exit code 1", 2.0, ""),
            FileResult("crashed_test.jl", false, "killed by signal 6", 3.0, ""),
        ]
        err = Ref{Any}(nothing)
        _, printed = capture_run() do
            try
                report_files(results)
            catch e
                err[] = e
            end
        end
        @test err[] isa ErrorException
        msg = sprint(showerror, err[])
        # The table is on screen whether or not anything failed.
        @test occursin("crashed_test.jl", printed)
        @test occursin("killed by signal 6", printed)
        @test occursin("2 of 3 test files failed", msg)
        @test occursin("bad_test.jl (exit code 1)", msg)
        @test occursin("crashed_test.jl (killed by signal 6)", msg)
        @test !occursin("good_test.jl", msg)
    end

    @testset "an all-passing summary does not throw" begin
        results = [FileResult("a_test.jl", true, "", 1.0, "")]
        value, printed = capture_run() do
            report_files(results)
        end
        @test value === nothing
        @test occursin("a_test.jl", printed)
    end
end
