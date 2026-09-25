using YATF.Private: plan, scan, discover, setup_modules, read_config, Filter, History, ConfigError,
            ScanFailure, nslots, nitems, NO_CHAIN, print_plan, RawItem, USE_RUN_DEFAULT,
            DEFAULT_PROFILE, ItemIdx
using Random: Xoshiro

const PKG = fixture("Basic.jl")
const TESTDIR = joinpath(PKG, "test")

read_items(; filter=Filter()) = scan(discover(TESTDIR), filter, setup_modules(TESTDIR))

function make_plan(; filter=Filter(), history=History(), strict_order=true, kwargs...)
    items = read_items(; filter)
    cfg = read_config(TESTDIR; nunits=length(items), kwargs...)
    return plan(items, cfg; history, root=PKG, strict_order)
end

# The order items would run in if the workers' queues were concatenated.
dispatch_order(p) = [p.items.name[i] for i in 1:nitems(p)]
slot_names(p, s) = [p.items.name[i] for u in p.slot_units[s] for i in p.units.span[u]]
# Every item in the order the plan hands them out: each pool's head, its slots' stretches
# (the whole body for a pool still waiting for a slot), then its tail.
planned(p) = [p.items.name[i] for (k, pool) in enumerate(p.pools)
              for r in [[pool.head]; [p.slot_units[s] for s in 1:nslots(p) if p.slot_pool[s] == k];
                        k in p.pending ? [pool.body] : UnitRange{Int32}[]; [pool.tail]]
              for u in r for i in p.units.span[u]]

@testset "plan" begin
    @testset "every item lands in exactly one unit, handed out exactly once" begin
        p = make_plan()
        @test nitems(p) == 6
        @test length(p.units) == 5
        @test sort(dispatch_order(p)) == sort([i.name for i in read_items()])
        assigned = planned(p)
        @test sort(assigned) == sort(dispatch_order(p))
        @test length(unique(assigned)) == length(assigned)
    end

    @testset "a chain is one unit, contiguous and in declaration order" begin
        p = make_plan()
        u = findfirst(==(:seq), p.units.chain)
        @test u !== nothing
        span = p.units.span[u]
        @test length(span) == 2
        @test [p.items.name[i] for i in span] == ["chain one", "chain two"]
        # contiguous: the items of a unit are adjacent, so the scheduler only
        # needs a range
        @test span == first(span):(first(span)+ItemIdx(1))
        # and they are on one worker
        @test count(s -> "chain one" in slot_names(p, s), 1:nslots(p)) == 1
        for s in 1:nslots(p)
            names = slot_names(p, s)
            @test ("chain one" in names) == ("chain two" in names)
        end
    end

    @testset "[order] first is honoured" begin
        p = make_plan()
        @test first(dispatch_order(p)) == "slow thing"
    end

    @testset "[order] naming a missing item is an error on a full run" begin
        dir = mktempdir(); mkpath(joinpath(dir, "test"))
        write(joinpath(dir, "test", "a_test.jl"), """@testitem "real" begin\n @test true\n end\n""")
        write(joinpath(dir, "test", "TestItems.toml"), "[order]\nfirst = [\"raal\"]\n")
        items = scan(discover(joinpath(dir, "test")), Filter(), Dict{Symbol,String}())
        cfg = read_config(joinpath(dir, "test"))
        err = try; plan(items, cfg; root=dir); catch e; e; end
        @test err isa ConfigError
        @test occursin("do not exist", sprint(showerror, err))
        @test occursin("did you mean", sprint(showerror, err))   # near-match suggestion
        # ...but a filtered run must not fail just because the pinned item was filtered out
        @test plan(items, cfg; root=dir, strict_order=false) isa YATF.Private.Plan
    end

    @testset "an unknown sandbox profile is an error naming the items" begin
        dir = mktempdir(); mkpath(joinpath(dir, "test"))
        write(joinpath(dir, "test", "a_test.jl"),
              """@testitem "x" sandbox=:nope begin\n @test true\n end\n""")
        items = scan(discover(joinpath(dir, "test")), Filter(), Dict{Symbol,String}())
        err = try; plan(items, read_config(joinpath(dir, "test")); root=dir); catch e; e; end
        @test err isa ConfigError
        @test occursin("sandbox=:nope", sprint(showerror, err))
        @test occursin("\"x\"", sprint(showerror, err))
    end

    @testset "a chain may not mix profiles" begin
        dir = mktempdir(); mkpath(joinpath(dir, "test"))
        write(joinpath(dir, "test", "a_test.jl"), """
        @testitem "one" chain=:c sandbox=:a begin
            @test true
        end
        @testitem "two" chain=:c sandbox=:b begin
            @test true
        end
        """)
        write(joinpath(dir, "test", "TestItems.toml"),
              "[profiles.a]\njulia_args = []\n[profiles.b]\njulia_args = []\n")
        items = scan(discover(joinpath(dir, "test")), Filter(), Dict{Symbol,String}())
        err = try; plan(items, read_config(joinpath(dir, "test")); root=dir); catch e; e; end
        @test err isa ScanFailure
        @test occursin("mixes sandbox profiles", sprint(showerror, err))
    end

    @testset "workers are capped by the work available" begin
        p = make_plan(; workers=64)
        @test nslots(p) <= length(p.units)
        # and no pool has more slots than it has units to hand out
        for (k, pool) in enumerate(p.pools)
            @test count(==(k), p.slot_pool) <= length(pool.head) + length(pool.body) + length(pool.tail)
        end
    end

    @testset "affinity keeps items that share a file or a setup together" begin
        p = make_plan(; workers=2)
        for s in 1:nslots(p)
            names = slot_names(p, s)
            # "add works" and "mul works" share a file and no setup; they should not
            # be split while a whole-group assignment is possible
            if "add works" in names || "mul works" in names
                @test ("add works" in names) == ("mul works" in names)
            end
        end
    end

    @testset "history drives ordering" begin
        h = History(Dict("uses setup" => 100.0, "add works" => 0.1, "mul works" => 0.1),
                    Dict("mul works" => 0), 0.0)
        p = make_plan(; history=h, workers=2)
        # the failure from last time is dispatched before the rest of its pool's work
        order = dispatch_order(p)
        @test findfirst(==("mul works"), order) < findfirst(==("uses setup"), order)
    end

    items(names...) = join(("@testitem \"$n\" begin\n    @test true\nend\n" for n in names))
    function plan_dir(dir; history=History(), workers=2)
        testdir = joinpath(dir, "test")
        raw = scan(discover(testdir), Filter(), setup_modules(testdir))
        return plan(raw, read_config(testdir; nunits=length(raw), workers); history, root=dir)
    end

    @testset "recent failures and changed files lead, then long units, then file order" begin
        dir = make_pkg("Urgent", "test/a_test.jl" => items("a1", "a2", "a3"),
                       "test/b_test.jl" => items("b1", "b2"), "test/c_test.jl" => items("c1", "c2"))
        # a3 failed in the last run and b2 two runs ago; c2 takes more than a quarter
        # of a slot's share of the work.
        h = History(Dict("c2" => 60.0, "a1" => 1.0), Dict("b2" => 2, "a3" => 0), 0.0)
        p = plan_dir(dir; history=h)
        @test length(only(p.pools).head) == 3
        @test dispatch_order(p) == ["a3", "b2", "c2", "a1", "a2", "b1", "c1"]
        # A file written since the last run leads, in file order.
        since = maximum(mtime, readdir(joinpath(dir, "test"); join=true))
        sleep(0.05)
        touch(joinpath(dir, "test", "b_test.jl"))
        @test dispatch_order(plan_dir(dir; history=History(Dict{String,Float64}(), Dict{String,Int}(), since)))[1:2] ==
              ["b1", "b2"]
        # Over a quarter of a slot's share, but a matter of seconds: not long.
        p = plan_dir(dir; history=History(Dict("a1" => 2.0), Dict{String,Int}(), 0.0))
        @test isempty(only(p.pools).head)
        @test p.units.why[p.items.unit[findfirst(==("a1"), p.items.name)]] === YATF.Private.IN_FILE_ORDER
        # A sandboxed unit goes before any of them: its process is fresh anyway.
        write(joinpath(dir, "test", "c_test.jl"), items("c1") * "@testitem \"alone\" sandbox=true begin\n    @test true\nend\n")
        @test first(dispatch_order(plan_dir(dir; history=h))) == "alone"
    end

    @testset "the body is cut at a file boundary rather than through a file" begin
        p = plan_dir(make_pkg("Cut", "test/a_test.jl" => items("a1", "a2", "a3"), "test/b_test.jl" => items("b1")))
        @test [slot_names(p, s) for s in 1:2] == [["a1", "a2", "a3"], ["b1"]]
        p = plan_dir(make_pkg("OneFile", "test/a_test.jl" => items("a1", "a2", "a3", "a4")))
        @test [slot_names(p, s) for s in 1:2] == [["a1", "a2"], ["a3", "a4"]]
    end

    @testset "a slot takes the head, walks its stretch, halves the largest one left, then the tail" begin
        p = plan_dir(make_pkg("Claims", "test/a_test.jl" => items("a1", "a2", "a3", "a4", "a5", "a6"),
                              "test/b_test.jl" => items("b1", "b2"),
                              "test/TestItems.toml" => "[order]\nfirst = [\"b2\"]\nlast = [\"a1\"]\n"))
        q = YATF.Private.Queues(p)
        next(s) = (c = YATF.Private.claim!(q, s); c.kind === :unit ? p.items.name[first(p.units.span[c.unit])] : c.kind)
        @test [next(2), next(2), next(1)] == ["b2", "b1", "a2"]
        @test next(2) == "a5"                                   # the second half of a3–a6
        @test [next(1), next(1), next(1)] == ["a3", "a4", "a6"] # then the one unit slot 2 had left
        @test [next(2), next(2)] == ["a1", :done]
        # A cursor pointing at a unit already handed out is a scheduling bug, stopped
        # rather than run twice.
        q2 = YATF.Private.Queues(p)
        q2.claimed[q2.head[1]] = true
        @test_throws ErrorException YATF.Private.claim!(q2, 1)
    end

    declared(names...; opts = "") = join(("@testitem \"$n\" $opts begin\n    @test true\nend\n" for n in names))

    @testset "however the slots take turns, a unit goes out once, whole, to a slot of its own profile" begin
        # Two profiles with a chain in each, and slot counts from fewer than the
        # profiles to more than one per pool, so a slot rebinds to a pool no slot
        # serves, or steals from another slot of its own pool.
        dir = make_pkg(
            "Claiming",
            "test/a_test.jl" => declared("a1", "a2", "a3") * declared("c1", "c2", "c3"; opts = "chain=:c"),
            "test/b_test.jl" => declared("b1", "b2", "b3", "b4") * declared("d1", "d2"; opts = "chain=:d"),
            "test/p_test.jl" => declared("p1", "p2", "p3"; opts = "sandbox=:bounds") *
                                declared("e1", "e2"; opts = "chain=:e sandbox=:bounds"),
            "test/TestItems.toml" => "[profiles.bounds]\njulia_args = [\"--check-bounds=yes\"]\n",
        )
        for workers in (1, 2, 3, 5)
            p = plan_dir(dir; workers)
            # A chain is one unit, its items in declaration order: handed out whole or
            # not at all.
            for (chain, links) in (:c => ["c1", "c2", "c3"], :d => ["d1", "d2"], :e => ["e1", "e2"])
                u = findfirst(==(chain), p.units.chain)
                @test [p.items.name[i] for i in p.units.span[u]] == links
            end
            # Every interleaving the slots could claim in, sampled.
            wrong = String[]
            for seed in 1:200
                rng = Xoshiro(seed)
                q = YATF.Private.Queues(p)
                serves = copy(p.slot_pool)      # the pool each slot's process was started for
                handed = zeros(Int, length(p.units))
                live = collect(1:nslots(p))
                while !isempty(live)
                    s = rand(rng, live)
                    c = YATF.Private.claim!(q, s)
                    if c.kind === :done
                        filter!(!=(s), live)
                    elseif c.kind === :rebind
                        c.pool in p.pending || push!(wrong, "seed $seed: slot $s rebound to pool $(c.pool), which had a slot")
                        serves[s] = c.pool
                    else
                        handed[c.unit] += 1
                        p.units.profile[c.unit] == p.pools[serves[s]].profile ||
                            push!(wrong, "seed $seed: slot $s, serving pool $(serves[s]), took unit $(c.unit)")
                    end
                end
                all(==(1), handed) || push!(wrong, "seed $seed: units handed out $(handed)")
            end
            @test isempty(wrong)
        end
    end

    @testset "a chain is ordered as one item, by its members' total" begin
        dir = make_pkg(
            "ChainWeight",
            "test/a_test.jl" => declared("c1", "c2", "c3"; opts = "chain=:c"),
            "test/b_test.jl" => declared("solo"),
            "test/c_test.jl" => declared("f1", "f2", "f3", "f4"),
        )
        seconds(solo) = Dict("c1" => 2.0, "c2" => 2.0, "c3" => 2.0, "solo" => solo,
                             "f1" => 0.5, "f2" => 0.5, "f3" => 0.5, "f4" => 0.5)
        unit(p, name) = p.items.unit[findfirst(==(name), p.items.name)]
        # Each link takes two seconds, under the floor below which nothing is long;
        # together they take six, and so go before a single item of four.
        p = plan_dir(dir; history = History(seconds(4.0), Dict{String, Int}(), 0.0))
        @test p.units.est_s[unit(p, "c1")] == 6.0
        @test p.units.why[unit(p, "c1")] === YATF.Private.LONG
        @test dispatch_order(p)[1:4] == ["c1", "c2", "c3", "solo"]
        # ...and after a single item of ten.
        p = plan_dir(dir; history = History(seconds(10.0), Dict{String, Int}(), 0.0))
        @test dispatch_order(p)[1:4] == ["solo", "c1", "c2", "c3"]
        # A link that failed last time takes the whole chain ahead of it.
        p = plan_dir(dir; history = History(seconds(10.0), Dict("c3" => 0), 0.0))
        @test p.units.why[unit(p, "c1")] === YATF.Private.RECENT
        @test dispatch_order(p)[1:4] == ["c1", "c2", "c3", "solo"]
    end

    @testset "planning is deterministic" begin
        a = make_plan()
        for _ in 1:3
            b = make_plan()
            @test dispatch_order(a) == dispatch_order(b)
            @test [slot_names(a, s) for s in 1:nslots(a)] == [slot_names(b, s) for s in 1:nslots(b)]
        end
    end

    @testset "in-process runs use a single slot" begin
        p = make_plan(; workers=0)
        @test nslots(p) == 1
        @test sort(planned(p)) == sort(dispatch_order(p))
    end

    @testset "the plan prints as one block and one table" begin
        out = sprint(print_plan, make_plan())
        @test occursin("dry run · ", out)
        @test occursin("6 test items in 2 files", out)
        @test occursin("setups: `BasicSetup`", out)
        rows = filter(l -> occursin("_test.jl:", l), split(out, '\n'))
        @test length(rows) == 6
        row(name) = only(filter(l -> occursin(repr(name), l), rows))
        @test occursin("[order] first", row("slow thing"))
        @test occursin("chain `seq` 1/2", row("chain one"))
        @test occursin("chain `seq` 2/2", row("chain two"))
        @test occursin("setup `BasicSetup`", row("uses setup"))
        # A chain is the one place several items run as one unit, and it says so on
        # its rows; the output has no other use for the word.
        @test !occursin(r"\bunits?\b", out)
    end

    @testset "the table's columns line up, each as wide as its widest entry" begin
        out = sprint(print_plan, make_plan())
        lines = split(out, '\n')
        header = only(filter(l -> occursin("test item", l) && occursin("tags", l), lines))
        rows = filter(l -> occursin("_test.jl:", l), lines)
        # Positions in characters, not bytes: the separator is not ASCII.
        column(l, text) = length(l[1:prevind(l, findfirst(text, l).start)]) + 1
        # The tags start in one column, just after the longest location and the
        # separator.
        tags_at = column(header, "tags")
        longest = maximum(l -> length(match(r"test[/\\]\S+:\d+", l).match), rows)   # `\` on Windows
        @test tags_at == column(header, "at ") + longest + length(YATF.Private.FIELD)
        # Every row's separators fall where the header's do, up to where the row ends.
        dots = findall(==('·'), collect(header))
        @test all(l -> all(d -> d > length(l) || collect(l)[d] == '·', dots), rows)
        tagged = filter(l -> occursin("fast", l), rows)
        @test length(tagged) == 2
        @test all(l -> column(l, "fast") == tags_at, tagged)
        # A row ends at its last character.
        @test all(l -> l == rstrip(l), lines)
    end

    @testset "the worker column is right-aligned under its title" begin
        lines = split(sprint(print_plan, make_plan(; workers=2)), '\n')
        column(l, text) = length(l[1:prevind(l, findfirst(text, l).start)]) + 1
        header = only(filter(l -> occursin("· worker ·", l), lines))
        ends = column(header, "worker") + length("worker")
        rows = filter(l -> occursin("_test.jl:", l), lines)
        @test all(rows) do l
            m = match(r"(w\d+) ·", l)
            column(l, m.match) + length(m.captures[1]) == ends
        end
    end

    @testset "a name too long for its column is shortened to a prefix only it has" begin
        names = ["short one", "short two",
                 "a long name about parsing dates carefully", "a long name about parsing times carefully",
                 "zebra crossings are long and winding roads", "long name (with parens) and more words"]
        cells = YATF.Private.shown_names(names, 20)
        shown = Dict(zip(names, cells))
        # One that fits is as it is, after the column the shortened ones have an `r` in.
        @test shown["short one"] == " \"short one\""
        # Shortened as far as fits, which is further than it needs to be unique.
        @test shown["zebra crossings are long and winding roads"] == "r\"^zebra crossings a\""
        @test textwidth(shown["zebra crossings are long and winding roads"]) == 1 + 20
        # What makes it the only one does not fit: the column is overrun, not the name cut.
        @test shown["a long name about parsing dates carefully"] == "r\"^a long name about parsing d\""
        # A regex character is escaped, so the prefix is matched as written.
        @test shown["long name (with parens) and more words"] == "r\"^long name \\(with \""
        # Every shortened name, passed to `name=`, picks out its item and no other.
        for (n, c) in zip(names, cells)
            startswith(c, 'r') || continue
            rx = eval(Meta.parse(c))
            @test occursin(rx, n) && count(m -> occursin(rx, m), names) == 1
        end
        # All the names fit: nothing changes, and there is no column for an `r`.
        @test YATF.Private.shown_names(["short one", "short two"], 20) == ["\"short one\"", "\"short two\""]
        # No prefix is a name's own when another name begins with all of it: it stays
        # whole, and the other is picked out by the character after it.
        @test YATF.Private.shown_names(["a name that is long", "a name that is long, and longer"], 12) ==
            [" \"a name that is long\"", "r\"^a name that is long,\""]
    end

    @testset "a shortened name is told apart from every name in the suite" begin
        shown = "a long name about parsing dates carefully"
        other = "a long name about parsing dates carelessly"
        # Among the names shown, a short prefix would do; the suite has another name
        # that shares most of it, so the prefix runs to where the two part.
        @test YATF.Private.shown_names([shown, "short"], 20) == ["r\"^a long name about\"", " \"short\""]
        @test YATF.Private.shown_names([shown, "short"], 20; among = [shown, "short", other]) ==
            ["r\"^a long name about parsing dates caref\"", " \"short\""]
        # A dry run of part of the suite: the item left out still has a name.
        items = join((string("@testitem ", repr(n), " begin\n    @test true\nend\n")
                      for n in ["one", "two", "three", shown, other]), "\n")
        dir = make_pkg("Apart", "test/a_test.jl" => items)
        p, _ = YATF.Private.prepare((dir,); name=Set(["one", "two", "three", shown]), workers=1,
                            logs=:issues, announce=false)
        row = only(filter(l -> occursin("r\"^", l), split(sprint(print_plan, p), '\n')))
        rx = eval(Meta.parse(match(r"r\"\^.*?[^\\]\"", row).match))
        @test occursin(rx, shown) && !occursin(rx, other)
    end

    @testset "the names line up on their opening quotes" begin
        long = "an item whose name runs on and on, far past any other in the suite"
        items = join((string("@testitem ", repr(n), " begin\n    @test true\nend\n")
                      for n in ["one", "two", "three", long, long * " too"]), "\n")
        dir = make_pkg("Quoted", "test/q_test.jl" => items)
        p, _ = YATF.Private.prepare((dir,); workers=2, logs=:issues, announce=false)
        rows = filter(l -> occursin("_test.jl:", l), split(sprint(print_plan, p), '\n'))
        quote_at(l) = length(l[1:prevind(l, findfirst('"', l))]) + 1
        @test length(unique(quote_at.(rows))) == 1
        @test any(l -> occursin("r\"^an item whose name", l), rows)
    end

    @testset "full_names writes every name whole" begin
        long = "an item whose name runs on and on, far past any other in the suite"
        items = join((string("@testitem ", repr(n), " begin\n    @test true\nend\n")
                      for n in ["one", "two", "three", long]), "\n")
        dir = make_pkg("Whole", "test/w_test.jl" => items)
        rows(; kw...) = filter(l -> occursin("_test.jl:", l), split(sprint(print_plan,
            first(YATF.Private.prepare((dir,); workers=1, logs=:issues, announce=false, kw...))), '\n'))
        @test any(l -> occursin("r\"^an i", l), rows())
        @test any(l -> occursin(repr(long), l), rows(full_names=true))
        @test !any(l -> occursin("r\"^", l), rows(full_names=true))
    end

    @testset "the dry run says why an item goes where it does" begin
        whys(p) = Dict(p.items.name[i] => YATF.Private.why_text(p, p.items.unit[i]) for i in 1:nitems(p))
        # From the recorded runs: one item failed in the newest, one three runs back,
        # and one took far longer than the rest.
        h = History(Dict("uses setup" => 100.0, "add works" => 0.1, "mul works" => 0.1),
                    Dict("add works" => 0, "mul works" => 2), 0.0)
        w = whys(make_plan(; history = h))
        @test w["slow thing"] == "[order] first"
        @test w["add works"] == "failed in the last run"
        @test w["mul works"] == "failed 3 runs ago"
        @test w["uses setup"] == "long: est 1m40.0s"
        # A file written since the newest run started: its items come early too.
        w = whys(make_plan(; history = History(Dict{String, Float64}(), Dict{String, Int}(), 1.0)))
        @test w["add works"] == "file changed since last"

        dir = make_pkg("Placed",
            "test/p_test.jl" => """
            @testitem "in its own process" sandbox=true begin
                @test true
            end
            @testitem "last of all" begin
                @test true
            end
            @testitem "in file order" begin
                @test true
            end
            """,
            "test/TestItems.toml" => "[order]\nlast = [\"last of all\"]\n")
        p, _ = YATF.Private.prepare((dir,); workers=2, logs=:issues, announce=false)
        w = whys(p)
        @test w["in its own process"] == "sandbox"
        @test w["last of all"] == "[order] last"
        @test w["in file order"] == ""
    end

    @testset "a chain's reason is its own, naming the member it is owed to" begin
        # A chain split across two files, a single item, and filler for the share.
        dir = make_pkg(
            "ChainWhy",
            "test/a_test.jl" => declared("c1", "c2"; opts = "chain=:c"),
            "test/d_test.jl" => declared("c3"; opts = "chain=:c"),
            "test/b_test.jl" => declared("solo"),
            "test/f_test.jl" => declared("f1", "f2", "f3", "f4"),
        )
        seconds = Dict("c1" => 2.0, "c2" => 2.0, "c3" => 2.0, "solo" => 10.0,
                       "f1" => 0.5, "f2" => 0.5, "f3" => 0.5, "f4" => 0.5)
        # What the dry run's column says, row by row: a chain's on its first row only.
        function why_column(history)
            p = plan_dir(dir; history)
            return Dict(p.items.name[i] => (i == first(p.units.span[p.items.unit[i]]) ?
                                            YATF.Private.why_text(p, p.items.unit[i]) : "")
                        for i in 1:nitems(p))
        end
        w = why_column(History(seconds, Dict("c3" => 0), 0.0))
        @test w["c1"] == "\"c3\" failed in the last run"
        @test w["c2"] == "" && w["c3"] == ""
        @test why_column(History(seconds, Dict("c3" => 1), 0.0))["c1"] == "\"c3\" failed 2 runs ago"
        # The first member itself: nothing to name.
        @test why_column(History(seconds, Dict("c1" => 0), 0.0))["c1"] == "failed in the last run"
        # Long by the chain's total, though each member is short.
        w = why_column(History(merge(seconds, Dict("solo" => 4.0)), Dict{String, Int}(), 0.0))
        @test w["c1"] == "long: est 6.0s (chain: `c`)"
        @test w["solo"] == "long: est 4.0s"
        # Written since the newest run: the file, which need not be the first member's.
        since = maximum(mtime, readdir(joinpath(dir, "test"); join = true))
        sleep(0.05)
        touch(joinpath(dir, "test", "d_test.jl"))
        @test why_column(History(seconds, Dict{String, Int}(), since))["c1"] ==
              "$(joinpath("test", "d_test.jl")) changed since last"
        # Pinned by the member `[order]` names.
        write(joinpath(dir, "test", "TestItems.toml"), "[order]\nfirst = [\"c2\"]\n")
        @test why_column(History(seconds, Dict{String, Int}(), 0.0))["c1"] == "[order] first names \"c2\""
        write(joinpath(dir, "test", "TestItems.toml"), "[order]\nfirst = [\"c1\"]\n")
        @test why_column(History(seconds, Dict{String, Int}(), 0.0))["c1"] == "[order] first"
    end

    @testset "the table is in the order the run would start the items, and says where" begin
        rows(p) = filter(l -> occursin("_test.jl:", l), split(sprint(print_plan, p), '\n'))
        worker(l) = match(r"·\s+(w\d+) ·", l).captures[1]
        # Nothing recorded, so every item counts the same: the pinned item goes to
        # the first worker to ask, and the second starts its own stretch meanwhile,
        # rather than waiting for the first worker's whole stretch to be listed.
        r = rows(make_plan(; workers=2))
        @test length(r) == 6
        @test [parse(Int, match(r"^\s*(\d+) ·", l).captures[1]) for l in r] == 1:6
        @test occursin("\"slow thing\"", r[1]) && worker(r[1]) == "w1"
        @test worker(r[2]) == "w2"
        @test sort(unique(worker.(r))) == ["w1", "w2"]
        # Each item once, and a chain's members one after the other on one worker.
        @test sort([match(r"\"(.*?)\"", l).captures[1] for l in r]) == sort([i.name for i in read_items()])
        one, two = findfirst(l -> occursin("chain one", l), r), findfirst(l -> occursin("chain two", l), r)
        @test one < two && worker(r[one]) == worker(r[two])
        # In a run without workers the items run in plan order, and there is no
        # worker to name.
        p = make_plan(; workers=0)
        r = rows(p)
        @test [match(r"\"(.*?)\"", l).captures[1] for l in r] == [p.items.name[i] for i in 1:nitems(p)]
        @test !any(l -> occursin(r"· w\d+", l), r)
    end
end
