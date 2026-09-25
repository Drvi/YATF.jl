using Random: Random
using YATF.Private: init_run_state, write_status!, finish_run_state!, read_run_state, history,
            runstate_files, runstate_dir, prune_runstates, new_runstate_path, prepare,
            execute, plan, scan, discover, setup_modules, read_config, Filter, History,
            UNSEEN, RUNNING, PASSED, FAILED, ERRORED, TIMEDOUT, SKIPPED, nitems, RS_STATUS_BYTES,
            project_revision

function a_plan(pkg=fixture("Basic.jl"))
    testdir = joinpath(pkg, "test")
    items = scan(discover(testdir), Filter(), setup_modules(testdir))
    return plan(items, read_config(testdir); root=pkg)
end

@testset "run state" begin
    @testset "by default a project's run states are the depot's own, and go with the project" begin
        depot = mktempdir()
        pushfirst!(DEPOT_PATH, depot)
        try
            withenv("YATF_RUNSTATE_DIR" => nothing) do
                one_item = "test/a_test.jl" => "@testitem \"one\" begin\n    @test true\nend\n"
                kept, gone, foreign = make_pkg("Kept", one_item), make_pkg("Gone", one_item),
                                      make_pkg("Foreign", one_item)
                paths = Dict(pkg => new_runstate_path(pkg) for pkg in (kept, gone, foreign))
                for (pkg, path) in paths
                    # Not under `scratchspaces/`, which `Pkg.gc` empties of what no package registered.
                    @test startswith(path, joinpath(depot, "yatf", "runs"))
                    finish_run_state!(init_run_state(path, a_plan(pkg)))
                    @test read(joinpath(dirname(path), "project"), String) == abspath(pkg)
                end
                # Among one gone project's run states, one recorded on another machine.
                here = gethostname()
                elsewhere = String(map(b -> b == UInt8('q') ? UInt8('r') : UInt8('q'), codeunits(here)))
                write(paths[foreign], replace(read(paths[foreign], String), here => elsewhere))
                rm(gone; recursive = true)
                rm(foreign; recursive = true)
                YATF.Private.sweep_runstate_dirs()
                @test isfile(paths[kept])
                @test !ispath(dirname(paths[gone]))
                @test isfile(paths[foreign])        # not this machine's to delete
            end
        finally
            filter!(!=(depot), DEPOT_PATH)
        end
    end

    @testset "round trip" begin
        p = a_plan()
        dir = mktempdir()
        path = joinpath(dir, "run.yatf")
        rsf = init_run_state(path, p)
        write_status!(rsf, 1, PASSED, 1, 3; elapsed=1.5, compile=0.5)
        write_status!(rsf, 2, FAILED, 2, 1; elapsed=0.25)
        finish_run_state!(rsf)

        rs = read_run_state(path)
        @test rs !== nothing
        @test rs.complete
        @test !rs.cancelled
        @test length(rs.items) == nitems(p)
        @test rs.items[1].name == p.items.name[1]
        @test rs.meta["julia"] == string(VERSION)
        @test rs.statuses[1].state === PASSED
        @test rs.statuses[1].elapsed ≈ 1.5f0
        @test rs.statuses[1].compile ≈ 0.5f0
        @test rs.statuses[1].slot == 3
        @test rs.statuses[2].state === FAILED
        @test rs.statuses[2].attempt == 2
        @test rs.statuses[3].state === UNSEEN
        @test haskey(rs.profiles, :default)
    end

    @testset "profiles survive the round trip, expressions and all" begin
        dir = mktempdir(); mkpath(joinpath(dir, "test"))
        write(joinpath(dir, "Project.toml"), "name = \"P\"\nuuid = \"1a2b3c4d-0000-4000-8000-00000000000a\"\n")
        write(joinpath(dir, "test", "a_test.jl"), """@testitem "x" sandbox=:p begin\n @test true\n end\n""")
        write(joinpath(dir, "test", "TestItems.toml"), """
        [profiles.p]
        julia_args = ["--check-bounds=yes"]
        threads = "3"
        env = { FOO = "bar" }
        init = "const A = 1"
        test_end = "GC.gc(true)"
        """)
        items = scan(discover(joinpath(dir, "test")), Filter(), Dict{Symbol,String}())
        p = plan(items, read_config(joinpath(dir, "test")); root=dir)
        path = joinpath(mktempdir(), "run.yatf")
        finish_run_state!(init_run_state(path, p))
        rs = read_run_state(path)
        prof = rs.profiles[:p]
        @test prof.julia_args == ["--check-bounds=yes"]
        @test prof.threads == "3"
        @test prof.env == ["FOO" => "bar"]
        @test occursin("A = 1", string(prof.init))
        @test occursin("GC.gc", string(prof.test_end))
    end

    @testset "a truncated file never throws, at any length" begin
        p = a_plan()
        path = joinpath(mktempdir(), "run.yatf")
        rsf = init_run_state(path, p)
        write_status!(rsf, 1, PASSED, 1, 1; elapsed=1.0)
        finish_run_state!(rsf)
        full = read(path)
        broken = joinpath(mktempdir(), "broken.yatf")
        for n in 0:length(full)
            write(broken, full[1:n])
            rs = read_run_state(broken)       # must not throw, whatever n is
            rs === nothing && continue
            @test length(rs.statuses) == nitems(p)
        end
        @test true    # reaching here is the assertion
    end

    @testset "a garbled file never throws" begin
        p = a_plan()
        path = joinpath(mktempdir(), "run.yatf")
        finish_run_state!(init_run_state(path, p))
        full = read(path)
        garbled = joinpath(mktempdir(), "garbled.yatf")
        # Seeded, so that a corruption which breaks the reader breaks every run of
        # this file rather than one in a hundred. A count is what usually does it:
        # the number some garbled bytes happen to spell, taken as a length, is an
        # allocation nobody comes back from.
        rng = Random.Xoshiro(20250921)
        for _ in 1:400
            bytes = copy(full)
            for _ in 1:20
                bytes[rand(rng, 1:length(bytes))] = rand(rng, UInt8)
            end
            write(garbled, bytes)
            @test (read_run_state(garbled); true)
        end
        @test read_run_state(joinpath(mktempdir(), "not_a_file")) === nothing
        write(garbled, "not a run state at all")
        @test read_run_state(garbled) === nothing
    end

    @testset "a killed run still reports what finished" begin
        # A real SIGKILL, not a simulated one: the file has to be readable
        # without anything having closed it.
        dir = mktempdir()
        script = joinpath(dir, "run.jl")
        write(script, """
        push!(LOAD_PATH, $(repr(dirname(@__DIR__))))
        using YATF
        YATF.runtests($(repr(fixture("Faulty.jl"))); workers=1, logs=:issues, monitor=false,
                      name=r"^(passes|hangs)\$", timeout=600)
        """)
        child_log = joinpath(dir, "child.log")
        proc = run(pipeline(addenv(`$(Base.julia_cmd()) --startup-file=no $script`,
                                   "YATF_RUNSTATE_DIR" => dir);
                            stdout=child_log, stderr=child_log); wait=false)
        # Wait until the run state shows the passing item is done, then kill. The
        # ceiling is generous because the child starts a Julia process, resolves a
        # test environment and starts a worker, and the files run several at a
        # time; the loop leaves as soon as the condition holds, so a slack ceiling
        # costs nothing and a tight one is a flake on a busy machine.
        deadline = time() + 600
        seen = false
        while time() < deadline && !seen
            files = filter!(endswith(".yatf"), readdir(dir; join=true))
            for f in files
                rs = read_run_state(f)
                rs === nothing && continue
                any(s -> s.state === PASSED, rs.statuses) && (seen = true)
            end
            seen || sleep(0.2)
        end
        kill(proc, Base.SIGKILL)
        wait(proc)
        seen || @info "the killed-run fixture never got going; its output was:\n" *
                      (isfile(child_log) ? read(child_log, String) : "(no output)")
        @test seen
        files = filter!(endswith(".yatf"), readdir(dir; join=true))
        @test !isempty(files)
        rs = read_run_state(last(sort!(files)))
        @test rs !== nothing
        # Killed that way, the coordinator never stopped its worker, which is asleep
        # in "hangs" and would outlive this test by ten minutes.
        rs === nothing || foreach(rs.events) do e
            e.kind === :worker_up && ccall(:uv_kill, Cint, (Cint, Cint), e.pid, Base.SIGKILL)
        end
        @test !rs.complete                              # the run never finished
        @test any(s -> s.state === PASSED, rs.statuses) # but what did finish is recorded
        @test any(s -> s.state === RUNNING, rs.statuses) # and what was in flight says so
    end

    @testset "history feeds the next run" begin
        dir = mktempdir()
        withenv("YATF_RUNSTATE_DIR" => dir) do
            pkg = fixture("Basic.jl")
            p, target = prepare((pkg,); workers=1, logs=:issues)
            run = execute(p, target)
            rm(run.logdir; force=true, recursive=true)
            h = history(pkg)
            @test length(h.seconds) == 6
            @test all(>(0), values(h.seconds))
            @test isempty(h.failed)
            # the next plan sees those timings
            p2, _ = prepare((pkg,); workers=2, logs=:issues)
            @test any(>(0), p2.units.est_s)
        end
    end

    @testset "failures are remembered and can be re-run" begin
        dir = mktempdir()
        withenv("YATF_RUNSTATE_DIR" => dir, "YATF_FAULTY_DIR" => mktempdir()) do
            pkg = fixture("Faulty.jl")
            p, target = prepare((pkg,); workers=1, logs=:issues, name=r"^(passes|fails)$")
            run = execute(p, target)
            rm(run.logdir; force=true, recursive=true)
            h = history(pkg)
            @test h.failed == Dict("fails" => 0)
            # `runtestsf` re-runs exactly those
            p2, _ = prepare((pkg,); workers=1, logs=:issues, name=Regex("^(fails)\$"))
            @test [p2.items.name[i] for i in 1:nitems(p2)] == ["fails"]
        end
    end

    @testset "old run states are pruned" begin
        dir = mktempdir()
        withenv("YATF_RUNSTATE_DIR" => dir) do
            p = a_plan()
            for i in 1:25
                path = joinpath(dir, string(1000000 + i, "-1.yatf"))
                finish_run_state!(init_run_state(path, p))
            end
            @test length(runstate_files(p.root)) == 25
            prune_runstates(p.root, 20)
            @test length(runstate_files(p.root)) == 20
        end
    end

    @testset "a run state recorded on another machine is never pruned" begin
        dir = mktempdir()
        withenv("YATF_RUNSTATE_DIR" => dir) do
            p = a_plan()
            for i in 1:25
                finish_run_state!(init_run_state(joinpath(dir, string(1000000 + i, "-1.yatf")), p))
            end
            # A CI artifact downloaded among them, older than any: the same file, but
            # recorded on another machine. Rewritten byte for byte, so it stays valid.
            here = gethostname()
            elsewhere = String(map(b -> b == UInt8('q') ? UInt8('r') : UInt8('q'), codeunits(here)))
            artifact = joinpath(dir, "999999-1.yatf")
            write(artifact, replace(read(joinpath(dir, "1000001-1.yatf"), String), here => elsewhere))
            @test read_run_state(artifact).meta["host"] == elsewhere
            before = read(artifact)
            prune_runstates(p.root, 20)
            @test isfile(artifact) && read(artifact) == before
            @test length(runstate_files(p.root)) == 21   # this machine's twenty, and the artifact
        end
    end

    @testset "YATF_HOST names the machine, so a CI cache is pruned like a local directory" begin
        dir = mktempdir()
        p = a_plan()
        withenv("YATF_RUNSTATE_DIR" => dir, "YATF_HOST" => "ci-linux") do
            for i in 1:25
                finish_run_state!(init_run_state(joinpath(dir, string(1000000 + i, "-1.yatf")), p))
            end
            @test read_run_state(joinpath(dir, "1000001-1.yatf")).meta["host"] == "ci-linux"
            # Recorded under the name this runner has too, whatever its hostname: its own.
            prune_runstates(p.root, 20)
            @test length(runstate_files(p.root)) == 20
        end
        # Under another name, those twenty are another machine's.
        withenv("YATF_RUNSTATE_DIR" => dir, "YATF_HOST" => "ci-macos") do
            prune_runstates(p.root, 5)
            @test length(runstate_files(p.root)) == 20
        end
    end

    @testset "a replay changes and deletes no run state, the one it runs among them" begin
        with_runstate_dir() do dir
            pkg = make_pkg("ReplayKeeps", "test/r_test.jl" => "@testitem \"x\" begin\n    @test true\nend\n")
            run_states(pkg; workers=0, logs=:issues, monitor=false)
            recorded = only(runstate_files(pkg))
            # The oldest of as many as are kept: the run a replay adds would push it out.
            stamp = parse(Int, first(split(basename(recorded), '-')))
            for k in 1:(YATF.Private.KEEP_RUNS - 1)
                cp(recorded, joinpath(dir, string(stamp + k, "-1.yatf")))
            end
            before = Dict(f => read(f) for f in runstate_files(pkg))
            capture_run(() -> run_states(pkg; workers=0, logs=:issues, monitor=false, replay=recorded))
            @test all(f -> isfile(f) && read(f) == before[f], keys(before))
            @test length(runstate_files(pkg)) == YATF.Private.KEEP_RUNS + 1
        end
    end

    @testset "a new run state never takes an existing file's name" begin
        dir = mktempdir()
        withenv("YATF_RUNSTATE_DIR" => dir) do
            # Whichever second the name is made in, a file already has it.
            now_ = round(Int, time())
            taken = [joinpath(dir, string(now_ + k, "-", getpid(), ".yatf")) for k in 0:3]
            foreach(f -> write(f, "someone else's"), taken)
            path = new_runstate_path(dir)
            @test !ispath(path) && endswith(path, ".yatf")
            # ...and it sorts after the file whose name it would have had.
            had = joinpath(dir, first(split(basename(path), '_')) * ".yatf")
            @test had in taken && sort([path, had]) == [had, path]
            @test all(f -> read(f, String) == "someone else's", taken)
        end
    end
    @testset "the commit is read straight out of .git" begin
        sha = "0123456789abcdef0123456789abcdef01234567"
        dir = mktempdir()
        mkpath(joinpath(dir, ".git", "refs", "heads"))
        write(joinpath(dir, ".git", "HEAD"), "ref: refs/heads/main\n")
        write(joinpath(dir, ".git", "refs", "heads", "main"), sha * "\n")
        @test project_revision(dir) == sha

        # A ref that has been packed away is still a ref.
        rm(joinpath(dir, ".git", "refs", "heads", "main"))
        write(joinpath(dir, ".git", "packed-refs"),
              "# pack-refs with: peeled fully-peeled sorted\n$sha refs/heads/main\n^deadbeef\n")
        @test project_revision(dir) == sha

        # A detached HEAD holds the commit itself.
        write(joinpath(dir, ".git", "HEAD"), sha * "\n")
        @test project_revision(dir) == sha

        # A worktree or a submodule: `.git` is a file pointing at the real one.
        wt = mktempdir()
        write(joinpath(wt, ".git"), "gitdir: " * joinpath(dir, ".git") * "\n")
        @test project_revision(wt) == sha

        # A worktree on a branch, laid out as `git worktree add` lays it out: its
        # own directory holds HEAD, and the branch is in the repository's.
        main = mktempdir()
        mkpath(joinpath(main, ".git", "refs", "heads"))
        write(joinpath(main, ".git", "HEAD"), "ref: refs/heads/main\n")
        write(joinpath(main, ".git", "refs", "heads", "feature"), sha * "\n")
        own = joinpath(main, ".git", "worktrees", "feature")
        mkpath(own)
        write(joinpath(own, "HEAD"), "ref: refs/heads/feature\n")
        write(joinpath(own, "commondir"), "../..\n")
        wt = mktempdir()
        write(joinpath(wt, ".git"), "gitdir: " * own * "\n")
        @test project_revision(wt) == sha
        rm(joinpath(main, ".git", "refs", "heads", "feature"))
        write(joinpath(main, ".git", "packed-refs"), "$sha refs/heads/feature\n")
        @test project_revision(wt) == sha

        @test project_revision(mktempdir()) == ""        # not a checkout
        @test project_revision("/nonexistent/path") == ""
    end

    @testset "the run state records the commit it ran from" begin
        sha = "abcdefabcdefabcdefabcdefabcdefabcdefabcd"
        dir = make_pkg("Revisioned", "test/a_test.jl" => """@testitem "x" begin\n @test true\nend\n""")
        mkpath(joinpath(dir, ".git"))
        write(joinpath(dir, ".git", "HEAD"), sha * "\n")
        items = scan(discover(joinpath(dir, "test")), Filter(), Dict{Symbol,String}())
        p = plan(items, read_config(joinpath(dir, "test")); root=dir)
        path = joinpath(mktempdir(), "run.yatf")
        finish_run_state!(init_run_state(path, p))
        @test read_run_state(path).meta["revision"] == sha
    end

    @testset "replay applies the worker configuration a run state recorded" begin
        dir = make_pkg(
            "Replayed",
            "test/a_test.jl" => """@testitem "x" sandbox=:p begin\n @test true\nend\n""",
            "test/TestItems.toml" =>
                "[profiles.p]\njulia_args = [\"--check-bounds=yes\"]\nthreads = \"3\"\n"
        )
        items = scan(discover(joinpath(dir, "test")), Filter(), Dict{Symbol,String}())
        p = plan(items, read_config(joinpath(dir, "test")); root=dir)
        path = joinpath(mktempdir(), "run.yatf")
        finish_run_state!(init_run_state(path, p))

        # The same suite after the profile was dropped from its configuration.
        write(joinpath(dir, "test", "TestItems.toml"), "")
        @test_throws YATF.ConfigError prepare((dir,))

        (p2, _), out = capture_run() do
            prepare((dir,); replay=path)
        end
        prof = only(x for x in p2.profiles if x.name === :p)
        @test prof.julia_args == ["--check-bounds=yes"]
        @test prof.threads == "3"
        @test occursin("replaying run.yatf", out)

        # A run state that cannot be read is an error, not a silent fallback to
        # whatever this checkout happens to say.
        @test_throws YATF.ConfigError prepare((dir,); replay=joinpath(mktempdir(), "nope.yatf"))
    end

    @testset "a run records where it ran, how it was asked for, and what each worker did" begin
        with_runstate_dir() do dir
            pkg = make_pkg("Recorded", "test/r_test.jl" => """
            @testitem "a" begin
                @test true
            end
            @testitem "b" begin
                @test true
            end
            @testitem "throws" begin
                error("thrown outside any @test")
            end
            """)
            run_states(pkg; workers=1, logs=:issues, monitor=false, seed=0x1234)
            rs = read_run_state(only(readdir(dir; join=true)))
            @test rs.meta["seed"] == "0x0000000000001234"
            @test (rs.meta["workers"], rs.meta["machine"], rs.meta["julia"]) == ("1", Sys.MACHINE, string(VERSION))
            @test occursin("[[deps.", rs.meta["environment_manifest"])
            @test occursin("Recorded", rs.meta["environment_project"])
            up, down = only(e for e in rs.events if e.kind === :worker_up), only(e for e in rs.events if e.kind === :worker_down)
            @test down.ended_by === :close && down.pid == up.pid
            attempts = [e for e in rs.events if e.kind === :attempt]
            @test sort([rs.items[e.item].name for e in attempts]) == ["a", "b", "throws"]
            @test all(e -> e.pid == up.pid && e.t1 >= e.t0, attempts)
            @test [e.state for e in attempts if rs.items[e.item].name != "throws"] == [PASSED, PASSED]
            # An item that throws took time and memory like any other.
            @test all(s -> s.pid == up.pid && s.peak_rss_mb > 0 && s.elapsed > 0, rs.statuses)
            @test occursin("run it again", sprint(show, MIME"text/plain"(), rs))
        end
    end

    @testset "a replay runs the same items with the same settings and the same seed" begin
        with_runstate_dir() do dir
            with_journal() do jdir
                pkg = make_pkg("Replayable", "test/r_test.jl" => """
                @testitem "draws" begin
                    write(joinpath(ENV["YATF_JOURNAL"], string(time_ns())), string(rand(UInt64)))
                    @test true
                end
                """)
                run_states(pkg; workers=1, retries=1, logs=:issues, monitor=false)
                recorded = only(readdir(dir; join=true))
                # An item added since is not part of the run that was recorded.
                write(joinpath(pkg, "test", "later_test.jl"), "@testitem \"added later\" begin\n @test true\nend\n")
                (p, _), out = capture_run(() -> prepare((pkg,); replay=recorded))
                @test p.items.name == ["draws"]
                @test p.cfg.retries == 1
                @test p.cfg.seed == parse(UInt64, read_run_state(recorded).meta["seed"])
                @test occursin("replaying ", out)
                @test prepare((pkg,); replay=recorded, retries=0)[1].cfg.retries == 0   # the call still wins
                _, out = capture_run(() -> run_states(pkg; replay=recorded, logs=:issues, monitor=false))
                @test occursin("the environment matches the one the run state was recorded in", out)
                draws = [read(f, String) for f in readdir(jdir; join=true)]
                @test length(draws) == 2 && draws[1] == draws[2]
            end
        end
    end

    @testset "a manifest is read as package versions" begin
        m = YATF.Private.manifest_versions("""
        manifest_format = "2.0"
        [[deps.Foo]]
        uuid = "7876af07-990d-54b4-ab0e-23690620f79a"
        version = "1.2.3"
        [[deps.Local]]
        path = "/elsewhere"
        uuid = "5b0c2a4e-7f3d-4e21-9c55-3a1f0e6d7b90"
        [[deps.Test]]
        uuid = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
        """)
        @test m == Dict("Foo" => "1.2.3", "Local" => "path", "Test" => "stdlib")
    end

    @testset "a run state lying next to the project does not change the next run" begin
        with_runstate_dir() do _
            dir = make_pkg("NotReplayed", "test/a_test.jl" => """@testitem "x" begin\n @test true\nend\n""")
            run_states(dir; workers=1, threads="1", logs=:issues, monitor=false)
            # What the caller asked for, not what the last run happened to record.
            p, _ = prepare((dir,); workers=1, threads="2,1")
            @test p.profiles[1].threads == "2,1"
        end
    end
end
