# Test items outside a run: `YATF.activate`, and a `@testitem` evaluated rather
# than scanned. What these check is that the two agree with a real run — same
# parser, same evaluator, same environment — because an item that behaves one way
# when pasted and another when scheduled is worse than one that cannot be pasted.

using YATF: activate, deactivate, is_activated, ScanFailure, ConfigError,
            collect_failures, PASSED, FAILED, SKIPPED, ERRORED
using YATFWorkers: state_of
using Logging: Logging

const DEPS = fixture("TestDeps.jl")

@testset "interactive" begin
    @testset "every exported name has help at the REPL" begin
        # A comment between a docstring and its definition detaches the docstring.
        for name in names(YATF)
            @test Base.Docs.hasdoc(YATF, name)
        end
    end

    @testset "activate puts the session where a worker would be" begin
        before_project, before_path = Base.active_project(), copy(LOAD_PATH)
        with_activated(DEPS) do env
            @test is_activated()
            @test Base.active_project() == env
            @test env != before_project
            # The setups are importable, which is the other half of what a test
            # item gets and a REPL does not.
            @test joinpath(DEPS, "test", "testsetups") in LOAD_PATH
            @test Base.identify_package("DepSetup") !== nothing
        end
        @test !is_activated()
        @test Base.active_project() == before_project
        @test LOAD_PATH == before_path
    end

    @testset "activating twice is an error, deactivating twice is not" begin
        with_activated(DEPS) do _
            @test_throws ConfigError activate(DEPS)
        end
        @test deactivate() === nothing
        @test deactivate() === nothing
        @test !is_activated()
    end

    @testset "a pasted item runs, and its results come back" begin
        with_activated(DEPS) do _
            ts, out = capture_run() do
                @testitem "pasted pass" begin
                    x = 1 + 1
                    @test x == 2
                    @test true
                end
            end
            @test ts isa Test.AbstractTestSet
            @test state_of(ts) === PASSED
            @test ts.n_passed == 2
            # It announces itself the way a scheduled item does.
            @test occursin("RUN", out)
            @test occursin("DONE", out)
            @test occursin("pasted pass", out)
        end
    end

    @testset "a failing item is a result, not an exception" begin
        with_activated(DEPS) do _
            ts, out = capture_run() do
                @testitem "pasted fail" begin
                    @test 1 == 2
                end
            end
            @test state_of(ts) === FAILED
            @test length(collect_failures(ts)) == 1
            # ...and it says what failed, here, because there is no coordinator.
            @test occursin("1 == 2", out)
        end
    end

    @testset "an item that throws is an error, not a thrown exception" begin
        with_activated(DEPS) do _
            ts, _ = capture_run() do
                @testitem "pasted throw" begin
                    error("boom")
                end
            end
            @test state_of(ts) === ERRORED
        end
    end

    @testset "the body gets Test, the package, and the setups" begin
        with_activated(DEPS) do _
            ts, _ = capture_run() do
                @testitem "pasted imports" begin
                    using DepSetup
                    @test DepSetup.draw() isa Float64          # a setup module
                    @test TestDeps.pick([3, 4]) == 3           # the package under test
                    @test @isdefined(Test)                     # Test, without asking
                end
            end
            @test state_of(ts) === PASSED
            @test ts.n_passed == 3
        end
    end

    @testset "the body has soft scope, as it does in a file" begin
        with_activated(DEPS) do _
            ts, _ = capture_run() do
                @testitem "pasted softscope" begin
                    total = 0
                    for i in 1:3
                        total += i
                    end
                    @test total == 6
                end
            end
            @test state_of(ts) === PASSED
        end
    end

    @testset "skip is honoured, literally and as an expression" begin
        with_activated(DEPS) do _
            static, _ = capture_run() do
                @testitem "pasted skip static" skip=true begin
                    @test false
                end
            end
            @test isempty(collect_failures(static))
            dynamic, _ = capture_run() do
                @testitem "pasted skip dynamic" skip=(1 + 1 == 2) begin
                    @test false
                end
            end
            @test isempty(collect_failures(dynamic))
        end
    end

    @testset "failfast stops the item at its first failure" begin
        with_activated(DEPS) do _
            ts, _ = capture_run() do
                @testitem "pasted failfast" failfast=true begin
                    @test 1 == 2
                    @test 3 == 4
                end
            end
            @test length(collect_failures(ts)) == 1   # the second never ran
        end
    end

    @testset "a keyword that is wrong in a file is wrong here too" begin
        with_activated(DEPS) do _
            @test_throws ScanFailure (
                @testitem "bad tags" tags = "not a vector" begin
                    @test true
                end
            )
            @test_throws ScanFailure (
                @testitem "unknown keyword" nonsense = 1 begin
                    @test true
                end
            )
            @test_throws ScanFailure (
                @testitem "given twice" timeout = 1 timeout = 2 begin
                    @test true
                end
            )
            @test_throws ScanFailure (
                @testitem "both" sandbox = true chain = :c begin
                    @test true
                end
            )
        end
    end

    @testset "keywords a single evaluation cannot honour are named" begin
        with_activated(DEPS) do _
            logs = Test.collect_test_logs() do
                capture_run() do
                    @testitem "pasted knobs" timeout=5 retries=2 chain=:c tags=[:x] begin
                        @test true
                    end
                end
            end
            warnings = filter(r -> r.level == Logging.Warn, first(logs))
            @test length(warnings) == 1
            msg = first(warnings).message
            # Every one of them named, and why.
            for key in ("timeout", "retries", "chain")
                @test occursin(key, msg)
            end
            # `tags` is not among them: selecting nothing is what a single pasted
            # item does, and saying so on every paste is noise.
            @test !occursin("tags", msg)
            @test occursin("pasted knobs", msg)
        end
    end

    @testset "sandbox=true really uses another process" begin
        with_activated(DEPS) do _
            ts, _ = withenv("YATF_REPL_PID" => string(getpid())) do
                capture_run() do
                    @testitem "pasted sandbox" sandbox=true begin
                        @test getpid() != parse(Int, ENV["YATF_REPL_PID"])
                    end
                end
            end
            @test state_of(ts) === PASSED
            @test isempty(collect_failures(ts))
        end
    end

    @testset "sandbox=:profile uses that profile's flags and init" begin
        dir = make_pkg(
            "PastedProfile",
            "test/TestItems.toml" =>
                "[profiles.bounds]\njulia_args = [\"--check-bounds=yes\"]\ninit = \"const FROM_INIT = 7\"\n",
        )
        with_activated(dir) do _
            ts, _ = capture_run() do
                @testitem "pasted profile" sandbox=:bounds begin
                    @test Base.JLOptions().check_bounds == 1
                    @test Main.FROM_INIT == 7
                end
            end
            @test state_of(ts) === PASSED
            @test ts.n_passed == 2
        end
    end

    @testset "a sandbox profile that does not exist says so" begin
        with_activated(DEPS) do _
            err = try
                @testitem "pasted missing profile" sandbox=:nope begin
                    @test true
                end
                nothing
            catch e
                e
            end
            @test err isa ConfigError
            @test occursin("nope", sprint(showerror, err))
        end
    end

    @testset "no worker is left behind by a sandboxed item" begin
        before = live_worker_processes()
        with_activated(DEPS) do _
            capture_run() do
                @testitem "pasted sandbox cleanup" sandbox=true begin
                    @test true
                end
            end
        end
        sleep(0.5)
        @test live_worker_processes() <= before
    end
end

@testset "a pasted sandbox has a process, so it keeps its keywords" begin
    # Without `sandbox` there is nothing to stop and nothing to restart, so
    # `timeout` and `retries` are ignored and said to be. With it the item runs in
    # a worker, which is exactly what those two need.

    @testset "the warning covers only what a sandbox cannot supply" begin
        ignored(sandboxed) = [k for (k, _) in YATF.repl_ignored(sandboxed)]
        @test :timeout in ignored(false)
        @test :retries in ignored(false)
        @test :timeout ∉ ignored(true)
        @test :retries ∉ ignored(true)
        # A chain has nothing to be sequenced with either way, and `tags` select
        # nothing here — which was never worth a line.
        @test :chain in ignored(true)
        @test :tags ∉ ignored(false)
    end

    @testset "a timeout stops it, and retries start it again" begin
        # Pinned to a fixture rather than left on whatever project the session is
        # in: under `Pkg.test` that is an unnamed generated environment, and a
        # sandbox asks for a test environment to be built from it.
        with_activated(DEPS) do _
        with_marker_dir() do work
            marker = joinpath(work, "count")
            withenv("YATF_CRASH_MARKER" => marker) do
                ex = :(@testitem "paste retries" timeout=3 retries=1 sandbox=true begin
                    k = let p = ENV["YATF_CRASH_MARKER"]
                        n = isfile(p) ? parse(Int, read(p, String)) : 0
                        write(p, string(n + 1))
                        n
                    end
                    k < 1 && sleep(30)
                    @test k == 1
                end)
                ts = Core.eval(Main, ex)
                # The first attempt was stopped at the timeout; the second passed.
                @test parse(Int, read(marker, String)) == 2
                @test isempty(collect_failures(ts))
            end
        end
        end
    end

    @testset "a sandbox that never finishes reports the timeout" begin
        with_activated(DEPS) do _
            ex = :(@testitem "paste overruns" timeout=2 sandbox=true begin
                sleep(30)
                @test true
            end)
            @test_throws YATF.TimeoutException Core.eval(Main, ex)
        end
    end
end
