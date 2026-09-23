using YATF: prepare, execute, report, ItemState, UNSEEN, PASSED, FAILED, ERRORED, TIMEDOUT,
            SKIPPED, BROKEN_CHAIN, CANCELLED, ConfigError, nitems, is_non_pass
using Logging: Logging
using Random: Random

const FAULTY = fixture("Faulty.jl")
const BASICPKG = fixture("Basic.jl")

@testset "every item draws from the run's seed, whatever ran before it" begin
    with_journal() do jdir
        pkg = make_pkg("Seeded", "test/s_test.jl" => """
        @testitem "one" begin
            write(joinpath(ENV["YATF_JOURNAL"], "one-" * string(time_ns())), string(rand(UInt64)))
        end
        @testitem "two" begin
            write(joinpath(ENV["YATF_JOURNAL"], "two-" * string(time_ns())), string(rand(UInt64)))
        end
        """)
        Random.seed!(42); expected = rand(UInt64); Random.seed!(42)
        run_states(pkg; workers=0, seed=7, logs=:issues, monitor=false)
        @test rand(UInt64) == expected   # the caller's own stream, untouched by the items
        run_states(pkg; workers=1, seed=7, name="two", logs=:issues, monitor=false)
        draws(prefix) = [read(f, String) for f in readdir(jdir; join=true) if startswith(basename(f), prefix)]
        @test length(draws("two-")) == 2 && allequal(draws("two-"))   # after "one", or alone on a worker
        @test only(draws("one-")) != first(draws("two-"))
    end
end

@testset "execute" begin
    @testset "a passing suite passes, on workers and in-process" begin
        for workers in (0, 1, 2)
            states, _, _ = run_states(BASICPKG; workers, logs=:issues)
            @test all(==(PASSED), values(states))
            @test length(states) == 6
        end
    end

    @testset "an item on a worker has `Test` without the worker loading YATF" begin
        # Whatever a worker loads beyond YATFWorkers is paid for by the first item
        # it runs, and YATF brings `Pkg` and `TestEnv` with it.
        pkg = make_pkg("Lean", "test/l_test.jl" => """
        @testitem "lean" begin
            @test Test isa Module
            loaded(uuid, name) = Base.root_module_exists(Base.PkgId(Base.UUID(uuid), name))
            @test !loaded("632efd68-cd41-4e05-bd25-b86dc2150078", "YATF")
            @test !loaded("44cfe95a-1eb2-52ea-b672-e2afdf69b78f", "Pkg")
        end
        """)
        states, _, _ = run_states(pkg; workers=1, logs=:issues)
        @test states["lean"] === PASSED
    end

    @testset "results are reported as a Test summary and failures throw" begin
        p, target = prepare((BASICPKG,); workers=1, logs=:issues)
        run = execute(p, target)
        ts = report(run)
        @test ts isa Test.AbstractTestSet
        # Nested inside this @testset, `report` records into the parent; outside
        # one it throws, which is what makes `runtests()` fail a CI job.
        p2, target2 = prepare((FAULTY,); workers=1, tags=:fail, logs=:issues)
        run2 = execute(p2, target2)
        threw = try
            YATF.without_enclosing_testset(() -> report(run2))
            false
        catch e
            e isa Test.TestSetException
        end
        @test threw
    end

    @testset "a failing item is recorded, not fatal" begin
        states, _, _ = run_states(FAULTY; workers=1, tags=[:fail], logs=:issues)
        @test states["fails"] === FAILED
    end

    @testset "an erroring item is recorded" begin
        states, _, _ = run_states(FAULTY; workers=1, tags=[:error], logs=:issues)
        @test states["errors"] === ERRORED
        @test states["throws outside a test"] === ERRORED
    end

    @testset "a worker that dies is replaced and the run continues" begin
        # The dying item and a passing item share one worker, so the second only
        # runs if the slot recovered from the first one killing its process.
        states, _, _ = run_states(FAULTY; workers=1, tags=nothing, name=r"^(kills its worker|passes)$",
                                  logs=:issues)
        @test states["kills its worker"] === ERRORED
        @test states["passes"] === PASSED
    end

    @testset "a hung item times out and its worker is killed" begin
        t = @elapsed ((states, _, _) = run_states(FAULTY; workers=1, tags=[:hang], logs=:issues))
        @test states["hangs"] === TIMEDOUT
        @test t < 60          # the item sleeps for 600s; the timeout is 3s
    end

    @testset "a worker that dies hard is retried, and the run carries on" begin
        # `ccall(:abort)` kills the process where it stands: no exit, no unwinding,
        # no message. The item asks for two retries and passes on the third
        # attempt, and the items around it must be unaffected.
        with_marker_dir() do dir
            states, _, _ = run_states(FAULTY; workers=1, logs=:issues,
                                      name=r"^(survives two dead workers|passes|fails)$")
            @test states["survives two dead workers"] === PASSED
            @test states["passes"] === PASSED          # the run was not cancelled
            @test states["fails"] === FAILED
            @test parse(Int, read(joinpath(dir, "yatf_abort_count"), String)) == 3
        end
    end

    @testset "a chain whose worker dies does not run its remaining items" begin
        with_marker_dir() do dir
            states, _, _ = run_states(FAULTY; workers=1, tags=[:chaindie], logs=:issues)
            @test states["chain start kills the worker"] === ERRORED
            @test states["chain rest must not run"] === BROKEN_CHAIN
            # not skipped quietly and not run on a fresh worker: it did not run
            @test !isfile(joinpath(dir, "yatf_must_not_run"))
        end
    end

    @testset "retries re-run a failing item" begin
        with_marker_dir() do dir
            states, _, _ = run_states(FAULTY; workers=1, tags=[:retry], logs=:issues)
            @test states["passes on the second try"] === PASSED
            @test isfile(joinpath(dir, "yatf_retry"))
        end
        # An item's own `retries` wins over the run default, in both directions.
        with_marker_dir() do dir
            states, _, _ = run_states(FAULTY; workers=1, name="passes on the second try",
                                      logs=:issues, retries=0)
            @test states["passes on the second try"] === PASSED   # the item asked for 1 retry
        end
        with_marker_dir() do dir
            states, _, _ = run_states(FAULTY; workers=1, name="fails", logs=:issues, retries=2)
            @test states["fails"] === FAILED                      # no amount of retrying helps
        end
    end

    @testset "retries work the same way in this process" begin
        # An attempt in this process goes through the same attempt loop as one on a
        # worker; what differs is only how the item is run.
        with_marker_dir() do dir
            states, _, _ = run_states(FAULTY; workers=0, tags=[:retry], logs=:issues)
            @test states["passes on the second try"] === PASSED
            @test parse(Int, read(joinpath(dir, "yatf_retry"), String) |> length |> string) >= 1
        end
    end

    @testset "a failing item's stacktrace stops at the test's own frames" begin
        p, target = prepare((FAULTY,); workers=1, logs=:issues, monitor=false, name="errors")
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        trimmed = sprint(show, first(YATF.collect_failures(run.statuses.testsets[1])))
        @test occursin("faults_test.jl", trimmed)        # the item's own frame is kept
        @test !occursin("runitem.jl", trimmed)           # the framework's are not
        @test !occursin("serve_requests", trimmed)

        p2, target2 = prepare((FAULTY,); workers=1, logs=:issues, monitor=false, name="errors",
                              full_stacktraces=true)
        run2 = execute(p2, target2)
        rm(run2.logdir; force=true, recursive=true)
        full = sprint(show, first(YATF.collect_failures(run2.statuses.testsets[1])))
        @test occursin("runitem.jl", full)               # kept when asked for
        @test length(split(full, '\n')) > length(split(trimmed, '\n'))
    end

    @testset "skip is honoured, statically and dynamically" begin
        states, _, _ = run_states(FAULTY; workers=1, tags=[:skip], logs=:issues)
        @test states["skipped statically"] === SKIPPED
        @test states["skipped dynamically"] === SKIPPED
    end

    @testset "a result that cannot be serialized is an error, not a lost worker" begin
        states, _, _ = run_states(FAULTY; workers=1, logs=:issues,
                                  name=r"^(returns something unserializable|passes)$")
        @test states["returns something unserializable"] === ERRORED
        # the worker survived to run the next item
        @test states["passes"] === PASSED
    end

    @testset "the scoped value is set inside an item and inherited by its tasks" begin
        states, _, _ = run_states(FAULTY; workers=1, tags=[:scope], logs=:issues)
        @test states["knows it is in a test item"] === PASSED
    end

    @testset "failfast stops the run" begin
        states, _, _ = run_states(FAULTY; workers=1, failfast=true, retries=1, logs=:issues,
                                  name=r"^(fails|passes|errors)$")
        # The item that stopped the run is still the failure it was once its retry
        # has failed too: stopping under the retry would record it as cancelled.
        @test count(s -> s === FAILED || s === ERRORED, values(states)) == 1
        @test any(==(UNSEEN), values(states)) || length(states) == 1
    end

    @testset "an item's RUN and DONE lines are drawn by the coordinator, on a worker or not" begin
        for workers in (0, 1)
            (states, _, _), out = capture_run() do
                run_states(FAULTY; workers, tags=[:routing], logs=:issues)
            end
            @test states["its own log lines go through the coordinator"] === PASSED
            @test count("· RUN ", out) == 1
            @test count("· DONE ", out) == 1
            # What a worker writes about an item is data for the coordinator.
            @test !occursin(YATFWorkers.RECORD_MARK, out)
        end
    end

    @testset "workers=0 still gives a sandboxed item its process" begin
        # `workers=0` is a promise about the pool, not about never starting a
        # process. An item that asked for `--check-bounds=yes` is testing
        # something that depends on it, so running it here and reporting a pass
        # would report a pass for a test that never ran the way it was written.
        dir = make_pkg(
            "Sandboxed",
            "test/a_test.jl" => """
            @testitem "bounded" sandbox=:bounds begin
                @test Base.JLOptions().check_bounds == 1          # what it asked for
                @test Main.FROM_PROFILE_INIT == 7                 # and its profile's init
                @test getpid() != parse(Int, ENV["YATF_SOLO_PID"])
            end
            @testitem "alone" sandbox=true begin
                @test getpid() != parse(Int, ENV["YATF_SOLO_PID"])
            end
            @testitem "ordinary" begin
                @test Base.JLOptions().check_bounds == 0
                @test getpid() == parse(Int, ENV["YATF_SOLO_PID"])
            end
            """,
            "test/TestItems.toml" =>
                "[profiles.bounds]\njulia_args = [\"--check-bounds=yes\"]\n" *
                "init = \"const FROM_PROFILE_INIT = 7\"\n",
        )
        before = live_worker_processes()
        out = Ref("")
        logs = Test.collect_test_logs() do
            withenv("YATF_SOLO_PID" => string(getpid())) do
                (states, _, _), printed = capture_run() do
                    run_states(dir; workers=0, logs=:issues, monitor=false)
                end
                out[] = printed
                # Every item runs, including the ones in a pool of their own —
                # those are not in the single slot's queue.
                @test length(states) == 3
                @test all(==(PASSED), values(states))
            end
        end
        # Each sandbox worker announces itself and its teardown, and each ran
        # exactly the one item it was started for.
        lifecycle = filter(l -> occursin("· UP ", l) || occursin("· EXIT", l),
                           collect(eachsplit(out[], '\n')))
        @test count(l -> occursin("· UP ", l), lifecycle) == 2
        @test count(l -> occursin("· EXIT", l), lifecycle) == 2
        @test all(l -> occursin("1 item ", l), filter(l -> occursin("· EXIT", l), lifecycle))
        @test any(l -> occursin("--check-bounds=yes", l), lifecycle)

        # ...and the processes it started are gone again.
        sleep(0.5)
        @test live_worker_processes() <= before

        warnings = filter(r -> r.level == Logging.Warn, first(logs))
        @test length(warnings) == 1
        msg = first(warnings).message
        @test occursin("workers=0", msg)
        @test occursin("a worker of its own", msg)
        @test occursin("\"bounded\"", msg)
        @test occursin("\"alone\"", msg)
        @test !occursin("\"ordinary\"", msg)   # it asked for nothing, so it ran here
    end

    @testset "workers=0 says nothing when nothing asked for a sandbox" begin
        logs = Test.collect_test_logs() do
            run_states(BASICPKG; workers=0, logs=:issues, monitor=false)
        end
        @test isempty(filter(r -> r.level == Logging.Warn, first(logs)))
    end

    @testset "a sandbox profile really changes the worker's julia flags" begin
        dir = mktempdir(); mkpath(joinpath(dir, "test"))
        write(joinpath(dir, "Project.toml"), "name = \"Flagged\"\nuuid = \"1a2b3c4d-0000-4000-8000-000000000004\"\n")
        mkpath(joinpath(dir, "src")); write(joinpath(dir, "src", "Flagged.jl"), "module Flagged end\n")
        write(joinpath(dir, "test", "a_test.jl"), """
        @testitem "default flags" begin
            @test Base.JLOptions().check_bounds == 0
        end
        @testitem "checked flags" sandbox=:bounds begin
            @test Base.JLOptions().check_bounds == 1
        end
        """)
        write(joinpath(dir, "test", "TestItems.toml"),
              "[profiles.bounds]\njulia_args = [\"--check-bounds=yes\"]\n")
        states, _, _ = run_states(dir; workers=2, logs=:issues)
        @test states["default flags"] === PASSED
        @test states["checked flags"] === PASSED
    end

    @testset "no worker processes are left behind" begin
        before = live_worker_processes()
        run_states(BASICPKG; workers=2, logs=:issues)
        sleep(0.5)
        @test live_worker_processes() <= before
    end

    @testset "the worker count is a cap, not a suggestion" begin
        # 6 units, 2 workers: this run must never have a third process alive.
        # Counted against a snapshot taken first, because workers an earlier test
        # is still reaping are not this run's doing.
        p, target = prepare((BASICPKG,); workers=2)
        before = live_worker_pids()
        peak = Ref(0)
        watcher = Threads.@spawn begin
            for _ in 1:400
                peak[] = max(peak[], length(setdiff(live_worker_pids(), before)))
                sleep(0.01)
            end
        end
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        wait(watcher)
        @test peak[] <= 2
    end
end
