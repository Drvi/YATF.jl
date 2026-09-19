# Sandboxes, chains and forced order, in combination. Each of the three decides
# something different about where an item runs — alone in a process, next to its
# chain, at a fixed point in the queue — and a suite normally uses more than one
# of them at once.

using YATF: PASSED, ERRORED, TIMEDOUT, BROKEN_CHAIN, nitems

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

    @testset "an idle slot never steals work belonging to another profile" begin
        # One quick item in the default pool and three slow ones in a pool with
        # different julia flags: the default slot drains first and goes looking for
        # work. What it must not find is an item declared to run under flags its
        # own process was not started with — that item would be reported as a pass
        # without ever having been run the way it was written.
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
        # The three bounds items shared one process; the quick one had its own.
        checked = unique(r.pid for r in rows if startswith(r.name, "checked"))
        @test length(checked) == 1
        @test only(r.pid for r in rows if r.name == "quick") ∉ checked
    end

    @testset "the last unit in a queue can still be stolen" begin
        # Two files are two affinity groups, so each slot gets one. One holds a
        # slow item followed by a quick one; the other holds a single quick item
        # and is done almost at once. The item left over must not sit behind the
        # slow one waiting for a worker that is busy, while a free worker goes home.
        dir = make_pkg(
            "LastUnit",
            "test/a_test.jl" => """
            @testitem "slow one" begin
                sleep(2)
                @test true
            end
            @testitem "left over" begin
                @test true
            end
            """,
            "test/b_test.jl" => """
            @testitem "quick" begin
                @test true
            end
            """,
        )
        states, run, p = run_states(dir; workers=2, logs=:issues, monitor=false)
        @test all(==(PASSED), values(states))
        # The slot the coordinator recorded: these two items now run at the same
        # time, which is the whole point, so a shared marker file would race.
        slot_of(name) = run.statuses.slot[findfirst(==(name), p.items.name)]
        @test slot_of("left over") != slot_of("slow one")
    end

    @testset "a stolen chain moves whole" begin
        # Two files are two affinity groups, so two slots get one each. The slot
        # holding the single quick item drains at once and steals from the tail of
        # the other queue, which is where the chain is. What it must take is the
        # whole chain: the members may not run at the same time as each other, and
        # two workers holding two halves is exactly that.
        dir = make_pkg(
            "StolenChain",
            "test/a_test.jl" => journal_item("solo"),
            "test/b_test.jl" => string(
                journal_item("filler one"; body="sleep(0.3)\n@test true"),
                journal_item("filler two"; body="sleep(0.3)\n@test true"),
                journal_item("filler three"; body="sleep(0.3)\n@test true"),
                journal_item("tail chain one"; opts="chain=:t", body="sleep(0.3)\n@test true"),
                journal_item("tail chain two"; opts="chain=:t", body="sleep(0.3)\n@test true"),
                journal_item("tail chain three"; opts="chain=:t", body="sleep(0.3)\n@test true"),
            ),
        )
        rows, run, p = with_journal() do path
            states, run, p = run_states(dir; workers=2, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
            journal(path), run, p
        end

        # The slot the planner gave each item, against the slot that ran it.
        planned(i) = findfirst(r -> p.items.unit[i] in r, p.slot_units)
        stolen = [i for i in 1:nitems(p) if run.statuses.slot[i] != planned(i)]
        @test !isempty(stolen)            # otherwise this test proves nothing

        chain = [r for r in rows if startswith(r.name, "tail chain")]
        @test length(chain) == 3
        # One process ran all three, in order: a split chain is two pids.
        @test length(unique(r.pid for r in chain)) == 1
        @test [r.name for r in chain] == ["tail chain one", "tail chain two", "tail chain three"]
        # ...and every member moved together, whether or not it was the chain that
        # was stolen.
        chain_idx = [i for i in 1:nitems(p) if startswith(p.items.name[i], "tail chain")]
        @test length(unique(run.statuses.slot[i] for i in chain_idx)) == 1
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
