# The configuration matrix. Every combination of worker count, worker thread
# setting and log mode has to run the same suite to the same outcome and say the
# same things about it: the three settings are independent, and what a run reports
# must not depend on which of them it got.
#
# The fixture is generated rather than checked in so that the assertions can be
# about real line numbers. A test that hard-codes `:14` is a test that goes wrong
# the first time somebody adds a line above it.

using YATF: PASSED, FAILED, ERRORED, SKIPPED
using YATFWorkers: YATFWorkers

"""
    marked(source) -> (source, marks)

`source` unchanged, and the line number of every `# mark:name` comment in it.
"""
function marked(source::AbstractString)
    marks = Dict{String, Int}()
    for (i, line) in enumerate(eachsplit(source, '\n'))
        m = match(r"#\s*mark:(\w+)", line)
        m === nothing || (marks[String(m.captures[1])] = i)
    end
    return source, marks
end

const MATRIX_SOURCE, MARKS = marked("""
@testitem "matrix passes" begin                          # mark:pass_item
    using MatrixSetup
    println("stdout from matrix passes")
    @info "info from matrix passes"
    @test MatrixSetup.value() == 42                      # mark:pass_assert
end

@testitem "matrix fails" begin                           # mark:fail_item
    println("stdout from matrix fails")
    x = 41
    @test x == 42                                        # mark:fail_assert
end

@testitem "matrix errors" begin                          # mark:error_item
    @warn "warning from matrix errors"
    error("deliberate matrix error")                     # mark:error_call
end

@testitem "matrix throws below the surface" begin        # mark:deep_item
    inner() = Base.get([1], 5, nothing) === nothing ? throw(ArgumentError("from inner")) : 0
    inner()                                              # mark:deep_call
end

@testitem "matrix nests testsets" begin                  # mark:nested_item
    @testset "the inner one" begin
        @test 1 == 1
        @test 2 == 3                                     # mark:nested_assert
    end
end

@testitem "matrix fails quietly" begin                   # mark:quiet_item
    @test false                                          # mark:quiet_assert
end

@testitem "matrix skips" skip=true begin                 # mark:skip_item
    @test false
end

@testitem "matrix sees its threads" begin                # mark:threads_item
    want = get(ENV, "YATF_EXPECT_THREADS", "")
    if haskey(ENV, "YATF_WORKER") && !isempty(want)
        @test string(Threads.nthreads(:default), ",", Threads.nthreads(:interactive)) == want
    else
        @test Threads.nthreads() >= 1
    end
end
""")

const MATRIX_PKG = make_pkg(
    "MatrixPkg",
    "test/matrix_test.jl" => MATRIX_SOURCE,
    "test/testsetups/MatrixSetup.jl" => "module MatrixSetup\nvalue() = 42\nend\n",
)

const MATRIX_STATES = Dict(
    "matrix passes" => PASSED,
    "matrix fails" => FAILED,
    "matrix errors" => ERRORED,
    "matrix throws below the surface" => ERRORED,
    "matrix nests testsets" => FAILED,
    "matrix fails quietly" => FAILED,
    "matrix skips" => SKIPPED,
    "matrix sees its threads" => PASSED,
)

# `0` is this process, `1` is one worker with no stealing, and the third is a real
# pool. At least two, so the multi-worker path is covered on a single-threaded
# session as well.
const MATRIX_WORKERS = unique((0, 1, max(2, Threads.nthreads())))
const MATRIX_THREADS = ("1", "2,1")
const MATRIX_LOGS = (:eager, :issues, :batched)

# `Test` prints an absolute path; the run's own lines print one relative to the
# project. Both end the same way.
at_line(mark) = string("matrix_test.jl:", MARKS[mark])

@testset "configuration matrix" begin
    @test length(MARKS) == 14   # every mark the assertions below reach for

    for workers in MATRIX_WORKERS, threads in MATRIX_THREADS, logs in MATRIX_LOGS
        @testset "workers=$workers threads=$(repr(threads)) logs=$logs" begin
            expected = threads == "1" ? "1,0" : "2,1"
            (states, run, _), out = withenv("YATF_EXPECT_THREADS" => expected) do
                capture_run() do
                    run_states(MATRIX_PKG; workers, threads, logs, monitor=false)
                end
            end
            lines = collect(eachsplit(out, '\n'))

            @testset "every item reaches the outcome it was written for" begin
                for (name, state) in MATRIX_STATES
                    @test states[name] === state
                end
            end

            @testset "every item announces its start and its end, once" begin
                starts = filter(l -> occursin("· RUN", l), lines)
                dones = filter(l -> occursin("· DONE", l), lines)
                @test length(starts) == length(MATRIX_STATES)
                @test length(dones) == length(MATRIX_STATES)
                @test all(l -> count("· RUN", l) <= 1, lines)
                @test all(l -> count("· DONE", l) <= 1, lines)
                # A start says where the item is declared.
                @test any(l -> occursin("\"matrix fails\"", l) && occursin(at_line("fail_item"), l),
                          starts)
                @test any(l -> occursin("\"matrix skips\"", l) && occursin(at_line("skip_item"), l),
                          starts)
                # An end says how it went, in the word and in the glyph.
                for (name, word) in ("matrix passes" => "PASS", "matrix fails" => "FAIL",
                                     "matrix errors" => "ERR", "matrix skips" => "SKIP")
                    @test any(l -> occursin(repr(name), l) && occursin(word, l), dones)
                end
                # Blue while it runs, whatever the item turns out to be.
                @test all(l -> occursin(YATF.MARK_RUNNING, l), starts)
                for (name, state) in MATRIX_STATES
                    line = only(filter(l -> occursin(repr(name), l), dones))
                    @test occursin(YATF.state_mark(state), line)
                end
                # ...and the glyph is the one the colour would have been.
                @test count(l -> occursin(YATF.MARK_PASSED, l), dones) ==
                    count(==(PASSED), values(MATRIX_STATES))
                @test count(l -> occursin(YATF.MARK_SET_ASIDE, l), dones) ==
                    count(==(SKIPPED), values(MATRIX_STATES))
                @test count(l -> occursin(YATF.MARK_FAILED, l), dones) == 5
            end

            @testset "the name column lines the outcomes up" begin
                dones = filter(l -> occursin("· DONE", l), lines)
                width = run.name_width
                # Every name this run can hold is padded to the same width, so the
                # outcome after it starts in the same column on every line.
                fitting = filter(dones) do l
                    name = match(r"DONE · [\d/]+ · (\"[^\"]*\")", l)
                    name !== nothing && textwidth(name.captures[1]) <= width
                end
                @test !isempty(fitting)
                columns = unique(first(findfirst(r"(PASS|FAIL|ERR|SKIP)", l)) for l in fitting)
                @test length(columns) == 1
                # ...and the width is the one the names asked for.
                @test width == YATF.name_width(collect(keys(MATRIX_STATES)))
            end

            @testset "a failure names the line it failed on" begin
                # Not the item's line, not the file's: the line of the `@test`,
                # and named the way the project names it.
                @test occursin("Test Failed at test/matrix_test.jl:" *
                               string(MARKS["fail_assert"]), out)
                @test occursin(at_line("fail_assert"), out)
                @test occursin("Expression: x == 42", out)
                @test occursin("Evaluated: 41 == 42", out)
                # ...and the same for one inside a nested testset.
                @test occursin(at_line("nested_assert"), out)
                @test occursin("Expression: 2 == 3", out)
            end

            @testset "an error carries a stacktrace that points at the test" begin
                @test occursin("deliberate matrix error", out)
                @test occursin("Got exception outside of a @test", out)
                @test occursin("Stacktrace:", out)
                # The frame for the line that threw, and for the one below it.
                @test occursin(at_line("error_call"), out)
                @test occursin("from inner", out)
                @test occursin(at_line("deep_call"), out)
            end

            @testset "the paths the run reports are relative to the project" begin
                # An absolute path is noise on a shared machine and meaningless in
                # a CI log. This covers what the run writes; what an item printed
                # for itself is passed through as the item wrote it, `@warn`'s own
                # absolute location included.
                @test !occursin("Test Failed at " * MATRIX_PKG, out)
                @test !occursin("Error During Test at " * MATRIX_PKG, out)
                @test occursin("Error During Test at test/matrix_test.jl:", out)
                # Stacktrace frames as well, not just the first line.
                @test occursin("@ test/matrix_test.jl:", out)
                @test !occursin("@ " * MATRIX_PKG, out)
                # ...and the footer the run draws under the block.
                @test any(l -> startswith(l, "└ @ test/matrix_test.jl:"), lines)
            end

            @testset "a stacktrace stops at the test's own frames" begin
                # The machinery that called the item says nothing about why it
                # failed, and is trimmed unless asked for.
                @test !occursin("runitem.jl", out)
                @test !occursin("serve_requests", out)
                @test !occursin("_run_item", out)
                @test !occursin("eval_block!", out)
            end

            @testset "each failing item is one block, with its own location" begin
                # An item's block, not the run's own header, which opens the
                # same way.
                blocks = filter(l -> occursin(r"^┌ \[ *\d+/\d+\] ", l), lines)
                # Exactly one block per item that did not pass.
                for name in ("matrix fails", "matrix errors", "matrix nests testsets",
                             "matrix throws below the surface", "matrix fails quietly")
                    @test count(l -> occursin(repr(name), l), blocks) == 1
                end
                # A skipped item has nothing to report, and a passing one only
                # under `:batched`.
                @test !any(l -> occursin(repr("matrix skips"), l), blocks)
                @test (logs === :batched) ==
                    any(l -> occursin(repr("matrix passes"), l), blocks)

                # The run's own footers, not the ones `Logging` draws under an
                # `@warn` the item raised: those carry the module and an absolute
                # path, these carry the project-relative one.
                footers = filter(l -> startswith(l, "└ @ test/matrix_test.jl:"), lines)
                @test any(l -> occursin("test/matrix_test.jl:$(MARKS["fail_item"])", l), footers)
                @test any(l -> occursin("test/matrix_test.jl:$(MARKS["error_item"])", l), footers)
                @test length(footers) == length(blocks)
                if workers == 0
                    @test !any(l -> occursin(" on worker ", l), footers)
                else
                    @test all(l -> occursin(" on worker ", l), footers)
                end
            end

            @testset "what an item printed is shown when the mode says so" begin
                # A failing item's output is always worth seeing.
                @test occursin("stdout from matrix fails", out)
                @test occursin("warning from matrix errors", out)
                if logs === :issues
                    # Only the items with something wrong say what they printed.
                    @test !occursin("stdout from matrix passes", out)
                    @test !occursin("info from matrix passes", out)
                    @test occursin("┌ Captured logs", out)
                    # A failure that printed nothing says that, rather than nothing.
                    @test occursin("No captured logs", out)
                elseif logs === :batched
                    @test occursin("stdout from matrix passes", out)
                    @test occursin("info from matrix passes", out)
                    @test occursin("┌ Captured logs", out)
                else
                    # Relayed as it happened, so there is nothing to print after.
                    @test occursin("stdout from matrix passes", out)
                    @test occursin("info from matrix passes", out)
                    @test !occursin("Captured logs", out)
                end
            end

            @testset "no two writers share a line" begin
                for marker in ("┌ [", "· RUN", "· DONE", "┌ Captured logs")
                    @test all(l -> count(marker, l) <= 1, lines)
                end
            end
        end
    end

    @testset "the framework's own frames come back when asked for" begin
        (_, run, p), out = capture_run() do
            run_states(MATRIX_PKG; workers=1, logs=:issues, monitor=false,
                       full_stacktraces=true, name="matrix errors")
        end
        @test occursin(at_line("error_call"), out)   # still the item's own line
        @test occursin("runitem.jl", out)            # and now the machinery too
    end
end
