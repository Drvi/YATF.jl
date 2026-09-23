# Stepping into a test item: `YATF.debug`, and the Debugger.jl extension behind it.
# The item's body becomes a function the debugger enters, and what cannot be part
# of a function runs first. Most of this is checked with a stand-in for the
# debugger that calls the function; the last testset drives the real one.

using YATF: FAILED, ERRORED, ConfigError, NoTestsError
using REPL: REPL, Terminals

const STEPPED = make_pkg(
    "Stepped",
    "test/s_test.jl" => """
    @testitem "declares and tests" begin
        using Random
        struct Point
            x::Int
        end
        Point() = Point(0)
        Base.show(io::IO, p::Point) = print(io, "Point(", p.x, ")")
        const ORIGIN = Point()
        macro twice(ex)
            :(2 * \$(esc(ex)))
        end
        @enum Colour red green
        Base.@kwdef struct Options
            n::Int = 3
        end
        square(x) = x^2
        total = 0
        for i in 1:Options().n
            total += square(i)
        end
        @test total == 14
        @test sprint(show, ORIGIN) == "Point(0)"
        @test @twice(21) == 42
        @test green isa Colour
        @test rand(Xoshiro(1), 1:10) isa Int
    end

    @testitem "fails" begin
        x = 41
        @test x == 42
    end

    @testitem "throws" begin
        error("thrown from the item")
    end

    @testitem "skipped" skip=true begin
        @test false
    end

    @testitem "draws and fails" begin
        write(ENV["YATF_DRAW"], string(rand(UInt64)))
        @test false
    end

    @testitem "profiled" sandbox=:flagged timeout=30 begin
        @test ENV["YATF_FROM_PROFILE"] == "env"
        @test Main.YATF_FROM_INIT == 7
    end
    """,
    "test/TestItems.toml" => """
    [profiles.flagged]
    julia_args = ["--check-bounds=yes"]
    env = { YATF_FROM_PROFILE = "env" }
    init = "YATF_FROM_INIT = 7"
    test_end = "write(ENV[\\"YATF_END\\"], \\"ran\\")"
    """,
)
const STEPPED_FILE = joinpath(STEPPED, "test", "s_test.jl")
line_of(text) = findfirst(contains(text), readlines(STEPPED_FILE))

# What stands in for the debugger: it calls the body, as `Debugger.@enter` followed
# by `c` does.
call(body) = body()

@testset "debugging a test item" begin
    @testset "without Debugger loaded, it says what it needs" begin
        @test Base.get_extension(YATF, :YATFDebuggerExt) === nothing
        for call_debug in (() -> YATF.debug("declares and tests"), () -> YATF.debug())
            err = try
                call_debug()
            catch e
                e
            end
            @test err isa ConfigError
            @test occursin("`using Debugger`", sprint(showerror, err))
        end
    end

    with_activated(STEPPED) do _
        @testset "the body is a function, and what cannot be part of one runs first" begin
            entered = Ref{Any}(nothing)
            ts = YATF.debug_item("declares and tests", nothing) do body
                entered[] = only(methods(body))
                body()
            end
            @test ts.n_passed == 5
            @test isempty(ts.results)
            # One method of no arguments, where the item is declared.
            @test entered[].nargs == 1
            @test endswith(String(entered[].file), joinpath("test", "s_test.jl"))
            @test entered[].line == line_of("@testitem \"declares and tests\"")
        end

        @testset "a failure and an error are the item's, at the test file's lines" begin
            ts = YATF.debug_item(call, "fails", nothing)
            @test YATFWorkers.state_of(ts) === FAILED
            @test only(ts.results).source.line == line_of("@test x == 42")
            ts = YATF.debug_item(call, "throws", nothing)
            @test YATFWorkers.state_of(ts) === ERRORED
            @test occursin("thrown from the item", sprint(show, only(ts.results)))
        end

        @testset "an item left before it finished is not a pass" begin
            # A debugger that is quit returns without the body having run to its end.
            ts = YATF.debug_item(body -> nothing, "declares and tests", nothing)
            @test YATFWorkers.state_of(ts) === ERRORED
            @test occursin("left before it finished", sprint(show, only(ts.results)))
        end

        @testset "a skipped item is not entered" begin
            entered = Ref(false)
            _, out = capture_run() do
                YATF.debug_item(body -> (entered[] = true; body()), "skipped", nothing)
            end
            @test !entered[]
            @test any(l -> occursin("· DONE ·", l) && occursin("SKIP", l), eachsplit(out, '\n'))
        end

        @testset "with a run's seed, the item draws what it drew in that run" begin
            mktempdir() do tmp
                draw = joinpath(tmp, "draw")
                drawn(f) = withenv(() -> (f(); read(draw, String)), "YATF_DRAW" => draw)
                debugged = drawn(() -> YATF.debug_item(call, "draws and fails", 7))
                ran = drawn(() -> run_states(STEPPED; workers=0, seed=7, name="draws and fails", logs=:issues, monitor=false))
                @test debugged == ran
                @test drawn(() -> YATF.debug_item(call, "draws and fails", 8)) != ran
            end
        end

        @testset "without a name, it is the last run's most recent failure, with the run's seed" begin
            debug_last() = try
                YATF.debug_item(call, nothing, nothing)
            catch e
                e
            end
            with_runstate_dir() do _
                err = debug_last()
                @test err isa NoTestsError
                @test occursin("no run of this project is recorded", sprint(showerror, err))

                # Two failures: the one that finished last is stepped into, and the
                # other is named for the asking.
                _, run, p = run_states(STEPPED; workers=0, name=Set(["fails", "throws"]), logs=:issues, monitor=false)
                ended(name) = let i = findfirst(==(name), p.items.name)
                    run.statuses.start[i] + run.statuses.elapsed[i]
                end
                latest, other = sort(["fails", "throws"]; by=ended, rev=true)
                _, out = capture_run(debug_last)
                @test occursin("debugging $(repr(latest)) in this process · the last run's most recent failure", out)
                @test occursin("the run's other failures: $(repr(other))", out)

                # Stepped into with the seed of the run it failed in, an item draws the
                # random numbers it drew there.
                mktempdir() do tmp
                    withenv("YATF_DRAW" => joinpath(tmp, "draw")) do
                        run_states(STEPPED; workers=0, seed=7, name="draws and fails", logs=:issues, monitor=false)
                        ran = read(ENV["YATF_DRAW"], String)
                        _, out = capture_run(debug_last)
                        @test read(ENV["YATF_DRAW"], String) == ran
                        @test occursin("the run's seed 0x0000000000000007", out)
                    end
                end

                # The last run passed: the failures of the runs before it are not
                # stepped into, since they may be fixed.
                run_states(STEPPED; workers=0, name="declares and tests", logs=:issues, monitor=false)
                err = debug_last()
                @test err isa NoTestsError
                @test occursin("had no failures", sprint(showerror, err))
            end
        end

        @testset "a profile's env, init and test_end apply, and what cannot is said" begin
            mktempdir() do tmp
                marker = joinpath(tmp, "end")
                ts, out = withenv("YATF_END" => marker) do
                    capture_run(() -> YATF.debug_item(call, "profiled", nothing))
                end
                @test ts.n_passed == 2
                @test isempty(ts.results)
                @test read(marker, String) == "ran"
                # A flag this process was started without, and a keyword for the
                # scheduler, are listed; what was applied is not.
                @test occursin("`--check-bounds=yes` of profile `flagged`", out)
                @test occursin("timeout=30", out)
                @test !occursin("YATF_FROM_PROFILE", out)
            end
        end

        @testset "a name that is not an item's suggests the ones it is part of" begin
            err = try
                YATF.debug_item(call, "declares", nothing)
            catch e
                e
            end
            @test err isa NoTestsError
            @test occursin("did you mean \"declares and tests\"", sprint(showerror, err))
        end
    end
end

# Debugger's REPL mode on a pair of pipes, as its own tests drive it.
mutable struct FakeTerminal <: Terminals.UnixTerminal
    in_stream::IO
    out_stream::IO
    err_stream::IO
    hascolor::Bool
    raw::Bool
end
Terminals.hascolor(t::FakeTerminal) = t.hascolor
Terminals.raw!(t::FakeTerminal, raw::Bool) = (t.raw = raw; true)
Terminals.size(::FakeTerminal) = (24, 80)

"""
    typed_into_debugger(f, keys) -> (value, output)

`f()` with `keys` typed into the REPL the debugger takes over, and what it drew. The
keys are all typed ahead, then the input ends: each command is read when the
debugger asks for one, so nothing depends on timing, and a debugger still asking
after the last one reads the end of its input and stops.
"""
function typed_into_debugger(f, keys::AbstractString)
    input, output = Pipe(), Pipe()
    Base.link_pipe!(input; reader_supports_async=true, writer_supports_async=true)
    Base.link_pipe!(output; reader_supports_async=true, writer_supports_async=true)
    write(input.in, keys)
    close(input.in)
    drawn = @async read(output.out, String)
    Base.active_repl = REPL.LineEditREPL(FakeTerminal(input.out, output.in, output.in, false, false), false)
    value = try
        f()
    finally
        close(output.in)
    end
    return value, replace(fetch(drawn), r"\e\[[0-9;?]*[A-Za-z]" => "")
end

using Debugger

@testset "with Debugger, the item is stepped through in its test file" begin
    @test Base.get_extension(YATF, :YATFDebuggerExt) !== nothing
    with_activated(STEPPED) do _
        (ts, drawn), out = capture_run() do
            typed_into_debugger(() -> YATF.debug("declares and tests"; seed=7), "n\rn\rc\r")
        end
        @test ts.n_passed == 5
        @test isempty(ts.results)
        # It stops at the body's first call, the loop, with everything that had to be
        # at top level already run, and shows it where it is in the file.
        @test occursin("testitem() at ", drawn)
        @test occursin(joinpath("test", "s_test.jl"), drawn)
        @test occursin(Regex(">\\s*$(line_of("for i in 1:Options"))\\s+for i in 1:Options"), drawn)
        @test occursin("debugging \"declares and tests\" in this process · seed 0x0000000000000007", out)

        # The input ends after one step: the item did not finish, and says so.
        (ts, _), _ = capture_run() do
            typed_into_debugger(() -> YATF.debug("declares and tests"), "n\r")
        end
        @test YATFWorkers.state_of(ts) === ERRORED
        @test occursin("left before it finished", sprint(show, only(ts.results)))

        # Without a name: the failure the last run recorded, continued to its end,
        # fails again.
        with_runstate_dir() do _
            run_states(STEPPED; workers=0, name="fails", logs=:issues, monitor=false)
            (ts, _), out = capture_run() do
                typed_into_debugger(() -> YATF.debug(), "c\r")
            end
            @test YATFWorkers.state_of(ts) === FAILED
            @test occursin("debugging \"fails\" in this process · the last run's most recent failure", out)
        end
    end
end
