# A worker process can die at any point a worker does anything: while evaluating a
# profile's `init` expression, while running an item, and while running the
# profile's `test_end` expression. None of those may lose the run, and each has to
# say which of the three it was.

using YATF: PASSED, FAILED, ERRORED, UNSEEN, CANCELLED, history, read_run_state, nitems

# An expression that kills the process where it stands the first `n` times it is
# reached, counting in a file. Written as a TOML literal string, which passes the
# Julia source through untouched.
crash_until(marker, n) = string(
    "init_or_end = 'let p = ENV[\"YATF_CRASH_MARKER\"]; ",
    "k = isfile(p) ? parse(Int, read(p, String)) : 0; write(p, string(k + 1)); ",
    "k < ", n, " && ccall(:abort, Cvoid, ()); end'"
)

init_crashes(marker, n) = "[profiles.default]\n" * replace(crash_until(marker, n), "init_or_end" => "init")
end_crashes(marker, n) = "[profiles.default]\n" * replace(crash_until(marker, n), "init_or_end" => "test_end")

const ONE_ITEM = """
@testitem "the item" begin
    @test true
end
"""

@testset "crashes" begin
    @testset "a worker that dies in its init expression is replaced" begin
        with_marker_dir() do work
            marker = joinpath(work, "count")
            dir = make_pkg("FlakyInit", "test/t_test.jl" => ONE_ITEM,
                           "test/TestItems.toml" => init_crashes(marker, 2))
            states, _, _ = withenv("YATF_CRASH_MARKER" => marker) do
                run_states(dir; workers=1, logs=:issues, monitor=false)
            end
            @test states["the item"] === PASSED
            # Two processes died in `init` and the third came up: a worker that
            # dies is a worker to replace, not a reason to stop.
            @test parse(Int, read(marker, String)) == 3
        end
    end

    @testset "an init expression that always kills its worker stops the run" begin
        with_marker_dir() do work
            marker = joinpath(work, "count")
            dir = make_pkg("DeadInit", "test/t_test.jl" => ONE_ITEM,
                           "test/TestItems.toml" => init_crashes(marker, 99))
            (states, _, _), out = withenv("YATF_CRASH_MARKER" => marker) do
                capture_run() do
                    run_states(dir; workers=1, logs=:issues, monitor=false)
                end
            end
            @test states["the item"] === ERRORED
            @test occursin("could not start a worker for profile `default`", out)
            @test occursin("after 3 attempts", out)
            # Tried three times and then stopped, rather than once per item forever.
            @test parse(Int, read(marker, String)) == 3
        end
    end

    @testset "a worker that dies in test_end is the test_end's fault, not the item's" begin
        with_marker_dir() do work
            marker = joinpath(work, "count")
            dir = make_pkg("DeadEnd", "test/t_test.jl" => ONE_ITEM,
                           "test/TestItems.toml" => end_crashes(marker, 99))
            (states, run, _), out = withenv("YATF_CRASH_MARKER" => marker) do
                capture_run() do
                    run_states(dir; workers=1, logs=:issues, monitor=false, retries=1)
                end
            end
            @test states["the item"] === ERRORED
            @test run.statuses.attempt[1] == 2
            @test occursin("`test_end` expression of profile `default` did not complete", out)
            # The item itself ran and passed both times; it is not blamed for it.
            @test !occursin("the worker running this item died", out)
        end
    end

    @testset "a test_end that dies still leaves the other items runnable" begin
        with_marker_dir() do work
            marker = joinpath(work, "count")
            dir = make_pkg("HalfDeadEnd", "test/t_test.jl" => """
            @testitem "first" begin
                @test true
            end
            @testitem "second" begin
                @test true
            end
            """, "test/TestItems.toml" => end_crashes(marker, 1))
            states, _, _ = withenv("YATF_CRASH_MARKER" => marker) do
                run_states(dir; workers=1, logs=:issues, monitor=false)
            end
            # One of them lost its worker; the other ran on the replacement.
            @test count(==(PASSED), values(states)) == 1
            @test count(==(ERRORED), values(states)) == 1
        end
    end

    @testset "the run state survives a worker dying" begin
        with_runstate_dir() do _
            dir = make_pkg("DeadItem", "test/t_test.jl" => """
            @testitem "aborts" begin
                ccall(:abort, Cvoid, ())
            end
            @testitem "fine" begin
                @test true
            end
            """)
            states, run, p = run_states(dir; workers=1, logs=:issues, monitor=false)
            rs = read_run_state(run.runstate.path)
            @test rs !== nothing
            @test rs.complete
            @test !rs.cancelled
            @test !rs.truncated
            @test length(rs.statuses) == nitems(p)
            # What the file says matches what the run recorded, item for item.
            for (i, it) in enumerate(rs.items)
                @test rs.statuses[i].state === states[it.name]
            end
        end
    end

    @testset "failfast is recorded as a cancellation" begin
        with_runstate_dir() do _
            dir = make_pkg("FailFast", "test/t_test.jl" => """
            @testitem "a fails" begin
                @test 1 == 2
            end
            @testitem "b never runs" begin
                @test true
            end
            @testitem "c never runs" begin
                @test true
            end
            """)
            states, run, _ = run_states(dir; workers=1, logs=:issues, monitor=false, failfast=true)
            @test states["a fails"] === FAILED
            rs = read_run_state(run.runstate.path)
            @test rs.complete
            @test rs.cancelled   # one flag reinterprets every item that has no result
            # The items that never ran are not passes, and after a run that stopped
            # early they are what to run again.
            unrun = [it.name for (i, it) in enumerate(rs.items)
                     if rs.statuses[i].state === UNSEEN || rs.statuses[i].state === CANCELLED]
            @test length(unrun) == 2
        end
    end

    @testset "a run that finishes is not recorded as cancelled" begin
        with_runstate_dir() do _
            dir = make_pkg("Complete", "test/t_test.jl" => ONE_ITEM)
            _, run, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
            rs = read_run_state(run.runstate.path)
            @test rs.complete
            @test !rs.cancelled
        end
    end

    @testset "everything a cancelled run did not reach is retried" begin
        with_runstate_dir() do _
            dir = make_pkg("RetryAfterFailfast", "test/t_test.jl" => """
            @testitem "a fails" begin
                @test 1 == 2
            end
            @testitem "b never runs" begin
                @test true
            end
            """)
            run_states(dir; workers=1, logs=:issues, monitor=false, failfast=true)
            h = history(dir; nruns=1)
            # The failure and the item that never got a turn, both.
            @test "a fails" in h.failed
            @test "b never runs" in h.failed
        end
    end
end

# The checkout, for a child process that has to find the same one.
const REPO_ROOT = dirname(@__DIR__)

@testset "an interrupt takes the workers with it, at once" begin
    # Ctrl-C is someone asking for their terminal back. The run used to let every
    # slot finish the item it had in flight first, so an item with a long sleep in
    # it held the interrupt for as long as it liked.
    ready = joinpath(mktempdir(), "ready")
    script = """
    # A script exits on SIGINT unless told otherwise; a REPL raises it, and the
    # second of those is what is under test.
    Base.exit_on_sigint(false)
    using YATF
    include(joinpath($(repr(REPO_ROOT)), "test", "helpers.jl"))
    const FIXTURES = joinpath($(repr(REPO_ROOT)), "test", "packages")
    fixture(name) = joinpath(FIXTURES, name)
    dir = make_pkg("Interrupted", "test/t_test.jl" => join(
        [\"\"\"
        @testitem "slow \$i" begin
            touch(joinpath($(repr(dirname(ready))), string("ready", \$i)))
            sleep(600)
            @test true
        end
        \"\"\" for i in 1:4], "\\n"))
    try
        run_states(dir; workers=4, logs=:issues, monitor=false)
    catch e
        println(stderr, "CAUGHT \$(typeof(e))")
    end
    sleep(0.5)
    alive = @lock YATFWorkers.LIVE_LOCK count(Base.process_running, YATFWorkers.LIVE_PROCESSES)
    println(stderr, "ALIVE \$alive")
    """
    path, io = mktemp()
    write(io, script)
    close(io)
    err = Base.BufferStream()
    proc = run(pipeline(
        setenv(`$(Base.julia_cmd()) --project=$(REPO_ROOT) --startup-file=no $path`,
               "JULIA_LOAD_PATH" => string(REPO_ROOT, ":", joinpath(REPO_ROOT, "test"), ":")),
        stdout = devnull, stderr = err,
    ); wait = false)
    # The items say when they are running, so the interrupt lands mid-item rather
    # than during an environment build that can take minutes.
    deadline = time() + 300
    while time() < deadline && process_running(proc) && !isfile(ready * "1")
        sleep(0.5)
    end
    @test isfile(ready * "1")
    t0 = time()
    kill(proc, Base.SIGINT)
    wait(proc)
    elapsed = time() - t0
    close(err)
    out = read(err, String)
    rm(path; force=true)
    @test occursin("CAUGHT InterruptException", out)
    @test occursin("ALIVE 0", out)
    # Generously above the second it takes, and far below the ten minutes an item
    # here sleeps for: what is checked is that it does not wait for them.
    @test elapsed < 30
end
