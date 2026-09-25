# Worker processes.
#
# One worker is one Julia process on this machine, connected to the coordinator
# over a loopback TCP socket. The coordinator sends one request at a time and the
# worker answers each on its root task before reading the next, so nothing in the
# protocol is concurrent:
#
#     EVAL  expr::Expr                       -> RESULT nothing            | ERROR message::String
#     RUN   spec::ItemSpec                   -> RESULT result::ItemResult | ERROR message::String
#     END   (spec::ItemSpec, test_end::Expr) -> RESULT result::ItemResult | ERROR message::String
#
# RUN and END are separate because they are timed separately: a profile's
# `test_end` is the suite's code, not the item's.
#
# Errors cross as strings, because an exception can hold a type that exists only on
# the worker. The only object that crosses is an item's result, and one that cannot
# be serialized becomes an ERROR that says so.
#
# Each message is
#
#     id::UInt64  kind::UInt8  len::UInt32  payload[len]  MSG_BOUNDARY
#
# assembled whole before any of it is written, so a payload that fails to serialize
# leaves nothing on the wire. The header is raw, so a payload that fails to
# deserialize is still reported against its request. The boundary is a check, not
# a resynchronization point: a missing one means the stream is corrupt, and the
# connection is dropped.
#
# Closing the connection is the shutdown request: a worker exits when it reads EOF,
# whether the coordinator closed the socket or died.

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

# The coordinator writes a cookie to the worker's stdin, and the worker serves only
# the connection that presents it. Not against attackers: it stops a port scanner
# or an endpoint agent from taking the worker's one connection.
const COOKIE_BYTES = 32

# A healthy worker exits within milliseconds of the connection closing. On SIGTERM
# Julia prints every thread's backtrace, a hung worker's most useful last words, so
# SIGTERM gets a moment before SIGKILL. A process that survives SIGKILL is stuck in
# the kernel.
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

# `serialize` in the latest world, so a method a test item defined for its own type
# is used. `sizehint` is the size of the previous message: a run's messages are
# much alike, and a fresh `IOBuffer` doubles its way up from 32 bytes.
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

# The byte buffers one reader reuses between messages. A connection is read by
# exactly one task (`process_responses` on the coordinator, `serve_requests` on the
# worker), so they need no lock.
struct FrameReader
    header   :: Vector{UInt8}
    payload  :: Vector{UInt8}
    boundary :: Vector{UInt8}
end

FrameReader() = FrameReader(
    zeros(UInt8, HEADER_BYTES), UInt8[], zeros(UInt8, length(MSG_BOUNDARY))
)

# Picked apart in place: `read(io, T)` of a number allocates a `Ref` per field.
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
    # Why the process was ended: the `from` of the first `terminate!`, `:interrupt`
    # for `kill!`. `:connection_lost` and `:process_exit` mean it ended on its own.
    @atomic ended_by   :: Symbol
    # On Windows, the job object the worker and every process it starts belong to,
    # until `end_group!` ends it; `C_NULL` elsewhere, or where no job could be made.
    @atomic job        :: Ptr{Cvoid}
    const on_exit    :: Any              # called with the worker once its process has exited, or nothing
end

struct WorkerTerminatedException <: Exception
    worker::Worker
end

function Base.showerror(io::IO, e::WorkerTerminatedException)
    print(io, "worker ", e.worker.pid, " terminated")
    process_exited(e.worker.process) && print(io, ": ", exit_description(e.worker.process))
end

"""
    exit_description(process) -> String

How a process ended, as a report says it: `exited with code 7`, or `killed by
signal 9 (Killed)`.
"""
function exit_description(p::Base.Process)
    p.termsignal == 0 || return string("killed by signal ", p.termsignal, signal_name(p.termsignal))
    # A Windows status such as 0xC0000005 means something in hex and nothing in decimal.
    code = p.exitcode
    return string("exited with code ", 0 <= code <= 255 ? string(code) : string("0x", string(UInt32(code % UInt32); base = 16, pad = 8)))
end

function signal_name(sig::Integer)
    Sys.iswindows() && return ""
    name = ccall(:strsignal, Cstring, (Cint,), sig)
    name == C_NULL && return ""
    # macOS appends the number ("Killed: 9"), which the caller has already said.
    return string(" (", replace(unsafe_string(name), r":\s*\d+$" => ""), ")")
end

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

"""
    live_worker_pids() -> Vector{Int32}

The worker processes this process has started and not yet seen end, from the moment
each is spawned: one still connecting or shutting down is among them.
"""
function live_worker_pids()
    pids = Int32[]
    @lock LIVE_LOCK for proc in LIVE_PROCESSES
        process_running(proc) || continue
        # It can end between the check and the lookup, which then throws.
        pid = try
            getpid(proc)
        catch e
            is_interrupt(e) && rethrow()
            continue
        end
        push!(pids, pid)
    end
    return pids
end

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

"""
    end_group!(w::Worker)

Put down what is left of the processes a worker started, once the worker itself has
exited: whatever its items started and did not wait for would otherwise outlive it,
and one that inherited its output pipe keeps that pipe from ever reaching EOF.

On Unix they are the worker's process group: SIGTERM, then SIGKILL after
`TERM_GRACE_SECONDS`. Called straight after the leader is reaped: a process group's
id is not reused while the group has a member, so the signal can only reach
processes of that group. A process that left the group, by starting a session of
its own, is out of reach. On Windows they are the worker's job object, ended and
closed once; a process cannot leave a job that does not allow it.
"""
function end_group!(w::Worker)
    Sys.iswindows() && return end_job!(@atomicswap w.job = C_NULL)
    pid = w.pid
    pid <= 0 && return nothing
    alive() = ccall(:uv_kill, Cint, (Cint, Cint), -Cint(pid), 0) == 0
    alive() || return nothing
    ccall(:uv_kill, Cint, (Cint, Cint), -Cint(pid), Base.SIGTERM)
    timedwait(() -> !alive(), TERM_GRACE_SECONDS; pollint=0.02) === :ok && return nothing
    ccall(:uv_kill, Cint, (Cint, Cint), -Cint(pid), Base.SIGKILL)
    return nothing
end

# JOBOBJECT_EXTENDED_LIMIT_INFORMATION, which `SetInformationJobObject` takes for its
# class 9: 144 bytes on 64-bit Windows, `LimitFlags` at offset 16.
struct JobBasicLimits
    per_process_user_time::Int64
    per_job_user_time::Int64
    limit_flags::UInt32
    minimum_working_set::Csize_t
    maximum_working_set::Csize_t
    active_process_limit::UInt32
    affinity::UInt
    priority_class::UInt32
    scheduling_class::UInt32
end

struct JobExtendedLimits
    basic::JobBasicLimits
    io::NTuple{6, UInt64}
    process_memory_limit::Csize_t
    job_memory_limit::Csize_t
    peak_process_memory::Csize_t
    peak_job_memory::Csize_t
end

const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = Cint(9)
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = UInt32(0x2000)
const PROCESS_SET_QUOTA_AND_TERMINATE = UInt32(0x0100 | 0x0001)

"""
    worker_job(pid) -> Ptr{Cvoid}

A job object holding process `pid`, on Windows, or `C_NULL`. Windows has no process
groups; a process a job holds brings every process it starts into the job, unless
the job lets them break away, which this one does not. The job is set to end what
it holds when its last handle closes, so a coordinator that dies takes its workers
and their processes with it. Assigned straight after the worker is spawned, before
it has run anything that could start a process. Anything that fails leaves the
worker outside a job, as it would be without one.
"""
function worker_job(pid::Integer)
    (Sys.iswindows() && pid > 0) || return C_NULL
    job = ccall((:CreateJobObjectW, "kernel32"), Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{UInt16}), C_NULL, C_NULL)
    job == C_NULL && return C_NULL
    limits = Ref(JobExtendedLimits(
        JobBasicLimits(0, 0, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, 0, 0, 0, 0, 0, 0),
        ntuple(_ -> UInt64(0), 6), 0, 0, 0, 0
    ))
    ok = ccall((:SetInformationJobObject, "kernel32"), Cint, (Ptr{Cvoid}, Cint, Ptr{JobExtendedLimits}, UInt32),
               job, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION, limits, sizeof(JobExtendedLimits)) != 0
    if ok
        h = ccall((:OpenProcess, "kernel32"), Ptr{Cvoid}, (UInt32, Cint, UInt32),
                  PROCESS_SET_QUOTA_AND_TERMINATE, 0, pid)
        ok = h != C_NULL && ccall((:AssignProcessToJobObject, "kernel32"), Cint, (Ptr{Cvoid}, Ptr{Cvoid}), job, h) != 0
        h == C_NULL || ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), h)
    end
    ok && return job
    ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), job)
    return C_NULL
end

# End every process the job holds, and close it. The caller owns `job` and passes
# it here once.
function end_job!(job::Ptr{Cvoid})
    job == C_NULL && return nothing
    ccall((:TerminateJobObject, "kernel32"), Cint, (Ptr{Cvoid}, UInt32), job, 1)
    ccall((:CloseHandle, "kernel32"), Cint, (Ptr{Cvoid},), job)
    return nothing
end

### Interrupts #############################################################

# Julia throws Ctrl-C into whichever task its first thread is running, or last ran.
# Without an interactive thread (`-t 1`, `-t 4,0`) that is often one of the tasks
# here: a worker's watcher, relay or reader, or a timer. Each hands it on rather
# than end with it or take it for a failure of its own.

# Atomic: set on the target's thread, read from whichever thread caught Ctrl-C.
mutable struct InterruptTarget
    @atomic task :: Union{Nothing,Task}
end

"""
    INTERRUPT_TARGET

`INTERRUPT_TARGET.task` is the task that an interrupt caught by one of this
package's tasks is handed to, or `nothing`. Whoever starts workers sets it for as
long as it wants those interrupts.
"""
const INTERRUPT_TARGET = InterruptTarget(nothing)

"""
    forward_interrupt(e) -> Bool

Throw `e` into [`INTERRUPT_TARGET`](@ref), once: the target is cleared as it is
thrown into, so the same Ctrl-C caught by a second task does not interrupt the
target's cleanup. Only from the target's own thread, where the target cannot be
running and scheduling it is safe. Julia delivers SIGINT to thread 1, where the
REPL and a script both run, so that is where the catching task is.
"""
function forward_interrupt(e::Exception)
    t = @atomic INTERRUPT_TARGET.task
    (t === nothing || t === current_task() || istaskdone(t)) && return false
    (t.sticky && Threads.threadid(t) == Threads.threadid()) || return false
    # Taken by exactly one of the tasks that caught the same Ctrl-C.
    (@atomicreplace INTERRUPT_TARGET.task t => nothing).success || return false
    schedule(t, e; error=true)
    return true
end

"""
    after(f, seconds) -> Timer

`Timer(_ -> f(), seconds)`, except that an interrupt thrown into the timer's task
while it waits is handed on and the wait goes on: in `Timer`'s own task it would
end the task, and the call with it. Closing the timer cancels the call.
"""
function after(f, seconds::Real)
    timer = Timer(seconds)
    # Shielded: a timeout fires however the work it bounds is being cancelled.
    shielded(() -> Threads.@spawn call_when_due(f, timer))
    return timer
end

function call_when_due(f, timer::Timer)
    while true
        try
            wait(timer)
            break
        catch e
            is_interrupt(e) || return nothing   # closed: cancelled
            forward_interrupt(e)
        end
    end
    f()
    return nothing
end

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
    catch e
        is_interrupt(e) && rethrow()
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
    @atomic w.ended_by = from
    @lock w.lock begin
        for (_, fut) in w.futures
            close(fut.value, cause)
        end
        empty!(w.futures)
    end
    # A worker that is already exiting (the coordinator closed the connection, or
    # the worker closed its own) gets a moment to finish. Signalled, it would report
    # the signal instead of the exit status it was about to give, and print a
    # backtrace for a crash that never happened.
    (w.closing || from === :connection_lost) && wait_exit(w.process, GRACEFUL_EXIT_SECONDS)
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
    # This task records the process's end, so it waits on through an interrupt.
    while true
        try
            wait(w.process)
            break
        catch e
            is_interrupt(e) || rethrow()
            forward_interrupt(e)
        end
    end
    terminate!(w, w.closing ? :close : :process_exit)
    end_group!(w)
    w.on_exit === nothing && return nothing
    try
        w.on_exit(w)
    catch e
        is_interrupt(e) && return forward_interrupt(e)
        @error "YATF: recording the exit of worker $(w.pid) failed" exception = (e, catch_backtrace())
    end
    return nothing
end

"""
    kill!(w)

Stop the worker now, without the grace `terminate!` allows: an interrupt is someone
asking for their terminal back, and across a pool the graceful windows add up to
most of a minute. Safe on a worker already being torn down, which is the common
case.
"""
function kill!(w::Worker)
    (; success) = @atomicreplace w.terminated false => true
    success && (@atomic w.ended_by = :interrupt)
    @lock w.lock begin
        for (_, fut) in w.futures
            close(fut.value, WorkerTerminatedException(w))
        end
        empty!(w.futures)
    end
    try
        process_exited(w.process) || signal!(w.pid, w.process, Base.SIGKILL)
    catch e
        is_interrupt(e) && rethrow()
        # Already gone, or never ours to signal. Either way there is nothing left
        # to stop, and an interrupt is not the moment to complain about it.
    end
    # What `terminate!` would do on its way out, which it skips for a worker
    # already marked terminated.
    untrack!(w.process)
    close(w.socket)
    return nothing
end

# Closing the connection is the shutdown request; `terminate!` gives the worker a
# moment to act on it before signalling.
function Base.close(w::Worker)
    @atomic w.closing = true
    close(w.socket)
    terminate!(w, :close)
    wait(w)
    return nothing
end

# Never throws: by now the worker is being torn down, and a task that failed on the
# way out has reported itself. Throwing would take down the slot and its queue.
function Base.wait(w::Worker)
    for t in (w.process_watch, w.messages)
        try
            wait(t)
        catch e
            is_interrupt(e) && rethrow()
        end
    end
    # The worker and its process group are gone by now, but the relay ends at EOF,
    # which a process that left the group and holds the pipe can put off for as long
    # as it runs. What the worker wrote has been read by then, or never will be.
    if timedwait(() -> istaskdone(w.output), GRACEFUL_EXIT_SECONDS; pollint=0.02) !== :ok
        close(w.process.out)
    end
    try
        wait(w.output)
    catch e
        is_interrupt(e) && rethrow()
    end
    return nothing
end

# A worker loads this package by UUID rather than by name. `using YATFWorkers` at
# the top level of the worker's `Main` needs the package in the active project's
# `[deps]`, and in a user's test environment it is only a dependency of YATF;
# `Base.require` on the `PkgId` finds it through the manifest either way.
const PKGID = Base.PkgId(@__MODULE__)

# What separates the entries of a path list in an environment variable.
const PATHSEP = Sys.iswindows() ? ";" : ":"

worker_startup_code(connect_timeout::Real) = string(
    "YATFWorkers = Base.require(Base.PkgId(Base.UUID(\"", PKGID.uuid, "\"), \"YATFWorkers\")); ",
    "YATFWorkers.startworker(", connect_timeout, ")")

"""
    Worker(; julia_args, threads, extra_env, dir, project, connect_timeout, redirect_io, redirect_fn, on_exit)

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
        on_exit=nothing,
    )
    env = Dict{String,String}(env)
    for (k, v) in extra_env
        env[k] = v
    end
    haskey(env, "JULIA_LOAD_PATH") || (env["JULIA_LOAD_PATH"] = join(LOAD_PATH, PATHSEP))
    haskey(env, "JULIA_DEPOT_PATH") || (env["JULIA_DEPOT_PATH"] = join(DEPOT_PATH, PATHSEP))
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
    # A process that fails at startup can be gone already, and a process that has
    # exited has no pid to give; `read_port` below then says how it ended.
    pid = try
        getpid(proc)
    catch e
        # Interrupted here, the process would be left waiting for a cookie.
        is_interrupt(e) && (kill(proc, Base.SIGKILL); untrack!(proc); rethrow())
        Int32(0)
    end
    job = worker_job(pid)
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
                   Dict{UInt64,Future}(), UInt64(0), 0, false, false, :none, job, on_exit)
        # Shielded: these watch the worker until it has gone, which on Ctrl-C is
        # what the caller's teardown waits for.
        e1, e2, e3 = Threads.Event(), Threads.Event(), Threads.Event()
        shielded() do
            w.process_watch = Threads.@spawn watch_and_terminate!(w, e1)
            w.output = Threads.@spawn redirect_worker_output(redirect_io, w, redirect_fn, proc, e2)
            w.messages = Threads.@spawn process_responses(w, e3)
        end
        wait(e1); wait(e2); wait(e3)
        return w
    catch
        try
            signal!(pid, proc, Base.SIGKILL)
        catch
        end
        untrack!(proc)
        @isdefined(sock) && close(sock)
        # The job is the worker's to end once it exists; until then, it is here.
        @isdefined(w) ? (terminate!(w, :start_failed); end_group!(w)) : end_job!(job)
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
    error("the worker process ", exit_description(proc), " before it was ready")
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
            is_interrupt(e) && forward_interrupt(e)
            CapturedException(e, catch_backtrace())
        end
        try
            put!(result, r)
        catch e
            # Closed by the timer: the caller has already given up. Interrupted, the
            # caller is woken by the target the interrupt goes to.
            is_interrupt(e) && forward_interrupt(e)
        end
    end
    timer = after(timeout) do
        close(result, ErrorException("timed out after $timeout seconds"))
    end
    try
        r = take!(result)
        # An interrupt stays one, so the caller does not take it for a failed start.
        r isa CapturedException && throw(is_interrupt(r.ex) ? r.ex : r)
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
    while true
        try
            while !eof(proc)
                line = readline(proc)
                isempty(line) || (fn(io, w.pid, line); flush(io))
            end
            return nothing
        catch e
            # `eof` and `readline` wait on the pipe's buffer and take nothing from it
            # until a line is whole, so an interrupt loses no output.
            is_interrupt(e) && (forward_interrupt(e); continue)
            # Without a relay the worker blocks as soon as the pipe fills, so it
            # cannot be kept.
            @error "YATF: could not relay the output of worker $(w.pid); terminating it" exception=(e, catch_backtrace())
            terminate!(w, :output_error, e)
            return nothing
        end
    end
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
                # The waiter may have given up and closed the channel, as a request
                # past its deadline does: the reply is late, not wrong. `put!` then
                # raises whatever reason the channel was closed with.
                try
                    put!(fut.value, frame.payload)
                catch e
                    isopen(fut.value) && rethrow()
                end
            elseif frame.kind === KIND_ERROR
                close(fut.value, RemoteException(w.pid, string(frame.payload)))
            else
                error("worker $(w.pid) sent a reply of unknown kind $(frame.kind)")
            end
        end
    catch e
        if is_interrupt(e)
            # A large payload is read straight into its buffer, so a read cut short
            # has taken bytes the next one would need: the connection is done. The
            # target the interrupt went to takes the worker down with the rest; with
            # none, it goes now, or its requests would wait for replies nobody reads.
            forward_interrupt(e) || kill!(w)
        elseif e isa EOFError || e isa Base.IOError
            terminate!(w, w.closing ? :close : :connection_lost)   # the coordinator closed it, or the worker died
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

"""
    wide_display(f)

Run `f` with a display size no terminal has. A worker's output is a pipe, which
`displaysize` calls eighty columns wide, and a profile report laid out to that
width cuts off the part that names what ran.
"""
wide_display(f) = withenv(f, "COLUMNS" => "10000", "LINES" => "10000")

# On SIGINFO or SIGUSR1 the runtime prints every thread's backtrace and collects a
# short CPU profile, which `Profile` reports afterwards from a task. In a deadlock
# the blocked tasks matter and no thread runs them, so their backtraces go first.
# Best effort: a worker without the hook is still a worker.
function install_inspection_hook()
    INSPECT_SIGNAL === nothing && return nothing
    try
        Profile = Base.require(Base.PkgId(Base.UUID("9abbd945-dff8-562f-b5e8-e1ebf5ef1b79"), "Profile"))
        report = Profile.peek_report[]
        Profile.peek_report[] = function ()
            ccall(:jl_print_task_backtraces, Cvoid, (Cint,), 0)
            wide_display(report)
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
        spec = frame.payload
        try
            println(stdout, record_run(spec)); flush(stdout)
            result = run_item(spec)
            println(stdout, record_done(spec, result)); flush(stdout)
            return KIND_RESULT, result
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

