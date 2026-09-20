"""
    YATFWorkers

The part of YATF that runs inside a worker process: the request/response
protocol between the coordinator and a worker, the types that cross it, and
`run_item`, which evaluates one test item. YATF depends on this package and
starts each worker by loading it alone, so a worker never loads the scanner,
the planner, the monitor, or `Pkg`.

Test code reaches this package through YATF: `YATF.current_testitem()`,
`YATF.in_testitem()` and `YATF.in_yatf_run()` are defined here.
"""
module YATFWorkers

using Base.ScopedValues: ScopedValue, with
using Logging: Logging, ConsoleLogger, with_logger
using Serialization
using Sockets
using Test: Test

include("runitem.jl")
include("workers.jl")

using PrecompileTools: @setup_workload, @compile_workload

"""
    precompile_or_throw(f, types)

`precompile(f, types)`, and an error if it did not take.

`precompile` answers `false` when the signature does not match a method — a name
that moved, an argument that changed type — and otherwise says nothing. A list of
signatures that quietly stopped matching is worse than no list: the cost it was
paying for is gone and nothing says so. This is called while the package is being
built, so a stale entry fails the build.

An abstract argument type is a legitimate `false`: the compiler cannot specialize
for `Function` or `IO`, so signatures like that do not belong in a list at all.
"""
function precompile_or_throw(@nospecialize(f), @nospecialize(types::Tuple))
    precompile(f, types) && return nothing
    error(
        "cannot precompile `", f, types, "`: no method matches that signature, or it ",
        "names an abstract argument type the compiler cannot specialize for"
    )
end

"""
    PRECOMPILE_SIGNATURES

What a worker does from its first instant, as signatures. Listed once so that the
workload and the test that guards it cannot disagree about what is covered.
"""
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

# What a worker does from its first instant: format its lines, decide an outcome,
# make a result fit to send, and frame a message. Without this each worker pays to
# compile that path before it can report anything.
#
# The workload deliberately does not *run* a test item: that evaluates code into
# `Main`, and a module left there at precompile time makes Julia warn that
# incremental compilation may be broken. `run_item` itself is precompiled by
# signature instead — the part of it that matters, since the body it evaluates is
# only known at run time.
@setup_workload begin
    body = quote
        x = 1 + 1
        @test x == 2
    end
    spec = ItemSpec(Int32(1), Int32(1), "precompile", "precompile.jl", Int32(1),
                    "precompile.jl:1", body, false, false, "", :default, Int8(1), Int8(1),
                    false, "", Int32(24))
    @compile_workload begin
        previous = LOG_SINK[]
        LOG_SINK[] = Returns(nothing)
        try
            ts = Test.DefaultTestSet("precompile")
            Test.record(ts, Test.Pass(:test, :(1 == 1), nothing, true, LineNumberNode(1, "p.jl")))
            state_of(ts)
            transferrable(ts)
            result = ItemResult(Int32(1), PASSED, ts, PerfStats())
            log_item(spec, "START")
            log_item(spec, "DONE", result)
            softscope_all!(Expr(:block, :(x = 1)))
            short_state(PASSED); state_color(FAILED)
        finally
            LOG_SINK[] = previous
        end
        io = IOBuffer()
        write(io, encode_message(UInt64(1), KIND_RUN, spec))
        seekstart(io)
        try
            read_message(io)
        catch
        end
    end
    # Running an item, and starting a worker and talking to it: the shapes are
    # known even though the workload cannot spawn a process.
        name_width(["one", "another name"]; columns = 120)
        quoted_width("a name")
    for (f, types) in PRECOMPILE_SIGNATURES
        precompile_or_throw(f, types)
    end
end

end # module YATFWorkers
