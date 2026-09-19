# One item of each outcome, each of them saying something on stdout, so that a run
# of this package exercises every branch of the reporting at once.

@testitem "mixed passes" begin
    using Mixed
    println("output from mixed passes")
    @test Mixed.double(21) == 42
end

@testitem "mixed fails" begin
    println("output from mixed fails")
    @test 1 == 2
end

@testitem "mixed skips" skip=true begin
    println("output from mixed skips")
    @test false
end

@testitem "mixed uses a setup" begin
    using MixedSetup
    @info "output from mixed uses a setup"
    @test MixedSetup.EXPECTED == 42
end

@testitem "mixed sees its threads" begin
    # A worker is started with the thread count the run asked for. In-process
    # there is no second process, so the count is the caller's own.
    want = get(ENV, "YATF_EXPECT_THREADS", "")
    if haskey(ENV, "YATF_WORKER") && !isempty(want)
        @test string(Threads.nthreads(:default), ",", Threads.nthreads(:interactive)) == want
    else
        @test Threads.nthreads() >= 1
    end
end
