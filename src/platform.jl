# Process and memory introspection, vendored.
#
# YATF takes no packages for this: each platform gets one small set of `ccall`s
# or file reads behind the same two functions, `process_rss` and `child_pids`.
# These read C structs at hard-coded offsets, which is exactly the kind of code
# that fails quietly or takes the process down with it, so `platform_selfcheck!`
# checks them against an independent source at load time and switches the whole
# thing off if they disagree. A platform with no working binding degrades to
# machine-level numbers; it never guesses and never segfaults in someone's CI.

module Platform

export process_rss, child_pids, machine_memory, available_fraction, cpu_load, cpu_count,
    platform_selfcheck!, ensure_checked!, PER_PROCESS_OK

const PER_PROCESS_OK = Ref(false)

# The self-check starts a process, so it runs once, the first time a run needs it.
# Two tasks asking at the same time must not both run it.
const ensure_checked! = OncePerProcess{Bool}() do
    platform_selfcheck!()
end

### macOS ##################################################################

# proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size): `struct proc_taskinfo`
# starts with pti_virtual_size then pti_resident_size, both UInt64.
const PROC_PIDTASKINFO = Cint(4)
const TASKINFO_BYTES = 128
const RESIDENT_OFFSET = 8

function rss_macos(pid::Integer)
    buf = zeros(UInt8, TASKINFO_BYTES)
    n = ccall(
        :proc_pidinfo, Cint, (Cint, Cint, UInt64, Ptr{UInt8}, Cint),
        pid, PROC_PIDTASKINFO, 0, buf, TASKINFO_BYTES
    )
    n <= 0 && return Int64(-1)
    return Int64(only(reinterpret(UInt64, @view buf[(RESIDENT_OFFSET + 1):(RESIDENT_OFFSET + 8)])))
end

# proc_listchildpids returns the NUMBER of children and fills the buffer with
# their pids. (It is not a byte count; reading it as one silently yields an empty
# child list, which is why the self-check spawns a process and looks for it.)
function children_macos(pid::Integer)
    buf = zeros(Int32, 256)
    n = ccall(:proc_listchildpids, Cint, (Cint, Ptr{Int32}, Cint), pid, buf, Cint(sizeof(buf)))
    n <= 0 && return Int32[]
    return buf[1:min(Int(n), length(buf))]
end

### Linux ##################################################################

const PAGESIZE = Ref{Int64}(4096)

function rss_linux(pid::Integer)
    path = "/proc/$(pid)/statm"
    isfile(path) || return Int64(-1)
    fields = try
        split(read(path, String))
    catch
        return Int64(-1)
    end
    length(fields) >= 2 || return Int64(-1)
    pages = tryparse(Int64, fields[2])
    pages === nothing && return Int64(-1)
    return pages * PAGESIZE[]
end

function children_linux(pid::Integer)
    out = Int32[]
    taskdir = "/proc/$(pid)/task"
    isdir(taskdir) || return out
    try
        for tid in readdir(taskdir)
            path = joinpath(taskdir, tid, "children")
            isfile(path) || continue
            for s in split(read(path, String))
                p = tryparse(Int32, s)
                p === nothing || push!(out, p)
            end
        end
    catch
        return out
    end
    return unique!(out)
end

### Windows ################################################################

# PROCESS_MEMORY_COUNTERS: cb, PageFaultCount (UInt32 each), then SIZE_T fields;
# WorkingSetSize is the second SIZE_T.
function rss_windows(pid::Integer)
    handle = ccall(:OpenProcess, Ptr{Cvoid}, (UInt32, Cint, UInt32), 0x1000, 0, UInt32(pid))
    handle == C_NULL && return Int64(-1)
    try
        buf = zeros(UInt8, 80)
        reinterpret(UInt32, @view buf[1:4])[1] = UInt32(length(buf))
        ok = ccall(
            :K32GetProcessMemoryInfo, Cint, (Ptr{Cvoid}, Ptr{UInt8}, UInt32),
            handle, buf, UInt32(length(buf))
        )
        ok == 0 && return Int64(-1)
        return Int64(only(reinterpret(UInt64, @view buf[17:24])))
    catch
        return Int64(-1)
    finally
        ccall(:CloseHandle, Cint, (Ptr{Cvoid},), handle)
    end
end

# Enumerating a process tree on Windows needs a toolhelp snapshot, which is more
# machinery than the numbers are worth here; workers are tracked by pid anyway,
# so only their children are missed.
children_windows(::Integer) = Int32[]

### Dispatch ###############################################################

@static if Sys.isapple()
    process_rss(pid::Integer) = rss_macos(pid)
    child_pids(pid::Integer) = children_macos(pid)
elseif Sys.islinux()
    process_rss(pid::Integer) = rss_linux(pid)
    child_pids(pid::Integer) = children_linux(pid)
elseif Sys.iswindows()
    process_rss(pid::Integer) = rss_windows(pid)
    child_pids(pid::Integer) = children_windows(pid)
else
    process_rss(::Integer) = Int64(-1)
    child_pids(::Integer) = Int32[]
end

### Memory pressure ########################################################

# `1 - Sys.free_memory()/Sys.total_memory()` is not memory pressure, and using it
# makes the guard fire on a machine that is perfectly healthy. `Sys.free_memory`
# counts only free pages, while most of what an OS holds — file cache, inactive
# and purgeable pages — is handed back the moment someone asks for it. Measured on
# a 64 GiB machine that was not under any pressure: the naive figure said 70% used
# while the kernel reported 65% still available.
#
# So each platform is asked the question it actually answers:
#
#   macOS    kern.memorystatus_level, the percentage the kernel itself uses to
#            decide when to start killing processes
#   Linux    MemAvailable from /proc/meminfo, and the cgroup's own limit and usage
#            when there is one, whichever is tighter
#   Windows  dwMemoryLoad from GlobalMemoryStatusEx
#
# with `Sys.free_memory()` as the last resort.

function available_fraction_macos()
    val = Ref{Cint}(0)
    sz = Ref{Csize_t}(sizeof(Cint))
    r = ccall(
        :sysctlbyname, Cint, (Cstring, Ptr{Cvoid}, Ptr{Csize_t}, Ptr{Cvoid}, Csize_t),
        "kern.memorystatus_level", val, sz, C_NULL, 0
    )
    (r == 0 && 0 <= val[] <= 100) || return -1.0
    return Float64(val[]) / 100
end

function meminfo_available()
    total = avail = Int64(-1)
    try
        for line in eachline("/proc/meminfo")
            if startswith(line, "MemTotal:")
                total = parse_kb(line)
            elseif startswith(line, "MemAvailable:")
                avail = parse_kb(line)
            end
            (total > 0 && avail >= 0) && break
        end
    catch
        return -1.0
    end
    (total > 0 && avail >= 0) || return -1.0
    return clamp(avail / total, 0.0, 1.0)
end

parse_kb(line::AbstractString) =
    (v = tryparse(Int64, strip(replace(split(line, ':')[2], "kB" => ""))); v === nothing ? Int64(-1) : v)

# cgroup v2: the container's own limit is what the OOM killer looks at, and it is
# usually far below the host's total.
function cgroup_available()
    try
        isfile("/sys/fs/cgroup/memory.max") || return -1.0
        maxs = strip(read("/sys/fs/cgroup/memory.max", String))
        maxs == "max" && return -1.0
        limit = tryparse(Int64, maxs)
        (limit === nothing || limit <= 0) && return -1.0
        current = tryparse(Int64, strip(read("/sys/fs/cgroup/memory.current", String)))
        current === nothing && return -1.0
        # Page cache inside the cgroup is reclaimable, so it is not "used".
        reclaimable = Int64(0)
        if isfile("/sys/fs/cgroup/memory.stat")
            for line in eachline("/sys/fs/cgroup/memory.stat")
                parts = split(line)
                length(parts) == 2 || continue
                if parts[1] == "inactive_file" || parts[1] == "slab_reclaimable"
                    v = tryparse(Int64, parts[2])
                    v === nothing || (reclaimable += v)
                end
            end
        end
        return clamp((limit - max(current - reclaimable, 0)) / limit, 0.0, 1.0)
    catch
        return -1.0
    end
end

function available_fraction_windows()
    buf = zeros(UInt8, 64)
    reinterpret(UInt32, @view buf[1:4])[1] = UInt32(length(buf))
    ok = ccall(:GlobalMemoryStatusEx, Cint, (Ptr{UInt8},), buf)
    ok == 0 && return -1.0
    load = only(reinterpret(UInt32, @view buf[5:8]))
    load > 100 && return -1.0
    return (100 - Float64(load)) / 100
end

"""
    available_fraction() -> Float64

How much of the machine's (or the container's) memory could still be handed out,
between 0 and 1. Falls back to `Sys.free_memory()` only when the platform has
nothing better to say.
"""
function available_fraction()
    f = @static if Sys.isapple()
        available_fraction_macos()
    elseif Sys.islinux()
        a, b = meminfo_available(), cgroup_available()
        b >= 0 && a >= 0 ? min(a, b) : max(a, b)
    elseif Sys.iswindows()
        available_fraction_windows()
    else
        -1.0
    end
    f >= 0 && return f
    total = Int64(Sys.total_memory())
    total <= 0 && return 1.0
    return clamp(Int64(Sys.free_memory()) / total, 0.0, 1.0)
end

### CPU ####################################################################

"""
    cpu_load() -> Float64

The one-minute load average, or `-1.0` where the platform does not report one
(libuv returns zeros on Windows, and a zero there means "no data", not "idle").
"""
function cpu_load()
    Sys.iswindows() && return -1.0
    load = try
        first(Sys.loadavg())
    catch
        return -1.0
    end
    return load >= 0 ? Float64(load) : -1.0
end

"""
    cpu_count() -> Int

How many hardware threads the load average is spread over.
"""
cpu_count() = Sys.CPU_THREADS

"""
    machine_memory() -> (used, total)

Bytes that are really committed, and the total this process may use.
`Sys.total_memory` already respects cgroup limits, so inside CI this is the
container's view and not the host's. `used` is derived from
[`available_fraction`](@ref), so it does not count reclaimable pages as in use.
"""
function machine_memory()
    total = Int64(Sys.total_memory())
    used = round(Int64, total * (1 - available_fraction()))
    return (clamp(used, 0, total), total)
end

"""
    process_tree(roots; maxdepth=4) -> Vector{Int32}

Every process descended from `roots`, including them. Precompilation spawns
Julia processes that belong to the run's memory footprint just as much as the
workers do, and so does anything a test item starts.
"""
function process_tree(roots; maxdepth::Int = 4)
    seen = Set{Int32}()
    frontier = Int32[Int32(r) for r in roots]
    for _ in 0:maxdepth
        isempty(frontier) && break
        next = Int32[]
        for pid in frontier
            pid in seen && continue
            push!(seen, pid)
            append!(next, child_pids(pid))
        end
        frontier = next
    end
    return collect(seen)
end

"""
    platform_selfcheck!() -> Bool

Check the vendored accessors against something independent before trusting them:
this process's resident size against `Sys.maxrss()`, and the child listing
against a process we just started ourselves.
"""
function platform_selfcheck!()
    PER_PROCESS_OK[] = false
    try
        Sys.islinux() && (PAGESIZE[] = Int64(ccall(:jl_getpagesize, Clong, ())))
        me = getpid()
        rss = process_rss(me)
        maxrss = Int64(Sys.maxrss())
        # Resident size is not maxrss, but a working binding lands in the same
        # neighbourhood; a wrong struct offset does not.
        (rss > 0 && maxrss > 0 && rss < 100 * maxrss && rss > maxrss ÷ 100) || return false
        if !Sys.iswindows()
            proc = run(`$(Base.julia_cmd()[1]) -e "sleep(20)"`; wait = false)
            try
                found = false
                for _ in 1:100
                    Int32(Libc.getpid(proc)) in child_pids(me) && (found = true; break)
                    sleep(0.05)
                end
                found || return false
            finally
                kill(proc, Base.SIGKILL)
            end
        end
        PER_PROCESS_OK[] = true
        return true
    catch
        PER_PROCESS_OK[] = false
        return false
    end
end

end # module Platform
