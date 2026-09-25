# A worker process can die at any point a worker does anything: while evaluating a
# profile's `init` expression, while running an item, and while running the
# profile's `test_end` expression. None of those may lose the run, and each has to
# say which of the three it was.

using YATF.Private: PASSED, FAILED, ERRORED, UNSEEN, CANCELLED, history, read_run_state, nitems

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
            # From the moment every offset in it counts from, so the start plus an
            # attempt's offset is when that attempt began.
            @test rs.start_unix == run.t0
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

"""
    interrupted_run(; items, julia_args, monitor, delay, repl) -> NamedTuple

Run `items` items that each sleep for ten minutes, on as many workers, in a
coordinator of its own started with `julia_args`, and send it SIGINT `delay` seconds
after every item is running. With `repl`, the coordinator raises the interrupt as a
REPL does; without, it exits on it, as a script and `Pkg.test` do. Returns whether
the items got running, how long the coordinator took to end, what it printed and
said on stderr, and the pids of the workers it started.
"""
function interrupted_run(; items = 4, julia_args = String[], monitor = false, delay, repl = true)
    ready = joinpath(mktempdir(), "ready")
    script = """
    # A script exits on SIGINT unless told otherwise; a REPL raises it.
    $(repl ? "Base.exit_on_sigint(false)" : "")
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
        \"\"\" for i in 1:$items], "\\n"))
    # From 1.14 Ctrl-C cancels this script's scope, where every later wait throws
    # again: what it says afterwards is said shielded.
    try
        run_states(dir; workers=$items, logs=:issues, monitor=$monitor)
    catch e
        YATFWorkers.shielded(() -> println(stderr, "CAUGHT \$(typeof(e))"))
    end
    YATFWorkers.shielded() do
        sleep(0.5)
        alive = @lock YATFWorkers.LIVE_LOCK count(Base.process_running, YATFWorkers.LIVE_PROCESSES)
        println(stderr, "ALIVE \$alive")
    end
    """
    path, io = mktemp()
    write(io, script)
    close(io)
    err = Base.BufferStream()
    log = Base.BufferStream()
    proc = run(pipeline(
        setenv(`$(Base.julia_cmd()) $julia_args --project=$(REPO_ROOT) --startup-file=no $path`,
               "JULIA_LOAD_PATH" => string(REPO_ROOT, ":", joinpath(REPO_ROOT, "test"), ":")),
        stdout = log, stderr = err,
    ); wait = false)
    # The items say when they are running, so the interrupt lands with all of them
    # mid-item: not during an environment build that can take minutes, and not
    # while a worker is still starting and has yet to print the pid looked for below.
    running() = all(i -> isfile(ready * string(i)), 1:items)
    deadline = time() + 300
    while time() < deadline && process_running(proc) && !running()
        sleep(0.1)
    end
    got_running = running()
    sleep(delay)
    t0 = time()
    kill(proc, Base.SIGINT)
    # Bounded: an interrupt that is lost would hold the test for the items' ten
    # minutes, and the time it took is what is checked. The workers go too: each is
    # in a process group of its own, holds the coordinator's stderr, and would keep
    # the output from ending until its item did.
    if timedwait(() -> process_exited(proc), 120) !== :ok
        run(ignorestatus(`pkill -9 -P $(getpid(proc))`))
        kill(proc, Base.SIGKILL)
    end
    wait(proc)
    elapsed = time() - t0
    close(err)
    close(log)
    out = read(err, String)
    printed = read(log, String)
    started = [parse(Int, m.captures[1]) for m in eachmatch(r"· pid (\d+)", printed)]
    rm(path; force=true)
    return (; got_running, elapsed, out, printed, started)
end

# What the coordinator catches: an `InterruptException`, or from 1.14 the
# `CancellationRequest` that Ctrl-C has become.
const CAUGHT_INTERRUPT = r"CAUGHT (InterruptException|(Base\.)?CancellationRequest)$"m

# Asked from outside the run, because that is where it matters: whatever the
# coordinator got to do on its way down, no worker of its is still running. A
# worker takes a moment to die after the signal reaches it.
function all_gone(pids)
    deadline = time() + 10
    while time() < deadline && any(process_alive, pids)
        sleep(0.2)
    end
    return !any(process_alive, pids)
end

Sys.iswindows() ||
@testset "an interrupt takes the workers with it, at once" begin
    # Ctrl-C is someone asking for their terminal back: the run goes down without
    # waiting for the item each slot has in flight, which here sleeps for ten
    # minutes. A real interrupt comes long after the stall watchdog first looked:
    # it has to reach the run whatever has run by then.
    r = interrupted_run(; items = 4, delay = YATF.Private.STALL_CHECK_S + 1)
    @test r.got_running
    # Generously above the second it takes, and far below the ten minutes an item
    # here sleeps for: what is checked is that it does not wait for them.
    @test r.elapsed < 30
    @test length(r.started) == 4
    @test all_gone(r.started)
    # The report never happens — the exception takes the run out before it — so the
    # run says what it got through on its way past. The items it took a worker away
    # from did not fail and are counted, not reported one by one. On 1.12 nothing
    # unwinds to say this, and the exit hook is what says it instead.
    @test occursin("interrupted after 0 of 4 test items", r.printed)
    @test occursin("4 cancelled", r.printed)
    @test !occursin("the worker running this item died", r.printed)
    @test !occursin("ERR ", r.printed)
    # The run itself sees the exception from 1.13. On 1.12 it is delivered to
    # whichever task thread 1 is running, which between items is one that has
    # already finished and has nothing left to catch it; the process dies there.
    if VERSION >= v"1.13"
        @test occursin(CAUGHT_INTERRUPT, r.out)
        @test occursin("ALIVE 0", r.out)
    end
end

Sys.iswindows() ||
@testset "an interrupt reaches the run whichever of its tasks catches it" begin
    # Without an interactive thread every task the run starts shares the thread
    # Ctrl-C is thrown into: the monitor's, which wakes five times a second, or
    # with no monitor a worker's output relay or message reader. Sent a second
    # after the items start, before the stall watchdog first looks.
    for monitor in (true, false)
        r = interrupted_run(; items = 2, julia_args = ["--threads=1,0"], monitor, delay = 1.0)
        @test r.got_running
        @test r.elapsed < 30
        @test all_gone(r.started)
        @test occursin("interrupted after 0 of 2 test items", r.printed)
        @test !occursin("could not relay", r.printed * r.out)
        @test !occursin("resource monitor stopped", r.printed * r.out)
        VERSION >= v"1.13" && @test occursin(CAUGHT_INTERRUPT, r.out)
    end
end

Sys.iswindows() ||
@testset "a script stopped by Ctrl-C blames its workers' deaths on nothing else" begin
    # A script, and `Pkg.test`, exit on SIGINT: the exit hooks close the run. The
    # run's own hook stops the workers before anything lets the slots run, so no
    # slot finds its worker gone and puts it down to the out-of-memory killer.
    r = interrupted_run(; items = 2, delay = 1.0, repl = false)
    @test r.got_running
    @test r.elapsed < 30
    @test all_gone(r.started)
    @test occursin("interrupted after 0 of 2 test items", r.printed)
    @test occursin("2 cancelled", r.printed)
    @test !occursin("out-of-memory", r.printed)
    @test !occursin("LOST", r.printed)
end
