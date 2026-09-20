# YATF's own tests use plain Test.jl, not YATF: a test framework that can only be
# tested by itself cannot be trusted at the moment it is broken. For the same
# reason the files are run in plain subprocesses rather than on YATF's own worker
# pool — a bug in the transport would stop the suite from running instead of
# telling you which test it broke.
#
#     julia --project test/runtests.jl                 every file, in parallel
#     julia --project test/runtests.jl test_scan.jl    one file, in this process
#     YATF_TEST_JOBS=1 julia --project test/runtests.jl   every file, in this process
#
# Each file is independent: it builds the fixtures it needs and asserts only on
# what it built.

using Test
using YATF

const FIXTURES = joinpath(@__DIR__, "packages")
fixture(name) = joinpath(FIXTURES, name)

include("helpers.jl")
include("parallel.jl")

# Slowest first. The files are independent and the run is only as short as its
# longest file, so the long ones have to be in flight from the start; the order
# is a packing hint and nothing depends on it.
const TEST_FILES = [
    "test_timeouts.jl",
    "test_sandbox.jl",
    "test_crashes.jl",
    "test_execute.jl",
    "test_setups.jl",
    "test_workers.jl",
    "test_runstate.jl",
    "test_matrix.jl",
    "test_monitor.jl",
    "test_pkgtest.jl",
    "test_testenv.jl",
    "test_output.jl",
    "test_filters.jl",
    "test_scan.jl",
    "test_plan.jl",
    "test_gating.jl",
    "test_config.jl",
    "test_runner.jl",
    "test_precompile.jl",
    "test_interactive.jl",
]

# Four is where this stops paying: the longest file takes about as long as a
# quarter of the suite, so more processes only add memory. Each of these starts
# worker processes of its own.
default_jobs() = something(tryparse(Int, get(ENV, "YATF_TEST_JOBS", "")), 4)

"""
    run_file(file)

Run one test file in this process and let `Test` decide the verdict: a failing
`@testset` throws, which is what makes the process exit non-zero.
"""
run_file(file::AbstractString) = @testset "$file" begin
    include(joinpath(@__DIR__, file))
end

if !isempty(ARGS)
    # A child, or someone running one file by hand.
    foreach(run_file, ARGS)
elseif default_jobs() <= 1
    @testset "YATF" begin
        foreach(run_file, TEST_FILES)
    end
else
    report_files(run_in_parallel(@__FILE__, TEST_FILES, default_jobs()))
end
