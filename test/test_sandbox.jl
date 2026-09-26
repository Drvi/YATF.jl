# Sandboxes, chains and forced order, in combination. Each of the three decides
# something different about where an item runs — alone in a process, next to its
# chain, at a fixed point in the queue — and a suite normally uses more than one
# of them at once.

using YATF.Private: PASSED, ERRORED, TIMEDOUT, BROKEN_CHAIN, nitems

# A chain member that takes long enough for an overlap to show, and records when it
# ended as well as when it started; `before` runs first.
chain_link(name; chain::Symbol, before="") = journal_item(name; opts="chain=:$chain", body=before * """
    sleep(0.2)
    open(joinpath(ENV["YATF_JOURNAL"], string(time_ns(), "-", getpid(), "-end")), "w") do io
        println(io, $(repr(name * " end")), "\\t", getpid(), "\\t", time())
    end
    @test true
    """)

# The chain `links` ran in one process, each member starting after the one before
# it ended: by the worker's clock, in the journal, and by the coordinator's, in the
# dispatch time and duration it recorded.
function check_ran_in_sequence(rows, run, p, links)
    ours = [r for r in rows if r.name in links || r.name in (l * " end" for l in links)]
    @test [r.name for r in ours] == collect(Iterators.flatten((l, l * " end") for l in links))
    @test length(unique(r.pid for r in ours)) == 1
    idx = [findfirst(==(l), p.items.name) for l in links]
    st = run.statuses
    @test allequal(st.slot[i] for i in idx)
    @test all(i -> st.pid[i] == first(ours).pid, idx)
    for (a, b) in zip(idx, idx[2:end])
        @test st.start[b] >= st.start[a] + st.elapsed[a] - 1e-3
    end
end

@testset "sandboxes, chains and order" begin
    @testset "a sandboxed item has its process to itself" begin
        dir = make_pkg("Alone", "test/t_test.jl" => string(
            journal_item("before"),
            journal_item("alone"; opts="sandbox=true"),
            journal_item("after"),
        ))
        rows = with_journal() do path
            states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
            journal(path)
        end
        @test length(rows) == 3
        alone = only(r for r in rows if r.name == "alone")
        # Nothing else ran in that process, before it or after it.
        @test count(r -> r.pid == alone.pid, rows) == 1
        # ...and the other two shared one, so this is about the sandbox and not
        # about every item getting a process.
        @test length(unique(r.pid for r in rows)) == 2
    end

    @testset "a sandbox worker says it is one, and is put down when it hangs" begin
        # A sandbox under the default profile is otherwise indistinguishable from a
        # pool worker in the log: same flags, same threads. The line has to say why
        # the process exists, because "one more worker came up" and "this item
        # demanded a process of its own" are different things to read past.
        dir = make_pkg("SandboxLog", "test/t_test.jl" => """
        @testitem "pooled one" begin
            @test true
        end
        @testitem "solo" sandbox=true begin
            @test true
        end
        @testitem "solo hangs" sandbox=true timeout=2 begin
            sleep(600)
        end
        @testitem "pooled two" begin
            @test true
        end
        """)
        _, out = capture_run() do
            run_states(dir; workers=1, logs=:issues, monitor=false)
        end
        lines = collect(eachsplit(out, '\n'))
        ups = filter(l -> occursin("· UP ", l), lines)
        @test length(ups) == 3                      # one pool worker and two sandboxes
        @test count(l -> occursin("· sandbox", l), ups) == 2
        # The pool worker that ran the two ordinary items is not one of them.
        @test count(l -> !occursin("· sandbox", l), ups) == 1
        # The one that hung was killed; the one that passed was closed. Both words
        # appear, and neither stands in for the other.
        @test count(l -> occursin("· KILL", l), lines) == 1
        @test any(l -> occursin("· KILL", l) && occursin("solo hangs", l), lines)
        # A killed worker is already gone, so it is not also reported as exiting:
        # one UP per teardown line, three and three.
        @test count(l -> occursin("· EXIT", l), lines) == 2
    end

    @testset "a slot that has drained its sandboxes takes ordinary work" begin
        # A sandbox leads its profile's pool, in a process of its own that is torn
        # down after it. The slot that ran it has to go on to the pool's ordinary
        # work: going home with the rest of the suite still queued is a worker the
        # run paid for and did not use.
        ordinary_names = ["ordinary $i" for i in 1:6]
        dir = make_pkg(
            "SandboxThenSteal",
            "test/a_test.jl" => """
            @testitem "solo" sandbox=true begin
                @test true
            end
            """,
            # Each holds its worker until another process has started one of them,
            # so the ordinary pool's own slot cannot get through them alone.
            ("test/b_$(i)_test.jl" => journal_item(
                ordinary_names[i]; body=started_elsewhere(ordinary_names) * "@test true"
            ) for i in 1:6)...,
        )
        states, run, p = with_journal() do _
            run_states(dir; workers=2, logs=:issues, monitor=false)
        end
        @test all(==(PASSED), values(states))
        idx(name) = findfirst(==(name), p.items.name)
        sandbox_slot = run.statuses.slot[idx("solo")]
        ordinary = [run.statuses.slot[idx(name)] for name in ordinary_names]
        @test count(==(sandbox_slot), ordinary) > 0
        # ...and the other slot did not sit idle either, so this is about sharing
        # the work and not about one slot taking all of it.
        @test length(unique(ordinary)) == 2
    end

    @testset "a sandbox reached with a used worker still gets a process of its own" begin
        # The reverse direction: a slot arrives at a sandbox holding a worker that
        # has already run another item. `[order] first` puts the ordinary item ahead
        # of the sandboxes at the head of the pool, so the slot that runs it takes a
        # sandbox next. A sandbox that inherits that process is not the test that
        # was declared, however green it comes out.
        dir = make_pkg(
            "SandboxAfterWork",
            "test/a_test.jl" => journal_item("ordinary"),
            ("test/b_$(i)_test.jl" => journal_item(
                "solo $i"; opts="sandbox=true", body="sleep(0.3)\n@test true"
            ) for i in 1:4)...,
            "test/TestItems.toml" => "[order]\nfirst = [\"ordinary\"]\n",
        )
        rows = with_journal() do path
            states, _, _ = run_states(dir; workers=2, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
            journal(path)
        end
        @test length(rows) == 5
        for i in 1:4
            solo = only(r for r in rows if r.name == "solo $i")
            @test count(r -> r.pid == solo.pid, rows) == 1
        end
    end

    @testset "a sandboxed item is retried in a fresh process each time" begin
        with_marker_dir() do work
            marker = joinpath(work, "count")
            dir = make_pkg("AloneRetries", "test/t_test.jl" => journal_item(
                "flaky alone"; opts="sandbox=true retries=2", body="""
                k = let p = ENV["YATF_CRASH_MARKER"]
                    n = isfile(p) ? parse(Int, read(p, String)) : 0
                    write(p, string(n + 1))
                    n
                end
                k < 2 && ccall(:abort, Cvoid, ())
                @test k == 2
                """
            ))
            rows = withenv("YATF_CRASH_MARKER" => marker) do
                with_journal() do path
                    states, run, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
                    @test states["flaky alone"] === PASSED
                    @test run.statuses.attempt[1] == 3
                    journal(path)
                end
            end
            @test length(rows) == 3
            @test length(unique(r.pid for r in rows)) == 3
        end
    end

    @testset "a chain retries from its first item" begin
        with_marker_dir() do work
            marker = joinpath(work, "count")
            dir = make_pkg("ChainRetry", "test/t_test.jl" => string(
                journal_item("link one"; opts="chain=:c"),
                journal_item("link two"; opts="chain=:c timeout=2 retries=1", body="""
                    k = let p = ENV["YATF_CRASH_MARKER"]
                        n = isfile(p) ? parse(Int, read(p, String)) : 0
                        write(p, string(n + 1))
                        n
                    end
                    k < 1 && sleep(600)
                    @test true
                    """),
                journal_item("link three"; opts="chain=:c"),
            ))
            rows = withenv("YATF_CRASH_MARKER" => marker) do
                with_journal() do path
                    states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
                    @test all(==(PASSED), values(states))
                    journal(path)
                end
            end
            names = [r.name for r in rows]
            # The first attempt got as far as the item that hung; the retry ran the
            # chain again from the top, because re-running the middle of a sequence
            # that mutates state does not mean anything.
            @test names == ["link one", "link two", "link one", "link two", "link three"]
            # Each attempt is a chain, so each attempt is one process.
            @test length(unique(r.pid for r in rows)) == 2
        end
    end

    @testset "a chain cut short by a timeout does not run its remaining items" begin
        dir = make_pkg("ChainTimeout", "test/t_test.jl" => string(
            journal_item("head"; opts="chain=:d"),
            journal_item("hangs"; opts="chain=:d timeout=2", body="sleep(600)"),
            journal_item("tail"; opts="chain=:d"),
        ))
        rows = with_journal() do path
            states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
            @test states["head"] === PASSED
            @test states["hangs"] === TIMEDOUT
            # The state it would have depended on died with the worker.
            @test states["tail"] === BROKEN_CHAIN
            journal(path)
        end
        @test [r.name for r in rows] == ["head", "hangs"]
    end

    @testset "a chain in a sandbox profile runs in order under that profile's flags" begin
        dir = make_pkg(
            "ChainProfile",
            "test/t_test.jl" => string(
                journal_item("checked one"; opts="chain=:p sandbox=:bounds",
                             body="@test Base.JLOptions().check_bounds == 1"),
                journal_item("checked two"; opts="chain=:p sandbox=:bounds",
                             body="@test Base.JLOptions().check_bounds == 1"),
            ),
            "test/TestItems.toml" => "[profiles.bounds]\njulia_args = [\"--check-bounds=yes\"]\n"
        )
        rows = with_journal() do path
            states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
            journal(path)
        end
        @test [r.name for r in rows] == ["checked one", "checked two"]
        @test length(unique(r.pid for r in rows)) == 1   # a chain is one worker
    end

    @testset "an idle slot never runs work belonging to another profile in its own process" begin
        # One quick item in the default pool and three slow ones in a pool with
        # different julia flags: the default slot drains first and goes looking for
        # work. What it must not do is run an item declared to run under flags its
        # own process was not started with — that item would be reported as a pass
        # without ever having been run the way it was written. It may go on with
        # them in a process started with their flags, which each item checks.
        dir = make_pkg(
            "NoCrossPoolSteal",
            "test/t_test.jl" => string(
                journal_item("quick"),
                journal_item("checked one"; opts="sandbox=:bounds",
                             body="sleep(0.5)\n@test Base.JLOptions().check_bounds == 1"),
                journal_item("checked two"; opts="sandbox=:bounds",
                             body="sleep(0.5)\n@test Base.JLOptions().check_bounds == 1"),
                journal_item("checked three"; opts="sandbox=:bounds",
                             body="sleep(0.5)\n@test Base.JLOptions().check_bounds == 1"),
            ),
            "test/TestItems.toml" => "[profiles.bounds]\njulia_args = [\"--check-bounds=yes\"]\n"
        )
        rows = with_journal() do path
            states, _, _ = run_states(dir; workers=2, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
            journal(path)
        end
        @test length(rows) == 4
        # The quick one's process ran none of the bounds items.
        checked = unique(r.pid for r in rows if startswith(r.name, "checked"))
        @test only(r.pid for r in rows if r.name == "quick") ∉ checked
    end

    @testset "a slot whose profile's items are done goes on with another profile's" begin
        # One quick item under a profile of its own, and two seconds of default
        # items. The profile's slot is done at once, and a fresh default worker in
        # it takes far less than the second each default slot would otherwise have
        # left, so it restarts under the default profile and takes a share.
        dir = make_pkg(
            "Refilled",
            "test/t_test.jl" => string(
                journal_item("tiny"; opts = "sandbox=:tiny", body = "@test ENV[\"TINY\"] == \"1\""),
                (journal_item("d$i"; body = "sleep(0.1)\n@test !haskey(ENV, \"TINY\")") for i in 1:20)...,
            ),
            "test/TestItems.toml" => "[profiles.tiny]\nenv = { TINY = \"1\" }\n",
        )
        rows = with_journal() do path
            states, run, p = run_states(dir; workers = 2, logs = :issues, monitor = false)
            @test all(==(PASSED), values(states))
            ran = [run.statuses.slot[i] for i in 1:nitems(p) if p.items.name[i] != "tiny"]
            tiny_slot = run.statuses.slot[findfirst(==("tiny"), p.items.name)]
            # Default items ran on both slots, the profile's among them.
            @test sort(unique(ran)) == [1, 2]
            @test tiny_slot in ran
            journal(path)
        end
        # In a process of its own, not the one the profile's item ran in: each item
        # checked it ran under its own profile's environment.
        tiny_pid = only(r.pid for r in rows if r.name == "tiny")
        @test tiny_pid ∉ [r.pid for r in rows if r.name != "tiny"]
    end

    @testset "the last unit in a queue can still be stolen" begin
        # Two files are two affinity groups, so each slot gets one. One holds a
        # slow item followed by a quick one; the other holds a single quick item
        # and is done almost at once. The item left over must not sit behind the
        # slow one waiting for a worker that is busy, while a free worker goes home.
        #
        # "slow one" holds its worker until "left over" has started elsewhere, and
        # "quick" holds the other worker until "slow one" is running: the free slot
        # goes looking for work while the other is busy, whichever starts first.
        dir = make_pkg(
            "LastUnit",
            "test/a_test.jl" => string(
                journal_item("slow one"; body=started_elsewhere(["left over"]) * "@test true"),
                journal_item("left over"),
            ),
            "test/b_test.jl" => journal_item("quick"; body=started_elsewhere(["slow one"]) * "@test true"),
        )
        states, run, p = with_journal() do _
            run_states(dir; workers=2, logs=:issues, monitor=false)
        end
        @test all(==(PASSED), values(states))
        # The slot the coordinator recorded: these two items now run at the same
        # time, which is the whole point, so a shared marker file would race.
        slot_of(name) = run.statuses.slot[findfirst(==(name), p.items.name)]
        @test slot_of("left over") != slot_of("slow one")
    end

    @testset "a chain stolen from the end of a queue moves whole" begin
        # Two files are two affinity groups, so each of two slots gets one. The slot
        # holding "solo" drains first and takes the second half of what the other
        # has left, which always holds that queue's last unit: the chain. "filler
        # one" holds its slot until the chain's last member has started elsewhere,
        # so the chain is taken on every run, and never taken back. Behind "filler
        # one" are "filler two" and the chain: as one unit the chain is the half
        # taken, where three units of their own would be split, two and one.
        links = ["tail chain one", "tail chain two", "tail chain three"]
        dir = make_pkg(
            "StolenChain",
            "test/a_test.jl" => journal_item("solo"; body=started_elsewhere(["filler one"]) * "@test true"),
            "test/b_test.jl" => string(
                journal_item("filler one"; body=started_elsewhere(["tail chain three"]) * "@test true"),
                journal_item("filler two"),
                (chain_link(l; chain=:t) for l in links)...,
            ),
        )
        rows, run, p, gave_up = with_journal() do path
            states, run, p = run_states(dir; workers=2, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
            journal(path), run, p, isfile(joinpath(path, "gave-up"))
        end
        @test !gave_up          # each hold was released by the move it waited for
        planned(i) = findfirst(r -> p.items.unit[i] in r, p.slot_units)
        chain = [findfirst(==(l), p.items.name) for l in links]
        @test all(i -> run.statuses.slot[i] != planned(i), chain)   # the chain itself moved
        check_ran_in_sequence(rows, run, p, links)
    end

    @testset "a slot looking for work never takes the rest of a running chain" begin
        # The chain is the first unit of its slot's queue, claimed whole as it
        # starts. "chain one" holds its worker until a filler has started
        # elsewhere, so the other slot, freed by "solo", goes looking for work in
        # this queue while the chain is under way: it finds the fillers, and never
        # the chain's later members.
        links = ["chain one", "chain two", "chain three"]
        fillers = ["filler one", "filler two"]
        dir = make_pkg(
            "RunningChain",
            "test/a_test.jl" => journal_item("solo"; body=started_elsewhere(["chain one"]) * "@test true"),
            "test/b_test.jl" => string(
                chain_link("chain one"; chain=:r, before=started_elsewhere(fillers)),
                chain_link("chain two"; chain=:r),
                chain_link("chain three"; chain=:r),
                (journal_item(f) for f in fillers)...,
            ),
        )
        rows, run, p, gave_up = with_journal() do path
            states, run, p = run_states(dir; workers=2, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
            journal(path), run, p, isfile(joinpath(path, "gave-up"))
        end
        @test !gave_up
        planned(i) = findfirst(r -> p.items.unit[i] in r, p.slot_units)
        at(name) = findfirst(==(name), p.items.name)
        @test any(f -> run.statuses.slot[at(f)] != planned(at(f)), fillers)   # work was taken
        @test all(l -> run.statuses.slot[at(l)] == planned(at(l)), links)     # but not the chain
        check_ran_in_sequence(rows, run, p, links)
    end

    @testset "[order] moves the chain an item belongs to, not just the item" begin
        dir = make_pkg(
            "Ordered",
            "test/t_test.jl" => string(
                journal_item("alpha"),
                journal_item("beta"; opts="chain=:c"),
                journal_item("gamma"; opts="chain=:c"),
                journal_item("delta"),
            ),
            "test/TestItems.toml" => "[order]\nfirst = [\"gamma\"]\nlast = [\"alpha\"]\n"
        )
        rows = with_journal() do path
            states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
            journal(path)
        end
        # `gamma` is pinned first, and it cannot go anywhere without `beta`.
        @test [r.name for r in rows] == ["beta", "gamma", "delta", "alpha"]
    end

    @testset "a sandbox alongside forced order still runs exactly once, alone" begin
        dir = make_pkg(
            "OrderedSandbox",
            "test/t_test.jl" => string(
                journal_item("plain one"),
                journal_item("solo"; opts="sandbox=true"),
                journal_item("plain two"),
            ),
            "test/TestItems.toml" => "[order]\nfirst = [\"plain two\"]\n"
        )
        rows = with_journal() do path
            states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
            journal(path)
        end
        @test length(rows) == 3
        solo = only(r for r in rows if r.name == "solo")
        @test count(r -> r.pid == solo.pid, rows) == 1
        # The pinned item leads the pool it is in.
        plain = [r.name for r in rows if r.name != "solo"]
        @test plain == ["plain two", "plain one"]
    end
end
