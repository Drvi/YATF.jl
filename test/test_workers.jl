# The worker protocol: the framing on its own, then real worker processes.
using YATFWorkers: YATFWorkers, Worker, remote_eval, remote_fetch, remote_run, terminate!,
                    WorkerTerminatedException, RemoteException
using YATFWorkers: ItemSpec, ItemResult, PASSED
using Sockets

# A connected socket pair standing in for coordinator and worker.
function socket_pair()
    port, server = listenany(Sockets.localhost, UInt16(20000))
    client = connect(Sockets.localhost, port)
    peer = accept(server)
    close(server)
    return client, peer
end

# What `Worker()` gives a worker process, for tests that spawn one by hand.
function worker_child_env(cmd)
    pathsep = Sys.iswindows() ? ";" : ":"
    env = ["JULIA_LOAD_PATH" => join(LOAD_PATH, pathsep), "JULIA_DEPOT_PATH" => join(DEPOT_PATH, pathsep)]
    Base.active_project() === nothing || push!(env, "JULIA_PROJECT" => Base.active_project())
    return addenv(cmd, env...)
end

# Built by field name, with a plain default for every field not given, so that a
# field added to `ItemSpec` does not break these tests.
function probe_spec(code::Expr; name="probe")
    given = (; name, code, file=@__FILE__, location=string(@__FILE__, ":1"), skip=false)
    default(T) = T === Int32 ? Int32(1) : T === Int8 ? Int8(1) : T === String ? "" : T === UInt64 ? UInt64(1) :
                 T === Bool ? false : T === Symbol ? :default : T === Expr ? Expr(:block) : nothing
    return ItemSpec((haskey(given, f) ? given[f] : default(fieldtype(ItemSpec, f))
                     for f in fieldnames(ItemSpec))...)
end

# Every worker these tests start is ended here, whatever the test body did: a
# worker left running would count against later tests' process-cap assertions.
function with_worker(f; kwargs...)
    w = Worker(; kwargs...)
    try
        f(w)
    finally
        w.terminated || (terminate!(w); wait(w))
    end
end

@testset "workers" begin
    @testset "framing: round trip, exact reads, corrupt stream" begin
        a, b = socket_pair()
        write(a, YATFWorkers.encode_message(UInt64(7), YATFWorkers.KIND_EVAL, :(1 + 1)))
        f = YATFWorkers.read_message(b)
        @test f.id == 7 && f.kind == YATFWorkers.KIND_EVAL && f.error === nothing
        @test f.payload == :(1 + 1)
        # Back-to-back messages stay separate.
        write(a, YATFWorkers.encode_message(UInt64(8), YATFWorkers.KIND_RESULT, (1, "two")),
                 YATFWorkers.encode_message(UInt64(9), YATFWorkers.KIND_RESULT, nothing))
        @test YATFWorkers.read_message(b).payload == (1, "two")
        @test YATFWorkers.read_message(b).id == 9
        # A frame whose boundary is wrong is a corrupt stream, not a message.
        bad = YATFWorkers.encode_message(UInt64(10), YATFWorkers.KIND_RESULT, 1)
        bad[end] ⊻= 0xff
        write(a, bad)
        @test_throws ErrorException YATFWorkers.read_message(b)
        close(a); close(b)
        # A connection cut mid-payload is EOF, not a short payload.
        c, d = socket_pair()
        msg = YATFWorkers.encode_message(UInt64(11), YATFWorkers.KIND_RESULT, collect(1:100))
        write(c, msg[1:end-20])
        close(c)
        @test_throws EOFError YATFWorkers.read_message(d)
        close(d)
    end

    @testset "a reply that cannot be serialized becomes an error string" begin
        bytes = YATFWorkers.encode_reply(UInt64(1), YATFWorkers.KIND_RESULT, current_task())
        f = YATFWorkers.read_message(IOBuffer(bytes))
        @test f.id == 1 && f.kind == YATFWorkers.KIND_ERROR
        @test f.payload isa String && occursin("could not serialize", f.payload)
    end

    @testset "a reply that cannot be deserialized is reported against its request" begin
        m = Module(:Nowhere)
        Core.eval(m, :(struct Ghost; x::Int; end))
        bytes = YATFWorkers.encode_message(UInt64(2), YATFWorkers.KIND_RESULT, Core.eval(m, :(Ghost(1))))
        f = YATFWorkers.read_message(IOBuffer(bytes))
        @test f.id == 2 && f.kind == YATFWorkers.KIND_RESULT
        @test f.error !== nothing
    end

    @testset "with_timeout never loses a result" begin
        # A function that returns before the caller waits must not hang the caller.
        for _ in 1:50
            @test YATFWorkers.with_timeout(() -> 42, 5) == 42
        end
        @test_throws ErrorException YATFWorkers.with_timeout(() -> sleep(3), 0.2)
        err = try; YATFWorkers.with_timeout(() -> error("inner"), 5); catch e; e; end
        @test err isa CapturedException && occursin("inner", sprint(showerror, err))
    end

    @testset "a worker evaluates, runs items, reports errors as text, and stops" begin
        out = IOBuffer()
        w = Worker(; threads="1", redirect_io=out)
        try
            @test remote_fetch(w, :(global probe = 41)) === nothing
            err = try; remote_fetch(w, :(error("boom"))); catch e; e; end
            @test err isa RemoteException && occursin("boom", sprint(showerror, err))
            # An exception type that exists only on the worker still arrives, as text.
            err = try
                remote_fetch(w, quote struct OnlyHere <: Exception end; throw(OnlyHere()) end)
            catch e
                e
            end
            @test err isa RemoteException && occursin("OnlyHere", sprint(showerror, err))
            res = fetch(remote_run(w, probe_spec(:(begin @test Main.probe == 41 end))))
            @test res isa ItemResult && res.state === PASSED
            # ...and the worker is still usable afterwards.
            @test remote_fetch(w, :(1 + 1)) === nothing
        finally
            t = @elapsed close(w)
            @test t < YATFWorkers.GRACEFUL_EXIT_SECONDS    # it left on its own, without being signalled
        end
        @test process_exited(w.process)
        @test w.process.exitcode == 0
        @test_throws WorkerTerminatedException remote_eval(w, :(1 + 1))
    end

    @testset "a worker that dies before it is ready is reported at once" begin
        t = @elapsed err = try
            Worker(; julia_args=["--no-such-flag"], redirect_io=IOBuffer())
        catch e
            e
        end
        @test err isa Exception
        @test occursin("before it was ready", sprint(showerror, err))
        @test t < 20   # neither the connect timeout nor a spin
    end

    @testset "closing a worker that cannot read the request still ends it" begin
        with_worker(; threads="1", redirect_io=IOBuffer()) do w
            remote_eval(w, :(while true end))    # a non-yielding loop on the worker's root task
            sleep(0.5)
            t = @elapsed close(w)
            @test process_exited(w.process)
            @test t < YATFWorkers.GRACEFUL_EXIT_SECONDS + YATFWorkers.TERM_GRACE_SECONDS + YATFWorkers.KILL_WAIT_SECONDS
        end
    end

    if !Sys.iswindows()
        @testset "a worker past its timeout reports where its tasks are" begin
            out = IOBuffer()
            with_worker(; threads="1", redirect_io=out) do w
                remote_eval(w, :(let c = Threads.Condition(); lock(c); wait(c) end))   # a deadlock on the root task
                sleep(0.5)
                YATFWorkers.inspect!(w)
                terminate!(w)
                wait(w)
            end
            @test occursin("live tasks", String(take!(out)))   # jl_print_task_backtraces ran on the worker
        end

        @testset "killing a worker kills the processes its item started" begin
            alive(pid) = ccall(:uv_kill, Cint, (Cint, Cint), pid, 0) == 0
            pidfile = tempname()
            child = 0
            with_worker(; threads="1", redirect_io=IOBuffer()) do w
                spec = probe_spec(:(begin write($pidfile, string(getpid(run(`sleep 600`; wait=false)))) end);
                                  name="spawner")
                fetch(remote_run(w, spec))
                child = parse(Int, read(pidfile, String))
                @test alive(child)
            end
            @test child != 0 && timedwait(() -> !alive(child), 5) === :ok
        end
    end

    @testset "a worker nobody connects to exits on its own" begin
        cmd = `$(Base.julia_cmd()) --startup-file=no -e $(YATFWorkers.worker_startup_code(1))`
        proc = open(worker_child_env(cmd), "r+")
        println(proc, "x"^YATFWorkers.COOKIE_BYTES)
        close(proc.in)
        t = @elapsed wait(proc)
        @test proc.exitcode == 1
        @test t < 30
        @test occursin("no coordinator connected", read(proc, String))
    end

    @testset "these tests leave no worker running" begin
        @test @lock(YATFWorkers.LIVE_LOCK, count(Base.process_running, YATFWorkers.LIVE_PROCESSES)) == 0
    end
end

@testset "the profile report is not laid out for a pipe" begin
    # A worker's output is a pipe, and `displaysize` calls a pipe eighty columns.
    # The report the inspection prints is a table of file, line and function fitted
    # to that width, so eighty columns is where the part naming what ran is cut.
    before = get(ENV, "COLUMNS", nothing)
    inside = YATFWorkers.wide_display() do
        (something(tryparse(Int, get(ENV, "COLUMNS", "")), 0), displaysize(stdout))
    end
    @test inside[1] >= 1000
    # What the report actually consults, and the reason for setting the variable.
    @test inside[2][1] >= 1000 && inside[2][2] >= 1000
    # Scoped to the report: the rest of the worker formats for whatever it had.
    @test get(ENV, "COLUMNS", nothing) == before
end
