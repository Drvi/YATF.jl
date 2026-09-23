using YATF: plan, scan, discover, setup_modules, read_config, Filter, History, ConfigError,
            ScanFailure, nslots, nitems, NO_CHAIN, print_plan, RawItem, USE_RUN_DEFAULT,
            DEFAULT_PROFILE, ItemIdx

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
        @test plan(items, cfg; root=dir, strict_order=false) isa YATF.Plan
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
        q = YATF.Queues(p)
        next(s) = (c = YATF.claim!(q, s); c.kind === :unit ? p.items.name[first(p.units.span[c.unit])] : c.kind)
        @test [next(2), next(2), next(1)] == ["b2", "b1", "a2"]
        @test next(2) == "a5"                                   # the second half of a3–a6
        @test [next(1), next(1), next(1)] == ["a3", "a4", "a6"] # then the one unit slot 2 had left
        @test [next(2), next(2)] == ["a1", :done]
        # A cursor pointing at a unit already handed out is a scheduling bug, stopped
        # rather than run twice.
        q2 = YATF.Queues(p)
        q2.claimed[q2.head[1]] = true
        @test_throws ErrorException YATF.claim!(q2, 1)
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

    @testset "the plan prints" begin
        out = sprint(print_plan, make_plan())
        @test occursin("YATF plan: 6 test items", out)
        @test occursin("chain :seq", out)
        @test occursin("slow thing", out)
        @test occursin("setups=BasicSetup", out)
    end
end
