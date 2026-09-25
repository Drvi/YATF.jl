using YATF.Private: prepare, init_run_state, finish_run_state!, read_run_state, runstate_files,
                    stale_runstates, STALE_RUN_DAYS, HISTORY_RUNS

# Sets a file's modification time `days` back.
function age!(path, days)
    f = Base.Filesystem.open(path, Base.Filesystem.JL_O_RDWR)
    try
        t = time() - days * 86400
        Base.Filesystem.futime(f, t, t)
    finally
        close(f)
    end
end

declared(names...) = join(("@testitem \"$n\" begin\n    @test true\nend\n" for n in names))

# `n` run states of this machine's in `dir`, oldest first, each `days` old.
function recorded_runs(dir, pkg, n; days)
    p, _ = prepare((pkg,); announce = false)
    return map(1:n) do i
        path = joinpath(dir, string(1_000_000 + i, "-1.yatf"))
        finish_run_state!(init_run_state(path, p))
        age!(path, days)
        path
    end
end

@testset "chores" begin
    @testset "a suite in order has nothing to do" begin
        dir = make_pkg("Tidy", "test/a_test.jl" => declared("one", "two"),
                       "test/TestItems.toml" => "[order]\nfirst = [\"two\"]\n")
        withenv("YATF_RUNSTATE_DIR" => mktempdir()) do
            ok, out = capture_run(() -> YATF.chores(dir))
            @test ok
            @test occursin("test items: 2 in 1 file, all valid", out)
            @test occursin("config: $(joinpath("test", "TestItems.toml")), valid", out)
            @test occursin("setups: none", out)
            @test occursin("run states: none", out)
            @test occursin("└ nothing to do", out)
        end
    end

    @testset "a check changes nothing, and fix does what it reported" begin
        dir = make_pkg("Untidy", "test/a_test.jl" => declared("one"),
                       "test/testsetups/Helpers.jl" => "module Helpers\nusing Random\nend\n")
        setups = joinpath(dir, "test", "testsetups")
        runs = mktempdir()
        withenv("YATF_RUNSTATE_DIR" => runs) do
            # Two more than the newest few that always stay, all of them old.
            recorded = recorded_runs(runs, dir, HISTORY_RUNS + 2; days = STALE_RUN_DAYS + 3)
            ok, out = capture_run(() -> YATF.chores(dir))
            @test !ok
            @test occursin("chores, checking only", out)
            @test occursin("setups: 1 of 1 to change:", out)
            @test occursin("`Helpers`: would move to $(joinpath("Helpers", "src", "Helpers.jl"))", out)
            @test occursin("2 of this machine's older than $STALE_RUN_DAYS days to delete (the newest $HISTORY_RUNS stay)", out)
            @test occursin("to do: 3, which `YATF.chores(fix = true)` does", out)
            @test isfile(joinpath(setups, "Helpers.jl"))
            @test runstate_files(dir) == recorded

            ok, out = capture_run(() -> YATF.chores(dir; fix = true))
            @test ok
            @test occursin("`Helpers`: moved to", out)
            @test occursin("└ done: 3", out)
            @test isfile(joinpath(setups, "Helpers", "Project.toml"))
            @test runstate_files(dir) == recorded[3:end]

            ok, out = capture_run(() -> YATF.chores(dir))
            @test ok
            @test occursin("setups: 1, all up to date", out)
            @test occursin("└ nothing to do", out)
        end
    end

    @testset "only this machine's old run states go, never the newest few" begin
        dir = make_pkg("OldRuns", "test/a_test.jl" => declared("one"))
        runs = mktempdir()
        withenv("YATF_RUNSTATE_DIR" => runs) do
            old = STALE_RUN_DAYS + 3
            recorded = recorded_runs(runs, dir, HISTORY_RUNS + 4; days = old)
            # Among the oldest: one recorded on another machine, one that cannot be
            # read, and one modified yesterday.
            here = gethostname()
            elsewhere = String(map(b -> b == UInt8('q') ? UInt8('r') : UInt8('q'), codeunits(here)))
            write(recorded[1], replace(read(recorded[1], String), here => elsewhere))
            @test read_run_state(recorded[1]).meta["host"] == elsewhere
            write(recorded[2], "not a run state")
            age!(recorded[1], old); age!(recorded[2], old); age!(recorded[3], 1)
            @test stale_runstates(dir) == [recorded[4]]
        end
    end

    @testset "what a run would refuse to start on is left to a person" begin
        # A test file that does not parse, beside settings with a key they do not take.
        dir = make_pkg("Broken", "test/a_test.jl" => "@testitem \"open\" begin\n",
                       "test/TestItems.toml" => "[run]\nworkerz = 2\n")
        withenv("YATF_RUNSTATE_DIR" => mktempdir()) do
            before = read(joinpath(dir, "test", "a_test.jl"), String)
            ok, out = capture_run(() -> YATF.chores(dir; fix = true))
            @test !ok
            @test occursin("test items: 1 problem:", out)
            @test occursin("a_test.jl:", out)
            @test occursin("config: unknown key `workerz`", out)
            @test occursin("└ to fix by hand: 2", out)
            @test read(joinpath(dir, "test", "a_test.jl"), String) == before
        end
        # Settings that name an item the suite does not have.
        dir = make_pkg("Misnamed", "test/a_test.jl" => declared("one"),
                       "test/TestItems.toml" => "[order]\nfirst = [\"onw\"]\n")
        withenv("YATF_RUNSTATE_DIR" => mktempdir()) do
            ok, out = capture_run(() -> YATF.chores(dir))
            @test !ok
            @test occursin("config: [order] of TestItems.toml names test items that do not exist:", out)
            @test occursin("onw", out)
            @test occursin("└ to fix by hand: 1", out)
        end
    end
end
