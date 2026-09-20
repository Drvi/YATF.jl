# What the packages precompile before a run starts.
#
# `precompile(f, types)` answers `false` when the signature matches no method and
# says nothing else, so a list of them rots silently: the build keeps paying for a
# workload that covers less and less. The build asserts, and this checks the same
# thing from a session that loaded the package out of a cache built earlier.

using YATFWorkers: precompile_or_throw
using YATF: PASSED

@testset "precompile coverage" begin
    @testset "every signature the packages list still names a method" begin
        for (f, types) in YATF.PRECOMPILE_SIGNATURES
            @test precompile(f, types)
        end
        for (f, types) in YATFWorkers.PRECOMPILE_SIGNATURES
            @test precompile(f, types)
        end
        @test !isempty(YATF.PRECOMPILE_SIGNATURES)
        @test !isempty(YATFWorkers.PRECOMPILE_SIGNATURES)
    end

    @testset "a signature that names no method is an error, not a shrug" begin
        @test precompile_or_throw(identity, (Int,)) === nothing
        # A method that does not exist.
        @test_throws ErrorException precompile_or_throw(YATF.nitems, (String,))
        # An abstract argument the compiler declines to specialize for, which is
        # why `with_test_env` is not on the list: it takes a closure. If this ever
        # stops throwing the compiler has got better and the signature belongs on
        # the list, so the failure is the notification.
        @test_throws ErrorException precompile_or_throw(
            YATF.with_test_env, (Function, YATF.Target, Any)
        )
    end

    @testset "the run state and the report shapes are covered by the workload" begin
        # These run for real while the package is built rather than being named as
        # signatures, so what this checks is that they are still callable the way
        # the workload calls them.
        dir = mktempdir()
        p = first(YATF.prepare((fixture("Basic.jl"),); workers=1, monitor=false))
        path = joinpath(dir, "covered.yatf")
        rsf = YATF.init_run_state(path, p)
        YATF.write_status!(rsf, 1, YATF.RUNNING, 1, 1)
        YATF.write_status!(rsf, 1, YATF.PASSED, 1, 1; elapsed=0.1, compile=0.05)
        YATF.write_memory!(rsf, YATF.MemStats())
        YATF.finish_run_state!(rsf)
        @test YATF.read_run_state(path) !== nothing

        buf = IOBuffer()
        YATF.print_bytes(buf, 3.5 * 2^30, YATF.BYTES_WIDTH)
        YATF.print_1dp(buf, 2.5, 4)
        YATF.print_int(buf, 42, 4)
        @test !isempty(String(take!(buf)))
        @test YATF.item_log_path("/precompile/item_", 1, 1) == "/precompile/item_1_1.log"
    end
end

@testset "the precompile stage and the workers" begin
    # A setup module nothing has compiled before, used by one item under the
    # default profile and one under julia flags of its own.
    dir = make_pkg("SetupCache")
    setup = string("Shared", string(hash(dir); base=16))
    mkpath(joinpath(dir, "test", "testsetups"))
    write(joinpath(dir, "test", "testsetups", setup * ".jl"),
          "module $setup\n" * join(["f$i(x) = x + $i" for i in 1:200], "\n") * "\nend\n")
    write(joinpath(dir, "test", "TestItems.toml"),
          "[profiles.bounds]\njulia_args = [\"--check-bounds=yes\"]\n")

    # A setup module is loaded from a file rather than as a registered package, so
    # its cache is a flat `<name>*.ji` beside the package directories, not inside
    # one of them.
    cache_root = joinpath(Base.DEPOT_PATH[1], "compiled", "v$(VERSION.major).$(VERSION.minor)")
    caches() = filter(f -> startswith(f, setup) && endswith(f, ".ji"), readdir(cache_root))

    @testset "a worker on the same flags reuses what the stage compiled" begin
        write(joinpath(dir, "test", "a_test.jl"), """
        @testitem "plain" begin
            using $setup
            @test $setup.f1(1) == 2
        end
        """)
        @test isempty(caches())
        _, out = capture_run() do
            states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
        end
        @test occursin("precompiling $setup", out)
        # One cache, written by the stage and loaded by the worker. A worker that
        # had to compile it again would write a second one under its own flags.
        @test length(caches()) == 1
    end

    @testset "a profile with other julia flags undoes the stage's work" begin
        # `--check-bounds=yes` changes code generation, so a worker under it will
        # not accept a cache compiled without it. A setup module has no UUID, so
        # Julia keys its cache by name alone with no room for the flags — the
        # worker recompiles into the same file and the next run under the ordinary
        # flags finds it stale. See `issues/setup-cache-collisions.md`.
        write(joinpath(dir, "test", "a_test.jl"), """
        @testitem "checked" sandbox=:bounds begin
            using $setup
            @test $setup.f1(1) == 2
            @test Base.JLOptions().check_bounds == 1
        end
        """)
        @test length(caches()) == 1
        states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
        @test all(==(PASSED), values(states))
        # One file still: the two sets of flags have nowhere separate to live.
        @test length(caches()) == 1

        # ...and what it now holds is no good to the ordinary flags, so the stage
        # runs again. This assertion documents the cost, and should be deleted by
        # whoever removes it.
        write(joinpath(dir, "test", "a_test.jl"), """
        @testitem "plain" begin
            using $setup
            @test $setup.f1(1) == 2
        end
        """)
        _, out = capture_run() do
            run_states(dir; workers=1, logs=:issues, monitor=false)
        end
        @test occursin("precompiling $setup", out)
    end
end

@testset "the test environment is precompiled for the profiles' flags" begin
    # Every item's module loads the package under test, so a pool with julia
    # arguments of its own needs that package — and everything it depends on —
    # compiled again under those flags. Doing it here makes one parallel pass of
    # what would otherwise happen inside the first worker of the pool, serially
    # and with nothing printed while the run appears to sit on its first item.

    @testset "the flags come from a process started the same way" begin
        @test YATF.cache_flags_for(``) == Base.CacheFlags()
        @test YATF.cache_flags_for(`--check-bounds=yes`).check_bounds == 1
        @test YATF.cache_flags_for(`--check-bounds=yes`) != Base.CacheFlags()
    end

    @testset "only profiles that change the cache flags are precompiled" begin
        # `bounds` changes code generation; `quiet` does not, so its workers can
        # use what this process already compiled and asking for it again would be
        # a whole environment's worth of work for no cache entry.
        dir = make_pkg(
            "ProfilePrecompile",
            "test/t_test.jl" => """
            @testitem "plain" begin
                @test true
            end
            @testitem "checked" sandbox=:bounds begin
                @test Base.JLOptions().check_bounds == 1
            end
            @testitem "hushed" sandbox=:quiet begin
                @test true
            end
            """,
            "test/TestItems.toml" => """
            [profiles.bounds]
            julia_args = ["--check-bounds=yes"]

            [profiles.quiet]
            julia_args = ["--banner=no"]
            """
        )
        states, _, _ = nothing, nothing, nothing
        _, out = capture_run() do
            states, _, _ = run_states(dir; workers=3, logs=:issues, monitor=false)
        end
        @test all(==(PASSED), values(states))
        line = only(filter(l -> occursin("precompiling the test environment", l),
                           collect(eachsplit(out, '\n'))))
        @test occursin("bounds", line)
        @test !occursin("quiet", line)
        @test occursin("1 profile", line)
    end

    @testset "a run with no profile flags says nothing about it" begin
        dir = make_pkg("NoProfilePrecompile", "test/t_test.jl" => """
        @testitem "plain" begin
            @test true
        end
        """)
        _, out = capture_run() do
            states, _, _ = run_states(dir; workers=1, logs=:issues, monitor=false)
            @test all(==(PASSED), values(states))
        end
        @test !occursin("precompiling the test environment", out)
    end
end
