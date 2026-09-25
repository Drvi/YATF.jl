using YATF.Private: PASSED, ERRORED, TIMEDOUT, merge_coverage, function_body_lines, print_coverage

# What the run's closing block says about coverage. The block is the report's, which
# `run_states` does not make: the lost-worker run has an item that times out, and
# its report would fail this file.
closing(run, p) = sprint(io -> print_coverage(io, run.coverage, p.root))

# A package whose functions a suite runs some of: `double` and `half` from items that
# land on two workers, `untested` never, and `more.jl`'s function never either.
function covered_package(name; items = """
        @testitem "doubles" begin
            @test $name.double(2) == 4
        end
        @testitem "halves" begin
            @test $name.half(4) == 2
        end
        """)
    return make_pkg(
        name,
        "src/$name.jl" => """
        module $name
        double(x) = 2x
        half(x) = x / 2
        function untested(x)
            y = x - 1
            return y
        end
        include("more.jl")
        end
        """,
        "src/more.jl" => "never_called(x) = x + 100\n",
        "test/a_test.jl" => items,
    )
end

@testset "coverage" begin
    @testset "a function body's lines are found however it is written" begin
        path = joinpath(mktempdir(), "forms.jl")
        write(path, """
        module Forms                        # 1
        const K = 1                         # 2: not in a function
        function long(x)                    # 3
            return x + K                    # 4
        end                                 # 5
        short(x) = x                        # 6
        typed(x::T) where {T} = x           # 7
        returns(x)::Int = x                 # 8
        "documented"                        # 9
        documented(x) = x                   # 10
        @inline inlined(x) = x              # 11
        const anon = x -> x + 1             # 12
        end                                 # 13
        """)
        @test function_body_lines(path) == [3, 4, 6, 7, 8, 10, 11, 12]
        write(path, "this is not julia (")
        @test isempty(function_body_lines(path))
    end

    @testset "workers' tracefiles are summed over src/ and ext/, and what never ran counts" begin
        root = mktempdir()
        mkpath(joinpath(root, "src")); mkpath(joinpath(root, "ext")); mkpath(joinpath(root, "test"))
        write(joinpath(root, "src", "P.jl"), "module P\nf(x) = x\ng(x) = x\nend\n")
        write(joinpath(root, "ext", "PExt.jl"), "module PExt\nh(x) = x\nend\n")
        write(joinpath(root, "test", "t_test.jl"), "t(x) = x\n")
        # What Julia writes: absolute, resolved paths, and only compiled functions.
        real = realpath(root)
        traces = mktempdir()
        write(joinpath(traces, "101.info"), """
        SF:$(joinpath(real, "src", "P.jl"))
        DA:2,3
        LH:1
        LF:1
        end_of_record
        SF:$(joinpath(real, "test", "t_test.jl"))
        DA:1,1
        LH:1
        LF:1
        end_of_record
        SF:$(joinpath(dirname(real), "Elsewhere", "src", "E.jl"))
        DA:1,1
        LH:1
        LF:1
        end_of_record
        """)
        write(joinpath(traces, "102.info"), "SF:$(joinpath(real, "src", "P.jl"))\nDA:2,2\nLH:1\nLF:1\nend_of_record\n")
        write(joinpath(traces, "103.info"), "")      # a worker that ran nothing counted
        out = joinpath(root, "lcov.info")
        # Given the root as it was, which on macOS is a symlink to the resolved path.
        files, lines, hit = merge_coverage(traces, root, out)
        @test (files, lines, hit) == (2, 3, 1)
        @test read(out, String) == """
        SF:ext/PExt.jl
        DA:2,0
        LH:0
        LF:1
        end_of_record
        SF:src/P.jl
        DA:2,5
        DA:3,0
        LH:1
        LF:2
        end_of_record
        """
    end

    @testset "a covered run merges its workers' counts into lcov.info at the root" begin
        dir = covered_package("CovRun")
        (states, run, p), out = capture_run(() -> run_states(dir; workers=2, logs=:issues, monitor=false, coverage=true))
        @test all(==(PASSED), values(states))
        @test length(unique(run.statuses.pid)) == 2                 # the two items, on two workers
        @test read(joinpath(dir, "lcov.info"), String) == """
        SF:src/CovRun.jl
        DA:2,1
        DA:3,1
        DA:4,0
        DA:5,0
        DA:6,0
        LH:2
        LF:5
        end_of_record
        SF:src/more.jl
        DA:1,0
        LH:0
        LF:1
        end_of_record
        """
        @test occursin("coverage: src/ and ext/, merged into lcov.info · set by the `coverage` keyword", out)
        @test closing(run, p) == "coverage: 33.3% of 6 lines in 2 files · lcov.info\n"
        @test !any(endswith(".cov"), readdir(joinpath(dir, "src")))  # nothing beside the source
    end

    @testset "a worker that dies without exiting is said to have left no coverage" begin
        # `_exit` ends the process without Julia's exit hooks, which write the
        # tracefile, as SIGKILL or a crash does.
        dir = covered_package("CovLost"; items = """
            @testitem "doubles" begin
                @test CovLost.double(2) == 4
            end
            @testitem "dies" begin
                CovLost.half(4)
                ccall(:_exit, Cvoid, (Cint,), 3)
            end
            """)
        (states, run, p), out = capture_run(() -> run_states(dir; workers=2, logs=:issues, monitor=false, coverage=true))
        @test states["doubles"] === PASSED && states["dies"] === ERRORED
        @test occursin("coverage: none from 1 worker that ran items and did not exit normally", closing(run, p))
        lcov = read(joinpath(dir, "lcov.info"), String)
        @test occursin("DA:2,1", lcov)      # the worker that exited counts
        @test occursin("DA:3,0", lcov)      # and what the other ran is lost with it
    end

    @testset "a worker stopped for timing out leaves its coverage, but on Windows" begin
        # Stopped with SIGTERM, on which Julia runs its exit hooks; on Windows with
        # TerminateProcess, which runs nothing.
        dir = covered_package("CovTimeout"; items = """
            @testitem "hangs" timeout=3 begin
                CovTimeout.half(4)
                sleep(600)
            end
            """)
        (states, run, p), out = capture_run(() -> run_states(dir; workers=1, logs=:issues, monitor=false, coverage=true))
        @test states["hangs"] === TIMEDOUT
        if Sys.iswindows()
            @test occursin("coverage: none from 1 worker that ran items", closing(run, p))
        else
            @test !occursin("did not exit normally", closing(run, p))
            @test occursin("DA:3,1", read(joinpath(dir, "lcov.info"), String))
        end
    end

    @testset "a report that cannot be written is said, and the run's result stands" begin
        dir = covered_package("CovUnwritable")
        mkpath(joinpath(dir, "lcov.info"))                           # a directory where the file goes
        (states, run, p), out = capture_run(() -> run_states(dir; workers=1, logs=:issues, monitor=false, coverage=true))
        @test all(==(PASSED), values(states))
        @test startswith(closing(run, p), "coverage: not written, the run's result stands: ")
        @test !isempty(run.coverage.error)
    end
end
