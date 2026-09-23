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
    @testset "a worker that dies says how its process ended" begin
        with_runstate_dir() do dir
            (states, _, _), out = capture_run() do
                run_states(fixture("Faulty.jl"); workers=1, tags=nothing, name=Set(["kills its worker"]),
                           logs=:issues, monitor=false)
            end
            @test states["kills its worker"] === ERRORED
            @test occursin("died while running \"kills its worker\": exited with code 7", out)
            @test occursin("the worker running this item died: exited with code 7", out)
            rs = read_run_state(only(readdir(dir; join=true)))
            down = only(e for e in rs.events if e.kind === :worker_down)
            @test down.ended_by in (:connection_lost, :process_exit)
            @test (down.exitcode, down.signal) == (7, 0)
            @test only(e for e in rs.events if e.kind === :attempt).pid == down.pid == only(rs.statuses).pid
        end
    end

    if !Sys.iswindows()
        @testset "what an item printed survives its worker being killed" begin
            dir = make_pkg("KilledMidway", "test/k_test.jl" => """
            @testitem "killed" begin
                println("the last line before the kill")
                run(`kill -9 \$(getpid())`)
                sleep(10)
            end
            """)
            (states, _, _), out = capture_run() do
                run_states(dir; workers=1, logs=:issues, monitor=false)
            end
            @test states["killed"] === ERRORED
            @test occursin("the last line before the kill", out)
            @test occursin("killed by signal 9", out)
            @test occursin("which nothing in this run sent", out)
        end
    end

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
            # Stamped when it started and again when it finished, in that order.
            @test 0 < rs.start_unix <= rs.end_unix
        end
    end

    @testset "a run state that cannot be written is done without" begin
        # A directory beneath an ordinary file cannot be created on any platform.
        blocker = touch(tempname())
        try
            dir = make_pkg("NoRunState", "test/t_test.jl" => ONE_ITEM)
            # Said through the run's own printer, like every record raised during a run.
            (states, run, _), out = withenv("YATF_RUNSTATE_DIR" => joinpath(blocker, "runs")) do
                capture_run(() -> run_states(dir; workers=0, logs=:issues, monitor=false))
            end
            @test occursin("could not open a run state", out)
            @test run.runstate === nothing
            @test states["the item"] === PASSED
        finally
            rm(blocker; force=true)
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
            @test haskey(h.failed, "a fails")
            @test haskey(h.failed, "b never runs")
        end
    end
end

# The checkout, for a child process that has to find the same one.
const REPO_ROOT = dirname(@__DIR__)

# Whether a pid belongs to a process that is still there. Signal 0 checks for one
# without sending anything; the workers are the dead coordinator's children, so
# they are reparented and reaped rather than left as zombies.
process_alive(pid::Integer) = ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0

# Windows has no signal to send: `kill` there terminates the process outright, so
# there is no teardown to watch.
Sys.iswindows() ||
@testset "an interrupt takes the workers with it, at once" begin
    # Ctrl-C is someone asking for their terminal back: the run goes down without
    # waiting for the item each slot has in flight, which here sleeps for ten
    # minutes.
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
    log = Base.BufferStream()
    proc = run(pipeline(
        setenv(`$(Base.julia_cmd()) --project=$(REPO_ROOT) --startup-file=no $path`,
               "JULIA_LOAD_PATH" => string(REPO_ROOT, ":", joinpath(REPO_ROOT, "test"), ":")),
        stdout = log, stderr = err,
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
    close(log)
    out = read(err, String)
    printed = read(log, String)
    started = [parse(Int, m.captures[1]) for m in eachmatch(r"· pid (\d+)", printed)]
    rm(path; force=true)
    # Generously above the second it takes, and far below the ten minutes an item
    # here sleeps for: what is checked is that it does not wait for them.
    @test elapsed < 30
    # Asked from outside the run, because that is where it matters: whatever the
    # coordinator got to do on its way down, no worker of its is still running. A
    # worker takes a moment to die after the signal reaches it.
    @test length(started) == 4
    deadline = time() + 10
    while time() < deadline && any(process_alive, started)
        sleep(0.2)
    end
    @test !any(process_alive, started)
    # The report never happens — the exception takes the run out before it — so the
    # run says what it got through on its way past. The items it took a worker away
    # from did not fail and are counted, not reported one by one. On 1.12 nothing
    # unwinds to say this, and the exit hook is what says it instead.
    @test occursin("interrupted after 0 of 4 test items", printed)
    @test occursin("4 cancelled", printed)
    @test !occursin("the worker running this item died", printed)
    @test !occursin("ERR ", printed)
    # The run itself sees the exception from 1.13. On 1.12 it is delivered to
    # whichever task thread 1 is running, which between items is one that has
    # already finished and has nothing left to catch it; the process dies there.
    if VERSION >= v"1.13"
        @test occursin("CAUGHT InterruptException", out)
        @test occursin("ALIVE 0", out)
    end
end
