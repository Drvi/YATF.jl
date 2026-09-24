# Running a plan: one task per slot. A slot takes its pool's head first, then walks
# its own stretch of the pool's body, takes half of the largest stretch left when
# its own is done, then the pool's tail, and rebinds to a pool no slot serves when
# its own has nothing left. `workers` caps live processes throughout: the run takes
# longer rather than start a process the caller did not authorize.

using Base: SIGKILL

mutable struct Slot
    const id::SlotIdx
    profile::Profile
    worker::Union{Nothing, YATFWorkers.Worker}
    started_at::Float64      # when this slot's current process came up
    worker_items::Int        # items the current process has run, for its EXIT line
    current::ItemIdx      # the item this slot is running, 0 when idle
    # A process killed for a timeout prints its signal and backtrace after its item
    # has stopped capturing. Those lines belong in `dying_log`, the log of the item
    # that was running (empty otherwise), and wait in `dying_lines` until the
    # process is gone.
    dying_log::String
    const dying_lines::Vector{String}
end

"""
    Queues

Every cursor a run has, behind one lock: each pool's head and tail, and each slot's
stretch of its pool's body. A run claims a few thousand times, so an uncontended
lock costs nothing, and one lock rules out racing cursors.
"""
mutable struct Queues
    const lock::ReentrantLock
    const pools::Vector{Pool}
    const head::Vector{UnitIdx}      # per pool: its next head unit
    const tail::Vector{UnitIdx}      # per pool: its next tail unit
    const from::Vector{UnitIdx}      # per slot: the next unit of its stretch
    const to::Vector{UnitIdx}        # per slot: the last unit of its stretch
    const pool::Vector{Int32}        # per slot: the pool it serves
    const pending::Vector{Int32}     # pools no slot serves yet, in pickup order
    const claimed::BitVector         # per unit: handed out already
    cancelled::Bool
    paused::Bool        # the memory guard is holding new work back
end

Queues(p::Plan) = Queues(
    ReentrantLock(), p.pools,
    UnitIdx[first(k.head) for k in p.pools], UnitIdx[first(k.tail) for k in p.pools],
    UnitIdx[first(r) for r in p.slot_units], UnitIdx[last(r) for r in p.slot_units],
    copy(p.slot_pool), copy(p.pending), falses(length(p.units)), false, false
)

struct Claim
    kind::Symbol        # :unit, :rebind, :done
    unit::UnitIdx
    pool::Int32
end
Claim(kind::Symbol) = Claim(kind, UnitIdx(0), Int32(0))

# The unit a cursor points at, moving the cursor past it. Every unit is handed out
# exactly once; a second time is a scheduling bug, stopped here rather than run twice.
function next!(q::Queues, cursor::Vector{UnitIdx}, i::Integer)
    u = cursor[i]
    cursor[i] += UnitIdx(1)
    q.claimed[u] && error("YATF internal error: unit $u was handed out twice")
    q.claimed[u] = true
    return Claim(:unit, u, Int32(0))
end

function claim!(q::Queues, s::Integer)
    @lock q.lock begin
        q.cancelled && return Claim(:done)
        k = q.pool[s]
        q.head[k] <= last(q.pools[k].head) && return next!(q, q.head, k)
        q.from[s] <= q.to[s] && return next!(q, q.from, s)
        # Its own stretch is done: take the second half of the largest stretch left
        # in the pool, so both slots go on walking neighbouring units. A stretch of
        # one gives it up too, so a slow slot's last unit does not wait behind the
        # one it is running. Never across pools: a unit run under another profile's
        # flags is not the test that was declared.
        victim, most = 0, 0
        for v in eachindex(q.pool)
            q.pool[v] == k || continue
            r = q.to[v] - q.from[v] + 1
            r > most && ((victim, most) = (v, r))
        end
        if victim != 0
            q.from[s] = q.from[victim] + UnitIdx(most ÷ 2)
            q.to[s] = q.to[victim]
            q.to[victim] = q.from[s] - UnitIdx(1)
            return next!(q, q.from, s)
        end
        q.tail[k] <= last(q.pools[k].tail) && return next!(q, q.tail, k)
        if !isempty(q.pending)
            k = popfirst!(q.pending)
            q.pool[s] = k
            q.from[s], q.to[s] = first(q.pools[k].body), last(q.pools[k].body)
            return Claim(:rebind, UnitIdx(0), k)
        end
        return Claim(:done)
    end
end

cancel!(q::Queues) = @lock q.lock (was = q.cancelled; q.cancelled = true; was)
is_cancelled(q::Queues) = @lock q.lock q.cancelled
set_paused!(q::Queues, v::Bool) = @lock q.lock (q.paused = v; nothing)
is_paused(q::Queues) = @lock q.lock q.paused

# Backpressure: hold new work while the machine is short of memory. Bounded,
# because the pressure is often someone else's, and a run that quietly stops making
# progress is worse than one that runs on a busy machine. Cancellation always gets
# through.
const MAX_BACKPRESSURE_SECONDS = 30.0

function wait_while_paused(q::Queues)
    is_paused(q) || return nothing
    deadline = time() + MAX_BACKPRESSURE_SECONDS
    while is_paused(q) && !is_cancelled(q) && time() < deadline
        sleep(0.2)
    end
    if is_paused(q) && !is_cancelled(q)
        set_paused!(q, false)
        @warn "YATF: memory has stayed tight for $(round(Int, MAX_BACKPRESSURE_SECONDS))s; " *
            "continuing rather than stalling the run" maxlog = 1
    end
    return nothing
end

"""
    Statuses

Per-item results, written by whichever slot task owns the item. Arrays rather than
objects so that the run state can be written straight out of them.
"""
struct Statuses
    counted::Vector{Bool}      # an item is counted as finished once, however many attempts
    synthetic::Vector{Bool}      # the outcome was written by the coordinator, not by the item
    state::Vector{ItemState}
    start::Vector{Float32}   # seconds from the start of the run to the item's dispatch
    attempt::Vector{Int8}
    slot::Vector{SlotIdx}
    pid::Vector{Int32}       # the process its last attempt ran in, 0 for none
    elapsed::Vector{Float32}
    compile::Vector{Float32}
    testsets::Vector{Any}
end

Statuses(n::Integer) = Statuses(
    falses(n), falses(n), fill(UNSEEN, n), zeros(Float32, n), zeros(Int8, n), fill(SlotIdx(0), n),
    zeros(Int32, n), zeros(Float32, n), zeros(Float32, n),
    Vector{Any}(nothing, n)
)

mutable struct Run
    const plan::Plan
    const queues::Queues
    const statuses::Statuses
    const slots::Vector{Slot}
    const project_name::String
    const runid::String
    const logdir::String
    const logprefix::String   # `logdir` and the part of a log's name that never varies
    # The name column, chosen once from every name the run will print.
    const name_width::Int32
    const printer::ReentrantLock
    const t0::Float64
    runstate::Union{Nothing, RunStateFile}
    monitor::Union{Nothing, Monitor}
    # Profile name -> the project directory its workers run in. Only profiles that
    # declare preferences have one; everything else uses the test environment.
    const profile_projects::Dict{Symbol, String}
    @atomic ndone::Int
    # When an item last finished, or testing started: what the watchdog measures from.
    @atomic last_finish::Float64
    # Set when the watchdog stopped the run because nothing finished in time.
    @atomic stalled::Bool
    # The tasks running items, for the watchdog to interrupt.
    const tasks::Vector{Task}
    # Workers `kill_workers!` took from their slots, for `shutdown!` to wait for.
    const killed::Vector{YATFWorkers.Worker}
    # Guards `tasks` and `killed`, which the watchdog's timer uses as well.
    const lock::ReentrantLock
end

"""
    execute(plan, target) -> Run

Run the plan to completion and return the run, whose `statuses` hold what
happened to every item. Printing and the pass/fail verdict are `report`'s job,
so a caller that wants to inspect the outcome does not have to catch anything.
"""
function execute(p::Plan, target)
    cfg = p.cfg
    warn_sandboxed_workers(p)
    project_name = something(project_name_of(target.project), "")
    runid = string(time_ns(); base = 16)
    logdir = mktempdir(; prefix = "yatf_")
    run = Run(
        p, Queues(p), Statuses(nitems(p)), Slot[], project_name, runid, logdir,
        joinpath(logdir, "item_"),
        name_width(p.items.name; columns = terminal_columns(stdout isa Base.TTY)),
        ReentrantLock(), time(), nothing, nothing, Dict{Symbol, String}(), 0, 0.0, false, Task[],
        YATFWorkers.Worker[], ReentrantLock()
    )
    cfg.monitor && (run.monitor = start_monitor!(Monitor(run; print_interval = cfg.monitor_interval)))
    for s in 1:nslots(p)
        push!(
            run.slots, Slot(
                SlotIdx(s), p.profiles[p.pools[p.slot_pool[s]].profile],
                nothing, 0.0, 0, ItemIdx(0), "", String[]
            )
        )
    end
    setup_path = joinpath(target.testdir, TESTSETUPS_DIR)
    return try
        run_phases(run, p, target, setup_path)
    finally
        # Wherever the run stopped: a throw before the first item would otherwise
        # leave the monitor running and the error printed over its line.
        stop_monitor!(run.monitor)
    end
end

function run_phases(run::Run, p::Plan, target, setup_path::AbstractString)
    cfg = p.cfg
    return with_logger(RunLogger(current_logger(), run)) do
        with_test_env(target, run) do
            # Opened once the test environment is active: its manifest is part of
            # what the file records.
            run.runstate = open_runstate(p)
            check_replayed_environment(run)
            with_load_path(setup_path) do
                profile_projects!(run, p)
                precompile_phase(run, p, target)
                # From the start of the run, as the monitor's setup stage is, so the
                # header and the closing block give the same figure.
                p.startup.setup = time() - run.t0
                # Printed once setup is done, so it can say what setup cost.
                print_run_header(run)
                set_phase!(run.monitor, PHASE_TEST)
                interrupted = false
                ensure_exit_report()
                LIVE_RUN[] = run
                limit = stall_limit(p)
                @atomic run.last_finish = time()
                watchdog = start_watchdog(run, limit)
                try
                    if cfg.workers == 0
                        run_in_process(run, target)
                    else
                        run_on_workers(run, target)
                    end
                    # Stopped with nothing in flight to interrupt: the slots saw their
                    # workers go and ended on their own.
                    (@atomic run.stalled) && throw(RunStalled(limit))
                catch e
                    stalled = @atomic run.stalled
                    if e isa InterruptException || stalled
                        interrupted = true
                        kill_workers!(run)
                    end
                    stalled ? throw(RunStalled(limit)) : rethrow()
                finally
                    close(watchdog)
                    # Reaching here at all means the run unwound, so the exit hook
                    # has nothing left to close.
                    LIVE_RUN[] = nothing
                    set_phase!(run.monitor, PHASE_REPORT)
                    stop_monitor!(run.monitor)
                    shutdown!(run)
                    run.monitor === nothing || write_memory!(run.runstate, run.monitor.stats)
                    finish_run_state!(run.runstate; cancelled = is_cancelled(run.queues))
                    prune_runstates(p.root)
                    # The exception on its way out stops the report from being
                    # made, so what the run got through is said here or nowhere.
                    interrupted && print_conclusion(run, (@atomic run.stalled) ? :stalled : :interrupted)
                end
                run
            end
        end
    end
end

"""
    with_test_env(f, target)

Run `f` with the package's test environment active, and restore whatever was
active afterwards. The environment is:

1. the active one, when the call came from `<root>/test/runtests.jl`: that is
   `Pkg.test`, which has built an environment with the test dependencies;
2. the active one, when it is the package's own `test/Project.toml`, because
   activating that is a deliberate choice;
3. otherwise a test environment built by `TestEnv`, cached for the session.

Never the package's plain project, which lacks the test-only dependencies.
"""
function with_test_env(f, target, run = nothing)
    # Building it is `Pkg`'s to narrate, and it draws its own progress by moving
    # the cursor. Ours comes down while it does.
    monitor = run === nothing ? nothing : run.monitor
    env = with_status_line_off(monitor) do
        test_env_for(target, run === nothing ? nothing : () -> say(run, "resolving the test environment"))
    end
    env === nothing && return f()
    current = Base.active_project()
    Base.set_active_project(env)
    try
        return f()
    finally
        Base.set_active_project(current)
    end
end

"""
    test_env_for(target) -> Union{Nothing,String}

The environment the target's items resolve against, or `nothing` when the active
one is it. `activate` asks too, and must agree with a run.
"""
function test_env_for(target, announce = nothing)
    current = Base.active_project()
    if current !== nothing
        running_from_runtests(target) && return nothing
        testproj = joinpath(target.testdir, "Project.toml")
        isfile(testproj) && abspath(current) == abspath(testproj) && return nothing
    end
    env = test_env(target, announce)
    (current !== nothing && abspath(current) == abspath(env)) && return nothing
    return env
end

# Generated test environments, kept for the session and keyed by project file:
# building one costs a resolve, and a new environment makes Julia precompile again,
# which at the REPL is the difference between a second and a minute. The stamp is
# what it was generated from, so a test dependency added mid-session rebuilds it.
const TEST_ENVS = Dict{String, Tuple{String, NTuple{4, Float64}}}()
const TEST_ENVS_LOCK = ReentrantLock()

function test_env(target, announce = nothing)
    proj = abspath(target.project)
    return @lock TEST_ENVS_LOCK begin
        cached = get(TEST_ENVS, proj, nothing)
        if cached !== nothing && isfile(cached[1]) && cached[2] == env_stamp(target)
            return cached[1]
        end
        # Announced only when building: a cache hit is immediate, and at the REPL
        # the hit is the point.
        announce === nothing || announce()
        original = Base.active_project()
        try
            # `Pkg` would precompile the new environment for this process's flags
            # only; `precompile_env` does it once for every set of flags the pools
            # use, and the time reported against this stays the resolve's.
            withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
                Pkg.activate(proj; io = devnull)
                TestEnv.activate()
            end
            env = Base.active_project()
            # Stamped *after* generating it: resolving writes the package's manifest,
            # so a stamp taken beforehand never matches again and every call would
            # rebuild the environment it was supposed to cache.
            TEST_ENVS[proj] = (env, env_stamp(target))
            return env
        catch e
            e isa InterruptException && rethrow()
            throw(
                ConfigError(
                    "could not build a test environment for $(relpath_or_path(proj)): " *
                        sprint(showerror, e)
                )
            )
        finally
            Base.set_active_project(original)
        end
    end
end

function env_stamp(target)
    root = dirname(abspath(target.project))
    return (
        mtime_or_zero(target.project),
        mtime_or_zero(joinpath(root, "Manifest.toml")),
        mtime_or_zero(joinpath(target.testdir, "Project.toml")),
        mtime_or_zero(joinpath(target.testdir, "Manifest.toml")),
    )
end

mtime_or_zero(path::AbstractString) = isfile(path) ? mtime(path) : 0.0

# `Pkg.test` runs `test/runtests.jl` in an environment it built for the purpose.
# The file being evaluated is how we can tell.
function running_from_runtests(target)
    source = get(task_local_storage(), :SOURCE_PATH, nothing)
    source === nothing && return false
    return abspath(String(source)) == abspath(joinpath(target.testdir, "runtests.jl"))
end

# A replay runs against this machine's environment, which may not be the one the
# run state was recorded in. Every package whose version differs is named: it is
# the first thing to rule out when a replay does not fail the way the original did.
function check_replayed_environment(run::Run)
    recorded = run.plan.cfg.replayed_manifest
    isempty(recorded) && return nothing
    env = Base.active_project()
    here = manifest_versions(read_text(env === nothing ? nothing : Base.project_file_manifest_path(env)))
    there = manifest_versions(recorded)
    diffs = String[]
    for name in sort!(collect(union(keys(here), keys(there))))
        h, t = get(here, name, "absent"), get(there, name, "absent")
        h == t || push!(diffs, string(name, ": ", t, " when recorded, ", h, " here"))
    end
    isempty(diffs) && return say(run, "the environment matches the one the run state was recorded in")
    @warn "YATF: the environment differs from the one the run state was recorded in:\n" *
        join(("  " * d for d in first(diffs, 40)), "\n") * (length(diffs) > 40 ? "\n  …" : "")
    return nothing
end

# Package name => version, from a manifest's text. A package tracked by path is
# `path`: its path is the recording machine's and says nothing here.
function manifest_versions(text::AbstractString)
    out = Dict{String, String}()
    isempty(text) && return out
    toml = try
        TOML.parse(text)
    catch
        return out
    end
    for (name, entries) in get(toml, "deps", Dict{String, Any}())
        entries isa AbstractVector || continue
        for entry in entries
            entry isa AbstractDict || continue
            out[name] = haskey(entry, "path") ? "path" : string(get(entry, "version", get(entry, "git-tree-sha1", "stdlib")))
        end
    end
    return out
end

# A run state we cannot write is a run state we do without: the tests matter more
# than the record of them.
function open_runstate(p::Plan)
    try
        return init_run_state(new_runstate_path(p.root), p)
    catch e
        @warn "YATF: could not open a run state file; continuing without one" exception = e
        return nothing
    end
end

"""
    needs_worker(p, u) -> Bool

Whether this unit needs a process of its own however the run is configured:
`--check-bounds=yes` cannot be applied to a running process, and one process
cannot give an item a process to itself. Such an item gets a worker even under
`workers=0`; passing it here would pass a test that never ran as written.
"""
needs_worker(p::Plan, u::UnitIdx) =
    p.units.exclusive[u] || p.profiles[p.units.profile[u]].name !== DEFAULT_PROFILE

# `workers=0` is a promise about the pool, not about never starting a process.
# Starting one anyway is the right thing and a surprising thing, so it is said out
# loud, once, with the items that caused it.
function warn_sandboxed_workers(p::Plan)
    single_process(p) || return nothing
    names = String[]
    for u in UnitIdx(1):UnitIdx(length(p.units))
        needs_worker(p, u) && append!(names, (p.items.name[i] for i in p.units.span[u]))
    end
    isempty(names) && return nothing
    @warn "YATF: workers=0, but these items ask for a sandbox that this process cannot " *
        "provide, so each one gets a worker of its own that is torn down afterwards:\n" *
        join(("  " * repr(n) for n in names), "\n")
    return nothing
end

function project_name_of(projectfile::AbstractString)
    try
        return get(TOML.parsefile(projectfile), "name", nothing)
    catch
        return nothing
    end
end

# The setups directory is an implicit environment, so putting it on LOAD_PATH is
# all that `using MySetup` needs. Done for the duration of the run rather than
# permanently: a test run should not leave the caller's session changed.
function with_load_path(f, setup_path::AbstractString)
    isdir(setup_path) || return f()
    setup_path in LOAD_PATH && return f()
    push!(LOAD_PATH, setup_path)
    try
        return f()
    finally
        i = findlast(==(setup_path), LOAD_PATH)
        i === nothing || deleteat!(LOAD_PATH, i)
    end
end

"""
    profile_projects!(run, p)

Give every profile that declares preferences a project of its own. A package takes
its preferences from the environment that owns it, and a stacked environment is not
consulted, so a profile's preferences have to arrive as the worker's own project:
the test environment's `Project.toml` and `Manifest.toml`, over a
`LocalPreferences.toml` of the environment's preferences with the profile's on top.
Preferences are part of a cache's identity, so these projects keep caches of their
own.
"""
function profile_projects!(run::Run, p::Plan)
    env = Base.active_project()
    env === nothing && return nothing
    root = dirname(env)
    for prof in values(p.profiles)
        isempty(prof.preferences) && continue
        dir = joinpath(root, string("yatf_profile_", prof.name))
        mkpath(dir)
        copy_env_files(dir, root)
        own = joinpath(root, "LocalPreferences.toml")
        merged = isfile(own) ? TOML.parsefile(own) : Dict{String, Any}()
        for (pkg, table) in TOML.parsefile(prof.preferences)
            # Per package, not per key: a half-overridden preferences table is a
            # configuration nobody wrote down.
            merged[pkg] = table
        end
        open(io -> TOML.print(io, merged), joinpath(dir, "LocalPreferences.toml"), "w")
        run.profile_projects[prof.name] = dir
    end
    return nothing
end

"""
    copy_env_files(dir, root)

Write `root`'s `Project.toml` and `Manifest.toml` into `dir`, every path made
absolute: `dir` is below `root`, so a relative path would resolve one directory too
deep, and a worker whose project cannot find a developed package dies before it is
ready.
"""
function copy_env_files(dir::AbstractString, root::AbstractString)
    for file in ("Project.toml", "Manifest.toml")
        src = joinpath(root, file)
        isfile(src) || continue
        open(io -> TOML.print(io, absolute_paths!(TOML.parsefile(src), root); sorted = true),
             joinpath(dir, file), "w")
    end
    return nothing
end

"""
    absolute_paths!(data, root) -> data

Rewrite every `path` in a parsed project or manifest as absolute, reading relative
ones from `root`. The whole table is walked: in these files a `path` is a
filesystem path wherever it appears.
"""
function absolute_paths!(data::AbstractDict, root::AbstractString)
    for (key, value) in data
        if key == "path" && value isa AbstractString
            # A package tracked at the environment's own directory is written `.`,
            # which `abspath` turns into a path with a separator on the end.
            p = abspath(root, value)
            data[key] = isdirpath(p) ? dirname(p) : p
        elseif value isa AbstractDict
            absolute_paths!(value, root)
        elseif value isa AbstractVector
            for entry in value
                entry isa AbstractDict && absolute_paths!(entry, root)
            end
        end
    end
    return data
end

# One process precompiles what every worker is about to need; otherwise the workers
# hit the same cold cache at once and serialize on Julia's precompilation lock.
function precompile_phase(run::Run, p::Plan, target)
    # The environment first: a setup module compiled before it would make its
    # worker build the dependencies itself, one at a time.
    precompile_env(run, p)
    precompile_setups(run, p, target)
    return nothing
end

const CACHE_FLAGS_CODE = "f = Base.CacheFlags(); print(f.use_pkgimages, ' ', f.debug_level, " *
    "' ', f.check_bounds, ' ', f.inline, ' ', f.opt_level)"

"""
    cache_flags_for(julia_args) -> Base.CacheFlags

The cache flags a worker started with `julia_args` will have, asked of a process
started the same way: which arguments reach the cache key is Julia's business and
changes between versions, and a wrong answer precompiles for the wrong key.
"""
function cache_flags_for(julia_args::Cmd)
    out = read(
        `$(Base.julia_cmd()) $julia_args --startup-file=no --history-file=no -e $CACHE_FLAGS_CODE`,
        String
    )
    f = split(out)
    length(f) == 5 || error("YATF: could not read the cache flags of `julia $julia_args`: $out")
    return Base.CacheFlags(
        parse(Bool, f[1]), parse(Int, f[2]), parse(Int, f[3]), parse(Bool, f[4]), parse(Int, f[5])
    )
end

"""
    precompile_env(run, p)

Precompile the test environment once for every set of cache flags the run will
use: this process's own, and one per pool with julia arguments of its own. A
package image built under other flags cannot be used, so a worker with other flags
would otherwise compile the package and its dependencies itself, serially and
silently, while the run looks stalled on its first item. `test_env` turns off
`Pkg`'s own precompilation so that this is the one pass.
"""
function precompile_env(run::Run, p::Plan)
    # The flags this process runs under lead, because every pool without julia
    # arguments of its own uses them and because `Pkg` is no longer doing it.
    configs = Pair{Cmd, Base.CacheFlags}[`` => Base.CacheFlags()]
    names = String[]
    for pool in p.pools
        prof = p.profiles[pool.profile]
        # Only julia arguments reach the cache key. A profile with preferences runs
        # in a project of its own, which `configs` cannot carry; it gets a call of
        # its own below.
        (isempty(prof.julia_args) || haskey(run.profile_projects, prof.name)) && continue
        flags = profile_flags(prof)
        (flags === nothing || flags in last.(configs)) && continue
        push!(configs, Cmd(prof.julia_args) => flags)
        push!(names, String(prof.name))
    end
    # One call each: a project is part of a cache's identity, so two profiles with
    # different preferences are two environments, not two configurations of one.
    for (name, dir) in run.profile_projects
        prof = p.profiles[findfirst(q -> q.name === name, p.profiles)]
        flags = profile_flags(prof)
        flags === nothing && continue
        say(run, "precompiling the test environment for profile ", name)
        precompile_configs(run, Cmd(prof.julia_args) => flags, joinpath(dir, "Project.toml"), "profile `$name`")
    end
    # Named only when there is something to name: `Pkg` narrates the rest, and says
    # nothing when there is nothing to do.
    isempty(names) || say(run, "precompiling the test environment for ", plural(length(names), "profile"), ": ", join(names, ", "))
    precompile_configs(run, configs, Base.active_project(), join(names, ", "))
    return nothing
end

# The cache flags a profile's workers will have, or `nothing` — said once — when
# they cannot be read, in which case the workers compile what they need themselves.
function profile_flags(prof::Profile)
    return try
        isempty(prof.julia_args) ? Base.CacheFlags() : cache_flags_for(Cmd(prof.julia_args))
    catch e
        e isa InterruptException && rethrow()
        @warn "YATF: could not read the cache flags of profile `$(prof.name)`; its \
               workers will compile what they need themselves" exception = e
        nothing
    end
end

# One `Pkg.precompile` in `project`. Work brought forward, not work that has to
# succeed: a worker that finds nothing cached still compiles what it needs, one
# process at a time. `Pkg` draws its own progress by moving the cursor, so ours
# comes down while it does.
function precompile_configs(run::Run, configs, project, what::AbstractString)
    original = Base.active_project()
    try
        with_status_line_off(run.monitor) do
            Base.set_active_project(project)
            Pkg.precompile(
                Pkg.Types.Context(), Pkg.Types.PackageSpec[];
                configs, warn_loaded = false, already_instantiated = true, io = stdout
            )
        end
    catch e
        e isa InterruptException && rethrow()
        @warn "YATF: could not precompile the test environment for $what; its workers \
               will compile what they need themselves" exception = e
    finally
        Base.set_active_project(original)
    end
    return nothing
end

function precompile_setups(run::Run, p::Plan, target)
    isempty(p.setups) && return nothing
    # `isprecompiled` asks whether there is a *valid* cache, which is the question:
    # a cache file left over from another checkout of the same setup would be
    # rebuilt by every worker at once, which is the whole thing this avoids.
    stale = filter(p.setups) do name
        pkg = Base.identify_package(String(name))
        pkg === nothing || !Base.isprecompiled(pkg)
    end
    isempty(stale) && return nothing
    say(run, "precompiling ", join(stale, ", "))
    for name in stale
        pkg = Base.identify_package(String(name))
        if pkg === nothing
            throw(
                ConfigError(
                    "test setup module `$name` is not loadable from " *
                        "$(joinpath(target.testdir, TESTSETUPS_DIR))"
                )
            )
        end
        # Julia writes why a module would not precompile to the stream it is given,
        # and throws an exception saying only that it failed; both go in the error.
        out = IOBuffer()
        try
            Base.compilecache(pkg, out, out)
        catch e
            e isa InterruptException && rethrow()
            detail = strip(String(take!(out)))
            throw(
                ConfigError(
                    "test setup module `$name` failed to precompile:\n" *
                        sprint(showerror, e) *
                        (isempty(detail) ? "" : string("\n", detail))
                )
            )
        end
    end
    return nothing
end

### Workers ################################################################

function run_on_workers(run::Run, target)
    tasks = map(run.slots) do slot
        Threads.@spawn begin
            s = $slot
            try
                run_slot(run, s, target)
            catch e
                if e isa InterruptException
                    cancel!(run.queues)
                    record_stopped_item!(run, s)
                    rethrow()
                end
                # This slot is finished, not the run: its units stay in its
                # queue for the others to steal, so one bad item does not stop
                # a suite.
                @error "YATF: worker slot $(s.id) stopped; its remaining items are " *
                    "left for the other workers" exception = (e, catch_backtrace())
            end
        end
    end
    @lock run.lock append!(run.tasks, tasks)
    try
        foreach(wait, tasks)
    catch e
        # Ctrl-C lands in whichever task was running, this one included. Stop
        # dispatching and kill the processes rather than wait for them, or an item
        # that sleeps for two minutes holds the interrupt that long. The slot tasks
        # are still waited for: `shutdown!` must not find a slot starting a worker.
        cancel!(run.queues)
        if e isa InterruptException
            kill_workers!(run)
            interrupt_slots!(tasks)
        end
        foreach(
            t -> (
                try
                    wait(t)
                catch end
            ), tasks
        )
        rethrow()
    end
    check_finished(run)
    return nothing
end

# Unless the run was stopped, every item ends with an outcome of its own. One that
# did not is a scheduling bug: said here, with the scheduler's cursors, rather than
# reported as an item the run never reached.
function check_finished(run::Run)
    is_cancelled(run.queues) && return nothing
    st = run.statuses
    left = [run.plan.items.name[i] for i in 1:nitems(run.plan) if st.state[i] === UNSEEN || st.state[i] === RUNNING]
    isempty(left) && return nothing
    q = run.queues
    @error "YATF internal error: $(length(left)) test items have no outcome, though the run was not stopped" items = left head = q.head tail = q.tail from = q.from to = q.to slot_pools = q.pool pending = q.pending unclaimed_units = findall(!, q.claimed)
    return nothing
end

"""
    record_stopped_item!(run, slot)

Record the item this slot was running when the run was stopped: it neither failed
nor finished, and is counted with the items the run never reached.
"""
function record_stopped_item!(run::Run, slot::Slot)
    i = slot.current
    i == ItemIdx(0) && return nothing
    # The slot may have recorded it already, on its way out of a dispatch that
    # failed for a reason of its own.
    run.statuses.state[i] === UNSEEN || return nothing
    attempt = max(run.statuses.attempt[i], Int8(1))
    if @atomic run.stalled
        record_error!(run, i, slot, attempt, TIMEDOUT, STALLED_NOTE)
    else
        record_error!(run, i, slot, attempt, CANCELLED, "the run was stopped")
    end
    return nothing
end

"""
    interrupt_slots!(tasks)

Hand the interrupt to each slot task rather than wait for it to notice. Killing
the workers frees a slot waiting on one and cancelling stops a slot between items,
but a slot building an environment or held back by the memory guard would wait for
whatever it is waiting on.
"""
function interrupt_slots!(tasks)
    for t in tasks
        (t === current_task() || istaskdone(t)) && continue
        try
            schedule(t, InterruptException(); error = true)
        catch
            # It finished between the two, or was never started: either way there
            # is nothing left in it to interrupt.
        end
    end
    return nothing
end

### Watchdog #################################################################

# What one attempt may spend besides its timeout and its profile's `init` and
# `test_end`: starting a worker, handing the result back, and reporting it.
const STALL_MARGIN_S = 5 * 60
# How often the watchdog looks, at most: the limit is half an hour or more.
const STALL_CHECK_S = 5.0

const STALLED_NOTE = "the run was stopped as hung while this item was running: no test item " *
    "had finished for longer than one attempt at any of them may take"

"""
    STALL_LIMIT_OVERRIDE

What [`stall_limit`](@ref) answers when a test has decided: a real limit is half an
hour or more, and a test cannot wait that long for a run to be declared hung.
"""
const STALL_LIMIT_OVERRIDE = ScopedValue{Union{Nothing, Float64}}(nothing)

"""
    stall_limit(p) -> Float64

The longest a run may go with no test item finishing, in seconds: one attempt at
the item with the largest timeout, on a worker whose profile's `init` and `test_end`
take all they are allowed, after the longest memory hold, with `STALL_MARGIN_S` for
everything around it. An item that runs past its timeout is killed, which ends its
attempt too, so nothing finishing for longer means something that should have
stopped did not.
"""
function stall_limit(p::Plan)
    forced = STALL_LIMIT_OVERRIDE[]
    forced === nothing || return forced
    cfg = p.cfg
    item = maximum(t -> t == USE_RUN_DEFAULT ? cfg.timeout_s : Int(t), p.items.timeout_s; init = cfg.timeout_s)
    init = any(prof -> !isempty(prof.init.args), p.profiles) ? cfg.init_timeout_s : 0
    test_end = any(prof -> !isempty(prof.test_end.args), p.profiles) ? cfg.test_end_timeout_s : 0
    return Float64(item + init + test_end + MAX_BACKPRESSURE_SECONDS + STALL_MARGIN_S)
end

"""
    start_watchdog(run, limit) -> Timer

Stop the run as hung once no test item has finished for `limit` seconds. A timer on
the coordinator, where a timer is free to run: the tasks there yield.
"""
function start_watchdog(run::Run, limit::Real)
    every = min(STALL_CHECK_S, limit / 4)
    return Timer(every; interval = every) do _
        (@atomic run.stalled) && return
        time() - (@atomic run.last_finish) > limit || return
        stall!(run, limit)
    end
end

# Everything the run started comes down: nothing more is handed out, the tasks
# waiting on an item are interrupted (they record it as timed out, with why), the
# workers are killed, and the monitor stops printing.
function stall!(run::Run, limit::Real)
    @atomic run.stalled = true
    say(run, "no test item has finished in ", fmt_seconds(limit),
        ", longer than one attempt at any of them may take; stopping the run as hung")
    cancel!(run.queues)
    interrupt_slots!(@lock run.lock copy(run.tasks))
    kill_workers!(run, "stopped as hung")
    m = run.monitor
    m === nothing || (@atomic m.stop = true)
    return nothing
end

function run_slot(run::Run, slot::Slot, target)
    while true
        wait_while_paused(run.queues)
        claim = claim!(run.queues, slot.id)
        if claim.kind === :done
            break
        elseif claim.kind === :rebind
            # This slot's own pool is empty and another profile still has work, so
            # the process is replaced instead of the worker cap being exceeded.
            slot.profile = run.plan.profiles[run.plan.pools[claim.pool].profile]
            stop_worker!(run, slot)
            continue
        end
        run_unit!(run, slot, claim.unit, target)
    end
    stop_worker!(run, slot)
    return nothing
end

function ensure_worker!(run::Run, slot::Slot, target, exclusive::Bool)
    slot.worker === nothing || (slot.worker.terminated ? nothing : return slot.worker)
    w = start_worker(run, slot, target, exclusive)
    slot.worker = w
    return w
end

const WORKER_START_RETRIES = 2

function start_worker(run::Run, slot::Slot, target, exclusive::Bool = false)
    prof = slot.profile
    last_err = nothing
    for attempt in 1:(WORKER_START_RETRIES + 1)
        w = try
            YATFWorkers.Worker(;
                julia_args = prof.julia_args,
                threads = prof.threads,
                extra_env = worker_env(run.runid, slot.id, get(run.profile_projects, slot.profile.name, Base.active_project()), slot.profile),
                dir = target.root,
                project = Base.active_project(),
                redirect_io = stdout,
                # Everything the worker writes: its RUN and DONE records, and under
                # `logs=:eager` whatever its items print.
                redirect_fn = let within = Ref(false)
                    (io, pid, line) -> relay!(run, slot, within, line)
                end,
                on_exit = w -> worker_ended!(run, slot.id, w)
            )
        catch e
            e isa InterruptException && rethrow()
            last_err = e
            attempt <= WORKER_START_RETRIES && sleep(1)
            continue
        end
        t = time() - run.t0
        append_event!(run.runstate, EVENT_WORKER_UP, 0, slot.id, w.pid, t, t)
        try
            init_worker!(run, slot, w)
            slot.started_at = time()
            slot.worker_items = 0
            count_worker_start!(run.monitor, slot.id)
            print_worker_line(
                run, slot.id, "UP", string(
                    "pid ", w.pid, " · threads ", prof.threads,
                    # Why this process exists: a pool worker runs whatever it is
                    # handed, a sandbox runs one unit and goes away again.
                    exclusive ? " · sandbox" : "",
                    prof.name === DEFAULT_PROFILE ? "" : string(" · profile ", prof.name),
                    isempty(prof.julia_args) ? "" : string(" · ", join(prof.julia_args, " "))
                )
            )
            return w
        catch e
            # The process is up; it is the `init` expression that failed or hung.
            YATFWorkers.terminate!(w, :init_failed)
            wait(w)
            e isa InterruptException && rethrow()
            if e isa YATFWorkers.RemoteException || e isa TimeoutException
                # The expression itself is at fault: another process would only
                # fail the same way. A timeout already names the expression it
                # timed out on, so only a remote error needs saying what failed.
                cancel!(run.queues)
                what = e isa TimeoutException ? sprint(showerror, e) :
                    string(
                        "the `init` expression of profile `", prof.name, "` failed: ",
                        sprint(showerror, e)
                    )
                throw(ErrorException("YATF: " * what))
            end
            last_err = e   # the worker died while running it: retried like a start failure
            attempt <= WORKER_START_RETRIES && sleep(1)
        end
    end
    # A profile that cannot start is a configuration error, and finding that out
    # once is better than finding it out again on every remaining unit.
    cancel!(run.queues)
    throw(
        ErrorException(
            "YATF: could not start a worker for profile `$(prof.name)` " *
                "after $(WORKER_START_RETRIES + 1) attempts: " * sprint(showerror, last_err)
        )
    )
end

# Held rather than appended as they arrive: the worker still has that log open, and
# two processes appending to one file keep separate offsets and overwrite each
# other (measured: lines lost and cut in half). Capped, because a process can print
# without limit on its way down.
const MAX_DYING_LINES = 500

function keep_dying_line!(slot::Slot, line::AbstractString)
    length(slot.dying_lines) < MAX_DYING_LINES && push!(slot.dying_lines, String(line))
    return nothing
end

"""
    relay!(run, slot, within, line)

One line of what a worker wrote. Its records of an item starting and finishing
become the item's RUN and DONE lines; anything else is the item talking, between a
RUN and its DONE, or the process itself. `within` follows the worker's own stream,
so it never races with the slot's task. While the process is being put down for a
timeout, the item is already recorded as timed out: a verdict it still manages to
send is dropped, and what it says goes with the item's log.
"""
function relay!(run::Run, slot::Slot, within::Base.RefValue{Bool}, line::AbstractString)
    rec = parse_record(line)
    if !isempty(slot.dying_log)
        rec === nothing && keep_dying_line!(slot, line)
        return nothing
    end
    if rec !== nothing
        within[] = rec.how === nothing
        return printline(run, item_line(run, slot.id, rec.i, rec.attempt, rec.how))
    end
    return printline(run, string(within[] ? MARK_ITEM : MARK_WORKER, " w", slot.id, FIELD, line))
end

# An item's RUN or DONE line, drawn from what this run knows about the item.
item_line(run::Run, slot_id, i::Integer, attempt::Integer, how) = item_line(
    slot_id, i, nitems(run.plan), run.plan.items.name[i], run.name_width, attempt,
    attempts_for(run.plan, run.plan.items.unit[i]), something(how, run.plan.locations[i])
)

"""
    flush_dying_log!(slot)

Put what the worker said while being taken down into the log of the item it was
running. Called once the process is gone and its relay task joined, so this is the
file's only writer.
"""
function flush_dying_log!(slot::Slot)
    path = slot.dying_log
    slot.dying_log = ""
    if !isempty(path) && !isempty(slot.dying_lines)
        try
            open(path, "a") do io
                for l in slot.dying_lines
                    println(io, l)
                end
            end
        catch e
            e isa InterruptException && rethrow()
            # The log is a convenience; losing a dying process's backtrace is not
            # a reason to disturb the run that is still going.
        end
    end
    empty!(slot.dying_lines)
    return nothing
end

# A worker's environment beyond the coordinator's own: the run and slot it belongs
# to, the load path as it is now (the setups directory included), the project its
# items resolve against, and the profile's own variables. The project is stated
# rather than inherited: a `JULIA_PROJECT` the caller happened to have set would
# otherwise win over the test environment this run just built.
function worker_env(run_id, slot_id, project, prof::Profile)
    env = ["YATF_RUN_ID" => string(run_id), "YATF_WORKER" => string(slot_id), "JULIA_LOAD_PATH" => join(LOAD_PATH, PATHSEP)]
    project === nothing || push!(env, "JULIA_PROJECT" => project)
    return append!(env, prof.env)
end

# Every worker's end is recorded once, by the task that sees its process exit,
# whichever way it went: closed by the run, killed, or dead on its own.
function worker_ended!(run::Run, slot::Integer, w::YATFWorkers.Worker)
    t = time() - run.t0
    p = w.process
    append_event!(run.runstate, EVENT_WORKER_DOWN, worker_end_code(w.ended_by), slot, w.pid, t, t;
        exitcode = p.exitcode, signal = p.termsignal)
    return nothing
end

function init_worker!(run::Run, slot::Slot, w::YATFWorkers.Worker)
    init = slot.profile.init
    isempty(init.args) && return nothing
    timeout = run.plan.cfg.init_timeout_s
    fut = YATFWorkers.remote_eval(w, Expr(:block, init.args...))
    fetch_within(
        fut, timeout,
        TimeoutException(timeout, "the `init` expression of profile `$(slot.profile.name)`", "", "init_timeout")
    )
    return nothing
end

function stop_worker!(run::Run, slot::Slot)
    w = slot.worker
    w === nothing && return nothing
    slot.worker = nothing
    ran = slot.worker_items
    alive = slot.started_at == 0.0 ? 0.0 : time() - slot.started_at
    try
        close(w)
    catch e
        @error "YATF: could not stop worker $(w.pid)" exception = (e, catch_backtrace())
    end
    p = w.process
    status = !process_exited(p) ? " · still running" :
        p.exitcode == 0 && p.termsignal == 0 ? "" : string(" · ", YATFWorkers.exit_description(p))
    print_worker_line(
        run, slot.id, "EXIT", string("pid ", w.pid, " · ", plural(ran, "item"), " · ", fmt_seconds(alive), status)
    )
    return nothing
end

# How a worker that was not asked to stop came to an end: its exit status, and
# what memory looked like when it was last seen, which is most of what an OOM kill
# leaves behind.
function died_how(run::Run, slot::Slot, w::YATFWorkers.Worker)
    how = YATFWorkers.exit_description(w.process)
    by = w.ended_by
    alone = by === :connection_lost || by === :process_exit
    if alone && w.process.termsignal == 9
        how *= ", which nothing in this run sent: usually the out-of-memory killer"
    elseif by === :memory_guard
        how *= ", stopped by the memory guard"
    elseif !alone
        how *= string(", stopped after ", replace(String(by), '_' => ' '))
    end
    return string(how, memory_note(run.monitor, slot.id))
end

"""
    LIVE_RUN

The run this process is part-way through, or nothing. A process runs one at a
time, and [`report_unfinished_run`](@ref) is the only reader.
"""
const LIVE_RUN = Ref{Any}(nothing)

# Registered when a run reaches its test phase; a process that never gets that far
# has nothing to say at exit.
const ensure_exit_report = OncePerProcess{Nothing}() do
    atexit(report_unfinished_run)
    nothing
end

"""
    report_unfinished_run()

Close the books on a run whose process is going down without unwinding. Julia 1.12
delivers an interrupt to whichever task its first thread is running, which between
items is a finished one that cannot catch it, so no `finally` runs; a test item
calling `exit` ends the same way. Best effort: the printer is taken with `trylock`,
so a line of output cannot hang the exit.
"""
function report_unfinished_run()
    run = LIVE_RUN[]
    run === nothing && return nothing
    LIVE_RUN[] = nothing
    try
        stop_monitor!(run.monitor)
        cancel!(run.queues)
        # Nothing unwound, so the slots never recorded what they were holding.
        # They are frozen where they were, and each still names its item.
        foreach(slot -> record_stopped_item!(run, slot), run.slots)
        finish_run_state!(run.runstate; cancelled = true)
        if trylock(run.printer)
            try
                print_conclusion(run, :interrupted)
            finally
                unlock(run.printer)
            end
        end
    catch
    end
    return nothing
end

"""
    kill_workers!(run)

Kill every worker this run has, now: the orderly teardown takes most of a minute
across a pool, a long time to hold a terminal someone has asked for back. Nothing
is reported for what they were running. `shutdown!` waits for them to be gone.
"""
function kill_workers!(run::Run, why::AbstractString = "interrupted")
    live = 0
    for slot in run.slots
        w = slot.worker
        w === nothing && continue
        @lock run.lock push!(run.killed, w)
        slot.worker = nothing
        live += 1
        YATFWorkers.kill!(w)
    end
    live == 0 || say(run, why, "; killed ", plural(live, "worker"))
    return nothing
end

function shutdown!(run::Run)
    for slot in run.slots
        stop_worker!(run, slot)
    end
    # A killed worker is the run's until its process is reaped and the tasks relaying
    # it have ended, and `kill!` returns before either. The run ends with nothing it
    # started still going, and with how each worker ended in its run state.
    foreach(wait, @lock run.lock copy(run.killed))
    return nothing
end

# The pieces rather than the sentence: one of these is built for every dispatch and
# almost none of them is ever shown. `setting` is what set the limit, so a report
# says which knob to turn.
struct TimeoutException <: Exception
    seconds::Int
    kind::String
    subject::String
    setting::String
end

TimeoutException(seconds::Integer, kind::AbstractString, subject::AbstractString, setting::AbstractString) =
    TimeoutException(Int(seconds), String(kind), String(subject), String(setting))

Base.showerror(io::IO, e::TimeoutException) = print(
    io, e.kind, isempty(e.subject) ? "" : string(" ", repr(e.subject)),
    " timed out after ", e.seconds, "s (", e.setting, ")"
)

# An item's own keyword wins over the run default, the same way `timeout` and
# `failfast` do. A chain is retried as a unit, so the most demanding member sets
# the number of attempts.
attempts_for(p::Plan, u::UnitIdx) = 1 + maximum(p.units.span[u]) do i
    p.items.retries[i] == USE_RUN_DEFAULT ? p.cfg.retries : Int(p.items.retries[i])
end

# The attempt policy, the same wherever the unit runs: on a pool worker, on a
# sandbox worker, or in this process under `workers=0`.
function run_unit!(run::Run, slot::Slot, u::UnitIdx, target)
    p = run.plan
    max_attempts = attempts_for(p, u)
    for attempt in 1:max_attempts
        broken = run_unit_once!(run, slot, u, target, Int8(attempt), max_attempts)
        has_non_pass(run, u) || return nothing
        if attempt == max_attempts
            # Out of attempts. A chain cut short by a dead worker has lost the state
            # its remaining items relied on, so they are recorded as broken.
            broken && mark_remaining_broken!(run, u, Int8(attempt))
            # Failfast waits for the last attempt: stopping the run under a retry
            # would record the failure as a cancellation.
            p.cfg.failfast && cancel!(run.queues) === false &&
                print_failfast(run, first(p.units.span[u]))
            return nothing
        end
        # Retrying a chain restarts it from its first item: re-running one item of
        # a sequence that mutates state does not mean anything.
        reset_unit!(run, u)
    end
    return nothing
end

has_non_pass(run::Run, u::UnitIdx) =
    any(i -> is_non_pass(run.statuses.state[i]), run.plan.units.span[u])

function reset_unit!(run::Run, u::UnitIdx)
    for i in run.plan.units.span[u]
        run.statuses.state[i] = UNSEEN
    end
    return nothing
end

# One attempt at every item of a unit: on the slot's worker, or here when there is
# no pool and the unit did not ask for a process of its own. `true` when a worker
# was lost part way through, which leaves the rest of the unit unable to run.
function run_unit_once!(run::Run, slot::Slot, u::UnitIdx, target, attempt::Int8, max_attempts::Int)
    p = run.plan
    exclusive = p.units.exclusive[u]
    attempt_item! = single_process(p) && !needs_worker(p, u) ? attempt_here! : attempt_on_worker!
    # A sandbox is a process to itself, and the slot may arrive holding a worker
    # that has already run other items.
    exclusive && slot.worker_items > 0 && stop_worker!(run, slot)
    for i in p.units.span[u]
        # Every item is unseen when the loop reaches it: `reset_unit!` puts them
        # back before each retry.
        is_cancelled(run.queues) && (run.statuses.state[i] = CANCELLED; continue)
        attempt_item!(run, slot, i, target, attempt, max_attempts) || return true
    end
    exclusive && stop_worker!(run, slot)
    return false
end

# When and in which process an attempt began, marked running before it is sent:
# if this process is killed, the file says which item was in flight, which is the
# truth and usually the answer. An outcome the run decides is timed from here.
function began!(run::Run, i::ItemIdx, slot::SlotIdx, attempt::Int8, pid::Integer)
    st = run.statuses
    st.start[i] = Float32(time() - run.t0)
    st.pid[i] = Int32(pid)
    pid == 0 || write_status!(run.runstate, i, RUNNING, attempt, slot; start_off = st.start[i], pid)
    return nothing
end

# One attempt at item `i` on the slot's worker, starting one when it has none.
# `false` when the worker is gone and the rest of its unit cannot be trusted.
function attempt_on_worker!(run::Run, slot::Slot, i::ItemIdx, target, attempt::Int8, max_attempts::Int)
    p = run.plan
    w = try
        ensure_worker!(run, slot, target, p.units.exclusive[p.items.unit[i]])
    catch e
        e isa InterruptException && rethrow()
        began!(run, i, slot.id, attempt, 0)
        record_error!(run, i, slot, attempt, ERRORED, sprint(showerror, e))
        return false
    end
    spec = item_spec(run, i, slot, attempt)
    began!(run, i, slot.id, attempt, w.pid)
    slot.current = i
    result = try
        dispatch(run, w, spec, item_timeout(p, i), slot)
    catch e
        # An interrupt leaves it set: the slot is unwinding, and what it was
        # running is the one thing `record_stopped_item!` needs from it.
        e isa InterruptException && rethrow()
        slot.current = ItemIdx(0)
        return handle_dispatch_failure!(run, slot, i, attempt, e, max_attempts)
    end
    slot.current = ItemIdx(0)
    slot.worker_items += 1
    record_result!(run, i, slot, attempt, result, max_attempts)
    return true
end

# One attempt at item `i` in this process. There is no second process to kill, so
# nothing times out, and no worker to lose, so the unit always goes on.
function attempt_here!(run::Run, slot::Slot, i::ItemIdx, _, attempt::Int8, max_attempts::Int)
    spec = item_spec(run, i, slot, attempt)
    began!(run, i, slot.id, attempt, getpid())
    printline(run, item_line(run, nothing, i, attempt, nothing))
    res = try
        r = run_item(spec)
        printline(run, item_line(run, nothing, i, attempt, outcome(r)))
        with_test_end(r, spec, slot.profile.test_end)
    catch e
        if e isa InterruptException
            (@atomic run.stalled) && record_error!(run, i, slot, attempt, TIMEDOUT, STALLED_NOTE)
            rethrow()
        end
        record_error!(
            run, i, slot, attempt, ERRORED,
            string(sprint(showerror, e), " · ", retry_note(attempt, max_attempts, is_cancelled(run.queues)))
        )
        return true
    end
    record_result!(run, i, slot, attempt, res, max_attempts)
    return true
end

# The item, then the profile's `test_end`: two requests to one process, each
# against its own limit, so a `test_end` that hangs is not reported as an item that
# hung. Most profiles have no `test_end` and send one request.
function dispatch(run::Run, w::YATFWorkers.Worker, spec::ItemSpec, timeout::Int, slot::Slot)
    fut = YATFWorkers.remote_run(w, spec)
    res = fetch_within(fut, timeout, TimeoutException(timeout, "test item", spec.name, timeout_setting(run.plan, spec.index)))::ItemResult
    test_end = slot.profile.test_end
    (isempty(test_end.args) || res.state === SKIPPED) && return res
    seconds = run.plan.cfg.test_end_timeout_s
    endfut = YATFWorkers.remote_end(w, spec, test_end)
    endres = try
        fetch_within(
            endfut, seconds,
            TimeoutException(seconds, "the `test_end` expression of profile `$(slot.profile.name)`", "", "test_end_timeout")
        )::ItemResult
    catch e
        # The item ran; it is the profile's own code that did not come back. Saying
        # "the worker running this item died" here would point at the wrong code.
        (e isa TimeoutException || e isa InterruptException) && rethrow()
        throw(TestEndFailure(slot.profile.name, e))
    end
    return merge_test_end(res, endres)
end

struct TestEndFailure <: Exception
    profile::Symbol
    cause::Any
end

Base.showerror(io::IO, e::TestEndFailure) = print(
    io, "the `test_end` expression of profile `", e.profile, "` did not complete: ",
    sprint(showerror, e.cause)
)

# A `test_end` that recorded nothing leaves the item's result alone; one that failed
# becomes a testset nested in the item's. The item's timings stay the item's.
function merge_test_end(res::ItemResult, endres::ItemResult)
    isempty(endres.testset.results) && return res
    push!(res.testset.results, endres.testset)
    state = severity(endres.state) > severity(res.state) ? endres.state : res.state
    return ItemResult(res.index, state, res.testset, res.stats)
end

severity(s::ItemState) = s === ERRORED ? 2 : s === FAILED ? 1 : 0

# `fetch(fut)`, or throw `on_timeout` once `seconds` pass without a reply. The timer
# closes the future's own channel, so there is no second channel or task per
# dispatch. A reply that arrived first is buffered, and `fetch` returns a buffered
# value even from a closed channel, so a reply racing its deadline wins.
function fetch_within(fut, seconds::Real, on_timeout::Exception)
    timer = Timer(seconds) do _
        close(fut.value, on_timeout)
    end
    try
        return fetch(fut)
    finally
        close(timer)
    end
end

# Whether the worker survived: `false` when it is gone and the rest of the unit
# cannot be trusted, `true` when the item failed on a process still fit to use.
function handle_dispatch_failure!(
        run::Run, slot::Slot, i::ItemIdx, attempt::Int8, e,
        max_attempts::Int
    )
    w = slot.worker
    item = run.plan.items.name[i]
    if e isa TimeoutException
        ended = time()   # the item held its worker until here; inspecting it is ours
        if w !== nothing
            print_worker_line(run, slot.id, "KILL", string("pid ", w.pid, " · ", sprint(showerror, e)))
            YATFWorkers.inspect!(w)   # where was it: every thread's and task's backtrace, into the item's log
            # `wait` below joins the task relaying this worker's output, so
            # everything the process says on its way down has been filed by the
            # time the item is reported.
            slot.dying_log = item_log_path(run.logprefix, i, attempt)
            YATFWorkers.terminate!(w, :timeout)
            wait(w)   # a replacement must not overlap the process it replaces
            flush_dying_log!(slot)
        end
        slot.worker = nothing
        record_error!(
            run, i, slot, attempt, TIMEDOUT,
            string(sprint(showerror, e), " · ", retry_note(attempt, max_attempts, is_cancelled(run.queues)));
            ended
        )
        return false
    elseif w !== nothing && !w.terminated
        # The request failed but the process is fine: a result that would not
        # serialize, a `skip` expression that threw. The worker keeps everything
        # it has compiled, and the item is an ordinary error.
        record_error!(run, i, slot, attempt, ERRORED, sprint(showerror, e))
        return true
    else
        ended = time()
        how = ""
        if w !== nothing
            wait(w)   # its exit status is known once its process is reaped
            how = died_how(run, slot, w)
            print_worker_line(run, slot.id, "LOST", string("pid ", w.pid, " · died while running ", repr(item), ": ", how))
        end
        slot.worker = nothing
        # A stopped run took this worker away itself: the item neither failed nor
        # ran, and is counted with the ones that never started.
        if is_cancelled(run.queues)
            record_error!(run, i, slot, attempt, CANCELLED, "the run was stopped"; ended)
        else
            record_error!(
                run, i, slot, attempt, ERRORED,
                string(
                    e isa YATFWorkers.WorkerTerminatedException ?
                        string("the worker running this item died: ", how) : sprint(showerror, e),
                    " · ", retry_note(attempt, max_attempts, false)
                );
                ended
            )
        end
        return false
    end
end

function item_spec(run::Run, i::ItemIdx, slot::Slot, attempt::Int8)
    p = run.plan
    # The directory is this run's own and (item, attempt) is unique within it, so
    # nothing is there to clear first.
    logpath = p.cfg.logs === :eager ? "" : item_log_path(run.logprefix, i, attempt)
    return ItemSpec(
        i, p.items.name[i], p.files[p.items.fileidx[i]], p.items.line[i],
        p.items.code[i], p.items.skip[i],
        p.items.failfast[i] == -1 ? p.cfg.item_failfast : p.items.failfast[i] == 1,
        run.project_name, slot.profile.name, attempt, p.cfg.full_stacktraces, logpath,
        item_seed(p.cfg.seed, p.items.name[i])
    )
end

# The run's seed and the item's name, mixed so that each item draws its own numbers
# whatever ran before it in the same process. CRC32c rather than `hash`, which may
# change between Julia versions and would make a recorded seed mean something else.
item_seed(seed::UInt64, name::AbstractString) = seed ⊻ (UInt64(crc32c(name)) * 0x9e3779b97f4a7c15)

item_timeout(p::Plan, i::ItemIdx) =
    p.items.timeout_s[i] == USE_RUN_DEFAULT ? p.cfg.timeout_s : Int(p.items.timeout_s[i])

timeout_setting(p::Plan, i::Integer) =
    p.items.timeout_s[i] == USE_RUN_DEFAULT ? "the run's timeout" : string("its own timeout=", p.items.timeout_s[i])

### Recording ##############################################################

# What happens next, said where the failure is reported: a dead worker is only
# half the story if the reader cannot tell whether the item gets another go.
function retry_note(attempt::Integer, max_attempts::Integer, cancelled::Bool)
    # A stopped run retries nothing, whatever the item asked for. Saying it will is
    # a promise the next line of the log breaks.
    cancelled && return "the run was stopped"
    retries = max_attempts - 1
    retries <= 0 && return "not retried (retries=0)"
    attempt <= retries && return string("retrying on a new worker (retry ", attempt, " of ", retries, ")")
    return string("no retries left (", retries, " of ", retries, " used)")
end

"""
    record!(run, i, slot, attempt, state, testset, stats, synthetic, note)

Everything that follows from one attempt's outcome, in one place: the item's
status in memory and on disk, the count of finished items, and the item's report.
`synthetic` says the run decided the outcome rather than the item — a timeout, a
dead worker, a chain cut short — and `testset` then holds a single error saying so.
"""
function record!(
        run::Run, i::ItemIdx, slot::SlotIdx, attempt::Int8, state::ItemState,
        testset::Test.AbstractTestSet, stats::YATFWorkers.PerfStats, synthetic::Bool,
        note::AbstractString; ended::Float64 = time()
    )
    (state === UNSEEN || state === RUNNING) && error("YATF internal error: item $i recorded as $state")
    st = run.statuses
    st.state[i] = state
    st.synthetic[i] = synthetic
    st.attempt[i] = attempt
    st.slot[i] = slot
    # An outcome the item reported took what the item measured; one the run decided
    # took as long as the item held its worker.
    st.elapsed[i] = synthetic ? max(0.0, ended - run.t0 - st.start[i]) : stats.elapsed_ns / 1.0e9
    st.compile[i] = stats.compile_ns / 1.0e9
    st.testsets[i] = testset
    write_status!(
        run.runstate, i, state, attempt, slot;
        start_off = st.start[i], elapsed = st.elapsed[i], compile = st.compile[i],
        recompile = stats.recompile_ns / 1.0e9, alloc_mb = stats.bytes / 2^20,
        peak_rss_mb = stats.maxrss / 2^20, pid = st.pid[i]
    )
    append_event!(run.runstate, EVENT_ATTEMPT, UInt8(state), slot, st.pid[i], st.start[i], ended - run.t0; item = i, attempt)
    @atomic run.last_finish = time()
    report_item!(run, i, state, count_done!(run, i), note)
    return nothing
end

function record_result!(
        run::Run, i::ItemIdx, slot::Slot, attempt::Int8, res::ItemResult,
        max_attempts::Int = 1
    )
    # Only worth saying when there is a policy to state: a plain failure with no
    # retries configured explains itself.
    note = (is_non_pass(res.state) && max_attempts > 1) ?
        retry_note(attempt, max_attempts, is_cancelled(run.queues)) : ""
    record!(run, i, slot.id, attempt, res.state, res.testset, res.stats, false, note)
    return nothing
end

record_error!(run::Run, i::ItemIdx, slot::Slot, attempt::Int8, state::ItemState, msg::AbstractString; ended::Float64 = time()) =
    record!(run, i, slot.id, attempt, state, error_testset(run, i, msg, ended), YATFWorkers.PerfStats(), true, msg; ended)

# The testset of an outcome the run decided: one error saying why, at the item's
# own line, so the summary and the verdict count it like any other error.
function error_testset(run::Run, i::ItemIdx, msg::AbstractString, ended::Float64)
    p = run.plan
    ts = started_testset(p.items.name[i]; verbose = false, at = run.t0 + run.statuses.start[i])
    finish_quietly(add_error!(ts, msg, source_of(p, i)))
    finished_at!(ts, ended)
    return ts
end

# A retried item is finished once, however many attempts it took.
function count_done!(run::Run, i::ItemIdx)
    run.statuses.counted[i] && return @atomic run.ndone
    run.statuses.counted[i] = true
    n = @atomic run.ndone += 1
    n <= nitems(run.plan) || error("YATF internal error: $n items counted as finished, of $(nitems(run.plan))")
    return n
end

function finish_quietly(ts::Test.AbstractTestSet)
    without_enclosing_testset() do
        with_testset_printing(false) do
            try
                Test.finish(ts)
            catch e
                e isa Test.TestSetException || rethrow()
            end
        end
    end
    return ts
end

function mark_remaining_broken!(run::Run, u::UnitIdx, attempt::Int8)
    p = run.plan
    for i in p.units.span[u]
        run.statuses.state[i] === UNSEEN || continue
        began!(run, i, SlotIdx(0), attempt, 0)
        ts = error_testset(
            run, i, "the worker running this chain died before this item ran; " *
                "the state it depended on is gone, so it was not run", time()
        )
        # Slot 0: in this attempt the item never ran anywhere.
        record!(
            run, i, SlotIdx(0), attempt, BROKEN_CHAIN, ts, YATFWorkers.PerfStats(), true,
            "the worker running this chain died before this item ran"
        )
    end
    return nothing
end

### In-process mode ########################################################

function run_in_process(run::Run, target)
    p = run.plan
    @lock run.lock push!(run.tasks, current_task())
    isempty(p.profiles[1].init.args) ||
        @warn "YATF: the profile's `init` expression is evaluated in this process (workers=0)"
    Core.eval(Main, Expr(:block, p.profiles[1].init.args...))
    slot = run.slots[1]
    # Every unit, not just the one slot's queue: a pool that would have had a
    # worker of its own has none here, and its items still have to run.
    for u in UnitIdx(1):UnitIdx(length(p.units))
        is_cancelled(run.queues) && break
        # A unit that asked for a process gets one here too — `run_unit_once!`
        # decides which do — started and stopped around it.
        slot.profile = p.profiles[p.units.profile[u]]
        try
            run_unit!(run, slot, u, target)
        finally
            stop_worker!(run, slot)
        end
    end
    check_finished(run)
    return nothing
end

# The profile's test-end expression after the item, merged the way a worker's two
# replies are. Nothing here can be timed out: there is no second process to kill.
with_test_end(res::ItemResult, spec::ItemSpec, test_end::Expr) =
    isempty(test_end.args) || res.state === SKIPPED ? res :
    merge_test_end(res, YATFWorkers.run_test_end(spec, test_end))
