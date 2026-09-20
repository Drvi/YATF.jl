# The run state file.
#
# Binary, fixed-stride, written as the run goes. Its first job is to survive the
# run: if the coordinator is killed, the file on disk still says which items
# passed and how long they took. Its second is to let a later run reproduce this
# one (the profiles, including their init and test-end expressions) and order
# itself better (durations, compile times, what failed).
#
# Layout:
#
#   header      96 B, fixed, holds the section offsets
#   strings     every string in the file, referenced by index
#   meta        julia and YATF versions, project identity, host, git revision
#   profiles    name, julia args, threads, env, init, test_end
#   units       n_units x 16 B: item span, profile, exclusive, chain
#   items       n_items x 16 B: name, file, line, unit
#   statuses    n_items x 32 B, fixed stride, overwritten in place
#   memory      fixed block, rewritten whenever a peak is set
#   events      append-only
#
# Only the status, memory and event sections are written after the run starts,
# which is what keeps a crash from corrupting anything else.

using CRC32c: crc32c
using Dates: Dates

const RS_MAGIC = 0x59415446   # "YATF"
const RS_VERSION = UInt32(4)
# 40 bytes of counts and times, then eight section offsets; the rest is room to
# add a field without moving every section.
const RS_HEADER_BYTES = 96
const RS_STATUS_BYTES = 32
const RS_MEMORY_BYTES = 64

const RS_FLAG_COMPLETE = UInt32(1) << 0
const RS_FLAG_DRY_RUN = UInt32(1) << 1
const RS_FLAG_CANCELLED = UInt32(1) << 2

"""
    write_record(io, ref)

Write the fixed-layout record `ref` points at, whole.

`write(io, x)` is defined only for primitive types, and for a number it boxes the
value into a `Ref` on the way out — a run writes tens of thousands of these small
fields, so the box is made once by the caller and refilled. The record structs
below have no padding except where noted, and their layout *is* the file format.
"""
@inline function write_record(io::IO, ref::Base.RefValue{T}) where {T}
    GC.@preserve ref unsafe_write(
        io, Ptr{UInt8}(Base.unsafe_convert(Ptr{T}, ref)), sizeof(T)
    )
    return nothing
end

# One item's place in the plan, and one unit's, laid out as they sit on disk.
# Written whole for the same reason as `StatusRecord`: `write(io, x)` for a number
# boxes it first, and a two-thousand-item suite writes tens of thousands of them
# before the first test runs.
struct ItemRecord
    name::UInt32
    file::UInt32
    line::UInt32
    unit::UInt32
end

# Sixteen bytes, two of which Julia pads in after `exclusive`. Written rather than
# packed by hand because nothing reads this section back yet, and a layout the
# compiler chose is one that cannot drift from the struct beside it.
struct UnitRecord
    first::UInt32
    last::UInt32
    profile::UInt8
    exclusive::UInt8
    chain::UInt32
end

"""
    StatusRecord

One item's status, laid out exactly as it sits on disk.

Written as a struct rather than field by field because `write(io, x)` for a
number boxes it into a `Ref` first: ten of those per status, twice per item, is
twenty allocations an item for thirty-two bytes. Every field here lands on its
natural alignment, so the struct needs no padding and its layout is the format.
"""
struct StatusRecord
    state::UInt8
    attempt::Int8
    slot::Int16
    start_off::Float32
    elapsed::Float32
    compile::Float32
    recompile::Float32
    alloc_mb::Float32
    peak_rss_mb::Float32
    reserved::UInt32
end

@assert sizeof(StatusRecord) == RS_STATUS_BYTES

mutable struct RunStateFile
    const io::IOStream
    const path::String
    const off_status::UInt32
    const off_memory::UInt32
    const n_items::UInt32
    const lock::ReentrantLock
    # Refilled for every status written, so a run of thousands of them allocates
    # nothing. Only ever touched under `lock`.
    const status_ref::Base.RefValue{StatusRecord}
    off_events::UInt32
end

### Writing ################################################################

struct StringTable
    index::Dict{String, UInt32}
    order::Vector{String}
end
StringTable() = StringTable(Dict{String, UInt32}(), String[])

# Not `get!` with a do-block: the block is a closure, and a closure allocates on
# every call including the ones that find what they were looking for. A run
# interns two strings per item before it starts.
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
    sizehint!(strings.index, 2 * nitems(p) + 32)
    sizehint!(strings.order, 2 * nitems(p) + 32)

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
    write(meta, intern!(strings, string(VERSION)))
    write(meta, intern!(strings, string(pkgversion(@__MODULE__))))
    write(meta, intern!(strings, project_id(p.root)))
    write(meta, intern!(strings, gethostname()))
    write(meta, intern!(strings, project_revision(p.root)))
    write(meta, UInt32(p.cfg.workers))
    write(meta, UInt32(p.cfg.timeout_s))
    write(meta, UInt32(p.cfg.retries))

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

    write(io, RS_MAGIC)
    write(io, RS_VERSION)
    write(io, dry_run ? RS_FLAG_DRY_RUN : UInt32(0))
    write(io, UInt32(nitems(p)))
    write(io, UInt32(length(p.units)))
    write(io, UInt16(length(p.profiles)))
    write(io, UInt16(0))
    write(io, Float64(Dates.datetime2unix(Dates.now(Dates.UTC))))
    write(io, Float64(0))
    for off in (
            off_strings, off_meta, off_profiles, off_units, off_items,
            off_status, off_memory, off_events,
        )
        write(io, off)
    end
    position(io) <= RS_HEADER_BYTES ||
        error("YATF: the run state header outgrew its $(RS_HEADER_BYTES)-byte slot")
    while position(io) < RS_HEADER_BYTES
        write(io, UInt8(0))
    end
    write(io, take!(strbuf)); write(io, take!(meta)); write(io, take!(profiles))
    write(io, take!(units)); write(io, take!(items))
    blank = Ref{StatusRecord}()
    for _ in 1:nitems(p)
        write_status_record(
            io, blank, UNSEEN, Int8(0), SlotIdx(0), 0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0
        )
    end
    write(io, zeros(UInt8, RS_MEMORY_BYTES))
    flush(io)
    return RunStateFile(
        io, String(path), off_status, off_memory, UInt32(nitems(p)),
        ReentrantLock(), Ref{StatusRecord}(), off_events
    )
end

function write_status_record(
        io::IO, ref::Base.RefValue{StatusRecord}, state::ItemState, attempt::Int8,
        slot::SlotIdx, start_off, elapsed, compile, recompile, alloc_mb, peak_rss_mb
    )
    ref[] = StatusRecord(
        UInt8(state), attempt, Int16(slot), Float32(start_off), Float32(elapsed),
        Float32(compile), Float32(recompile), Float32(alloc_mb), Float32(peak_rss_mb),
        UInt32(0)
    )
    write_record(io, ref)
    return nothing
end

"""
    write_status!(rsf, i, state, attempt, slot; ...)

Overwrite one status record in place and flush. A crash can lose at most the
record being written, and a reader treats a record it cannot make sense of as
`unseen`.
"""
function write_status!(
        rsf::Union{Nothing, RunStateFile}, i::Integer, state::ItemState,
        attempt::Integer, slot::Integer; start_off = 0.0, elapsed = 0.0,
        compile = 0.0, recompile = 0.0, alloc_mb = 0.0, peak_rss_mb = 0.0
    )
    rsf === nothing && return nothing
    (1 <= i <= rsf.n_items) || return nothing
    @lock rsf.lock begin
        try
            seek(rsf.io, Int(rsf.off_status) + (Int(i) - 1) * RS_STATUS_BYTES)
            write_status_record(
                rsf.io, rsf.status_ref, state, Int8(attempt), SlotIdx(slot), start_off,
                elapsed, compile, recompile, alloc_mb, peak_rss_mb
            )
            flush(rsf.io)
        catch e
            # Bookkeeping must never take down a run: if the file cannot be
            # written, the tests still matter more than the record of them.
            @warn "YATF: could not write the run state" exception = e maxlog = 1
        end
    end
    return nothing
end

function write_memory!(rsf::Union{Nothing, RunStateFile}, m)
    rsf === nothing && return nothing
    @lock rsf.lock begin
        try
            seek(rsf.io, Int(rsf.off_memory))
            write(rsf.io, Float32(m.peak_total_bytes / 2^20))
            write(rsf.io, Float32(m.peak_total_at))
            write(rsf.io, Float32(m.peak_single_bytes / 2^20))
            write(rsf.io, Int32(m.peak_single_pid))
            write(rsf.io, Float32(phase_peak(m, PHASE_SETUP) / 2^20))
            write(rsf.io, Float32(phase_peak(m, PHASE_TEST) / 2^20))
            write(rsf.io, Int32(m.nprocs_peak))
            flush(rsf.io)
        catch e
            @warn "YATF: could not write the run state memory summary" exception = e maxlog = 1
        end
    end
    return nothing
end

function finish_run_state!(rsf::Union{Nothing, RunStateFile}; cancelled::Bool = false)
    rsf === nothing && return nothing
    @lock rsf.lock begin
        try
            seek(rsf.io, 8)
            flags = RS_FLAG_COMPLETE | (cancelled ? RS_FLAG_CANCELLED : UInt32(0))
            write(rsf.io, flags)
            seek(rsf.io, 24)
            write(rsf.io, Float64(Dates.datetime2unix(Dates.now(Dates.UTC))))
            flush(rsf.io)
            close(rsf.io)
        catch e
            @warn "YATF: could not finalize the run state" exception = e maxlog = 1
        end
    end
    return nothing
end

### Reading ################################################################

struct RunStateItem
    name::String
    file::String
    line::Int32
    unit::Int32
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
end

struct RunStateRecord
    path::String
    version::UInt32
    complete::Bool
    dry_run::Bool
    cancelled::Bool
    start_unix::Float64
    end_unix::Float64
    julia::String
    yatf::String
    project_id::String
    host::String
    revision::String   # the commit the tests were run from, "" when there is none
    profiles::Dict{Symbol, Profile}
    items::Vector{RunStateItem}
    statuses::Vector{RunStateStatus}
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
    try
        read(io, UInt32) == RS_MAGIC || return nothing
        version = read(io, UInt32)
        version == RS_VERSION || return nothing
        flags = read(io, UInt32)
        n_items = Int(read(io, UInt32))
        _n_units = read(io, UInt32)
        _n_profiles = read(io, UInt16); read(io, UInt16)
        start_unix = read(io, Float64)
        end_unix = read(io, Float64)
        offs = [read(io, UInt32) for _ in 1:8]
        off_strings, off_meta, off_profiles, off_units, off_items, off_status, _off_mem, _off_ev = offs

        seek(io, Int(off_strings))
        strings = read_strings(io, length(bytes))
        seek(io, Int(off_meta))
        julia = lookup(strings, read(io, UInt32))
        yatf = lookup(strings, read(io, UInt32))
        pid = lookup(strings, read(io, UInt32))
        host = lookup(strings, read(io, UInt32))
        revision = lookup(strings, read(io, UInt32))

        seek(io, Int(off_profiles))
        profiles = read_profiles_section(io, strings)

        seek(io, Int(off_items))
        n = Int(read(io, UInt32))
        items = RunStateItem[]
        for _ in 1:min(n, n_items)
            name = lookup(strings, read(io, UInt32))
            file = lookup(strings, read(io, UInt32))
            line = Int32(read(io, UInt32))
            unit = Int32(read(io, UInt32))
            push!(items, RunStateItem(name, file, line, unit))
        end

        statuses = RunStateStatus[]
        truncated = false
        for i in 1:n_items
            at = Int(off_status) + (i - 1) * RS_STATUS_BYTES
            if at + RS_STATUS_BYTES > length(bytes)
                truncated = true
                push!(statuses, RunStateStatus(UNSEEN, Int8(0), Int16(0), 0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0))
                continue
            end
            seek(io, at)
            push!(statuses, read_status_record(io))
        end
        return RunStateRecord(
            String(path), version, flags & RS_FLAG_COMPLETE != 0,
            flags & RS_FLAG_DRY_RUN != 0, flags & RS_FLAG_CANCELLED != 0,
            start_unix, end_unix, julia, yatf, pid, host, revision, profiles,
            items, statuses, truncated
        )
    catch e
        # Any malformed section: report nothing rather than failing a test run over
        # the remains of an older one. `JULIA_DEBUG=YATF` shows what went wrong.
        @debug "YATF: could not read run state $(path)" exception = (e, catch_backtrace())
        return nothing
    end
end

function read_status_record(io::IO)
    raw = read(io, UInt8)
    state = raw <= UInt8(CANCELLED) ? ItemState(raw) : UNSEEN
    attempt = reinterpret(Int8, read(io, UInt8))
    slot = read(io, Int16)
    start_off = read(io, Float32); elapsed = read(io, Float32); compile = read(io, Float32)
    recompile = read(io, Float32); alloc_mb = read(io, Float32); peak = read(io, Float32)
    read(io, UInt32)
    return RunStateStatus(state, attempt, slot, start_off, elapsed, compile, recompile, alloc_mb, peak)
end

function read_strings(io::IO, total::Integer)
    n = Int(read(io, UInt32))
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
    n = Int(read(io, UInt32))
    profiles = Dict{Symbol, Profile}()
    for _ in 1:n
        name = Symbol(lookup(strings, read(io, UInt32)))
        nargs = Int(read(io, UInt32))
        args = String[lookup(strings, read(io, UInt32)) for _ in 1:nargs]
        threads = lookup(strings, read(io, UInt32))
        nenv = Int(read(io, UInt32))
        env = Pair{String, String}[]
        for _ in 1:nenv
            k = lookup(strings, read(io, UInt32)); v = lookup(strings, read(io, UInt32))
            push!(env, k => v)
        end
        init = parse_block(lookup(strings, read(io, UInt32)))
        test_end = parse_block(lookup(strings, read(io, UInt32)))
        profiles[name] = Profile(name, args, threads, env, init, test_end)
    end
    return profiles
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

new_runstate_path(root::AbstractString) =
    joinpath(
    runstate_dir(root),
    string(round(Int, time()), "-", getpid(), ".yatf")
)

function runstate_files(root::AbstractString)
    dir = runstate_dir(root)
    isdir(dir) || return String[]
    files = filter!(endswith(".yatf"), readdir(dir; join = true))
    return sort!(files)   # names start with a unix timestamp, so this is oldest-first
end

const KEEP_RUNS = 20

function prune_runstates(root::AbstractString, keep::Int = KEEP_RUNS)
    files = runstate_files(root)
    for f in files[1:max(0, length(files) - keep)]
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

Per-item durations and last-run failures, taken from the most recent runs. Only
items that actually ran contribute; a name that has never been seen simply has no
estimate and is scheduled as if it were new.
"""
function history(root::AbstractString; nruns::Int = 5)
    seconds = Dict{String, Float64}()
    failed = Set{String}()
    files = runstate_files(root)
    isempty(files) && return History()
    recent = files[max(1, end - nruns + 1):end]
    for (k, f) in enumerate(recent)
        rs = read_run_state(f)
        rs === nothing && continue
        rs.dry_run && continue
        for (i, it) in enumerate(rs.items)
            i <= length(rs.statuses) || break
            st = rs.statuses[i]
            if st.state === UNSEEN
                # A cancelled run stopped before reaching these. They did not pass,
                # and after a run that stopped early, what did not pass is exactly
                # what `retry_failed` should run again.
                k == length(recent) && rs.cancelled && push!(failed, it.name)
                continue
            end
            st.elapsed > 0 && (seconds[it.name] = Float64(st.elapsed))
            # Only the newest run decides what counts as "failed last time".
            if k == length(recent)
                is_non_pass(st.state) ? push!(failed, it.name) : delete!(failed, it.name)
            end
        end
    end
    return History(seconds, failed)
end

"""
    project_revision(root) -> String

The commit the tests are being run from, or `""` when there is not one to be had.

Recorded so that a run state — one downloaded from a CI job, say — says what to
check out to reproduce it. It is read out of `.git` rather than by running `git`:
a subprocess on the path between `runtests()` and the first test item costs more
than the answer is worth.

It identifies the commit and not the working tree, so local edits do not change
it. See `issues/runstate-worktree-identity.md`.
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
