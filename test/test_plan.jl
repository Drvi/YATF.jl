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

@testset "plan" begin
    @testset "every item lands in exactly one unit on exactly one worker" begin
        p = make_plan()
        @test nitems(p) == 6
        @test length(p.units) == 5
        @test sort(dispatch_order(p)) == sort([i.name for i in read_items()])
        assigned = reduce(vcat, [slot_names(p, s) for s in 1:nslots(p)])
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
        @test all(s -> !isempty(p.slot_units[s]), 1:nslots(p))
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
                    Set(["mul works"]))
        p = make_plan(; history=h, workers=2)
        # the failure from last time is dispatched before the rest of its pool's work
        order = dispatch_order(p)
        @test findfirst(==("mul works"), order) < findfirst(==("uses setup"), order)
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
        @test length(slot_names(p, 1)) == nitems(p)
    end

    @testset "the plan prints" begin
        out = sprint(print_plan, make_plan())
        @test occursin("YATF plan: 6 test items", out)
        @test occursin("chain :seq", out)
        @test occursin("slow thing", out)
        @test occursin("setups=BasicSetup", out)
    end
end
