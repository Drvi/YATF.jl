# The run state file: binary, fixed-stride, written as the run goes, so that a
# killed coordinator still leaves behind which items passed and how long they took.
# It also holds what it takes to run the same run again elsewhere: a run state
# downloaded from CI and passed to `runtests(replay = path)` brings back the items,
# the configuration, the profiles and the seed, and says how the environment
# differs from the one it was recorded in.
#
# Layout:
#
#   header      96 B, fixed, holds the section offsets
#   strings     every string in the file, referenced by index
#   meta        key/value pairs of strings: platform, invocation, environment
#   profiles    name, julia args, threads, env, init, test_end, preferences path and content
#   units       n_units x 16 B: item span, profile, exclusive, chain
#   items       n_items x 16 B: name, file, line, unit
#   statuses    n_items x 32 B, fixed stride, overwritten in place
#   memory      fixed block, rewritten whenever a peak is set
#   events      32 B each, appended: every attempt, and every worker's start and end
#
# After the run starts only the statuses, the memory block, the events and the
# header's flags and end time are written, which keeps a crash from corrupting
# anything else; a reader drops a torn last event.

using CRC32c: crc32c

const RS_MAGIC = 0x59415446   # "YATF"
const RS_VERSION = UInt32(6)
# 40 bytes of counts and times, then eight section offsets; the rest is room to
# add a field without moving every section.
const RS_HEADER_BYTES = 96
const RS_STATUS_BYTES = 32
const RS_MEMORY_BYTES = 64
const RS_EVENT_BYTES = 32

const RS_FLAG_COMPLETE = UInt32(1) << 0
const RS_FLAG_DRY_RUN = UInt32(1) << 1
const RS_FLAG_CANCELLED = UInt32(1) << 2

const EVENT_ATTEMPT = UInt8(1)       # an attempt at an item ended
const EVENT_WORKER_UP = UInt8(2)     # a worker process started
const EVENT_WORKER_DOWN = UInt8(3)   # a worker process ended

# Why a worker process ended, as `Worker.ended_by` names it; the index is what the
# file holds. `:connection_lost` and `:process_exit` mean it ended on its own.
const WORKER_ENDS = (
    :close, :timeout, :connection_lost, :process_exit, :memory_guard, :interrupt,
    :init_failed, :protocol_error, :output_error, :start_failed,
)
worker_end_code(by::Symbol) = UInt8(something(findfirst(==(by), WORKER_ENDS), 0))
worker_end(code::Integer) = 1 <= code <= length(WORKER_ENDS) ? WORKER_ENDS[code] : :unknown

# Write the fixed-layout record `ref` points at, whole; the record structs' layout
# is the file format. The caller refills one `Ref`, because `write(io, x)` of a
# number boxes it, and a run writes tens of thousands of fields.
@inline function write_record(io::IO, ref::Base.RefValue{T}) where {T}
    GC.@preserve ref unsafe_write(
        io, Ptr{UInt8}(Base.unsafe_convert(Ptr{T}, ref)), sizeof(T)
    )
    return nothing
end

function read_record(io::IO, ::Type{T}) where {T}
    ref = Ref{T}()
    GC.@preserve ref unsafe_read(io, Ptr{UInt8}(Base.unsafe_convert(Ptr{T}, ref)), sizeof(T))
    return ref[]
end

# The header as it sits on disk: counts and times, then where each section starts.
# The flags and the end time are rewritten in place when the run finishes, at the
# offsets this layout gives them.
struct Header
    magic::UInt32
    version::UInt32
    flags::UInt32
    n_items::UInt32
    n_units::UInt32
    n_profiles::UInt16
    pad::UInt16
    start_unix::Float64
    end_unix::Float64
    off_strings::UInt32
    off_meta::UInt32
    off_profiles::UInt32
    off_units::UInt32
    off_items::UInt32
    off_status::UInt32
    off_memory::UInt32
    off_events::UInt32
end
@assert sizeof(Header) <= RS_HEADER_BYTES

header_offset(field::Symbol) = Int(fieldoffset(Header, Base.fieldindex(Header, field)))

# One item's place in the plan, and one unit's, as they sit on disk.
struct ItemRecord
    name::UInt32
    file::UInt32
    line::UInt32
    unit::UInt32
end

# Sixteen bytes, two of them padding after `exclusive`: the compiler's layout, so
# it cannot drift from the struct.
struct UnitRecord
    first::UInt32
    last::UInt32
    profile::UInt8
    exclusive::UInt8
    chain::UInt32
end

# One item's status as it sits on disk. Every field lands on its natural alignment,
# so there is no padding.
struct StatusRecord
    state::UInt8
    attempt::Int8
    slot::Int16
    start_off::Float32
    elapsed::Float32
    compile::Float32
    recompile::Float32
    alloc_mb::Float32
    peak_rss_mb::Float32   # the worker process's largest resident size when the item ended
    pid::Int32             # the process the last attempt ran in, 0 for none
end
@assert sizeof(StatusRecord) == RS_STATUS_BYTES

# One event as it sits on disk, natural alignment throughout. For an attempt,
# `state` is its outcome and `item`/`attempt` say which; for a worker's end, `state`
# is why (`WORKER_ENDS`) and `exitcode`/`signal` how.
struct EventRecord
    kind::UInt8
    state::UInt8
    attempt::Int8
    reserved::UInt8
    slot::Int16
    reserved2::Int16
    item::Int32
    pid::Int32
    t0::Float32   # seconds since the run started: when it began
    t1::Float32   # when it ended; a worker's start has t1 == t0
    exitcode::Int32
    signal::Int32
end
@assert sizeof(EventRecord) == RS_EVENT_BYTES

struct RunStateFile
    io::IOStream
    path::String
    off_status::UInt32
    off_memory::UInt32
    n_items::UInt32
    lock::ReentrantLock
    # Refilled for every record written, so a run of thousands of them allocates
    # nothing. Only ever touched under `lock`.
    status_ref::Base.RefValue{StatusRecord}
    event_ref::Base.RefValue{EventRecord}
end

### Writing ################################################################

struct StringTable
    index::Dict{String, UInt32}
    order::Vector{String}
end
StringTable() = StringTable(Dict{String, UInt32}(), String[])

# Not `get!` with a do-block: the closure allocates on every call, hits included,
# and a run interns two strings per item before it starts.
function intern!(t::StringTable, s::AbstractString)
    str = String(s)
    i = get(t.index, str, UInt32(0))
    i == 0 || return i
    push!(t.order, str)
    i = UInt32(length(t.order))
    t.index[str] = i
    return i
end

function write_strings(io::IO, t::StringTable)
    write(io, UInt32(length(t.order)))
    for s in t.order
        bytes = codeunits(s)
        write(io, UInt32(length(bytes)))
        write(io, bytes)
    end
    return nothing
end

read_text(path) = (path isa AbstractString && isfile(path)) ? read(path, String) : ""

# The seed as it is printed and passed back: a Julia literal, `runtests(seed = 0x…)`.
seed_text(seed::UInt64) = string("0x", string(seed; base = 16, pad = 16))

# The run settings a replay puts back, with how each is read out of the file. What
# only changes how a run is presented is recorded but not replayed.
const REPLAYED_SETTINGS = (
    :workers => s -> parse(Int, s), :threads => identity,
    :timeout => s -> parse(Int, s), :init_timeout => s -> parse(Int, s),
    :test_end_timeout => s -> parse(Int, s), :retries => s -> parse(Int, s),
    :failfast => s -> parse(Bool, s), :item_failfast => s -> parse(Bool, s),
    :logs => Symbol, :memory_threshold => s -> parse(Float64, s),
    :seed => s -> parse(UInt64, s),
)

run_setting(cfg::RunConfig, key::Symbol) =
    key === :timeout ? cfg.timeout_s : key === :init_timeout ? cfg.init_timeout_s :
    key === :test_end_timeout ? cfg.test_end_timeout_s : getfield(cfg, key)

# Variables a run's behaviour can depend on, and the ones that find the CI job it
# ran in. Anything that looks like a credential stays out: the file is meant to be
# passed around.
function environment_variables()
    keep(k) = startswith(k, "JULIA_") || startswith(k, "YATF_") || k == "CI" ||
        k in ("GITHUB_REPOSITORY", "GITHUB_SHA", "GITHUB_REF", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT",
              "GITHUB_WORKFLOW", "GITHUB_JOB", "RUNNER_OS", "RUNNER_ARCH")
    secret(k) = occursin(r"TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|AUTH|KEY"i, k)
    return join((string(k, "=", v) for (k, v) in sort!(collect(ENV); by = first) if keep(k) && !secret(k)), '\n')
end

# Where the run ran, how it was asked for, and against which environment. The test
# environment is active by the time this is called, so its files are the ones the
# items resolved against.
function run_meta(p::Plan)
    cfg = p.cfg
    env = something(Base.active_project(), "")
    manifest = isempty(env) ? nothing : Base.project_file_manifest_path(env)
    meta = Pair{String, String}[
        "julia" => string(VERSION), "julia_commit" => Base.GIT_VERSION_INFO.commit,
        "yatf" => string(pkgversion(@__MODULE__)), "yatf_revision" => project_revision(pkgdir(@__MODULE__)),
        "host" => gethostname(), "machine" => Sys.MACHINE, "cpu_threads" => string(Sys.CPU_THREADS),
        "memory_bytes" => string(Sys.total_memory()),
        "coordinator_threads" => string(Threads.nthreads(:default), ",", Threads.nthreads(:interactive)),
        "environment_variables" => environment_variables(),
        "project_id" => project_id(p.root), "revision" => project_revision(p.root),
        "selection" => p.selection,
        "environment" => env, "environment_project" => read_text(env),
        "environment_manifest" => read_text(manifest),
    ]
    for key in RUN_KEYS
        push!(meta, string(key) => key === :seed ? seed_text(cfg.seed) : string(run_setting(cfg, key)))
    end
    push!(meta, "order_first" => join(cfg.order_first, '\n'), "order_last" => join(cfg.order_last, '\n'))
    return meta
end

"""
    init_run_state(path, plan; dry_run=false) -> RunStateFile

Write everything that is known before the run starts, including a full status
section of `unseen` records, so that every later write is an overwrite at a
known offset.
"""
function init_run_state(path::AbstractString, p::Plan; dry_run::Bool = false)
    mkpath(dirname(path))
    io = open(path, "w+")
    strings = StringTable()
    # Two per item — its name and its file — plus the profiles and the metadata.
    sizehint!(strings.index, 2 * nitems(p) + 64)
    sizehint!(strings.order, 2 * nitems(p) + 64)

    profiles = IOBuffer()
    write(profiles, UInt32(length(p.profiles)))
    for prof in p.profiles
        write(profiles, intern!(strings, string(prof.name)))
        write(profiles, UInt32(length(prof.julia_args)))
        for a in prof.julia_args
            write(profiles, intern!(strings, a))
        end
        write(profiles, intern!(strings, prof.threads))
        write(profiles, UInt32(length(prof.env)))
        for (k, v) in prof.env
            write(profiles, intern!(strings, k))
            write(profiles, intern!(strings, v))
        end
        write(profiles, intern!(strings, expr_text(prof.init)))
        write(profiles, intern!(strings, expr_text(prof.test_end)))
        write(profiles, intern!(strings, prof.preferences))
        # The content too: the path is one on the machine that ran it.
        write(profiles, intern!(strings, read_text(prof.preferences)))
    end

    units = IOBuffer()
    write(units, UInt32(length(p.units)))
    uref = Ref{UnitRecord}()
    for u in 1:length(p.units)
        span = p.units.span[u]
        uref[] = UnitRecord(
            UInt32(first(span)), UInt32(last(span)), UInt8(p.units.profile[u]),
            UInt8(p.units.exclusive[u]), intern!(strings, string(p.units.chain[u]))
        )
        write_record(units, uref)
    end

    items = IOBuffer()
    write(items, UInt32(nitems(p)))
    iref = Ref{ItemRecord}()
    for i in 1:nitems(p)
        iref[] = ItemRecord(
            intern!(strings, p.items.name[i]), intern!(strings, itemfile(p, i)),
            UInt32(p.items.line[i]), UInt32(p.items.unit[i])
        )
        write_record(items, iref)
    end

    meta = IOBuffer()
    pairs_ = run_meta(p)
    write(meta, UInt32(length(pairs_)))
    for (k, v) in pairs_
        write(meta, intern!(strings, k), intern!(strings, v))
    end

    strbuf = IOBuffer()
    write_strings(strbuf, strings)

    off_strings = UInt32(RS_HEADER_BYTES)
    off_meta = off_strings + UInt32(strbuf.size)
    off_profiles = off_meta + UInt32(meta.size)
    off_units = off_profiles + UInt32(profiles.size)
    off_items = off_units + UInt32(units.size)
    off_status = off_items + UInt32(items.size)
    off_memory = off_status + UInt32(RS_STATUS_BYTES * nitems(p))
    off_events = off_memory + UInt32(RS_MEMORY_BYTES)

    write_record(io, Ref(Header(
        RS_MAGIC, RS_VERSION, dry_run ? RS_FLAG_DRY_RUN : UInt32(0), nitems(p), length(p.units),
        length(p.profiles), 0, time(), 0.0, off_strings, off_meta, off_profiles, off_units,
        off_items, off_status, off_memory, off_events
    )))
    write(io, zeros(UInt8, RS_HEADER_BYTES - sizeof(Header)))
    write(io, take!(strbuf)); write(io, take!(meta)); write(io, take!(profiles))
    write(io, take!(units)); write(io, take!(items))
    blank = Ref{StatusRecord}()
    for _ in 1:nitems(p)
        write_status_record(
            io, blank, UNSEEN, Int8(0), SlotIdx(0), 0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0, 0
        )
    end
    write(io, zeros(UInt8, RS_MEMORY_BYTES))
    flush(io)
    return RunStateFile(
        io, String(path), off_status, off_memory, UInt32(nitems(p)),
        ReentrantLock(), Ref{StatusRecord}(), Ref{EventRecord}()
    )
end

function write_status_record(
        io::IO, ref::Base.RefValue{StatusRecord}, state::ItemState, attempt::Int8,
        slot::SlotIdx, start_off, elapsed, compile, recompile, alloc_mb, peak_rss_mb, pid
    )
    ref[] = StatusRecord(
        UInt8(state), attempt, Int16(slot), Float32(start_off), Float32(elapsed),
        Float32(compile), Float32(recompile), Float32(alloc_mb), Float32(peak_rss_mb),
        Int32(pid)
    )
    write_record(io, ref)
    return nothing
end

# Every write after the header: in place (at the end, for `at < 0`), under the lock,
# flushed, and never a reason to fail the run — the tests matter more than the
# record of them. A crash loses at most the record being written, and a reader
# treats a record it cannot make sense of as `unseen`.
function update!(f, rsf::Union{Nothing, RunStateFile}, at::Integer)
    rsf === nothing && return nothing
    @lock rsf.lock try
        # Closed means the run is over; a worker that exits after that has nothing
        # left to add to it.
        isopen(rsf.io) || return nothing
        at < 0 ? seekend(rsf.io) : seek(rsf.io, at)
        f(rsf.io)
        flush(rsf.io)
    catch e
        @warn "YATF: could not write the run state" exception = e maxlog = 1
    end
    return nothing
end

function write_status!(
        rsf::Union{Nothing, RunStateFile}, i::Integer, state::ItemState,
        attempt::Integer, slot::Integer; start_off = 0.0, elapsed = 0.0,
        compile = 0.0, recompile = 0.0, alloc_mb = 0.0, peak_rss_mb = 0.0, pid = 0
    )
    (rsf === nothing || !(1 <= i <= rsf.n_items)) && return nothing
    update!(rsf, Int(rsf.off_status) + (Int(i) - 1) * RS_STATUS_BYTES) do io
        write_status_record(
            io, rsf.status_ref, state, Int8(attempt), SlotIdx(slot), start_off,
            elapsed, compile, recompile, alloc_mb, peak_rss_mb, pid
        )
    end
end

function append_event!(
        rsf::Union{Nothing, RunStateFile}, kind::UInt8, state::Integer, slot::Integer, pid::Integer,
        t0::Real, t1::Real; item::Integer = 0, attempt::Integer = 0, exitcode::Integer = 0, signal::Integer = 0
    )
    update!(rsf, -1) do io
        rsf.event_ref[] = EventRecord(
            kind, UInt8(state), Int8(attempt), 0x00, Int16(slot), Int16(0), Int32(item), Int32(pid),
            Float32(t0), Float32(t1), Int32(exitcode), Int32(signal)
        )
        write_record(io, rsf.event_ref)
    end
end

write_memory!(rsf::Union{Nothing, RunStateFile}, m) = update!(rsf, rsf === nothing ? 0 : rsf.off_memory) do io
    write(io, Float32(m.peak_total_bytes / 2^20), Float32(m.peak_total_at), Float32(m.peak_single_bytes / 2^20))
    write(io, Int32(m.peak_single_pid), Float32(phase_peak(m, PHASE_SETUP) / 2^20))
    write(io, Float32(phase_peak(m, PHASE_TEST) / 2^20), Int32(m.nprocs_peak))
end

function finish_run_state!(rsf::Union{Nothing, RunStateFile}; cancelled::Bool = false)
    rsf === nothing && return nothing
    update!(io -> write(io, RS_FLAG_COMPLETE | (cancelled ? RS_FLAG_CANCELLED : UInt32(0))), rsf, header_offset(:flags))
    update!(io -> write(io, time()), rsf, header_offset(:end_unix))
    @lock rsf.lock close(rsf.io)
    return nothing
end

### Reading ################################################################

struct RunStateItem
    name::String
    file::String
    line::Int32
    unit::Int32
end

struct RunStateUnit
    span::UnitRange{Int32}
    profile::Int32
    exclusive::Bool
    chain::Symbol
end

struct RunStateStatus
    state::ItemState
    attempt::Int8
    slot::Int16
    start_off::Float32
    elapsed::Float32
    compile::Float32
    recompile::Float32
    alloc_mb::Float32
    peak_rss_mb::Float32
    pid::Int32
end

"""
    RunStateEvent

One thing that happened during a run, in the order it happened: `kind` is
`:attempt` (an attempt at `item` ended in `state`), `:worker_up` or `:worker_down`
(the process `pid` of `slot` started or ended; `ended_by`, `exitcode` and `signal`
say why and how). Times are seconds since the run started.
"""
struct RunStateEvent
    kind::Symbol
    state::ItemState
    ended_by::Symbol
    attempt::Int8
    slot::Int16
    item::Int32
    pid::Int32
    t0::Float32
    t1::Float32
    exitcode::Int32
    signal::Int32
end

struct RunStateRecord
    path::String
    version::UInt32
    complete::Bool
    dry_run::Bool
    cancelled::Bool
    start_unix::Float64
    end_unix::Float64
    meta::Dict{String, String}
    profiles::Dict{Symbol, Profile}
    preferences::Dict{Symbol, String}   # profile name => its preferences file's content, as recorded
    units::Vector{RunStateUnit}
    items::Vector{RunStateItem}
    statuses::Vector{RunStateStatus}
    memory::@NamedTuple{peak_total_mb::Float32, peak_total_at::Float32, peak_single_mb::Float32,
        peak_single_pid::Int32, setup_peak_mb::Float32, test_peak_mb::Float32, nprocs_peak::Int32}
    events::Vector{RunStateEvent}
    truncated::Bool
end

"""
    read_run_state(path) -> Union{Nothing,RunStateRecord}

Read a run state file. Never throws: a file that is truncated, from a crashed
run, or written by a different version comes back as much as can be read (or
`nothing`), because a broken record of an old run must not stop a new one.
"""
function read_run_state(path::AbstractString)
    bytes = try
        read(path)
    catch
        return nothing
    end
    length(bytes) >= RS_HEADER_BYTES || return nothing
    io = IOBuffer(bytes)
    total = length(bytes)
    try
        h = read_record(io, Header)
        (h.magic == RS_MAGIC && h.version == RS_VERSION) || return nothing
        n_items = bounded(h.n_items, total)

        seek(io, Int(h.off_strings))
        strings = read_strings(io, total)
        seek(io, Int(h.off_meta))
        meta = Dict{String, String}()
        for _ in 1:bounded(read(io, UInt32), total)
            k = lookup(strings, read(io, UInt32))
            meta[k] = lookup(strings, read(io, UInt32))
        end

        seek(io, Int(h.off_profiles))
        profiles, preferences = read_profiles_section(io, strings)

        seek(io, Int(h.off_units))
        units = map(1:bounded(read(io, UInt32), total)) do _
            r = read_record(io, UnitRecord)
            RunStateUnit(Int32(r.first):Int32(r.last), Int32(r.profile), r.exclusive != 0, Symbol(lookup(strings, r.chain)))
        end

        seek(io, Int(h.off_items))
        items = map(1:min(bounded(read(io, UInt32), total), n_items)) do _
            r = read_record(io, ItemRecord)
            RunStateItem(lookup(strings, r.name), lookup(strings, r.file), Int32(r.line), Int32(r.unit))
        end

        statuses = RunStateStatus[]
        truncated = false
        for i in 1:n_items
            at = Int(h.off_status) + (i - 1) * RS_STATUS_BYTES
            if at + RS_STATUS_BYTES > total
                truncated = true
                push!(statuses, RunStateStatus(UNSEEN, Int8(0), Int16(0), 0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0, Int32(0)))
                continue
            end
            seek(io, at)
            push!(statuses, read_status_record(io))
        end

        memory = if Int(h.off_memory) + 28 <= total
            seek(io, Int(h.off_memory))
            (; peak_total_mb = read(io, Float32), peak_total_at = read(io, Float32), peak_single_mb = read(io, Float32),
                peak_single_pid = read(io, Int32), setup_peak_mb = read(io, Float32), test_peak_mb = read(io, Float32),
                nprocs_peak = read(io, Int32))
        else
            truncated = true
            (; peak_total_mb = 0.0f0, peak_total_at = 0.0f0, peak_single_mb = 0.0f0, peak_single_pid = Int32(0),
                setup_peak_mb = 0.0f0, test_peak_mb = 0.0f0, nprocs_peak = Int32(0))
        end

        events = RunStateEvent[]
        at = Int(h.off_events)
        while at + RS_EVENT_BYTES <= total
            seek(io, at)
            e = read_record(io, EventRecord)
            kind = e.kind == EVENT_ATTEMPT ? :attempt : e.kind == EVENT_WORKER_UP ? :worker_up :
                e.kind == EVENT_WORKER_DOWN ? :worker_down : :unknown
            state = kind === :attempt && e.state <= UInt8(CANCELLED) ? ItemState(e.state) : UNSEEN
            ended_by = kind === :worker_down ? worker_end(e.state) : :none
            push!(events, RunStateEvent(kind, state, ended_by, e.attempt, e.slot, e.item, e.pid, e.t0, e.t1, e.exitcode, e.signal))
            at += RS_EVENT_BYTES
        end
        return RunStateRecord(
            String(path), h.version, h.flags & RS_FLAG_COMPLETE != 0,
            h.flags & RS_FLAG_DRY_RUN != 0, h.flags & RS_FLAG_CANCELLED != 0,
            h.start_unix, h.end_unix, meta, profiles, preferences, units, items, statuses,
            memory, events, truncated
        )
    catch e
        e isa InterruptException && rethrow()
        # Any exception, not a list of expected ones: the caller has a run to finish
        # and no use for a file it cannot read. Reader bugs still surface, because
        # the round-trip tests assert on what a written file reads back as.
        # `JULIA_DEBUG=YATF` shows what went wrong.
        @debug "YATF: could not read run state $(path)" exception = (e, catch_backtrace())
        return nothing
    end
end

function read_status_record(io::IO)
    r = read_record(io, StatusRecord)
    return RunStateStatus(
        r.state <= UInt8(CANCELLED) ? ItemState(r.state) : UNSEEN, r.attempt, r.slot,
        r.start_off, r.elapsed, r.compile, r.recompile, r.alloc_mb, r.peak_rss_mb, r.pid
    )
end

"""
    bounded(n, limit) -> Int

A count read out of a file, capped at what the file could hold: every record takes
at least a byte. Uncapped, a garbled count sizes an allocation, and a loop that only
pushes, or a comprehension sized up front, does not stop at the end of the file.
"""
bounded(n::Integer, limit::Integer) = min(Int(n), Int(limit))

function read_strings(io::IO, total::Integer)
    n = bounded(read(io, UInt32), total)
    out = String[]
    for _ in 1:n
        len = Int(read(io, UInt32))
        (position(io) + len > total) && break
        push!(out, String(read(io, len)))
    end
    return out
end

lookup(strings::Vector{String}, i::UInt32) = (1 <= i <= length(strings)) ? strings[i] : ""

function read_profiles_section(io::IO, strings)
    n = bounded(read(io, UInt32), bytesavailable(io))
    profiles = Dict{Symbol, Profile}()
    preferences = Dict{Symbol, String}()
    for _ in 1:n
        name = Symbol(lookup(strings, read(io, UInt32)))
        nargs = bounded(read(io, UInt32), bytesavailable(io))
        args = String[lookup(strings, read(io, UInt32)) for _ in 1:nargs]
        threads = lookup(strings, read(io, UInt32))
        nenv = bounded(read(io, UInt32), bytesavailable(io))
        env = Pair{String, String}[]
        for _ in 1:nenv
            k = lookup(strings, read(io, UInt32)); v = lookup(strings, read(io, UInt32))
            push!(env, k => v)
        end
        init = parse_block(lookup(strings, read(io, UInt32)))
        test_end = parse_block(lookup(strings, read(io, UInt32)))
        path = lookup(strings, read(io, UInt32))
        content = lookup(strings, read(io, UInt32))
        profiles[name] = Profile(name, args, threads, env, init, test_end, path)
        isempty(content) || (preferences[name] = content)
    end
    return profiles, preferences
end

function parse_block(str::AbstractString)
    isempty(strip(str)) && return Expr(:block)
    ex = try
        Meta.parseall(str)
    catch
        return Expr(:block)
    end
    return normalize_block(Expr(:block, ex.args...))
end

# An expression that has been printed and parsed back is not `==` to the original
# — line numbers move and blocks nest — so both sides are normalized before they
# are written or compared. Otherwise every run would think the recorded
# configuration differs from its own and say so.
function normalize_block(ex::Expr)
    out = Base.remove_linenums!(deepcopy(ex))
    while out isa Expr && out.head === :block && length(out.args) == 1 &&
            out.args[1] isa Expr && out.args[1].head === :block
        out = out.args[1]
    end
    return out
end

expr_text(ex::Expr) = string(normalize_block(ex))

# What someone who was handed the file needs first: where and how it ran, what did
# not pass, what each worker did before it ended, and how to run it again.
function Base.show(io::IO, ::MIME"text/plain", rs::RunStateRecord)
    m(k) = get(rs.meta, k, "")
    println(io, "YATF run state ", rs.path, rs.complete ? "" : " (incomplete: the run did not finish)")
    took = rs.end_unix > rs.start_unix ? string(", took ", fmt_seconds(rs.end_unix - rs.start_unix)) : ""
    println(io, "  started ", Libc.strftime("%Y-%m-%d %H:%M:%S", rs.start_unix), took, rs.cancelled ? ", cancelled" : "")
    println(io, "  julia ", m("julia"), " (", first(m("julia_commit"), 10), ") · ", m("machine"), " · ",
        m("cpu_threads"), " CPU threads · ", fmt_gib(something(tryparse(Int, m("memory_bytes")), 0)), " · host ", m("host"))
    println(io, "  project ", m("project_id"), isempty(m("revision")) ? "" : string(" · rev ", first(m("revision"), 10)),
        " · YATF ", m("yatf"), isempty(m("yatf_revision")) ? "" : string(" (", first(m("yatf_revision"), 10), ")"))
    println(io, "  seed ", m("seed"), " · workers ", m("workers"), " · threads ", m("threads"), " · timeout ", m("timeout"),
        "s · retries ", m("retries"), isempty(m("selection")) ? "" : string(" · selected ", m("selection")))
    isempty(m("environment_manifest")) || println(io, "  environment recorded: ",
        count(l -> startswith(l, "[[deps."), eachline(IOBuffer(m("environment_manifest")))), " packages in its manifest")
    states = [s.state for s in rs.statuses]
    passed = count(==(PASSED), states)
    tally = [passed > 0 ? ["$passed passed"] : String[]; state_tally(states)]
    println(io, "  ", length(rs.items), " items: ", join(tally, ", "))
    bad = [i for i in eachindex(rs.items, rs.statuses) if is_non_pass(rs.statuses[i].state) || rs.statuses[i].state === RUNNING]
    isempty(bad) || println(io, "  not passed:")
    for i in bad
        it, st = rs.items[i], rs.statuses[i]
        println(io, "    ", rpad(repr(it.name), 30), " ", rpad(string(st.state), 12), " attempt ", st.attempt,
            " · worker ", st.slot, " (pid ", st.pid, ") · ", fmt_seconds(st.elapsed), " · ", it.file, ":", it.line)
    end
    downs = filter(e -> e.kind === :worker_down && e.ended_by !== :close, rs.events)
    isempty(downs) || println(io, "  workers that did not end normally:")
    for d in downs
        ran = [rs.items[e.item].name for e in rs.events if e.kind === :attempt && e.pid == d.pid && 1 <= e.item <= length(rs.items)]
        # The signal's number alone: names and some numbers differ between systems,
        # and this may not be the one that recorded it.
        how = d.signal != 0 ? string("signal ", d.signal) : string("exit code ", d.exitcode)
        println(io, "    worker ", d.slot, " pid ", d.pid, " at ", fmt_seconds(d.t0), ": ", worker_end_text(d.ended_by),
            " (", how, ") · had run ", length(ran), isempty(ran) ? "" : string(": ", join(repr.(last(ran, 5)), ", "), length(ran) > 5 ? ", …" : ""))
    end
    print(io, "  run it again with YATF.runtests(replay = ", repr(rs.path), ")")
end

### Where run states live ##################################################

"""
    runstate_dir(root) -> String

`\$YATF_RUNSTATE_DIR` when set, otherwise a scratch space keyed by the project
path, so nothing lands in the repository. The path is printed at the end of a
run so CI can upload it.
"""
function runstate_dir(root::AbstractString)
    dir = get(ENV, "YATF_RUNSTATE_DIR", "")
    isempty(dir) || return dir
    key = string(crc32c(abspath(root)); base = 16, pad = 8)
    return joinpath(first(DEPOT_PATH), "scratchspaces", "yatf", key, "runs")
end

# Named for when the run started, so that names sort oldest first. A file already
# there, a run state downloaded from CI say, is never written over: the new name
# takes a suffix instead, one that sorts after it.
function new_runstate_path(root::AbstractString)
    dir = runstate_dir(root)
    stem = string(round(Int, time()), "-", getpid())
    path = joinpath(dir, stem * ".yatf")
    n = 1
    while ispath(path)
        n += 1
        path = joinpath(dir, string(stem, "_", n, ".yatf"))
    end
    return path
end

function runstate_files(root::AbstractString)
    dir = runstate_dir(root)
    isdir(dir) || return String[]
    files = filter!(endswith(".yatf"), readdir(dir; join = true))
    return sort!(files)   # names start with a unix timestamp, so this is oldest-first
end

const KEEP_RUNS = 20

# Only the run states this machine recorded are pruned, and the newest `keep` of
# them stay. One recorded elsewhere, a CI artifact downloaded into the directory
# say, and one that cannot be read are never deleted: nothing shows they are ours.
function prune_runstates(root::AbstractString, keep::Int = KEEP_RUNS)
    here = gethostname()
    ours = filter(runstate_files(root)) do f
        rs = read_run_state(f)
        rs !== nothing && get(rs.meta, "host", "") == here
    end
    for f in ours[1:max(0, length(ours) - keep)]
        try
            rm(f; force = true)
        catch
        end
    end
    return nothing
end

latest_runstate(root::AbstractString) = (fs = runstate_files(root); isempty(fs) ? nothing : last(fs))

"""
    history(root) -> History

Per-item durations and last-run failures, taken from the most recent runs, and
when the newest of them started. Only items that actually ran contribute; a name
that has never been seen simply has no estimate and is scheduled as if it were new.
"""
function history(root::AbstractString; nruns::Int = 5)
    seconds = Dict{String, Float64}()
    failed = Dict{String, Int}()
    since = 0.0
    files = runstate_files(root)
    isempty(files) && return History()
    recent = files[max(1, end - nruns + 1):end]
    for (k, f) in enumerate(recent)
        ago = length(recent) - k
        rs = read_run_state(f)
        rs === nothing && continue
        rs.dry_run && continue
        since = rs.start_unix
        for (i, it) in enumerate(rs.items)
            i <= length(rs.statuses) || break
            st = rs.statuses[i]
            if st.state === UNSEEN
                # A cancelled run stopped before reaching these. They did not pass,
                # and after a run that stopped early, what did not pass is exactly
                # what `retry_failed` should run again.
                ago == 0 && rs.cancelled && (failed[it.name] = 0)
                continue
            end
            st.elapsed > 0 && (seconds[it.name] = Float64(st.elapsed))
            # Runs are read oldest first, so a newer failure overwrites an older one.
            is_non_pass(st.state) && (failed[it.name] = ago)
        end
    end
    return History(seconds, failed, since)
end

"""
    project_revision(root) -> String

The commit the tests run from, or `""`, so a run state (one downloaded from CI,
say) says what to check out. Read from `.git` rather than by running `git`, which
would put a subprocess between `runtests()` and the first item. It names the commit,
not the working tree: local edits do not change it.
"""
function project_revision(root::AbstractString)
    try
        gitdir = joinpath(root, ".git")
        if isfile(gitdir)
            # A worktree or a submodule: `.git` is a file pointing at the real one.
            m = match(r"^gitdir:\s*(.+?)\s*$"m, read(gitdir, String))
            m === nothing && return ""
            gitdir = isabspath(m.captures[1]) ? String(m.captures[1]) : joinpath(root, m.captures[1])
        end
        isdir(gitdir) || return ""
        head = String(strip(read(joinpath(gitdir, "HEAD"), String)))
        # A detached HEAD holds the commit itself; otherwise it names a ref.
        startswith(head, "ref:") || return head
        ref = String(strip(head[5:end]))
        loose = joinpath(gitdir, ref)
        isfile(loose) && return String(strip(read(loose, String)))
        packed = joinpath(gitdir, "packed-refs")
        isfile(packed) || return ""
        for line in eachline(packed)
            (isempty(line) || startswith(line, '#') || startswith(line, '^')) && continue
            parts = split(line)
            length(parts) >= 2 && parts[2] == ref && return String(parts[1])
        end
        return ""
    catch
        return ""
    end
end

# Identity of the project, so a run state from somewhere else is not mistaken for
# this project's: the UUID when there is one, else the name, else a checksum of
# the project file.
function project_id(root::AbstractString)
    for name in PROJECT_NAMES
        path = joinpath(root, name)
        isfile(path) || continue
        proj = try
            TOML.parsefile(path)
        catch
            return string(crc32c(read(path)); base = 16)
        end
        haskey(proj, "uuid") && return string(proj["uuid"])
        haskey(proj, "name") && return string(proj["name"])
        return string(crc32c(read(path)); base = 16)
    end
    return ""
end
