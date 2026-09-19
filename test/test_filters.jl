# Subsetting a run. Name, tags, path and line each narrow what runs; they combine;
# and none of them may quietly change what the items that do run mean — a chain is
# still a chain, and forced order still holds over whatever survived.

using YATF: PASSED, prepare, nitems, NoTestsError

const SUITE = string(
    """
    @testitem "adds numbers" tags=[:fast, :math] begin
        @test 1 + 1 == 2
    end

    @testitem "multiplies numbers" tags=[:fast] begin
        @test 2 * 3 == 6
    end

    @testitem "solves slowly" tags=[:slow, :math] begin
        @test true
    end
    """
)

const CHAINED = """
@testitem "step one" tags=[:seq] chain=:c begin
    @test true
end

@testitem "step two" chain=:c begin
    @test true
end

@testitem "unrelated" begin
    @test true
end
"""

# What a selection actually resolves to, by name.
filtered(paths...; kwargs...) =
    (p = first(prepare(paths; kwargs...)); sort([p.items.name[i] for i in 1:nitems(p)]))

@testset "filters" begin
    dir = make_pkg("Filtered", "test/a_test.jl" => SUITE, "test/sub/b_test.jl" => CHAINED)

    @testset "by name, exactly or by pattern" begin
        @test filtered(dir; name="adds numbers") == ["adds numbers"]
        @test filtered(dir; name=r"numbers$") == ["adds numbers", "multiplies numbers"]
        @test_throws NoTestsError filtered(dir; name="no such item")
    end

    @testset "by tag, and an item must carry all of them" begin
        @test filtered(dir; tags=:fast) == ["adds numbers", "multiplies numbers"]
        @test filtered(dir; tags=[:fast, :math]) == ["adds numbers"]
        @test filtered(dir; tags=[:slow, :math]) == ["solves slowly"]
        @test_throws NoTestsError filtered(dir; tags=[:fast, :slow])
    end

    @testset "by path: a file, a directory, or a line inside one" begin
        @test filtered(dir, joinpath(dir, "test", "a_test.jl")) ==
            ["adds numbers", "multiplies numbers", "solves slowly"]
        @test filtered(dir, joinpath(dir, "test", "sub")) == ["step one", "step two", "unrelated"]
        # `file.jl:line` is the item that line is inside.
        @test filtered(dir, string(joinpath(dir, "test", "a_test.jl"), ":6")) == ["multiplies numbers"]
    end

    @testset "name, tags and path narrow together" begin
        @test filtered(dir, joinpath(dir, "test", "a_test.jl"); tags=:math) ==
            ["adds numbers", "solves slowly"]
        @test filtered(dir, joinpath(dir, "test", "a_test.jl"); tags=:math, name=r"^adds") ==
            ["adds numbers"]
        # A path that holds none of the tagged items is no items, not all of them.
        @test_throws NoTestsError filtered(dir, joinpath(dir, "test", "sub"); tags=:math)
    end

    @testset "selecting one item of a chain selects that item and no other" begin
        # A chain says these items may not run at the same time as each other. It
        # says nothing about any of them needing the others to have run, so a
        # selection that reaches one of them does not drag the rest in.
        @test filtered(dir; name="step two") == ["step two"]
        @test filtered(dir; tags=:seq) == ["step one"]
        @test filtered(dir, string(joinpath(dir, "test", "sub", "b_test.jl"), ":6")) == ["step two"]
    end

    @testset "what is left of a chain is still one unit" begin
        # Two of three selected still may not overlap; one of three has nothing to
        # overlap with and is an ordinary item.
        three = make_pkg("PartialChain", "test/a_test.jl" => """
        @testitem "c one" tags=[:keep] chain=:c begin
            @test true
        end
        @testitem "c two" chain=:c begin
            @test true
        end
        @testitem "c three" tags=[:keep] chain=:c begin
            @test true
        end
        """)
        p, _ = prepare((three,); tags=:keep, workers=4)
        @test sort([p.items.name[i] for i in 1:nitems(p)]) == ["c one", "c three"]
        @test length(p.units) == 1
        @test p.units.chain[1] === :c
        @test length(p.units.span[1]) == 2

        single, _ = prepare((three,); name="c two", workers=4)
        @test length(single.units) == 1
        @test length(single.units.span[1]) == 1
    end

    @testset "the run says what it selected" begin
        _, out = capture_run() do
            prepare((dir,); name="step two")
        end
        @test occursin("matching name = \"step two\"", out)
        @test occursin("found 1 test item", out)
        _, plain = capture_run() do
            prepare((dir,); tags=:fast)
        end
        @test occursin("matching tags = [:fast]", plain)
    end

    @testset "a filtered run still honours forced order" begin
        ordered = make_pkg(
            "FilteredOrder",
            "test/a_test.jl" => string(
                journal_item("one"; opts="tags=[:pick]"),
                journal_item("two"; opts="tags=[:pick]"),
                journal_item("three"),
            ),
            "test/TestItems.toml" => "[order]\nfirst = [\"two\"]\n"
        )
        rows = with_journal() do path
            states, _, _ = run_states(ordered; workers=1, tags=:pick, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
            journal(path)
        end
        @test [r.name for r in rows] == ["two", "one"]
    end

    @testset "[order] naming an item the filter removed is not an error" begin
        # Only a full run can tell a typo from an item the filter took out.
        ordered = make_pkg(
            "FilteredMissing",
            "test/a_test.jl" => SUITE,
            "test/TestItems.toml" => "[order]\nfirst = [\"solves slowly\"]\n"
        )
        @test filtered(ordered; tags=:fast) == ["adds numbers", "multiplies numbers"]
    end
end
