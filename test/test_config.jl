using YATF.Private: read_config, ConfigError, Profile, DEFAULT_PROFILE, auto_workers

function with_toml(f, contents::AbstractString)
    dir = mktempdir()
    write(joinpath(dir, "TestItems.toml"), contents)
    return f(dir)
end

@testset "config" begin
    @testset "defaults without a TestItems.toml" begin
        cfg = read_config(mktempdir())
        @test cfg.workers >= 1
        @test cfg.timeout_s == 30 * 60
        @test cfg.retries == 0
        @test cfg.memory_threshold == 0.9
        @test !cfg.full_names   # a name too long for its column is shortened
        @test cfg.testset_name == "YATF"
        @test haskey(cfg.profiles, DEFAULT_PROFILE)
        @test isempty(cfg.order_first) && isempty(cfg.order_last)
    end

    @testset "TestItems.toml is read" begin
        with_toml("""
        [run]
        workers = 3
        timeout = 120
        retries = 2
        logs = "eager"
        full_names = true
        testset_name = "unit"

        [order]
        first = ["a"]
        last = ["z"]

        [profiles.bounds]
        julia_args = ["--check-bounds=yes"]
        threads = "4"
        env = { FOO = "1" }
        init = "using Test"
        test_end = "GC.gc(true)"
        """) do dir
            cfg = read_config(dir)
            @test cfg.workers == 3
            @test cfg.timeout_s == 120
            @test cfg.retries == 2
            @test cfg.logs === :eager
            @test cfg.full_names
            @test cfg.testset_name == "unit"
            @test cfg.order_first == ["a"] && cfg.order_last == ["z"]
            p = cfg.profiles[:bounds]
            @test p.julia_args == ["--check-bounds=yes"]
            @test p.threads == "4"
            @test p.env == ["FOO" => "1"]
            @test p.init.head === :block && !isempty(p.init.args)
            @test p.test_end.head === :block
        end
    end

    @testset "an explicit keyword beats the file" begin
        with_toml("[run]\nworkers = 3\n") do dir
            @test read_config(dir; workers=7).workers == 7
            @test read_config(dir).workers == 3
        end
    end

    @testset "coverage comes from the keyword, then YATF_COVERAGE, then the file, and says which" begin
        withenv("YATF_COVERAGE" => nothing) do
            cfg = read_config(mktempdir())
            @test !cfg.coverage && cfg.coverage_source == ""          # the default says nothing
            with_toml("[run]\ncoverage = true\n") do dir
                cfg = read_config(dir)
                @test cfg.coverage && endswith(cfg.coverage_source, "TestItems.toml")
                # `nothing` is no choice: the file's stands.
                @test read_config(dir; coverage = nothing).coverage
                withenv("YATF_COVERAGE" => "false") do
                    cfg = read_config(dir)
                    @test !cfg.coverage && cfg.coverage_source == "`YATF_COVERAGE`"
                    @test !read_config(dir; coverage = nothing).coverage
                    cfg = read_config(dir; coverage = true)
                    @test cfg.coverage && cfg.coverage_source == "the `coverage` keyword"
                end
            end
            withenv("YATF_COVERAGE" => "yes") do
                @test read_config(mktempdir()).coverage
                @test !read_config(mktempdir(); coverage = false).coverage
            end
            withenv("YATF_COVERAGE" => "maybe") do
                err = try; read_config(mktempdir()); catch e; e; end
                @test err isa ConfigError
                @test occursin("`YATF_COVERAGE` must be true or false", sprint(showerror, err))
            end
            # A process's coverage is set when it starts, so it takes a worker.
            err = try; read_config(mktempdir(); coverage = true, workers = 0); catch e; e; end
            @test err isa ConfigError
            @test occursin("`workers = 0` runs the items in this one", sprint(showerror, err))
        end
    end

    @testset "a testset name is a non-empty string" begin
        @test read_config(mktempdir(); testset_name = "integration").testset_name == "integration"
        for bad in ("", 3)
            err = try; read_config(mktempdir(); testset_name = bad); catch e; e; end
            @test err isa ConfigError
            @test occursin("`testset_name` must be a non-empty string", sprint(showerror, err))
        end
    end

    @testset "unknown keys are errors, not no-ops" begin
        for (toml, needle) in (
            ("[run]\nworkerz = 2\n", "unknown key `workerz`"),
            ("[orderr]\nfirst = []\n", "unknown key `orderr`"),
            ("[order]\nfirstt = []\n", "unknown key `firstt`"),
            ("[profiles.p]\njulia_argz = []\n", "unknown key `julia_argz`"),
        )
            with_toml(toml) do dir
                err = try; read_config(dir); catch e; e; end
                @test err isa ConfigError
                @test occursin(needle, sprint(showerror, err))
            end
        end
    end

    @testset "init expressions are parsed here, not on a worker" begin
        with_toml("[profiles.p]\ninit = \"using \"\n") do dir
            err = try; read_config(dir); catch e; e; end
            @test err isa ConfigError
            @test occursin("could not parse `init`", sprint(showerror, err))
        end
        with_toml("[profiles.p]\ntest_end = \"1 +\"\n") do dir
            @test_throws ConfigError read_config(dir)
        end
    end

    @testset "values are validated" begin
        for toml in ("[run]\nworkers = -1\n", "[run]\ntimeout = 0\n", "[run]\nretries = -1\n",
                     "[run]\nmemory_threshold = 1.5\n", "[run]\nlogs = \"loud\"\n",
                     "[run]\nworkers = \"most\"\n")
            with_toml(toml) do dir
                @test_throws ConfigError read_config(dir)
            end
        end
    end

    @testset "malformed TOML is an error with the file named" begin
        with_toml("[run\n") do dir
            err = try; read_config(dir); catch e; e; end
            @test err isa ConfigError
            @test occursin("TestItems.toml", sprint(showerror, err))
        end
    end

    @testset "auto worker count" begin
        @test auto_workers("2", 0) >= 1
        @test auto_workers("2", 1) == 1          # never more workers than there is work
        @test auto_workers("2", 100) <= 8
    end
end

@testset "the default logging style" begin
    # One worker prints as it goes; several would interleave more than a reader can
    # follow, so only the items with something wrong say anything. `:batched` is
    # never chosen for you.
    @test YATF.Private.default_logs(1, true) === :eager
    @test YATF.Private.default_logs(0, true) === :eager
    @test YATF.Private.default_logs(2, true) === :issues
    @test YATF.Private.default_logs(8, true) === :issues
    # Nothing is watching a non-interactive run as it goes.
    @test YATF.Private.default_logs(1, false) === :issues
    @test YATF.Private.default_logs(8, false) === :issues
end
