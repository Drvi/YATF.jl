# Timeouts, and what they are measured against. An item's limit is for the item:
# a profile's `init` and `test_end` expressions are the suite's own code, run on
# the same worker, and each is timed against a limit of its own.

using YATF: PASSED, FAILED, ERRORED, TIMEDOUT, UNSEEN, collect_failures, report,
            without_enclosing_testset

@testset "timeouts" begin
    @testset "every attempt is timed separately" begin
        dir = make_pkg("NeverFinishes", "test/t_test.jl" => """
        @testitem "never finishes" timeout=2 retries=2 begin
            sleep(600)
        end
        """)
        elapsed = @elapsed states, run, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
        @test states["never finishes"] === TIMEDOUT
        @test run.statuses.attempt[1] == 3          # the first go and two retries
        # Three attempts of two seconds, not one attempt of two shared between them.
        @test elapsed >= 6
        @test elapsed < 120
    end

    if !Sys.iswindows()
        @testset "a worker past its timeout says where its tasks were" begin
            dir = make_pkg("Hangs", "test/t_test.jl" => """
            @testitem "hangs" timeout=2 begin
                sleep(600)
            end
            """)
            (states, _, _), out = capture_run() do
                run_states(dir; workers=1, logs=:issues, monitor=false)
            end
            @test states["hangs"] === TIMEDOUT
            # The worker is asked where it is before it is killed, and it has to
            # answer before the kill lands: a short timeout is the case that has to
            # work, because it is the one people set.
            @test occursin("live tasks", out)
            @test occursin("KILL", out)
        end
    end

    @testset "an init expression is not charged to the item" begin
        # The item's own limit is shorter than the profile spends starting up.
        dir = make_pkg(
            "SlowInit",
            "test/t_test.jl" => """@testitem "quick" timeout=2 begin\n    @test true\nend\n""",
            "test/TestItems.toml" => "[profiles.default]\ninit = \"sleep(4)\"\n"
        )
        states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
        @test states["quick"] === PASSED
    end

    @testset "an init expression that hangs is stopped by its own limit" begin
        dir = make_pkg(
            "HangingInit",
            "test/t_test.jl" => """
            @testitem "first" begin
                @test true
            end
            @testitem "second" begin
                @test true
            end
            @testitem "third" begin
                @test true
            end
            """,
            "test/TestItems.toml" => "[profiles.default]\ninit = \"sleep(600)\"\n"
        )
        (states, run, _), out = capture_run() do
            run_states(dir; workers=1, logs=:issues, monitor=false, init_timeout=2)
        end
        # The item that asked for the worker is told why it did not get one; the
        # rest never ran, and the run says so rather than passing them over.
        @test count(==(ERRORED), values(states)) == 1
        @test count(==(UNSEEN), values(states)) == 2
        @test occursin("`init` expression of profile `default` timed out after 2 seconds", out)
        # Said once: the run does not restate what the failure already says.
        @test count("`init` expression of profile", out) == 1
        # An item that never ran is not an item that passed.
        threw = Ref(false)
        _, conclusion = capture_run() do
            try
                without_enclosing_testset(() -> report(run))
            catch e
                threw[] = e isa Test.TestSetException
            end
        end
        @test threw[]
        @test occursin("2 did not run", conclusion)
    end

    @testset "a test_end expression is not charged to the item" begin
        dir = make_pkg(
            "SlowEnd",
            "test/t_test.jl" => """@testitem "quick" timeout=3 begin\n    @test true\nend\n""",
            "test/TestItems.toml" => "[profiles.default]\ntest_end = \"sleep(5)\"\n"
        )
        states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
        @test states["quick"] === PASSED
    end

    @testset "a test_end expression that hangs is reported as itself" begin
        dir = make_pkg(
            "HangingEnd",
            "test/t_test.jl" => """@testitem "fine on its own" begin\n    @test true\nend\n""",
            "test/TestItems.toml" => "[profiles.default]\ntest_end = \"sleep(600)\"\n"
        )
        (states, _, _), out = capture_run() do
            run_states(dir; workers=1, logs=:issues, monitor=false, test_end_timeout=2)
        end
        @test states["fine on its own"] === TIMEDOUT
        @test occursin("`test_end` expression", out)
        @test !occursin("test item \"fine on its own\" timed out", out)
    end

    @testset "what a test_end expression finds is the item's result" begin
        # On a worker and in this process: the two paths run the same two blocks.
        for workers in (0, 1)
            dir = make_pkg(
                "EndFails",
                "test/t_test.jl" => """@testitem "passes on its own" begin\n    @test true\nend\n""",
                "test/TestItems.toml" => "[profiles.default]\ntest_end = \"@test 1 == 2\"\n"
            )
            states, run, _ = run_states(dir; workers, logs=:issues, monitor=false)
            @test states["passes on its own"] === FAILED
            failures = collect_failures(run.statuses.testsets[1])
            @test any(r -> occursin("1 == 2", sprint(show, r)), failures)
        end
    end

    @testset "an item that passes is not asked to run test_end twice" begin
        dir = make_pkg(
            "EndCounts",
            "test/t_test.jl" => """
            @testitem "one" begin
                @test true
            end
            @testitem "two" skip=true begin
                @test false
            end
            """,
            "test/TestItems.toml" =>
                "[profiles.default]\ntest_end = \"open(ENV[\\\"YATF_END_LOG\\\"], \\\"a\\\") do io; println(io, 1); end\"\n"
        )
        mktempdir() do work
            log = joinpath(work, "ends")
            withenv("YATF_END_LOG" => log) do
                states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
                @test states["one"] === PASSED
            end
            # Once for the item that ran, and not at all for the one that was
            # skipped: there is nothing of its to check.
            @test count(==('1'), read(log, String)) == 1
        end
    end
end

@testset "an item that finishes after it was given up on" begin
    # The inspection that follows a timeout leaves the worker alive long enough to
    # finish what it was doing, so its result and its own DONE line arrive after
    # the run has recorded the item as timed out. Neither is welcome: one is a pass
    # for a test nobody accepted, the other is a reply on a channel already closed.
    dir = make_pkg("LateReply", "test/t_test.jl" => """
    @testitem "overruns" timeout=2 retries=0 begin
        sleep(6)
        @test true
    end
    """)
    states, _, _ = nothing, nothing, nothing
    _, out = capture_run() do
        states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
    end
    @test states["overruns"] === TIMEDOUT
    lines = collect(eachsplit(out, '\n'))
    @test any(l -> occursin("· KILL", l), lines)
    # The worker's own verdict for the abandoned item never reaches the log.
    @test !any(l -> occursin("· DONE", l) && occursin("overruns", l), lines)
    @test !any(l -> occursin("PASS", l) && occursin("overruns", l), lines)
    # ...and a late reply is an expected end to a timeout, not a broken connection.
    @test !occursin("protocol error", out)
    # Whatever the process prints on its way down — a signal, a backtrace — is the
    # worker's, not the item's. This item prints nothing of its own, so a line
    # attributed to it would be a line attributed wrongly.
    @test !occursin(YATF.MARK_ITEM, out)
    @test any(l -> occursin(YATF.MARK_WORKER, l) && occursin("KILL", l), lines)
    # It is filed with the item rather than printed across the run: the only worker
    # lines left are the lifecycle words, and the rest went where the report for
    # this item will find it.
    lifecycle = l -> any(w -> occursin(w, l), ("UP", "EXIT", "KILL", "LOST"))
    @test all(lifecycle, filter(l -> occursin(YATF.MARK_WORKER, l), lines))
    @test occursin("Captured logs", out)
end
