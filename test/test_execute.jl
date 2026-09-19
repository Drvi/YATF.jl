using YATF: prepare, execute, report, ItemState, UNSEEN, PASSED, FAILED, ERRORED, TIMEDOUT,
            SKIPPED, BROKEN_CHAIN, CANCELLED, ConfigError, nitems, is_non_pass

const FAULTY = fixture("Faulty.jl")
const BASICPKG = fixture("Basic.jl")

@testset "execute" begin
    @testset "a passing suite passes, on workers and in-process" begin
        for workers in (0, 1, 2)
            states, _, _ = run_states(BASICPKG; workers, logs=:issues)
            @test all(==(PASSED), values(states))
            @test length(states) == 6
        end
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
        # The in-process path has its own loop; it must apply the same policy.
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
        states, _, _ = run_states(FAULTY; workers=1, failfast=true, logs=:issues,
                                  name=r"^(fails|passes|errors)$")
        @test any(is_non_pass, values(states))
        @test any(==(UNSEEN), values(states)) || length(states) == 1
    end

    @testset "an in-process run prints through the coordinator's printer" begin
        # The item checks this from the inside, in both modes; here we check the
        # sink is left as it was found.
        for workers in (0, 1)
            @test YATFWorkers.LOG_SINK[] === nothing
            states, _, _ = run_states(FAULTY; workers, tags=[:routing], logs=:issues)
            @test states["its own log lines go through the coordinator"] === PASSED
            @test YATFWorkers.LOG_SINK[] === nothing
        end
    end

    @testset "workers=0 refuses a sandbox it cannot provide" begin
        dir = mktempdir(); mkpath(joinpath(dir, "test"))
        write(joinpath(dir, "Project.toml"), "name = \"Sandboxed\"\nuuid = \"1a2b3c4d-0000-4000-8000-000000000003\"\n")
        mkpath(joinpath(dir, "src")); write(joinpath(dir, "src", "Sandboxed.jl"), "module Sandboxed end\n")
        write(joinpath(dir, "test", "a_test.jl"),
              """@testitem "bounded" sandbox=:bounds begin\n @test true\n end\n""")
        write(joinpath(dir, "test", "TestItems.toml"),
              "[profiles.bounds]\njulia_args = [\"--check-bounds=yes\"]\n")
        p, target = prepare((dir,); workers=0)
        err = try; execute(p, target); catch e; e; end
        @test err isa ConfigError
        @test occursin("workers=0", sprint(showerror, err))
        @test occursin("bounded", sprint(showerror, err))
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
