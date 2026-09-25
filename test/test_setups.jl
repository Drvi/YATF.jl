# Test setups are ordinary modules under `test/testsetups/`, loaded through
# LOAD_PATH. That is the whole mechanism, and it is what lets a setup use anything
# the package declares for testing — including another setup.

using YATF.Private: PASSED, ERRORED, ConfigError, prepare, execute, nitems, setup_modules, TOML

@testset "test setups" begin
    @testset "a setup may use any of the package's test-time dependencies" begin
        pkg = fixture("TestDeps.jl")
        for workers in (0, 1)
            states, _, _ = run_states(pkg; workers, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
            @test length(states) == 3
        end
    end

    @testset "the setups an item names are the ones the run arranges for" begin
        pkg = fixture("TestDeps.jl")
        p, _ = prepare((pkg,); workers=1, logs=:issues, monitor=false)
        @test Set(p.setups) == Set([:DepSetup, :TimeSetup])
    end

    @testset "setups are precompiled once, before any worker starts" begin
        dir = make_pkg("PrecompiledSetup")
        # A module nothing has compiled before. Julia caches a setup under its own
        # name, so a fixed one would be warm from whichever earlier run of this
        # suite happened to compile it.
        setup = string("Once", string(hash(dir); base=16))
        write(joinpath(dir, "test", "a_test.jl"), """
        @testitem "uses it" begin
            using $setup
            @test $setup.value() == 7
        end
        """)
        mkpath(joinpath(dir, "test", "testsetups"))
        write(joinpath(dir, "test", "testsetups", setup * ".jl"), "module $setup\nvalue() = 7\nend\n")

        (states, _, p), out = capture_run() do
            run_states(dir; workers=2, logs=:issues, monitor=false)
        end
        @test states["uses it"] === PASSED
        @test p.setups == [Symbol(setup)]
        # One process does it, before the workers exist: without this, N workers
        # hit the same cold cache at once and serialize on Julia's precompile lock.
        @test occursin("precompiling " * setup, out)
        _, again = capture_run() do
            run_states(dir; workers=2, logs=:issues, monitor=false)
        end
        @test !occursin("precompiling", again)
    end

    @testset "setups are found as a file or as a directory" begin
        dir = make_pkg(
            "SetupShapes",
            "test/a_test.jl" => """
            @testitem "uses both" begin
                using Flat
                using Nested
                @test Flat.value() + Nested.value() == 3
            end
            """,
            "test/testsetups/Flat.jl" => "module Flat\nvalue() = 1\nend\n",
            "test/testsetups/Nested/src/Nested.jl" => "module Nested\nvalue() = 2\nend\n",
        )
        setups = setup_modules(joinpath(dir, "test"))
        @test sort(collect(keys(setups))) == [:Flat, :Nested]
        states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
        @test states["uses both"] === PASSED
    end

    @testset "a setup that will not precompile stops the run and names itself" begin
        dir = make_pkg(
            "BrokenSetup",
            "test/a_test.jl" => """
            @testitem "needs it" begin
                using Broken
                @test true
            end
            """,
            "test/testsetups/Broken.jl" => "module Broken\nerror(\"this setup is broken\")\nend\n",
        )
        err = try
            run_states(dir; workers=1, logs=:issues, monitor=false)
            nothing
        catch e
            e
        end
        @test err isa ConfigError
        msg = sprint(showerror, err)
        @test occursin("Broken", msg)
        @test occursin("failed to precompile", msg)
        # The reason, not just the fact.
        @test occursin("this setup is broken", msg)
    end

    @testset "a module that is not a setup is an ordinary load failure" begin
        # Nothing under `testsetups/` is named `Absent`, so this is not a setup the
        # run has to arrange for: it is the item asking for a package it has not got.
        dir = make_pkg("NoSuchSetup", "test/a_test.jl" => """
        @testitem "asks for a package it has not got" begin
            using Absent
            @test true
        end
        """)
        p, target = prepare((dir,); workers=1, logs=:issues, monitor=false)
        @test isempty(p.setups)
        states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
        @test states["asks for a package it has not got"] === ERRORED
    end

    @testset "the setups directory is left off LOAD_PATH afterwards" begin
        before = copy(LOAD_PATH)
        run_states(fixture("TestDeps.jl"); workers=1, logs=:issues, monitor=false)
        @test LOAD_PATH == before
    end
end

@testset "setups as packages" begin
    stdlib_uuid(name) = TOML.parsefile(joinpath(Sys.STDLIB, name, "Project.toml"))["uuid"]
    # A setup that reads a file beside `testsetups/`, one that imports it, and an item
    # that uses both: what making them packages has to keep working.
    convertible() = make_pkg(
        "SetupPkgs",
        "test/a_test.jl" => """
        @testitem "uses both" begin
            using Uses, Helpers
            @test Uses.two() == 2
            @test Helpers.DATA == "beside the setups"
            @test basename(Helpers.here()) == "testsetups"
            @test basename(Uses.HERE) == "testsetups"
        end
        """,
        "test/data.txt" => "beside the setups",
        "test/testsetups/Helpers.jl" => """
        module Helpers
        using Random
        using SetupPkgs
        # Read from the directory above this one, @__DIR__/..
        const DATA = read(joinpath(@__DIR__, "..", "data.txt"), String)
        const WHERE = "@__DIR__"
        here() = @__DIR__()
        value() = 1
        end
        """,
        "test/testsetups/Uses.jl" => """
        "One more than `Helpers` has."
        module Uses
        using Helpers: value
        import Dates
        const HERE = @__DIR__
        two() = value() + 1
        end
        """,
    )

    @testset "each setup moves into a package of its own, and items load it as before" begin
        dir = convertible()
        setups = joinpath(dir, "test", "testsetups")
        _, out = capture_run(() -> YATF.setups_to_packages(dir))
        for name in ("Helpers", "Uses")
            @test isfile(joinpath(setups, name, "src", name * ".jl"))
            @test !ispath(joinpath(setups, name * ".jl"))
        end
        project = joinpath(setups, "Helpers", "Project.toml")
        @test startswith(read(project, String), "name = \"Helpers\"\nuuid = ")
        helpers = TOML.parsefile(project)
        uses = TOML.parsefile(joinpath(setups, "Uses", "Project.toml"))
        # What each imports: a standard library, the package under test, another setup.
        @test helpers["deps"] == Dict(
            "Random" => stdlib_uuid("Random"),
            "SetupPkgs" => TOML.parsefile(joinpath(dir, "Project.toml"))["uuid"],
        )
        # `Uses` imports the package under test only to name its directory.
        @test uses["deps"] == Dict("Dates" => stdlib_uuid("Dates"), "Helpers" => helpers["uuid"],
                                   "SetupPkgs" => helpers["deps"]["SetupPkgs"])
        @test helpers["uuid"] != uses["uuid"]
        # `@__DIR__` in code is the package's `test/testsetups/`, by the name the setup
        # gives the package; in a comment or a string it is text.
        code = read(joinpath(setups, "Helpers", "src", "Helpers.jl"), String)
        @test occursin("read(pkgdir(SetupPkgs, \"test\", \"data.txt\"), String)", code)
        @test occursin("here() = pkgdir(SetupPkgs, \"test\", \"testsetups\")\n", code)
        @test occursin("# Read from the directory above this one, @__DIR__/..", code)
        @test occursin("const WHERE = \"@__DIR__\"", code)
        code = read(joinpath(setups, "Uses", "src", "Uses.jl"), String)
        @test occursin("module Uses\nimport SetupPkgs\nusing Helpers: value\n", code)
        @test occursin("const HERE = pkgdir(SetupPkgs, \"test\", \"testsetups\")\n", code)
        @test occursin(
            "`Helpers`: moved to $(joinpath("Helpers", "src", "Helpers.jl")) · `@__DIR__` rewritten 2× · " *
                "deps: Random, SetupPkgs",
            out
        )
        @test occursin(
            "`Uses`:    moved to $(joinpath("Uses", "src", "Uses.jl")) · `@__DIR__` rewritten 1× · " *
                "`import SetupPkgs` added · deps: Dates, Helpers, SetupPkgs",
            out
        )
        # A package, and so a cache filed under its UUID.
        YATF.Private.with_load_path(setups) do
            @test Base.identify_package("Helpers") == Base.PkgId(Base.UUID(helpers["uuid"]), "Helpers")
        end
        for workers in (0, 1)
            states, _, _ = run_states(dir; workers, logs=:issues, monitor=false)
            @test states["uses both"] === PASSED
        end
    end

    @testset "run again, it adds what a setup has come to import and changes nothing else" begin
        dir = convertible()
        setups = joinpath(dir, "test", "testsetups")
        capture_run(() -> YATF.setups_to_packages(dir))
        project = joinpath(setups, "Uses", "Project.toml")
        helpers = read(joinpath(setups, "Helpers", "Project.toml"), String)
        before = read(project, String)
        _, out = capture_run(() -> YATF.setups_to_packages(dir))
        @test read(project, String) == before
        @test occursin("`Uses`:    up to date", out)
        # A dependency added by hand stays, and an import added since is added.
        entry = joinpath(setups, "Uses", "src", "Uses.jl")
        write(entry, replace(read(entry, String), "import Dates" => "import Dates\nusing Test"))
        toml = TOML.parsefile(project)
        toml["deps"]["Logging"] = stdlib_uuid("Logging")
        open(io -> TOML.print(io, toml), project, "w")
        _, out = capture_run(() -> YATF.setups_to_packages(dir))
        after = TOML.parsefile(project)
        @test after["uuid"] == toml["uuid"]
        @test after["deps"] == merge(toml["deps"], Dict("Test" => stdlib_uuid("Test")))
        @test occursin("`Uses`:    added to deps: Test", out)
        @test read(joinpath(setups, "Helpers", "Project.toml"), String) == helpers
    end

    @testset "nothing is written unless every setup can be made a package" begin
        dir = make_pkg(
            "UnconvertibleSetups",
            "test/testsetups/Fine.jl" => "module Fine\nusing Random\nend\n",
            "test/testsetups/Unknown.jl" => "module Unknown\nusing NotInTheEnvironment\nend\n",
            "test/testsetups/Relative.jl" => "module Relative\ninclude(\"helpers.jl\")\nend\n",
            "test/testsetups/OwnFile.jl" => "module OwnFile\nconst F = @__FILE__\nend\n",
            "test/testsetups/Misnamed.jl" => "module SomethingElse\nend\n",
            "test/testsetups/Clash.jl" => "module Clash\nend\n",
            "test/testsetups/Clash/notes.txt" => "not a setup\n",
            "test/testsetups/Stale/src/Stale.jl" => "module Stale\nusing Random\nend\n",
            "test/testsetups/Stale/Project.toml" =>
                "name = \"Stale\"\n\n[deps]\nRandom = \"00000000-0000-0000-0000-000000000001\"\n",
            "test/testsetups/Renamed/src/Renamed.jl" => "module Renamed\nend\n",
            "test/testsetups/Renamed/Project.toml" => "name = \"Other\"\n",
        )
        setups = joinpath(dir, "test", "testsetups")
        listing() = sort([relpath(joinpath(d, f), setups) for (d, _, fs) in walkdir(setups) for f in fs])
        before = listing()
        err = try
            YATF.setups_to_packages(dir)
            nothing
        catch e
            e
        end
        @test err isa ConfigError
        msg = sprint(showerror, err)
        at(name) = joinpath("test", "testsetups", name)
        @test occursin("$(at("Unknown.jl")): imports `NotInTheEnvironment`, which neither", msg)
        @test occursin("$(at("Relative.jl")):2: `include` of a relative path", msg)
        @test occursin("$(at("OwnFile.jl")):2: `@__FILE__` would change with the move", msg)
        @test occursin("$(at("Misnamed.jl")): does not define `module Misnamed`", msg)
        @test occursin("$(at("Clash.jl")): `Clash/` is there as well", msg)
        @test occursin("$(at(joinpath("Stale", "Project.toml"))): lists `Random` as 00000000-0000-0000-0000-000000000001; " *
                       "it is $(stdlib_uuid("Random"))", msg)
        @test occursin("$(at(joinpath("Renamed", "Project.toml"))): names the package `Other`, not `Renamed`", msg)
        @test !occursin("Fine", msg)
        @test listing() == before
    end

    @testset "a moved setup's `@__DIR__` becomes `pkgdir`, however it is written" begin
        relocated(code) = first(YATF.Private.relocate(code, Meta.parseall(code), "S", "MyPkg"))
        # By the name the setup already gives the package.
        @test relocated("module S\nimport MyPkg as P\nconst D = @__DIR__\nend\n") ==
              "module S\nimport MyPkg as P\nconst D = pkgdir(P, \"test\", \"testsetups\")\nend\n"
        # The `".."`s fold as far as the package's root and no further.
        @test relocated("module S\nusing MyPkg\nf(x) = joinpath(@__DIR__, \"..\", \"..\", \"..\", x)\nend\n") ==
              "module S\nusing MyPkg\nf(x) = pkgdir(MyPkg, \"..\", x)\nend\n"
        # A call written over several lines.
        @test relocated("module S\nusing MyPkg\nf() = joinpath(\n    @__DIR__,\n    \"..\",\n    \"data\",\n)\nend\n") ==
              "module S\nusing MyPkg\nf() = pkgdir(MyPkg, \"test\",\n    \"data\",\n)\nend\n"
        # Inside an interpolation it is code. Without an import of the package, one is
        # added, indented as the module's body is.
        @test relocated("module S\n    p = \"\$(@__DIR__)/x\"\nend\n") ==
              "module S\n    import MyPkg\n    p = \"\$(pkgdir(MyPkg, \"test\", \"testsetups\"))/x\"\nend\n"
        # A body that goes on on the module's own line gets the import first in it,
        # inside the module; evaluated, the setup finds the directory it was in.
        for (code, expected) in (
                "module S; p = @__DIR__; end\n" => "module S; import MyPkg; p = pkgdir(MyPkg, \"test\", \"testsetups\"); end\n",
                "module S p = @__DIR__ end\n" => "module S; import MyPkg; p = pkgdir(MyPkg, \"test\", \"testsetups\") end\n",
            )
            @test relocated(code) == expected
            yatf = replace(code, "S" => "Setup")
            m = Module()
            Core.eval(m, Meta.parseall(first(YATF.Private.relocate(yatf, Meta.parseall(yatf), "Setup", "YATF"))))
            @test Core.eval(m, :(Setup.p)) == pkgdir(YATF, "test", "testsetups")
        end
    end

    @testset "a relative include is found however it is spaced" begin
        hazards(code) = last(YATF.Private.relocate(code, Meta.parseall(code), "S", "MyPkg"))
        for call in ("include(\"helper.jl\")", "include( \"helper.jl\")", "include(\n    \"helper.jl\",\n)")
            @test length(hazards("module S\n$call\nend\n")) == 1
        end
        @test isempty(hazards("module S\ninclude(\"/abs/helper.jl\")\nend\n"))
        @test isempty(hazards("module S\ninclude(joinpath(@__DIR__, \"helper.jl\"))\nend\n"))
    end

    @testset "every module a setup imports from outside is found" begin
        ex = Meta.parseall("""
        using A, B.C
        using D.E: f
        import G as H
        import I.J as K
        import L: m as n
        using .Relative, ..Parent
        @reexport using M
        module Inner
            using N
        end
        f() = @eval using O
        """)
        @test YATF.Private.imported_roots(ex) == Set([:A, :B, :D, :G, :I, :L, :M, :N, :O])
    end

    @testset "a package without setups is left as it is" begin
        dir = make_pkg("NoSetups")
        _, out = capture_run(() -> YATF.setups_to_packages(dir))
        @test occursin("no setups in $(joinpath("test", "testsetups"))", out)
        @test !ispath(joinpath(dir, "test", "testsetups"))
    end
end
@testset "profile preferences" begin
    @testset "a profile's preferences reach the items that run under it" begin
        dir = make_pkg("PrefProfile")
        # A package the test environment can see, which reads a preference when it
        # is compiled.
        pkgdir = joinpath(dir, "PrefTarget")
        mkpath(joinpath(pkgdir, "src"))
        u = "9f2b1c3d-0000-4000-8000-00000000abcd"
        write(joinpath(pkgdir, "Project.toml"),
              "name = \"PrefTarget\"\nuuid = \"$u\"\nversion = \"0.1.0\"\n")
        write(joinpath(pkgdir, "src", "PrefTarget.jl"), """
        module PrefTarget
        const UUID = Base.UUID("$u")
        Base.record_compiletime_preference(UUID, "mode")
        const MODE = get(Base.get_preferences(UUID), "mode", "unset")
        end
        """)
        write(joinpath(dir, "prefs.toml"), "[PrefTarget]\nmode = \"fast\"\n")
        write(joinpath(dir, "test", "TestItems.toml"), """
        [profiles.tuned]
        preferences = "../prefs.toml"
        """)
        write(joinpath(dir, "test", "t_test.jl"), """
        @testitem "default sees no preference" begin
            using PrefTarget
            @test PrefTarget.MODE == "unset"
        end
        @testitem "tuned sees it" sandbox=:tuned begin
            using PrefTarget
            @test PrefTarget.MODE == "fast"
        end
        """)
        Pkg = Base.require(Base.PkgId(Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))
        orig = Base.active_project()
        Pkg.activate(dir; io=devnull)
        Pkg.develop(path=pkgdir; io=devnull)
        Pkg.activate(orig; io=devnull)

        states, run, _ = run_states(dir; workers=2, logs=:issues, monitor=false)
        @test states["default sees no preference"] === PASSED
        @test states["tuned sees it"] === PASSED
        # The tuned profile ran in a project of its own, carrying the same manifest.
        proj = run.profile_projects[:tuned]
        @test isfile(joinpath(proj, "Manifest.toml"))
        @test occursin("fast", read(joinpath(proj, "LocalPreferences.toml"), String))
        # Every package that manifest names is findable from where it now sits.
        for entries in values(YATF.Private.TOML.parsefile(joinpath(proj, "Manifest.toml"))["deps"])
            for entry in entries
                haskey(entry, "path") && @test isdir(joinpath(proj, entry["path"]))
            end
        end
    end

    @testset "a profile's project finds every package the environment found" begin
        # The copy sits a directory below the environment it is taken from, so a
        # path written relative to the environment names the wrong place from
        # there — and Pkg writes a relative one for any package it reached through
        # another package's checkout, which is how a developed package is reached.
        base = mktempdir()
        env = joinpath(base, "env")
        outside = joinpath(base, "Outside")
        inside = joinpath(env, "Inside")
        foreach(mkpath, (env, outside, inside))
        write(joinpath(env, "Project.toml"), """
        [deps]
        Outside = "11111111-0000-4000-8000-000000000001"

        [sources]
        Outside = {path = "../Outside"}
        """)
        write(joinpath(env, "Manifest.toml"), """
        julia_version = "1.13.0"
        manifest_format = "2.0"
        project_hash = "6aba1e0a1b0ee9b0cb2b0b0e2d0e7e9f0a0b0c0d"

        [[deps.Outside]]
        uuid = "11111111-0000-4000-8000-000000000001"
        path = "../Outside"
        version = "0.1.0"

        [[deps.Inside]]
        uuid = "11111111-0000-4000-8000-000000000002"
        path = "Inside"
        version = "0.2.0"

        [[deps.Fixed]]
        uuid = "11111111-0000-4000-8000-000000000003"
        path = '$(base)'
        version = "0.3.0"

        [[deps.Itself]]
        uuid = "11111111-0000-4000-8000-000000000004"
        path = "."
        version = "0.4.0"
        """)
        dir = joinpath(env, "yatf_profile_tuned")
        mkpath(dir)
        YATF.Private.copy_env_files(dir, env)

        manifest = YATF.Private.TOML.parsefile(joinpath(dir, "Manifest.toml"))
        paths = Dict(name => only(entries)["path"] for (name, entries) in manifest["deps"])
        @test realpath(paths["Outside"]) == realpath(outside)
        @test realpath(paths["Inside"]) == realpath(inside)
        @test realpath(paths["Fixed"]) == realpath(base)
        @test realpath(paths["Itself"]) == realpath(env)
        # Read from the copy's own directory, which is what a worker does.
        @test all(p -> isdir(joinpath(dir, p)), values(paths))
        # An environment's own package is written `.`; the copy names a directory,
        # not a directory with a separator after it.
        @test !isdirpath(paths["Itself"])
        # Everything else crosses as it was, versions and the manifest's own keys.
        @test manifest["manifest_format"] == "2.0"
        @test manifest["julia_version"] == "1.13.0"
        @test manifest["project_hash"] == "6aba1e0a1b0ee9b0cb2b0b0e2d0e7e9f0a0b0c0d"
        @test only(manifest["deps"]["Inside"])["version"] == "0.2.0"
        @test only(manifest["deps"]["Inside"])["uuid"] ==
            "11111111-0000-4000-8000-000000000002"
        # A `[sources]` path is read relative to the project file, so it moves too.
        sources = YATF.Private.TOML.parsefile(joinpath(dir, "Project.toml"))["sources"]
        @test realpath(sources["Outside"]["path"]) == realpath(outside)
    end

    @testset "a preferences file that is missing or broken is a config error" begin
        dir = make_pkg("BadPrefs", "test/t_test.jl" => """
        @testitem "x" begin
            @test true
        end
        """, "test/TestItems.toml" => "[profiles.p]\npreferences = \"nope.toml\"\n")
        @test_throws YATF.ConfigError YATF.Private.prepare((dir,); workers=1, monitor=false)
    end
end
