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
                    false, "")
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
    precompile(run_item, (ItemSpec,))
    precompile(run_test_end, (ItemSpec, Expr))
    precompile(handle_request, (Frame,))
    # Starting a worker and talking to it: the shapes are known even though the
    # workload cannot spawn a process.
    precompile(send_request, (Worker, UInt8, ItemSpec))
    precompile(send_request, (Worker, UInt8, Tuple{ItemSpec,Expr}))
    precompile(remote_run, (Worker, ItemSpec))
    precompile(remote_end, (Worker, ItemSpec, Expr))
    precompile(process_responses, (Worker, Base.Event))
    precompile(read_message, (IOBuffer,))
    precompile(terminate!, (Worker, Symbol))
end

end # module YATFWorkers
