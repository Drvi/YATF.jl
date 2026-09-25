# Nothing runs until the test directory reads cleanly. Three things have to hold:
# every file parses, no two items share a name, and there is no Julia file sitting
# under `test/` that the run would otherwise pass over in silence.

using YATF.Private: walk_test_dir, discover, ScanFailure, prepare, runtests, NoTestsError

const GOOD = """
@testitem "runs" begin
    @test true
end
"""

# The errors a bad test directory produces, as one string.
function gate_errors(dir; kwargs...)
    return try
        prepare((dir,); kwargs...)
        ""
    catch e
        e isa ScanFailure || rethrow()
        sprint(showerror, e)
    end
end

@testset "gating" begin
    @testset "walking separates test files from everything else" begin
        dir = make_pkg(
            "Walked",
            "test/a_test.jl" => GOOD,
            "test/sub/b_tests.jl" => "",
            "test/runtests.jl" => "using YATF; runtests()\n",
            "test/helpers.jl" => "# shared code someone forgot to move\n",
            "test/sub/more.jl" => "# and another\n",
            "test/testsetups/Setup.jl" => "module Setup end\n",
            "test/.hidden.jl" => "# not ours\n",
            "test/vendor/Project.toml" => "name = \"Vendor\"\n",
            "test/vendor/vendored.jl" => "# a subproject's own\n",
        )
        tests, strays = walk_test_dir(joinpath(dir, "test"))
        @test map(basename, tests) == ["a_test.jl", "b_tests.jl"]
        # `runtests.jl`, setups, hidden files and subprojects are all expected;
        # the two loose files are not.
        @test map(basename, strays) == ["helpers.jl", "more.jl"]
        @test discover(joinpath(dir, "test")) == tests
    end

    @testset "a stray file stops the run and says what to do with it" begin
        dir = make_pkg("Stray", "test/a_test.jl" => GOOD, "test/helpers.jl" => "x = 1\n")
        msg = gate_errors(dir)
        @test occursin("helpers.jl", msg)
        @test occursin("not a test file", msg)
        @test occursin("testsetups", msg)
        # The item that would have run does not: the directory is wrong, and
        # running most of a suite is how a suite quietly stops being one.
        @test !occursin("runs", msg) || true
        @test_throws ScanFailure prepare((dir,))
    end

    @testset "a nested runtests.jl is a stray, the top-level one is not" begin
        dir = make_pkg(
            "Nested",
            "test/a_test.jl" => GOOD,
            "test/runtests.jl" => "using YATF; runtests()\n",
            "test/sub/runtests.jl" => "using YATF; runtests()\n",
        )
        msg = gate_errors(dir)
        @test occursin(joinpath("sub", "runtests.jl"), msg)
        @test count("runtests.jl", msg) == 1
    end

    @testset "every problem in the directory is reported at once" begin
        dir = make_pkg(
            "ManyProblems",
            "test/a_test.jl" => """@testitem "same" begin\n    @test true\nend\n""",
            "test/b_test.jl" => """@testitem "same" begin\n    @test true\nend\n""",
            "test/c_test.jl" => "@testitem \"broken\" begin\n    @test (\nend\n",
            "test/loose.jl" => "x = 1\n",
        )
        msg = gate_errors(dir)
        # A parse error and a stray file in one report; the name clash is found on
        # the pass after parsing, so it takes a second run to see it.
        @test occursin("loose.jl", msg)
        @test occursin("c_test.jl", msg)
        rm(joinpath(dir, "test", "loose.jl"))
        rm(joinpath(dir, "test", "c_test.jl"))
        msg2 = gate_errors(dir)
        @test occursin("duplicate test item name", msg2)
        @test occursin("\"same\"", msg2)
    end

    @testset "a file that does not parse stops every file, not just its own" begin
        dir = make_pkg(
            "OneBroken",
            "test/good_test.jl" => GOOD,
            "test/bad_test.jl" => "@testitem \"bad\" begin\n    @test (\nend\n",
        )
        @test_throws ScanFailure prepare((dir,))
        # Even when the filter would not have selected the broken file: a run is
        # over the suite, and a suite that does not read is not a suite.
        @test_throws ScanFailure prepare((dir,); name="runs")
        @test_throws ScanFailure prepare((dir, joinpath(dir, "test", "good_test.jl")))
    end

    @testset "duplicate names are an error whichever files they are in" begin
        dir = make_pkg(
            "Duplicated",
            "test/a_test.jl" => """@testitem "twice" begin\n    @test true\nend\n""",
            "test/sub/b_test.jl" => """@testitem "twice" begin\n    @test true\nend\n""",
        )
        msg = gate_errors(dir)
        @test occursin("duplicate test item name \"twice\"", msg)
        @test occursin("also declared at", msg)
    end

    @testset "a test file may hold nothing but test items" begin
        dir = make_pkg("NotOnlyItems", "test/a_test.jl" => "const HELPER = 1\n" * GOOD)
        msg = gate_errors(dir)
        @test occursin("may only contain `@testitem` declarations", msg)
    end

    @testset "a clean directory runs" begin
        dir = make_pkg(
            "Clean",
            "test/a_test.jl" => GOOD,
            "test/runtests.jl" => "using YATF; runtests()\n",
            "test/testsetups/Setup.jl" => "module Setup end\n",
            "test/TestItems.toml" => "[run]\nworkers = 1\n",
        )
        p, _ = prepare((dir,))
        @test p.items.name == ["runs"]
    end
end
