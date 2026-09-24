# YATF's own tests use plain Test.jl, not YATF: a test framework that can only be
# tested by itself cannot be trusted at the moment it is broken. For the same
# reason the files are run in plain subprocesses rather than on YATF's own worker
# pool — a bug in the transport would stop the suite from running instead of
# telling you which test it broke.
#
#     julia --project=test test/runtests.jl                    every file, in parallel
#     julia --project=test test/runtests.jl test_scan.jl       one file, in this process
#     YATF_TEST_JOBS=1 julia --project=test test/runtests.jl   every file, in this process
#
# `test/` is a project in the package's workspace, with the test-only dependencies,
# and `Pkg.test()` runs in it too.
#
# Each file is independent: it builds the fixtures it needs and asserts only on
# what it built.

using Test
using YATF

# A worker finds YATFWorkers through the load path it is given, and `@` there means
# the worker's own project, which is a fixture's. `Pkg.test` puts this environment
# on the path by name; a run started with `--project=test` has to do it here.
let env = dirname(Base.active_project())
    env in LOAD_PATH || push!(LOAD_PATH, env)
end

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
    "test_runner.jl",
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
    "test_precompile.jl",
    "test_debug.jl",
    "test_interactive.jl",
]

# Four is where this stops paying: the longest file takes about as long as a
# quarter of the suite, so more processes only add memory. Each of these starts
# worker processes of its own; the run ends with each file's peak memory, and the
# suite's, to choose from.
default_jobs() = something(tryparse(Int, get(ENV, "YATF_TEST_JOBS", "")), 4)

"""
    run_file(file)

Run one test file in this process and let `Test` decide the verdict: a failing
`@testset` throws, which is what makes the process exit non-zero.
"""
run_file(file::AbstractString) = @testset "$file" begin
    include(joinpath(@__DIR__, file))
end

# Where the suite ran, for a CI log read by someone who was not there.
print_environment() = println(
    "[tests] julia ", VERSION, " (", Base.GIT_VERSION_INFO.commit_short, ") · ", Sys.MACHINE, " · ",
    Sys.CPU_THREADS, " CPU threads · ", round(Sys.total_memory() / 2^30; digits = 1), " GiB · threads ",
    Threads.nthreads(:default), ",", Threads.nthreads(:interactive), " · ", default_jobs(), " files at a time",
    get(ENV, "CI", "") == "true" ? " · CI" : ""
)

if !isempty(ARGS)
    # A child, or someone running one file by hand. The hook makes the signal a
    # hung file is sent print every task's backtrace, which is where it is stuck.
    YATFWorkers.install_inspection_hook()
    foreach(run_file, ARGS)
elseif default_jobs() <= 1
    print_environment()
    @testset "YATF" begin
        for file in TEST_FILES
            println(stdout, "[tests] running ", file)
            run_file(file)
        end
    end
else
    print_environment()
    results, memory = run_in_parallel(@__FILE__, TEST_FILES, default_jobs())
    report_files(results; memory, jobs = default_jobs())
end
