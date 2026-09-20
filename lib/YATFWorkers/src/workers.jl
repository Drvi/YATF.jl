# Worker processes.
#
# One worker is one Julia process on this machine, connected to the coordinator
# over a loopback TCP socket. The coordinator sends one request at a time, and the
# worker answers each on its root task before reading the next, so nothing in the
# protocol is ever concurrent. Two request kinds and two reply kinds cover a test
# run:
#
#     EVAL  expr::Expr                       -> RESULT nothing            | ERROR message::String
#     RUN   spec::ItemSpec                   -> RESULT result::ItemResult | ERROR message::String
#     END   (spec::ItemSpec, test_end::Expr) -> RESULT result::ItemResult | ERROR message::String
#
# RUN and END are separate requests because they are timed separately: a profile's
# test-end expression is the suite's own code, and the time it takes is not the
# item's. A profile without one sends no END request at all.
#
# Errors cross the wire as strings. An exception object can hold a type that
# exists only on the worker, and the coordinator could not even deserialize it; a
# string always arrives. The only object that crosses is an item's result, and a
# result that cannot be serialized becomes an ERROR that says so.
#
# Each message is
#
#     id::UInt64  kind::UInt8  len::UInt32  payload[len]  MSG_BOUNDARY
#
# The whole message is assembled in memory before any of it is written, so a
# payload that fails to serialize leaves nothing on the wire, and the header is
# raw, so a payload that fails to deserialize is still reported against its
# request. The boundary is a check, not a resynchronization point: the header
# carries the length, so a missing boundary means the stream is corrupt, and the
# connection is dropped rather than trusted.
#
# Closing the connection is the shutdown request: a worker exits when it reads
# EOF, whether the coordinator closed the socket on purpose or died.

export Worker, remote_eval, remote_fetch, remote_run, remote_end, inspect!, terminate!,
       WorkerTerminatedException, RemoteException

const KIND_EVAL   = UInt8(1)
const KIND_RUN    = UInt8(2)
const KIND_RESULT = UInt8(3)
const KIND_ERROR  = UInt8(4)
const KIND_END    = UInt8(5)

# Same value as Distributed's: 10 bytes, so hitting it inside a payload by chance
# is not a practical concern.
const MSG_BOUNDARY = UInt8[0x79, 0x8e, 0x8e, 0xf5, 0x6e, 0x9b, 0x2e, 0x97, 0xd5, 0x7d]
const HEADER_BYTES = sizeof(UInt64) + sizeof(UInt8) + sizeof(UInt32)

# The coordinator writes a cookie to the worker's stdin, and the worker serves the
# one connection that presents it. Same machine, so this is not about attackers:
# it stops a port scanner or an endpoint agent from taking the worker's only
# connection and leaving the coordinator waiting for a worker that will never
# answer.
const COOKIE_BYTES = 32

# Once the coordinator closes the connection a healthy worker exits within
# milliseconds. Julia prints every thread's backtrace on SIGTERM before exiting,
# which is a hung worker's most useful last words, so SIGTERM gets a moment
# before SIGKILL. A process that survives SIGKILL is stuck in the kernel, and
# nothing more can be done about it from here.
const GRACEFUL_EXIT_SECONDS = 3
const TERM_GRACE_SECONDS    = 2
const KILL_WAIT_SECONDS     = 10

### Framing ################################################################

struct Frame
    id      :: UInt64
    kind    :: UInt8
    payload :: Any
    error   :: Any     # the exception, when the payload could not be deserialized here
end

# `serialize` in the latest world, so that a `serialize` method a test item
# defined for one of its own types is used rather than the generic path.
#
# `sizehint` is what the last message to this worker came to. An `IOBuffer` starts
# at 32 bytes and doubles, so serializing an item's syntax tree into a fresh one
# copies it through every power of two on the way; the messages in a run are all
# much the same size, so the previous one is a good guess at the next.
function encode_message(id::UInt64, kind::UInt8, payload, sizehint::Integer = 0)
    buf = IOBuffer(; sizehint = max(Int(sizehint), 64))
    write(buf, id, kind, UInt32(0))
    Base.invokelatest(serialize, buf, payload)
    len = UInt32(position(buf) - HEADER_BYTES)
    seek(buf, HEADER_BYTES - sizeof(UInt32))
    write(buf, len)
    seekend(buf)
    write(buf, MSG_BOUNDARY)
    return take!(buf)
end

"""
    FrameReader

The byte buffers one reader reuses between messages.

A connection is read by exactly one task — `process_responses` on the coordinator,
`serve_requests` on the worker — so these need no locking, and the bytes of a
message are finished with before the next one is read. What the payload
*deserializes into* cannot be reused: an item's code and a test's results are
arbitrary object graphs, and building them is the point.
"""
struct FrameReader
    header   :: Vector{UInt8}
    payload  :: Vector{UInt8}
    boundary :: Vector{UInt8}
end

FrameReader() = FrameReader(
    zeros(UInt8, HEADER_BYTES), UInt8[], zeros(UInt8, length(MSG_BOUNDARY))
)

# `read(io, T)` for a number allocates a `Ref` to read into, so a header read
# field by field is three allocations before the payload is even looked at. The
# header comes in as bytes and is picked apart in place.
@inline function header_field(buf::Vector{UInt8}, ::Type{T}, offset::Int) where {T}
    return GC.@preserve buf unsafe_load(Ptr{T}(pointer(buf, offset + 1)))
end

# Reads one frame. Throws `EOFError` or `IOError` when the connection is gone and
# `ErrorException` when the stream is corrupt. `read!` insists on every byte, so a
# connection cut mid-message is an `EOFError`, never a short payload.
function read_message(io::IO, r::FrameReader = FrameReader())
    read!(io, r.header)
    id = header_field(r.header, UInt64, 0)
    kind = header_field(r.header, UInt8, 8)
    len = header_field(r.header, UInt32, 9)
    # `resize!` down keeps the capacity, so after the first few messages this is
    # the same memory every time.
    resize!(r.payload, len)
    read!(io, r.payload)
    read!(io, r.boundary)
    r.boundary == MSG_BOUNDARY ||
        error("message boundary missing after message $id (kind $kind, $len bytes): the stream is corrupt")
    payload, err = nothing, nothing
    try
        payload = Base.invokelatest(deserialize, IOBuffer(r.payload))
    catch e
        err = e
    end
    return Frame(id, kind, payload, err)
end

### Coordinator side #######################################################

struct Future
    id    :: UInt64
    value :: Channel{Any}
end

Base.fetch(f::Future) = fetch(f.value)

mutable struct Worker
    const lock       :: ReentrantLock    # guards `futures`, and the `terminated` check made when registering one
    const write_lock :: ReentrantLock    # one message at a time on the socket
    const pid        :: Int
    const process    :: Base.Process
    const socket     :: TCPSocket
    messages         :: Task
    output           :: Task
    process_watch    :: Task
    const futures    :: Dict{UInt64,Future}
    @atomic next_id    :: UInt64
    @atomic last_encoded :: Int          # size of the last message sent, as a buffer hint
    @atomic terminated :: Bool
    @atomic closing    :: Bool           # the coordinator closed the connection and expects the worker to exit on its own
end

struct WorkerTerminatedException <: Exception
    worker::Worker
end

Base.showerror(io::IO, e::WorkerTerminatedException) =
    print(io, "worker ", e.worker.pid, " terminated")

"""
    RemoteException

A request failed on the worker. `msg` is the error and backtrace as the worker
printed them.
"""
struct RemoteException <: Exception
    pid :: Int
    msg :: String
end

Base.showerror(io::IO, e::RemoteException) = print(io, "on worker ", e.pid, ": ", e.msg)

Base.show(io::IO, w::Worker) = print(io, "Worker(pid=", w.pid,
    w.terminated ? ", terminated, signal=$(w.process.termsignal)" : "", ")")

# Every live worker process, so that an interrupted or crashed coordinator does
# not leave Julia processes behind holding onto memory. Finalizers are not run
# reliably at exit; this is.
const LIVE_PROCESSES = Set{Base.Process}()
const LIVE_LOCK = ReentrantLock()

# Registered when the first worker is tracked: a process that never starts one has
# nothing to clean up.
const ensure_cleanup_hook = OncePerProcess{Nothing}() do
    atexit(kill_leftovers)
    nothing
end

function track!(proc::Base.Process)
    ensure_cleanup_hook()
    @lock LIVE_LOCK begin
        filter!(Base.process_running, LIVE_PROCESSES)
        push!(LIVE_PROCESSES, proc)
    end
    return proc
end

untrack!(proc::Base.Process) = @lock LIVE_LOCK (delete!(LIVE_PROCESSES, proc); nothing)

function kill_leftovers()
    @lock LIVE_LOCK begin
        for proc in LIVE_PROCESSES
            try
                signal!(getpid(proc), proc, Base.SIGKILL)
            catch
            end
        end
        empty!(LIVE_PROCESSES)
    end
    return nothing
end

# `detach` gives the worker its own process group, so on Unix a signal to the group
# reaches the subprocesses a test item started as well as the worker itself. The
# pid is the one recorded at spawn: an exited process cannot be asked for it.
function signal!(pid::Integer, proc::Base.Process, sig::Integer)
    process_running(proc) || return nothing
    if Sys.iswindows()
        try
            kill(proc, sig)
        catch e
            # TerminateProcess on a process that is already exiting fails with
            # ERROR_ACCESS_DENIED, which libuv reports as EACCES rather than ESRCH.
            (e isa Base.IOError && e.code == Base.UV_EACCES) || rethrow()
        end
    else
        err = ccall(:uv_kill, Cint, (Cint, Cint), -Cint(pid), Cint(sig))
        # ESRCH: nothing left in the group. EPERM: the group is gone and the id has
        # no owner we may signal — which is what a worker that died of a signal
        # looks like from here. Both mean the job is already done.
        err == 0 || err == Base.UV_ESRCH || err == Base.UV_EPERM ||
            throw(Base._UVError("kill", err))
    end
    return nothing
end

wait_exit(proc::Base.Process, seconds::Real) =
    timedwait(() -> process_exited(proc), seconds; pollint=0.02) === :ok

# The signal on which the runtime prints every thread's backtrace and collects a
# short CPU profile: SIGINFO on the BSDs, SIGUSR1 on Linux. Windows has neither.
const INSPECT_SIGNAL = Sys.iswindows() ? nothing : Sys.isbsd() ? 29 : 10
# The runtime samples for `Profile.get_peek_duration()`, one second by default,
# and the report follows from a task, so the output needs a moment to appear.
const INSPECT_SECONDS = 2.5

"""
    inspect!(w::Worker)

Ask a worker that is past its timeout where it is. The worker prints every
thread's backtrace, the backtrace of every live task and a short CPU profile,
which the coordinator relays like any other output. Does nothing on Windows.
"""
function inspect!(w::Worker)
    INSPECT_SIGNAL === nothing && return nothing
    process_running(w.process) || return nothing
    try
        kill(w.process, INSPECT_SIGNAL)   # the worker itself, not its process group
    catch
        return nothing
    end
    wait_exit(w.process, INSPECT_SECONDS)   # a worker that exits meanwhile needs no more time
    return nothing
end

"""
    terminate!(w::Worker, from::Symbol=:manual, cause::Exception=WorkerTerminatedException(w))

Kill the worker and fail everything waiting on it with `cause`. Safe to call from
several tasks at once and safe to call twice; only the first caller does the work.
Callers that are about to start a replacement should `wait(w)` afterwards, so
that the number of live processes never exceeds the configured cap.
"""
function terminate!(w::Worker, from::Symbol=:manual, cause::Exception=WorkerTerminatedException(w))
    (; success) = @atomicreplace w.terminated false => true
    success || return nothing
    @lock w.lock begin
        for (_, fut) in w.futures
            close(fut.value, cause)
        end
        empty!(w.futures)
    end
    # A worker whose connection the coordinator closed exits on its own. Signalling
    # a process that is already exiting turns the end of a normal run into a crash
    # in the log, so it gets a moment to leave first.
    w.closing && wait_exit(w.process, GRACEFUL_EXIT_SECONDS)
    if !process_exited(w.process)
        signal!(w.pid, w.process, Base.SIGTERM)
        if !wait_exit(w.process, TERM_GRACE_SECONDS)
            signal!(w.pid, w.process, Base.SIGKILL)
            wait_exit(w.process, KILL_WAIT_SECONDS) ||
                @error "YATF: worker $(w.pid) is still alive $(KILL_WAIT_SECONDS)s after SIGKILL; giving up on it"
        end
    end
    untrack!(w.process)
    close(w.socket)
    return nothing
end

function watch_and_terminate!(w::Worker, ev::Threads.Event)
    notify(ev)
    wait(w.process)
    terminate!(w, :process_exit)
    return nothing
end

# Closing the connection is the shutdown request; `terminate!` gives the worker a
# few seconds to act on it before escalating to signals.
"""
    kill!(w)

Stop the worker now, with none of the grace an orderly shutdown allows.

An interrupt is someone asking for their terminal back. `terminate!` gives the
process a window to exit on its own and then another to handle `SIGTERM`, which
across a pool is most of a minute; here it is killed outright and whatever it was
doing is abandoned. Safe to call on a worker already being torn down — that is the
common case, since the interrupt lands while the run is in the middle of one.
"""
function kill!(w::Worker)
    @atomic w.terminated = true
    @lock w.lock begin
        for (_, fut) in w.futures
            close(fut.value, WorkerTerminatedException(w))
        end
        empty!(w.futures)
    end
    try
        process_exited(w.process) || signal!(w.pid, w.process, Base.SIGKILL)
    catch e
        e isa InterruptException && rethrow()
        # Already gone, or never ours to signal. Either way there is nothing left
        # to stop, and an interrupt is not the moment to complain about it.
    end
    return nothing
end

function Base.close(w::Worker)
    @atomic w.closing = true
    close(w.socket)
    terminate!(w, :close)
    wait(w)
    return nothing
end

# Waits for the worker's tasks to finish and never throws: by the time anyone
# waits, the worker is being torn down, and a task that failed on the way out has
# already reported itself. Propagating here would take down the coordinator's
# slot, and with it the rest of that slot's queue.
function Base.wait(w::Worker)
    for t in (w.process_watch, w.messages, w.output)
        try
            wait(t)
        catch e
            e isa InterruptException && rethrow()
        end
    end
    return nothing
end

# A worker loads this package by UUID rather than by name. `using YATFWorkers` at
# the top level of the worker's `Main` needs the package in the active project's
# `[deps]`, and in a user's test environment it is only a dependency of YATF;
# `Base.require` on the `PkgId` finds it through the manifest either way.
const PKGID = Base.PkgId(@__MODULE__)

worker_startup_code(connect_timeout::Real) = string(
    "YATFWorkers = Base.require(Base.PkgId(Base.UUID(\"", PKGID.uuid, "\"), \"YATFWorkers\")); ",
    "YATFWorkers.startworker(", connect_timeout, ")")

"""
    Worker(; julia_args, threads, extra_env, dir, project, connect_timeout, redirect_io, redirect_fn)

Start a worker process and connect to it.
"""
function Worker(;
        julia_args::Vector{String}=String[],
        threads::String="2,1",
        env::AbstractDict=ENV,
        extra_env=Pair{String,String}[],
        dir::String=pwd(),
        project::Union{Nothing,String}=Base.ACTIVE_PROJECT[],
        connect_timeout::Int=60,
        redirect_io::IO=stdout,
        redirect_fn=(io, pid, line) -> println(io, "      worker ", pid, " | ", line),
    )
    env = Dict{String,String}(env)
    for (k, v) in extra_env
        env[k] = v
    end
    pathsep = Sys.iswindows() ? ";" : ":"
    haskey(env, "JULIA_LOAD_PATH") || (env["JULIA_LOAD_PATH"] = join(LOAD_PATH, pathsep))
    haskey(env, "JULIA_DEPOT_PATH") || (env["JULIA_DEPOT_PATH"] = join(DEPOT_PATH, pathsep))
    project === nothing || haskey(env, "JULIA_PROJECT") || (env["JULIA_PROJECT"] = project)
    # Every worker would otherwise start a BLAS thread pool sized for the whole machine.
    haskey(env, "OPENBLAS_NUM_THREADS") || (env["OPENBLAS_NUM_THREADS"] = "1")
    color = get(redirect_io, :color, false) ? "yes" : "no"
    # A worker runs the suite's code and nothing else: no startup file, because a
    # developer's own is not part of the tests, and no history file, because a
    # worker has no REPL to record.
    cmd = `$(Base.julia_cmd()) --threads=$threads --startup-file=no --history-file=no
           --color=$color $julia_args -e $(worker_startup_code(connect_timeout))`
    proc = track!(open(detach(setenv(addenv(cmd, env), dir=dir)), "r+"))
    pid = getpid(proc)
    cookie = bytes2hex(rand(UInt8, COOKIE_BYTES ÷ 2))
    local sock, w
    try
        # The cookie is the only thing the worker ever reads from its stdin.
        try
            println(proc, cookie)
            close(proc.in)
        catch e
            e isa Base.IOError || rethrow()   # the process is already gone; `read_port` reports that
        end
        sock = with_timeout(connect_timeout) do
            port = read_port(proc, redirect_io, pid, redirect_fn)
            s = Sockets.connect(Sockets.localhost, port)
            Sockets.nagle(s, false)
            Sockets.quickack(s, true)
            write(s, cookie)
            s
        end
        w = Worker(ReentrantLock(), ReentrantLock(), pid, proc, sock,
                   Task(nothing), Task(nothing), Task(nothing),
                   Dict{UInt64,Future}(), UInt64(0), 0, false, false)
        e1 = Threads.Event(); w.process_watch = Threads.@spawn watch_and_terminate!(w, $e1)
        e2 = Threads.Event(); w.output = Threads.@spawn redirect_worker_output(redirect_io, w, redirect_fn, proc, $e2)
        e3 = Threads.Event(); w.messages = Threads.@spawn process_responses(w, $e3)
        wait(e1); wait(e2); wait(e3)
        return w
    catch
        try
            signal!(pid, proc, Base.SIGKILL)
        catch
        end
        untrack!(proc)
        @isdefined(sock) && close(sock)
        @isdefined(w) && terminate!(w, :start_failed)
        rethrow()
    end
end

# The worker announces the port it listens on; anything it prints before that is
# relayed like any other output. `eof` blocks until there is a line or the pipe is
# closed, so a worker that dies before it is ready is reported at once.
function read_port(proc::Base.Process, io::IO, pid::Integer, fn)
    while !eof(proc)
        line = readline(proc)
        m = match(r"yatfworker:(\d+)", line)
        m === nothing || return parse(Int, m.captures[1])
        isempty(line) || (fn(io, pid, line); flush(io))
    end
    wait(proc)
    error("worker process exited before it was ready (exit code $(proc.exitcode), signal $(proc.termsignal))")
end

# The result travels through a channel rather than a condition: a condition's
# notify is lost when nobody is waiting yet, and the task can finish before the
# caller reaches the wait.
function with_timeout(f, timeout::Real)
    result = Channel{Any}(1)
    Threads.@spawn begin
        r = try
            Some($f())
        catch e
            CapturedException(e, catch_backtrace())
        end
        try
            put!(result, r)
        catch
            # Closed by the timer: the caller has already given up.
        end
    end
    timer = Timer(timeout) do _
        close(result, ErrorException("timed out after $timeout seconds"))
    end
    try
        r = take!(result)
        r isa CapturedException && throw(r)
        return something(r)
    finally
        close(timer)
    end
end

# `eof` blocks until there is a line or the pipe is closed, and the partial last
# line of a worker that was killed comes back from `readline`: nothing is polled
# for and nothing is lost.
function redirect_worker_output(io::IO, w::Worker, fn, proc::Base.Process, ev::Threads.Event)
    notify(ev)
    try
        while !eof(proc)
            line = readline(proc)
            isempty(line) || (fn(io, w.pid, line); flush(io))
        end
    catch e
        # Without a relay the worker blocks as soon as the pipe fills, so it
        # cannot be kept.
        @error "YATF: could not relay the output of worker $(w.pid); terminating it" exception=(e, catch_backtrace())
        terminate!(w, :output_error, e)
    end
    return nothing
end

function process_responses(w::Worker, ev::Threads.Event)
    notify(ev)
    reader = FrameReader()
    try
        while true
            frame = read_message(w.socket, reader)
            fut = @lock w.lock pop!(w.futures, frame.id, nothing)
            if fut === nothing
                # A reply to a request that `terminate!` has already failed is
                # expected. Any other unmatched reply means the two sides disagree
                # about the conversation, and the stream cannot be trusted.
                w.terminated && break
                error("worker $(w.pid) replied to a request that was never made (id $(frame.id))")
            end
            if frame.error !== nothing
                close(fut.value, ErrorException(string(
                    "the reply from worker ", w.pid, " could not be deserialized on the coordinator (",
                    sprint(showerror, frame.error), "). Test results travel between processes, so ",
                    "everything they hold must be of a type the coordinator knows; a custom ",
                    "AbstractTestSet or exception type defined inside a test is the usual cause.")))
            elseif frame.kind === KIND_RESULT
                # The waiter may have given up and closed this channel — a request
                # past its deadline does that. The reply is late, not wrong, and
                # dropping it is not a reason to distrust the connection.
                try
                    put!(fut.value, frame.payload)
                catch e
                    # Closing a channel carries the reason, and `put!` raises that
                    # reason rather than an `InvalidStateException` — a timeout
                    # would come back here as the timeout. Whatever it says, a
                    # closed channel means the waiter has gone.
                    isopen(fut.value) && rethrow()
                end
            elseif frame.kind === KIND_ERROR
                close(fut.value, RemoteException(w.pid, string(frame.payload)))
            else
                error("worker $(w.pid) sent a reply of unknown kind $(frame.kind)")
            end
        end
    catch e
        if e isa EOFError || e isa Base.IOError
            terminate!(w, :connection_lost)   # the worker died, or the coordinator closed the connection
        else
            @error "YATF: protocol error with worker $(w.pid); terminating it" exception=(e, catch_backtrace())
            terminate!(w, :protocol_error, e)
        end
    end
    return nothing
end

"""
    remote_eval(w::Worker, expr) -> Future

Evaluate `expr` in the worker's `Main`. Fetching the future returns `nothing`, or
throws a [`RemoteException`](@ref) carrying the worker's error message.
"""
remote_eval(w::Worker, expr::Expr) =
    send_request(w, KIND_EVAL, expr.head === :block ? Expr(:toplevel, expr.args...) : expr)
remote_eval(w::Worker, expr) = send_request(w, KIND_EVAL, expr)

remote_fetch(w::Worker, expr) = fetch(remote_eval(w, expr))

"""
    remote_run(w::Worker, spec) -> Future

Run one test item on the worker. Fetching the future returns the worker's
`ItemResult`, or throws a [`RemoteException`](@ref).
"""
remote_run(w::Worker, spec) = send_request(w, KIND_RUN, spec)

"""
    remote_end(w::Worker, spec, test_end::Expr) -> Future

Evaluate a profile's test-end expression on the worker, after the item `spec`
describes. Fetching the future returns an `ItemResult` holding whatever the
expression recorded or threw.
"""
remote_end(w::Worker, spec, test_end::Expr) = send_request(w, KIND_END, (spec, test_end))

function send_request(w::Worker, kind::UInt8, payload)
    id = @atomic w.next_id += 1
    # A payload that will not serialize leaves nothing registered.
    bytes = encode_message(id, kind, payload, @atomic w.last_encoded)
    @atomic w.last_encoded = length(bytes)
    fut = Future(id, Channel{Any}(1))
    # Registered under the lock that `terminate!` sweeps futures under, together
    # with the `terminated` check: a future is either swept or never registered,
    # never left waiting for a reply that cannot come.
    @lock w.lock begin
        w.terminated && throw(WorkerTerminatedException(w))
        w.futures[id] = fut
    end
    try
        @lock w.write_lock write(w.socket, bytes)
    catch e
        @lock w.lock delete!(w.futures, id)
        w.terminated && throw(WorkerTerminatedException(w))
        rethrow()
    end
    return fut
end

### Worker side ############################################################

"""
    startworker(connect_timeout)

The worker process's entry point. `connect_timeout` is how long to wait for the
coordinator before giving up.
"""
function startworker(connect_timeout::Real)
    cookie = readline(stdin)
    redirect_stdin(devnull)
    close(stdin)
    redirect_stderr(stdout)   # one ordered stream for the coordinator to relay
    install_inspection_hook()
    port, server = listenany(Sockets.localhost, UInt16(rand(10000:50000)))
    println(stdout, "yatfworker:", port)
    flush(stdout)
    # A coordinator that dies between spawning this process and connecting to it
    # would otherwise leave it waiting forever.
    deadline = Timer(connect_timeout) do _
        println(stdout, "YATF worker: no coordinator connected within $(connect_timeout)s; exiting")
        exit(1)
    end
    sock = accept(server)
    close(server)   # exactly one connection is ever served
    Sockets.nagle(sock, false)
    Sockets.quickack(sock, true)
    presented = read!(sock, Vector{UInt8}(undef, COOKIE_BYTES))
    close(deadline)
    if presented != codeunits(cookie)
        println(stdout, "YATF worker: the connection did not present this worker's cookie; exiting")
        exit(1)
    end
    try
        serve_requests(sock)
    catch e
        println(stdout, "YATF worker: protocol error; exiting")
        showerror(stdout, e, catch_backtrace())
        println(stdout)
        exit(1)
    end
    exit(0)
end

# On SIGINFO or SIGUSR1 the runtime prints every thread's backtrace and collects a
# short CPU profile, and `Profile` reports that profile afterwards from a task.
# In a deadlock the blocked tasks are what matters and no thread is running them,
# so their backtraces go first. Best effort: a worker without the hook is still a
# worker.
function install_inspection_hook()
    INSPECT_SIGNAL === nothing && return nothing
    try
        Profile = Base.require(Base.PkgId(Base.UUID("9abbd945-dff8-562f-b5e8-e1ebf5ef1b79"), "Profile"))
        report = Profile.peek_report[]
        Profile.peek_report[] = function ()
            ccall(:jl_print_task_backtraces, Cvoid, (Cint,), 0)
            report()
        end
    catch e
        println(stdout, "YATF worker: task backtraces on timeout are unavailable: ", sprint(showerror, e))
    end
    return nothing
end

# Requests run on this task one after another, and a reply is written before the
# next request is read.
function serve_requests(io::IO)
    reader = FrameReader()
    while true
        frame = try
            read_message(io, reader)
        catch e
            # The coordinator closed the connection, or is gone: the request to exit.
            (e isa EOFError || e isa Base.IOError) && return nothing
            rethrow()
        end
        kind, payload = handle_request(frame)
        write(io, encode_reply(frame.id, kind, payload))
    end
end

function handle_request(frame::Frame)
    frame.error === nothing ||
        return KIND_ERROR, "the request could not be deserialized on the worker: " * format_error(frame.error)
    if frame.kind === KIND_EVAL
        try
            Core.eval(Main, frame.payload)
            return KIND_RESULT, nothing
        catch e
            return KIND_ERROR, format_error(e, catch_backtrace())
        end
    elseif frame.kind === KIND_RUN
        try
            return KIND_RESULT, run_item(frame.payload)
        catch e
            return KIND_ERROR, "the worker could not run this test item: " * format_error(e, catch_backtrace())
        end
    elseif frame.kind === KIND_END
        spec, test_end = frame.payload
        try
            return KIND_RESULT, run_test_end(spec, test_end)
        catch e
            return KIND_ERROR, "the worker could not run the `test_end` expression: " *
                format_error(e, catch_backtrace())
        end
    end
    error("request of unknown kind $(frame.kind)")
end

# A reply that cannot be serialized becomes an error that says so; a String
# always can be.
function encode_reply(id::UInt64, kind::UInt8, payload)
    try
        return encode_message(id, kind, payload)
    catch e
        return encode_message(id, KIND_ERROR, string(
            "the worker could not serialize the result of this test item (", format_error(e),
            "). Test results travel between processes, so everything they hold must be serializable."))
    end
end

# `showerror` in the latest world, so a method the test item defined for its own
# exception type is used; and never a second failure on top of the first.
function format_error(e, bt=nothing)
    try
        return sprint() do io
            bt === nothing ? Base.invokelatest(showerror, io, e) : Base.invokelatest(showerror, io, e, bt)
        end
    catch
        return string(typeof(e))
    end
end

