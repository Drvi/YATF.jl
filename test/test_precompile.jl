# What the packages precompile before a run starts.
#
# `precompile(f, types)` answers `false` when the signature matches no method and
# says nothing else, so a list of them rots silently: the build keeps paying for a
# workload that covers less and less. The build asserts, and this checks the same
# thing from a session that loaded the package out of a cache built earlier.

using YATFWorkers: precompile_or_throw

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
