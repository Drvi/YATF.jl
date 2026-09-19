# The configuration matrix. Every combination of worker count, worker thread
# setting and log mode has to run the same suite to the same outcome: the three
# settings are independent, and a run must not depend on which of them it got.

using YATF: PASSED, FAILED, SKIPPED

const MIXED = fixture("Mixed.jl")

# `0` is this process, `1` is one worker with no stealing, and the third is a real
# pool. At least two, so the multi-worker path is covered on a single-threaded
# session as well.
const MATRIX_WORKERS = unique((0, 1, max(2, Threads.nthreads())))
const MATRIX_THREADS = ("1", "2,1")
const MATRIX_LOGS = (:eager, :issues, :batched)

@testset "configuration matrix" begin
    for workers in MATRIX_WORKERS, threads in MATRIX_THREADS, logs in MATRIX_LOGS
        @testset "workers=$workers threads=$(repr(threads)) logs=$logs" begin
            # What `--threads=$threads` gives a worker, as the worker sees it.
            expected = threads == "1" ? "1,0" : "2,1"
            (states, _, _), out = withenv("YATF_EXPECT_THREADS" => expected) do
                capture_run() do
                    run_states(MIXED; workers, threads, logs, monitor=false)
                end
            end

            @test states["mixed passes"] === PASSED
            @test states["mixed fails"] === FAILED
            @test states["mixed skips"] === SKIPPED
            @test states["mixed uses a setup"] === PASSED
            @test states["mixed sees its threads"] === PASSED

            # Every item announces itself once at each end, in every mode.
            @test count(" | START", out) == 5
            @test count(" | DONE", out) == 5
            @test all(l -> count(" | START", l) <= 1, eachsplit(out, '\n'))
            @test all(l -> count(" | DONE", l) <= 1, eachsplit(out, '\n'))

            # What an item printed reaches the reader, and the mode decides when.
            @test occursin("output from mixed fails", out)
            if logs === :issues
                # Only the items with something wrong say what they printed.
                @test !occursin("output from mixed passes", out)
                @test occursin("┌ Captured logs", out)
            elseif logs === :batched
                @test occursin("output from mixed passes", out)
                @test occursin("┌ Captured logs", out)
            else
                # Relayed as it happened, so there is nothing to print afterwards.
                @test occursin("output from mixed passes", out)
                @test !occursin("Captured logs", out)
            end
        end
    end
end
