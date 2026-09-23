"""
    YATFWorkers

The part of YATF that runs inside a worker process: the protocol between the
coordinator and a worker, the types that cross it, and `run_item`. A worker loads
this package alone, never the scanner, the planner, the monitor or `Pkg`.

Test code reaches this package through YATF: `YATF.current_testitem()`,
`YATF.in_testitem()` and `YATF.in_yatf_run()` are defined here.
"""
module YATFWorkers

using Base.ScopedValues: ScopedValue, with
using Logging: Logging, ConsoleLogger, with_logger
using Random: Random
using Serialization
using Sockets
using Test: Test

include("runitem.jl")
include("workers.jl")

using PrecompileTools: @setup_workload, @compile_workload

# `precompile(f, types)`, or an error when it does not take. `precompile` returns
# `false` quietly for a signature that no longer matches a method, and this runs at
# build time, so a stale entry fails the build. Abstract argument types (`Function`,
# `IO`) cannot be specialized for and do not belong in the list.
function precompile_or_throw(@nospecialize(f), @nospecialize(types::Tuple))
    precompile(f, types) && return nothing
    error(
        "cannot precompile `", f, types, "`: no method matches that signature, or it ",
        "names an abstract argument type the compiler cannot specialize for"
    )
end

# What a worker does from its first instant. Listed once so the workload and the
# test that guards it agree on what is covered.
const PRECOMPILE_SIGNATURES = (
    (run_item, (ItemSpec,)),
    (run_test_end, (ItemSpec, Expr)),
    (handle_request, (Frame,)),
    (send_request, (Worker, UInt8, ItemSpec)),
    (send_request, (Worker, UInt8, Tuple{ItemSpec, Expr})),
    (remote_run, (Worker, ItemSpec)),
    (remote_end, (Worker, ItemSpec, Expr)),
    (process_responses, (Worker, Base.Event)),
    (read_message, (IOBuffer,)),
    (read_message, (IOBuffer, FrameReader)),
    (terminate!, (Worker, Symbol)),
)

# The workload does not *run* a test item: that evaluates code into `Main`, and a
# module left there at precompile time makes Julia warn that incremental
# compilation may be broken. `run_item` is precompiled by signature instead.
@setup_workload begin
    body = quote
        x = 1 + 1
        @test x == 2
    end
    spec = ItemSpec(Int32(1), "precompile", "precompile.jl", Int32(1), body, false, false,
                    "", :default, Int8(1), false, "", UInt64(1))
    @compile_workload begin
        ts = Test.DefaultTestSet("precompile")
        Test.record(ts, Test.Pass(:test, :(1 == 1), nothing, true, LineNumberNode(1, "p.jl")))
        state_of(ts)
        transferrable(ts)
        result = ItemResult(Int32(1), PASSED, ts, PerfStats())
        record_run(spec); record_done(spec, result)
        softscope_all!(Expr(:block, :(x = 1)))
        io = IOBuffer()
        write(io, encode_message(UInt64(1), KIND_RUN, spec))
        seekstart(io)
        try
            read_message(io)
        catch
        end
    end
    # Starting a worker and talking to it: the workload cannot spawn a process.
    for (f, types) in PRECOMPILE_SIGNATURES
        precompile_or_throw(f, types)
    end
end

end # module YATFWorkers
