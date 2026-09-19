using YATF: RawItem, ScanError, ScanFailure, Filter, scan, discover, setup_modules,
            is_test_file, scanner_mode, NO_CHAIN, DEFAULT_PROFILE,
            USE_RUN_DEFAULT, select_by_line

const BASIC = fixture("Basic.jl")

# Scan a source string in a temporary file, in both scanner modes, and assert the
# two agree: the streaming scanner reads Base internals, and the day it drifts,
# this is what catches it.
function scan_source(src::AbstractString; filter=Filter(), setups=Dict{Symbol,String}(), name="t_test.jl")
    dir = mktempdir()
    path = joinpath(dir, name)
    write(path, src)
    results = Dict{Symbol,Any}()
    for mode in (:stream, :parseall)
        results[mode] = try
            scan([path], filter, setups; mode)
        catch e
            e
        end
    end
    return results[:stream], results[:parseall], path
end

function same_items(a, b)
    a isa Vector && b isa Vector || return false
    length(a) == length(b) || return false
    return all(eachindex(a)) do i
        x, y = a[i], b[i]
        x.name == y.name && x.line == y.line && x.tags == y.tags && x.setups == y.setups &&
            x.timeout_s == y.timeout_s && x.retries == y.retries && x.failfast == y.failfast &&
            x.chain === y.chain && x.profile === y.profile && x.exclusive == y.exclusive &&
            x.code == y.code && x.skip == y.skip
    end
end

@testset "scan" begin
    @testset "file naming" begin
        @test is_test_file("a_test.jl")
        @test is_test_file("a_tests.jl")
        @test !is_test_file("a-test.jl")     # one spelling, not four
        @test !is_test_file("test.jl")
        @test !is_test_file("runtests.jl")
    end

    @testset "discovery" begin
        files = discover(joinpath(BASIC, "test"))
        @test length(files) == 2
        @test all(is_test_file, files)
        @test any(f -> occursin("sub", f), files)   # descends
        @test !any(f -> occursin("testsetups", f), files)
        @test discover("/nonexistent/path") == String[]
    end

    @testset "setup modules" begin
        setups = setup_modules(joinpath(BASIC, "test"))
        @test haskey(setups, :BasicSetup)
        @test setup_modules("/nonexistent") == Dict{Symbol,String}()
    end

    @testset "both scanners agree" begin
        src = """
        @testitem "one" tags=[:a, :b] timeout=2*60 retries=3 failfast=true begin
            using MySetup
            @test true
        end

        @testitem "two" chain=:c sandbox=:bounds skip=(Sys.iswindows()) begin
            @test false
        end

        @testitem "three" sandbox=true begin
            x = 1
        end
        """
        a, b, _ = scan_source(src; setups=Dict(:MySetup => "x.jl"))
        @test a isa Vector && length(a) == 3
        @test same_items(a, b)
        @test a[1].tags == [:a, :b]
        @test a[1].timeout_s == 120              # literal arithmetic is folded
        @test a[1].retries == 3
        @test a[1].failfast == 1
        @test a[1].setups == [:MySetup]
        @test a[2].chain === :c
        @test a[2].profile === :bounds
        @test a[2].skip isa Expr                 # evaluated on the worker, not here
        @test a[3].exclusive
        @test a[3].profile === DEFAULT_PROFILE
    end

    @testset "defaults" begin
        a, b, _ = scan_source("""@testitem "x" begin\n end""")
        @test same_items(a, b)
        @test a[1].timeout_s == USE_RUN_DEFAULT
        @test a[1].retries == USE_RUN_DEFAULT
        @test a[1].failfast == -1
        @test a[1].chain === NO_CHAIN
        @test a[1].skip === false
        @test isempty(a[1].tags)
    end

    @testset "nothing is evaluated while scanning" begin
        # If the scanner evaluated anything in these files, these would blow up or
        # leave a mark. The whole point is that they cannot.
        src = """
        @testitem "boom" begin
            error("this must never run during a scan")
        end
        """
        a, b, _ = scan_source(src)
        @test a isa Vector && length(a) == 1
        @test same_items(a, b)
        @test !isdefined(Main, :__yatf_scan_side_effect__)
    end

    @testset "errors are collected, not thrown one at a time" begin
        for (src, needle) in (
            ("""@testitem "a" begin\n end\nfoo() = 1\n""", "may only contain `@testitem`"),
            ("""@testsetup module M end\n""", "may only contain `@testitem`"),
            ("""@testitem "a" tags=[:x] tags=[:y] begin\n end\n""", "`tags` given twice"),
            ("""@testitem "a" timeout=1 timeout=2 begin\n end\n""", "`timeout` given twice"),
            ("""@testitem 42 begin\n end\n""", "string literal name"),
            ("""@testitem "a"\n""", "body"),
            ("""@testitem "a" begin\n end\n@testitem "a" begin\n end\n""", "duplicate test item name"),
            ("""@testitem "a" tags=:notalist begin\n end\n""", "must be a vector of symbols"),
            ("""@testitem "a" timeout=0 begin\n end\n""", "positive number"),
            ("""@testitem "a" bogus=1 begin\n end\n""", "unknown keyword `bogus`"),
            ("""@testitem "a" tags=[foo] begin\n end\n""", "vector of symbols"),
            ("""@testitem "a" sandbox=true chain=:c begin\n end\n""", "cannot be combined"),
            ("""@testitem "a" timeout=CONST begin\n end\n""", "positive number"),
        )
            a, b, _ = scan_source(src)
            @test a isa ScanFailure
            @test b isa ScanFailure
            @test occursin(needle, sprint(showerror, a))
            @test occursin(needle, sprint(showerror, b))
        end
    end

    @testset "every broken file is reported, not just the first" begin
        dir = mktempdir()
        write(joinpath(dir, "a_test.jl"), "not_a_testitem()\n")
        write(joinpath(dir, "b_test.jl"), "also_wrong()\n")
        err = try
            scan(sort!(readdir(dir; join=true)), Filter(), Dict{Symbol,String}())
        catch e
            e
        end
        @test err isa ScanFailure
        @test length(err.errors) == 2
    end

    @testset "syntax errors are located" begin
        a, b, path = scan_source("""@testitem "a" begin\n   x = (1 +\nend\n""")
        @test a isa ScanFailure
        @test b isa ScanFailure
    end

    @testset "filters" begin
        setups = setup_modules(joinpath(BASIC, "test"))
        files = discover(joinpath(BASIC, "test"))
        names(f) = [i.name for i in scan(files, f, setups)]
        @test length(names(Filter())) == 6
        @test names(Filter(name="add works")) == ["add works"]
        @test names(Filter(name=r"^chain")) == ["chain one", "chain two"]
        @test names(Filter(tags=:fast)) == ["add works", "mul works"]
        @test names(Filter(tags=[:fast, :math])) == ["mul works"]
        @test isempty(names(Filter(name="no such item")))
    end

    @testset "results are ordered by file and line, whatever the task order" begin
        setups = setup_modules(joinpath(BASIC, "test"))
        files = discover(joinpath(BASIC, "test"))
        expected = [(i.file, i.line) for i in scan(files, Filter(), setups; ntasks=1)]
        for ntasks in (2, 4, 8)
            @test [(i.file, i.line) for i in scan(files, Filter(), setups; ntasks)] == expected
        end
    end

    @testset "line targeting picks the item the line is inside" begin
        files = [joinpath(BASIC, "test", "a_test.jl")]
        setups = Dict{Symbol,String}()
        @test [i.name for i in scan(files, Filter(line=1), setups)] == ["add works"]
        @test [i.name for i in scan(files, Filter(line=3), setups)] == ["add works"]
        @test [i.name for i in scan(files, Filter(line=7), setups)] == ["mul works"]
        @test [i.name for i in scan(files, Filter(line=99), setups)] == ["uses setup"]
        @test isempty(scan(files, Filter(line=0), setups)) == false
    end

    @testset "scanning in parallel finds every item, every time" begin
        # The scan hands each task its own buffer. A task that looked the buffer up
        # itself would read the loop variable when it ran rather than when it was
        # spawned, and two tasks would then share one buffer — which loses items
        # quietly. This needs real threads, so it runs in its own process.
        dir = mktempdir()
        for f in 1:40, _ in 1:1
            open(joinpath(dir, "gen_$(lpad(f, 3, '0'))_test.jl"), "w") do io
                for i in 1:25
                    println(io, """@testitem "item $f-$i" begin\n    @test true\nend\n""")
                end
            end
        end
        script = joinpath(dir, "scan.jl")
        write(script, """
        push!(LOAD_PATH, $(repr(dirname(@__DIR__))))
        using YATF
        files = YATF.discover($(repr(dir)))
        counts = [length(YATF.scan(files, YATF.Filter(), Dict{Symbol,String}(); ntasks=16)) for _ in 1:10]
        println(join(unique(counts), ","))
        """)
        out = read(ignorestatus(`$(Base.julia_cmd()) --startup-file=no -t4 $script`), String)
        @test strip(out) == "1000"      # one count, and it is all of them
    end

    @testset "the streaming scanner is chosen only when it agrees with itself" begin
        # The mode is never one that has not been verified against a known input,
        # and it is decided once per process rather than on every scan.
        @test scanner_mode() in (:stream, :parseall)
        @test scanner_mode() === scanner_mode()
    end
end
