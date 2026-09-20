# Running a plan.
#
# One task per slot. A slot takes work from its own queue, steals from the tail of
# the longest queue when its own drains, and rebinds to another profile's queue
# when there is nothing left to steal. `workers` is a hard cap on live processes
# throughout: the framework takes longer rather than starting a process the caller
# did not authorize.

using Base: SIGKILL

mutable struct Slot
    const id::SlotIdx
    # What a line relayed from this slot's worker starts with, one per glyph in
    # `LINE_MARKS`. Constant for the life of the slot, and a run relays at least
    # two lines an item, so the choice is an index rather than a concatenation.
    const prefixes::NTuple{length(LINE_MARKS), String}
    pool::Int32
    profile::Profile
    worker::Union{Nothing, YATFWorkers.Worker}
    started_at::Float64      # when this slot's current process came up
    worker_items::Int        # items the current process has run, for its EXIT line
    units_started::Int
    current::ItemIdx      # the item this slot is running, 0 when idle
    # Where to put what the worker prints while it is being taken down, or empty.
    # A process killed for a timeout prints a signal and a backtrace after its item
    # has stopped capturing, so that output arrives loose on the relay with nowhere
    # obvious to go; it belongs with the item that was running.
    dying_log::String
end

"""
    Queues

Every cursor a run has, behind one lock. Claiming happens a few thousand times in
a run, so an uncontended lock costs nothing measurable and removes a whole class
of racy-cursor bugs that would be very hard to reproduce in a test framework.
"""
mutable struct Queues
    const lock::ReentrantLock
    const head::Vector{UnitIdx}      # next unit this slot will take
    const tail::Vector{UnitIdx}      # last unit still available to this slot
    const pool::Vector{Int32}        # the pool each slot is currently serving
    # The profile behind each pool, by pool index. Two pools can share one — an
    # exclusive unit is pooled apart from the ordinary work of the same profile —
    # and stealing is decided on the profile, not on which pool it came from.
    const pool_profile::Vector{Int32}
    const pending::Vector{Int32}        # pools with no slot yet
    const pending_units::Vector{UnitRange{UnitIdx}}
    cancelled::Bool
    paused::Bool        # the memory guard is holding new work back
end

function Queues(p::Plan)
    head = UnitIdx[first(r) for r in p.slot_units]
    tail = UnitIdx[last(r) for r in p.slot_units]
    return Queues(
        ReentrantLock(), head, tail, copy(p.slot_pool),
        Int32[pool.profile for pool in p.pools],
        copy(p.pending), copy(p.pending_units), false, false
    )
end

struct Claim
    kind::Symbol        # :unit, :rebind, :done
    unit::UnitIdx
    pool::Int32
    units::UnitRange{UnitIdx}
end
Claim(kind::Symbol) = Claim(kind, UnitIdx(0), Int32(0), UnitIdx(1):UnitIdx(0))

remaining(q::Queues, s::Integer) = Int(q.tail[s]) - Int(q.head[s]) + 1

function claim!(q::Queues, s::Integer)
    @lock q.lock begin
        q.cancelled && return Claim(:done)
        if remaining(q, s) > 0
            u = q.head[s]
            q.head[s] += UnitIdx(1)
            return Claim(:unit, u, Int32(0), UnitIdx(1):UnitIdx(0))
        end
        # Steal from the tail of the busiest queue running the same profile: the
        # owner has not warmed that end up either, so it is the cheapest end to
        # give away. Never across profiles — a profile is a worker configuration,
        # and an item run under another profile's julia flags was not the test that
        # was declared, however green it comes out.
        #
        # Same profile is the whole condition, and a pool is narrower than that: a
        # profile's exclusive units are pooled separately from its ordinary ones,
        # so a slot serving one sandbox would otherwise go home for good with the
        # rest of its own configuration still queued.
        #
        # A queue holding a single unit is worth stealing from: `remaining` counts
        # what has not been claimed, and the unit its owner is running was claimed
        # when it started. Leaving that one behind is how the last item of a slow
        # worker's queue waits out an item that takes a minute while every other
        # worker has gone home.
        victim, most = 0, 0
        for v in eachindex(q.head)
            (v == s || q.pool_profile[q.pool[v]] != q.pool_profile[q.pool[s]]) && continue
            r = remaining(q, v)
            r > most && ((victim, most) = (v, r))
        end
        if victim != 0
            u = q.tail[victim]
            q.tail[victim] -= UnitIdx(1)
            return Claim(:unit, u, Int32(0), UnitIdx(1):UnitIdx(0))
        end
        if !isempty(q.pending)
            pool = popfirst!(q.pending)
            units = popfirst!(q.pending_units)
            q.head[s] = first(units)
            q.tail[s] = last(units)
            q.pool[s] = pool
            return Claim(:rebind, UnitIdx(0), pool, units)
        end
        return Claim(:done)
    end
end

cancel!(q::Queues) = @lock q.lock (was = q.cancelled; q.cancelled = true; was)
is_cancelled(q::Queues) = @lock q.lock q.cancelled
set_paused!(q::Queues, v::Bool) = @lock q.lock (q.paused = v; nothing)
is_paused(q::Queues) = @lock q.lock q.paused

# Backpressure: hold new work rather than add another item's allocations to a
# machine that is already short of memory.
#
# The hold is bounded. Memory pressure is often caused by something other than
# this run, and a test framework that quietly stops making progress is worse than
# one that runs its tests on a busy machine — so after `MAX_BACKPRESSURE_SECONDS`
# the run continues and says so. Cancellation always gets through.
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
    elapsed::Vector{Float32}
    compile::Vector{Float32}
    testsets::Vector{Any}
    logpaths::Vector{String}
end

Statuses(n::Integer) = Statuses(
    falses(n), falses(n), fill(UNSEEN, n), zeros(Float32, n), zeros(Int8, n), fill(SlotIdx(0), n),
    zeros(Float32, n), zeros(Float32, n),
    Vector{Any}(nothing, n), fill("", n)
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
        YATFWorkers.name_width(p.items.name; columns = YATFWorkers.terminal_columns()),
        ReentrantLock(), time(), nothing, nothing, Dict{Symbol, String}(), 0
    )
    run.runstate = open_runstate(p)
    cfg.monitor && (run.monitor = start_monitor!(Monitor(run; print_interval = cfg.monitor_interval)))
    for s in 1:nslots(p)
        push!(
            run.slots, Slot(
                SlotIdx(s),
                ntuple(k -> string(MARK_INDENT, LINE_MARKS[k], " w", s, FIELD), length(LINE_MARKS)),
                p.slot_pool[s], p.profiles[p.pools[p.slot_pool[s]].profile],
                nothing, 0.0, 0, 0, ItemIdx(0), ""
            )
        )
    end
    setup_path = joinpath(target.testdir, TESTSETUPS_DIR)
    # Every log record raised while the run is going goes through the printer, so
    # nothing can land in the middle of the status line or another writer's line.
    return with_logger(RunLogger(current_logger(), run)) do
        t_env = time()
        with_test_env(target, run) do
            p.startup.env = time() - t_env
            with_load_path(setup_path) do
                t_pre = time()
                profile_projects!(run, p)
                precompile_phase(run, p, target)
                p.startup.precompile = time() - t_pre
                # Printed once everything before the tests is done, so it can say what
                # that cost.
                print_run_header(run)
                set_phase!(run.monitor, PHASE_TEST)
                try
                    if cfg.workers == 0
                        run_in_process(run, target)
                    else
                        run_on_workers(run, target)
                    end
                catch e
                    e isa InterruptException && kill_workers!(run)
                    rethrow()
                finally
                    set_phase!(run.monitor, PHASE_REPORT)
                    stop_monitor!(run.monitor)
                    shutdown!(run)
                    run.monitor === nothing || write_memory!(run.runstate, run.monitor.stats)
                    finish_run_state!(run.runstate; cancelled = is_cancelled(run.queues))
                    prune_runstates(p.root)
                end
                run
            end
        end
    end
end

"""
    with_test_env(f, target)

Run `f` with the package's test environment active, and restore whatever was
active afterwards: `runtests` at the REPL must not leave the caller somewhere else.

The environment is chosen in this order:

1. the one already active, when the call came from `<root>/test/runtests.jl` —
   that is `Pkg.test`, which has already built an environment holding the package
   and its test dependencies, and switching away would lose them;
2. the one already active, when it is the package's own `test/Project.toml`,
   because activating that is a deliberate choice;
3. a test environment built by `TestEnv`, cached for the session.

The package's plain project is deliberately *not* used: it does not contain the
test-only dependencies, so every item that needs one would fail to load it.
"""
function with_test_env(f, target, run = nothing)
    # Building it is `Pkg`'s to narrate, and it draws its own progress by moving
    # the cursor. Ours comes down while it does.
    monitor = run === nothing ? nothing : run.monitor
    env = with_status_line_off(monitor) do
        test_env_for(target, run === nothing ? nothing : () -> printline(
            run, string(yatf_prefix(), "resolving the test environment")
        ))
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

The environment the target's test items should resolve against, or `nothing` when
the one already active is it.

Split out because a run is not the only thing that needs the answer: `activate`
puts the REPL in the same place, and the two must agree about where that is.
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

# Generated test environments are kept for the lifetime of the session, keyed by
# project file. Building one costs a resolve, and the new environment makes Julia
# believe the code it holds has changed, so it precompiles again — at the REPL,
# where `runtests` is called over and over, that is the difference between a
# second and a minute. The stamp is what the environment was generated from, so
# adding a test dependency mid-session rebuilds it instead of being ignored.
const TEST_ENVS = Dict{String, Tuple{String, NTuple{4, Float64}}}()
const TEST_ENVS_LOCK = ReentrantLock()

function test_env(target, announce = nothing)
    proj = abspath(target.project)
    return @lock TEST_ENVS_LOCK begin
        cached = get(TEST_ENVS, proj, nothing)
        if cached !== nothing && isfile(cached[1]) && cached[2] == env_stamp(target)
            return cached[1]
        end
        # Only here: resolving takes seconds and is the longest unexplained pause a
        # run has, while a cache hit is immediate and a line about it would be
        # noise at the REPL, where that hit is the point.
        announce === nothing || announce()
        original = Base.active_project()
        try
            # `Pkg` precompiles an environment it has just resolved, for the flags
            # this process happens to be running under. The run wants the same work
            # done for every set of flags its pools will use, which is one pass over
            # the environment rather than this one plus another; `precompile_env`
            # does it, and this stays a resolve so the time reported against it is
            # the resolve's.
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

Whether this unit has to run in a process of its own however the run is
configured.

`--check-bounds=yes` cannot be applied to a process that is already running, and
nothing can give an item a process to itself when there is only one. An item that
asked for either is testing something that depends on it, so it gets a worker even
under `workers=0` — running it here and reporting a pass would be reporting a pass
for a test that was never run the way it was written.
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

# One process precompiles what every worker is about to need. Without this, N
# workers hit the same cold cache at the same moment and serialize on Julia's
# precompilation lock exactly when the run starts.
"""
    profile_projects!(run, p)

Give every profile that declares preferences a project of its own, and record
where it is.

A package takes its preferences from the environment that owns it. A second
environment stacked above the first is not consulted — measured — so a profile's
preferences cannot be layered onto the test environment and have to arrive as the
worker's own project. Each directory holds the test environment's `Project.toml`
and `Manifest.toml`, so every package resolves to the same version it would
otherwise, over a `LocalPreferences.toml` of the environment's own preferences
with the profile's laid on top.

Preferences are part of a cache's identity, so these projects keep caches of their
own rather than displacing the ones the other workers use.
"""
function profile_projects!(run::Run, p::Plan)
    env = Base.active_project()
    env === nothing && return nothing
    root = dirname(env)
    for prof in values(p.profiles)
        isempty(prof.preferences) && continue
        dir = joinpath(root, string("yatf_profile_", prof.name))
        mkpath(dir)
        for file in ("Project.toml", "Manifest.toml")
            src = joinpath(root, file)
            isfile(src) && cp(src, joinpath(dir, file); force = true)
        end
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

function precompile_phase(run::Run, p::Plan, target)
    # The environment first: a setup module is compiled against it, and compiling
    # one before it is there makes that worker build the dependencies itself, one
    # at a time, instead of reading what this pass wrote.
    precompile_env(run, p)
    precompile_setups(run, p, target)
    return nothing
end

"""
    cache_flags_for(julia_args) -> Base.CacheFlags

The cache flags a worker started with `julia_args` will have.

Asked of a process started the same way rather than derived from the arguments:
which of them reach the cache key is Julia's business and changes between
versions, and a wrong answer here silently precompiles for the wrong key.
"""
cache_flags_for(julia_args::Cmd) = parse(
    Base.CacheFlags,
    read(
        `$(Base.julia_cmd()) $julia_args --startup-file=no --history-file=no -e "show(Base.CacheFlags())"`,
        String
    )
)

"""
    precompile_env(run, p)

Precompile the test environment once for every set of cache flags the run will
use: this process's own, and one per pool that has julia arguments of its own.

Every test item's module loads the package under test, and a package image built
under other julia flags cannot be used, so the first worker of a pool with
`julia_args` would otherwise compile that package and everything it depends on —
inside the worker, serially, with no output, while the run looks stalled on its
first item. One pass here covers every set of flags at once, and what it writes
serves every later worker and every later run.

This is also where the environment's ordinary precompilation happens. `Pkg` would
do that as part of resolving, for this process's flags alone; `test_env` turns that
off so the whole thing is one pass rather than that one and then another.
"""
function precompile_env(run::Run, p::Plan)
    mine = Base.CacheFlags()
    # The flags this process runs under lead, because every pool without julia
    # arguments of its own uses them and because `Pkg` is no longer doing it.
    configs = Pair{Cmd, Base.CacheFlags}[`` => mine]
    names = String[]
    seen = Set{Base.CacheFlags}()
    for pool in p.pools
        prof = p.profiles[pool.profile]
        # A profile with preferences runs in a project of its own, and a project is
        # not something `configs` can carry, so it gets a call to itself below.
        haskey(run.profile_projects, prof.name) && continue
        # Only julia arguments reach the cache key; a profile that differs only in
        # threads or environment shares the flags this process already compiled for.
        isempty(prof.julia_args) && continue
        args = Cmd(prof.julia_args)
        flags = try
            cache_flags_for(args)
        catch e
            e isa InterruptException && rethrow()
            @warn "YATF: could not read the cache flags of profile `$(prof.name)`; its \
                   workers will compile what they need themselves" exception = e
            continue
        end
        (flags == mine || flags in seen) && continue
        push!(seen, flags)
        push!(configs, args => flags)
        push!(names, String(prof.name))
    end
    for prof in values(p.profiles)
        dir = get(run.profile_projects, prof.name, nothing)
        dir === nothing && continue
        precompile_profile_project(run, prof, dir)
    end
    # Named only when there is something to name. `Pkg` narrates the rest itself,
    # and says nothing at all when there is nothing to do, which is what this line
    # would have to work out for itself to avoid printing on every cached run.
    isempty(names) || printline(
        run, string(
            yatf_prefix(), "precompiling the test environment for ",
            plural(length(names), "profile"), ": ", join(names, ", ")
        )
    )
    try
        # `Pkg` draws its own progress by moving the cursor, so ours comes down.
        with_status_line_off(run.monitor) do
            Pkg.precompile(
                Pkg.Types.Context(), Pkg.Types.PackageSpec[];
                configs, warn_loaded = false, already_instantiated = true, io = stdout
            )
        end
    catch e
        e isa InterruptException && rethrow()
        # Work brought forward, not work that has to succeed: a worker that finds
        # nothing cached still compiles what it needs, one process at a time.
        @warn "YATF: could not precompile the test environment for \
               $(join(names, ", ")); its workers will compile what they need \
               themselves" exception = e
    end
    return nothing
end

# One call each, because a project is part of a cache's identity and `configs`
# only carries julia arguments: two profiles with different preferences are two
# environments, not two configurations of one.
function precompile_profile_project(run::Run, prof::Profile, dir::AbstractString)
    args = Cmd(prof.julia_args)
    flags = try
        isempty(prof.julia_args) ? Base.CacheFlags() : cache_flags_for(args)
    catch e
        e isa InterruptException && rethrow()
        @warn "YATF: could not read the cache flags of profile `$(prof.name)`; its \
               workers will compile what they need themselves" exception = e
        return nothing
    end
    printline(
        run,
        string(yatf_prefix(), "precompiling the test environment for profile ", prof.name)
    )
    original = Base.active_project()
    try
        with_status_line_off(run.monitor) do
            Base.set_active_project(joinpath(dir, "Project.toml"))
            Pkg.precompile(
                Pkg.Types.Context(), Pkg.Types.PackageSpec[];
                configs = args => flags, warn_loaded = false,
                already_instantiated = true, io = stdout
            )
        end
    catch e
        e isa InterruptException && rethrow()
        @warn "YATF: could not precompile the test environment for profile \
               `$(prof.name)`; its workers will compile what they need themselves" exception = e
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
    printline(run, string(yatf_prefix(), "precompiling ", join(stale, ", ")))
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
        # Julia writes the reason a module would not precompile to the stream it
        # is given, and throws an exception that says only that it failed. Both
        # halves are needed to act on it, so the output is captured and reported
        # with the failure rather than left somewhere above it.
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
    original_logger = current_logger()
    tasks = map(run.slots) do slot
        Threads.@spawn begin
            s = $slot
            # The logger in force before any user code was evaluated: logging from
            # a task that inherited a later world age can hit world-age errors.
            with_logger(original_logger) do
                try
                    run_slot(run, s, target)
                catch e
                    e isa InterruptException && (cancel!(run.queues); rethrow())
                    # This slot is finished, but the run is not: the units it had
                    # left are still in its queue for the other slots to steal.
                    # Cancelling everything because one slot fell over is how a
                    # single bad test item stops a whole suite from running.
                    @error "YATF: worker slot $(s.id) stopped; its remaining items are " *
                        "left for the other workers" exception = (e, catch_backtrace())
                end
            end
        end
    end
    try
        foreach(wait, tasks)
    catch e
        # Ctrl-C lands in whichever task was running, this one included. Stop
        # dispatching, and kill the processes rather than wait for them: an item
        # that sleeps for two minutes would otherwise hold the interrupt for two
        # minutes. The slot tasks are still waited for, because killing their
        # workers is what lets them unwind and `shutdown!` must not find a slot
        # still starting one.
        cancel!(run.queues)
        e isa InterruptException && kill_workers!(run)
        foreach(
            t -> (
                try
                    wait(t)
                catch end
            ), tasks
        )
        rethrow()
    end
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
            slot.pool = claim.pool
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
                extra_env = worker_env(run, slot, target),
                dir = target.root,
                project = Base.active_project(),
                redirect_io = stdout,
                # Everything a worker says while it is running items: its own
                # START/DONE lines, which arrive carrying the glyph for how the
                # item went, and in `logs=:eager` whatever the items print, which
                # does not.
                redirect_fn = function (io, pid, line)
                    mark, at = mark_index(line)
                    if slot.current == ItemIdx(0)
                        # Nothing of this worker's is an item's any more. Its own
                        # verdict for an item the run has already recorded as timed
                        # out is a pass nobody accepted, and is dropped.
                        mark == MARK_IDX_ITEM || return nothing
                        log = slot.dying_log
                        # A process on its way down: its last words go with the item
                        # it was running, where the report will pick them up, rather
                        # than across the middle of the run.
                        isempty(log) || return append_line(log, line, at)
                        mark = MARK_IDX_WORKER
                    end
                    printline(run, string(slot.prefixes[mark], SubString(line, at)))
                end
            )
        catch e
            e isa InterruptException && rethrow()
            last_err = e
            attempt <= WORKER_START_RETRIES && sleep(1)
            continue
        end
        try
            init_worker!(run, slot, w)
            slot.started_at = time()
            slot.worker_items = 0
            count_worker_start!(run.monitor)
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

# Opened per line rather than held: this runs only while a worker is dying, a few
# dozen lines at most, and a handle kept across that window would outlive the
# item's own writer and have to be closed on every path out of the kill.
function append_line(path::AbstractString, line::AbstractString, at::Integer)
    try
        open(io -> println(io, SubString(line, at)), path, "a")
    catch e
        e isa InterruptException && rethrow()
        # The log is a convenience; losing a line of a dying process's backtrace is
        # not a reason to disturb the run that is still going.
    end
    return nothing
end

function worker_env(run::Run, slot::Slot, target)
    pathsep = Sys.iswindows() ? ";" : ":"
    env = Pair{String, String}[
        "YATF_RUN_ID" => run.runid,
        "YATF_WORKER" => string(slot.id),
        "JULIA_LOAD_PATH" => join(LOAD_PATH, pathsep),
    ]
    # Stated rather than left to the worker to infer. A worker inherits this
    # process's environment, so a `JULIA_PROJECT` the caller happened to have set
    # would otherwise be the project its items resolve against — and the test
    # environment this run just built, holding the package under test and its test
    # dependencies, would be the one thing the items could not see.
    proj = get(run.profile_projects, slot.profile.name, nothing)
    proj === nothing && (proj = Base.active_project())
    proj === nothing || push!(env, "JULIA_PROJECT" => proj)
    append!(env, slot.profile.env)
    return env
end

function init_worker!(run::Run, slot::Slot, w::YATFWorkers.Worker)
    init = slot.profile.init
    isempty(init.args) && return nothing
    timeout = run.plan.cfg.init_timeout_s
    fut = YATFWorkers.remote_eval(w, Expr(:block, init.args...))
    fetch_within(
        fut, timeout,
        TimeoutException(timeout, "the `init` expression of profile `$(slot.profile.name)`")
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
    print_worker_line(
        run, slot.id, "EXIT", string(
            "pid ", w.pid, " · ",
            plural(ran, "item"), " · ", fmt_seconds(alive)
        )
    )
    return nothing
end

"""
    kill_workers!(run)

Kill every worker this run has, immediately.

The orderly teardown gives each process seconds to leave on its own, which across
a pool is most of a minute — a long time to hold a terminal someone has just asked
for back. Nothing is reported for what they were running: the run is being
abandoned, not finished.
"""
function kill_workers!(run::Run)
    live = 0
    for slot in run.slots
        w = slot.worker
        w === nothing && continue
        slot.worker = nothing
        live += 1
        YATFWorkers.kill!(w)
    end
    live == 0 || printline(
        run, string(yatf_prefix(), "interrupted; killed ", plural(live, "worker"))
    )
    return nothing
end

function shutdown!(run::Run)
    for slot in run.slots
        stop_worker!(run, slot)
    end
    return nothing
end

# `what` is the pieces rather than the sentence: one of these is built for every
# dispatch and almost none of them is ever shown.
struct TimeoutException <: Exception
    seconds::Int
    kind::String
    subject::String
end

TimeoutException(seconds::Integer, kind::AbstractString) =
    TimeoutException(Int(seconds), String(kind), "")

Base.showerror(io::IO, e::TimeoutException) = print(
    io, e.kind, isempty(e.subject) ? "" : string(" ", repr(e.subject)),
    " timed out after ", e.seconds, " seconds"
)

# The same words, without "seconds" spelled out, for a one-line report.
timeout_text(e::TimeoutException) = string(
    e.kind, isempty(e.subject) ? "" : string(" ", repr(e.subject)),
    " timed out after ", e.seconds, "s"
)

# An item's own keyword wins over the run default, the same way `timeout` and
# `failfast` do. A chain is retried as a unit, so the most demanding member sets
# the number of attempts.
attempts_for(p::Plan, u::UnitIdx) = 1 + maximum(p.units.span[u]) do i
    p.items.retries[i] == USE_RUN_DEFAULT ? p.cfg.retries : Int(p.items.retries[i])
end

function run_unit!(run::Run, slot::Slot, u::UnitIdx, target)
    p = run.plan
    span = p.units.span[u]
    # An item's own keyword wins over the run default, the same way `timeout` and
    # `failfast` do. A chain is retried as a unit, so the most demanding member
    # sets the number of attempts.
    max_attempts = attempts_for(p, u)
    for attempt in 1:max_attempts
        outcome = run_unit_once!(run, slot, u, target, Int8(attempt), max_attempts)
        outcome === :done && return nothing
        if attempt == max_attempts
            # Out of attempts. A unit cut short by a dead worker leaves items that
            # never ran: for a chain the state they relied on is gone, so they are
            # recorded as broken rather than run on a cold worker or passed over.
            outcome === :broken && mark_remaining_broken!(run, u, Int8(attempt))
            p.cfg.failfast && has_non_pass(run, u) && cancel!(run.queues)
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

# `:done` when everything passed, `:retry` when something did not, `:broken` when
# the worker died part way through the unit.
function run_unit_once!(run::Run, slot::Slot, u::UnitIdx, target, attempt::Int8, max_attempts::Int)
    p = run.plan
    span = p.units.span[u]
    exclusive = p.units.exclusive[u]
    # A sandbox is a process to itself. The slot can arrive here holding a worker
    # that has already run other items — its own queue drained and it stole this
    # unit — and that process is not the one the unit asked for.
    exclusive && slot.worker_items > 0 && stop_worker!(run, slot)
    for i in span
        is_cancelled(run.queues) && (record_cancelled!(run, i); continue)
        w = try
            ensure_worker!(run, slot, target, exclusive)
        catch e
            e isa InterruptException && rethrow()
            record_error!(run, i, slot, attempt, ERRORED, sprint(showerror, e))
            return :broken
        end
        spec = item_spec(run, i, slot, attempt, max_attempts)
        timeout = item_timeout(p, i)
        # Mark it running before dispatching: if this process is killed, the file
        # says which item was in flight, which is the truth and usually the answer.
        write_status!(run.runstate, i, RUNNING, attempt, slot.id; start_off = time() - run.t0)
        slot.current = i
        result = try
            dispatch(run, w, spec, timeout, slot)
        catch e
            slot.current = ItemIdx(0)
            e isa InterruptException && rethrow()
            if handle_dispatch_failure!(run, slot, i, attempt, e, max_attempts) === :broken
                return :broken   # the worker is gone; the rest of this unit cannot be trusted
            end
            continue   # an ordinary error on a live worker; `has_non_pass` decides what happens next
        end
        slot.current = ItemIdx(0)
        slot.worker_items += 1
        record_result!(run, i, slot, attempt, result, max_attempts)
    end
    exclusive && stop_worker!(run, slot)
    slot.units_started += 1
    if has_non_pass(run, u)
        p.cfg.failfast && cancel!(run.queues) === false && print_failfast(run, first(span))
        return :retry
    end
    return :done
end

# The item, then the profile's test-end expression: two requests to the same
# process, each against its own limit. An item's timeout is for the item, and a
# profile whose test-end expression hangs must not be reported as an item that
# hung. Most profiles have no test-end expression and send one request.
function dispatch(run::Run, w::YATFWorkers.Worker, spec::ItemSpec, timeout::Int, slot::Slot)
    fut = YATFWorkers.remote_run(w, spec)
    res = fetch_within(fut, timeout, TimeoutException(timeout, "test item", spec.name))::ItemResult
    test_end = slot.profile.test_end
    (isempty(test_end.args) || res.state === SKIPPED) && return res
    seconds = run.plan.cfg.test_end_timeout_s
    endfut = YATFWorkers.remote_end(w, spec, test_end)
    endres = try
        fetch_within(
            endfut, seconds,
            TimeoutException(seconds, "the `test_end` expression of profile `$(slot.profile.name)`")
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

# A test-end expression that recorded nothing leaves the item's result alone. One
# that failed becomes a testset nested in the item's, which is where a reader
# looking at why the item did not pass will find it. The item's own timings stay
# the item's: what the expression cost is not what the test cost.
function merge_test_end(res::ItemResult, endres::ItemResult)
    isempty(endres.testset.results) && return res
    push!(res.testset.results, endres.testset)
    state = severity(endres.state) > severity(res.state) ? endres.state : res.state
    return ItemResult(res.index, state, res.testset, res.stats)
end

severity(s::ItemState) = s === ERRORED ? 2 : s === FAILED ? 1 : 0

# `fetch(fut)`, or throw `on_timeout` once `seconds` have passed without a reply.
#
# The timer closes the future's own channel, so there is no second channel and no
# task to shuttle between them — this runs once per dispatch, and a channel, a
# task and a timer is a dozen allocations for a wait. A reply that arrives before
# the timer fires is buffered in that channel, and `fetch` returns a buffered
# value whether or not the channel has since been closed, so the race between a
# reply and its deadline resolves to the reply.
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

# `:broken` when the worker is gone, `:failed` when it is still usable.
function handle_dispatch_failure!(
        run::Run, slot::Slot, i::ItemIdx, attempt::Int8, e,
        max_attempts::Int
    )
    w = slot.worker
    item = run.plan.items.name[i]
    if e isa TimeoutException
        if w !== nothing
            print_worker_line(
                run, slot.id, "KILL", string(
                    "pid ", w.pid, " · ", timeout_text(e)
                )
            )
            YATFWorkers.inspect!(w)   # where was it: every thread's and task's backtrace, into the item's log
            # `wait` below joins the task relaying this worker's output, so
            # everything the process says on its way down has been filed by the
            # time the item is reported.
            slot.dying_log = item_log_path(run.logprefix, i, attempt)
            YATFWorkers.terminate!(w, :timeout)
            wait(w)   # a replacement must not overlap the process it replaces
            slot.dying_log = ""
        end
        slot.worker = nothing
        record_error!(
            run, i, slot, attempt, TIMEDOUT,
            string(timeout_text(e), " · ", retry_note(attempt, max_attempts, is_cancelled(run.queues)))
        )
        return :broken
    elseif w !== nothing && !w.terminated
        # The request failed but the process is fine: a result that would not
        # serialize, a `skip` expression that threw. The worker keeps everything
        # it has compiled, and the item is an ordinary error.
        record_error!(run, i, slot, attempt, ERRORED, sprint(showerror, e))
        return :failed
    else
        if w !== nothing
            print_worker_line(
                run, slot.id, "LOST", string(
                    "pid ", w.pid, " · exited while running ",
                    repr(item)
                )
            )
            wait(w)
        end
        slot.worker = nothing
        record_error!(
            run, i, slot, attempt, ERRORED,
            string(
                e isa YATFWorkers.WorkerTerminatedException ?
                    "the worker running this item died" : sprint(showerror, e),
                " · ", retry_note(attempt, max_attempts, is_cancelled(run.queues))
            )
        )
        return :broken
    end
end

function item_spec(run::Run, i::ItemIdx, slot::Slot, attempt::Int8, attempts::Int)
    p = run.plan
    # One string rather than a name and a `joinpath` over it. The directory is
    # this run's own and (item, attempt) is unique within it, so nothing can be
    # there already and there is nothing to clear away first.
    logpath = p.cfg.logs === :eager ? "" : item_log_path(run.logprefix, i, attempt)
    file = p.files[p.items.fileidx[i]]
    return ItemSpec(
        i, ItemIdx(nitems(p)), p.items.name[i], file, p.items.line[i],
        itemlocation(p, i),
        p.items.code[i], p.items.skip[i],
        p.items.failfast[i] == -1 ? p.cfg.item_failfast : p.items.failfast[i] == 1,
        run.project_name, slot.profile.name, attempt, Int8(clamp(attempts, 1, 127)),
        p.cfg.full_stacktraces, logpath, run.name_width
    )
end

item_timeout(p::Plan, i::ItemIdx) =
    p.items.timeout_s[i] == USE_RUN_DEFAULT ? p.cfg.timeout_s : Int(p.items.timeout_s[i])

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

function record_result!(
        run::Run, i::ItemIdx, slot::Slot, attempt::Int8, res::ItemResult,
        max_attempts::Int = 1
    )
    st = run.statuses
    st.synthetic[i] = false
    st.state[i] = res.state
    st.attempt[i] = attempt
    st.slot[i] = slot.id
    st.elapsed[i] = res.stats.elapsed_ns / 1.0e9
    st.compile[i] = res.stats.compile_ns / 1.0e9
    st.testsets[i] = res.testset
    st.start[i] = Float32(time() - run.t0 - st.elapsed[i])
    write_status!(
        run.runstate, i, res.state, attempt, slot.id;
        start_off = st.start[i],
        elapsed = st.elapsed[i], compile = st.compile[i],
        recompile = res.stats.recompile_ns / 1.0e9,
        alloc_mb = res.stats.bytes / 2^20
    )
    n = count_done!(run, i)
    # Only worth saying when there is a policy to state: a plain failure with no
    # retries configured explains itself.
    note = (is_non_pass(res.state) && max_attempts > 1) ?
        retry_note(attempt, max_attempts, is_cancelled(run.queues)) : ""
    report_item!(run, i, res.state, n, note)
    return nothing
end

# `Test.Error` renders its message from the exception stack, not from the value,
# so a synthesized error needs one or it prints an empty "Got exception" and
# nothing else.
exception_stack(msg::AbstractString) =
    Base.ExceptionStack([(exception = ErrorException(msg), backtrace = Ptr{Nothing}[])])

function record_error!(run::Run, i::ItemIdx, slot::Slot, attempt::Int8, state::ItemState, msg::AbstractString)
    p = run.plan
    ts = Test.DefaultTestSet(p.items.name[i])
    # `Test.record` prints an error where it is recorded. The run prints this one
    # itself, in the item's own block, so it must not also appear here on its own.
    with_testset_printing(false) do
        Test.record(
            ts, Test.Error(
                :nontest_error, Expr(:tuple), ErrorException(msg),
                exception_stack(msg),
                LineNumberNode(Int(p.items.line[i]), p.files[p.items.fileidx[i]])
            )
        )
    end
    finish_quietly(ts)
    st = run.statuses
    st.state[i] = state
    st.synthetic[i] = true
    st.attempt[i] = attempt
    st.slot[i] = slot.id
    st.testsets[i] = ts
    st.start[i] = Float32(time() - run.t0)
    write_status!(run.runstate, i, state, attempt, slot.id; start_off = st.start[i])
    n = count_done!(run, i)
    report_item!(run, i, state, n, msg)
    return nothing
end

# A retried item is finished once, however many attempts it took.
function count_done!(run::Run, i::ItemIdx)
    run.statuses.counted[i] && return @atomic run.ndone
    run.statuses.counted[i] = true
    return @atomic run.ndone += 1
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

function record_cancelled!(run::Run, i::ItemIdx)
    run.statuses.state[i] === UNSEEN && (run.statuses.state[i] = CANCELLED)
    return nothing
end

function mark_remaining_broken!(run::Run, u::UnitIdx, attempt::Int8)
    p = run.plan
    for i in p.units.span[u]
        run.statuses.state[i] === UNSEEN || continue
        ts = Test.DefaultTestSet(p.items.name[i])
        with_testset_printing(false) do
            chain_msg = "the worker running this chain died before this item ran; " *
                "the state it depended on is gone, so it was not run"
            Test.record(
                ts, Test.Error(
                    :nontest_error, Expr(:tuple), ErrorException(chain_msg),
                    exception_stack(chain_msg),
                    LineNumberNode(Int(p.items.line[i]), p.files[p.items.fileidx[i]])
                )
            )
        end
        finish_quietly(ts)
        run.statuses.state[i] = BROKEN_CHAIN
        run.statuses.synthetic[i] = true
        run.statuses.attempt[i] = attempt
        run.statuses.testsets[i] = ts
        write_status!(run.runstate, i, BROKEN_CHAIN, attempt, SlotIdx(0))
        report_item!(
            run, i, BROKEN_CHAIN, count_done!(run, i),
            "the worker running this chain died before this item ran"
        )
    end
    return nothing
end

### In-process mode ########################################################

function run_in_process(run::Run, target)
    p = run.plan
    isempty(p.profiles[1].init.args) ||
        @warn "YATF: the profile's `init` expression is evaluated in this process (workers=0)"
    Core.eval(Main, Expr(:block, p.profiles[1].init.args...))
    # The items run here, so their own lines have to go through the printer like
    # everything else this process writes.
    YATFWorkers.LOG_SINK[] = function (line)
        mark, at = mark_index(line)
        printline(run, string(SOLO_PREFIXES[mark], SubString(line, at)))
    end
    try
        run_in_process_items(run, target)
    finally
        YATFWorkers.LOG_SINK[] = nothing
    end
    return nothing
end

function run_in_process_items(run::Run, target)
    p = run.plan
    slot = run.slots[1]
    # Every unit, not just the one slot's queue: a pool that would have had a
    # worker of its own has none here, and its items still have to run.
    for u in UnitIdx(1):UnitIdx(length(p.units))
        is_cancelled(run.queues) && break
        if needs_worker(p, u)
            # A sandbox is a process, so this one gets a process — the same path a
            # pooled run takes, with the worker started and stopped around it.
            slot.pool = p.units.profile[u]
            slot.profile = p.profiles[p.units.profile[u]]
            try
                run_unit!(run, slot, u, target)
            finally
                stop_worker!(run, slot)
            end
        else
            # The same attempt policy as a worker run: an item's own `retries`
            # wins over the run default, and a chain is retried from its first item.
            max_attempts = attempts_for(p, u)
            for attempt in 1:max_attempts
                run_unit_in_process!(run, slot, u, Int8(attempt), max_attempts)
                has_non_pass(run, u) || break
                attempt == max_attempts && break
                reset_unit!(run, u)
            end
        end
        if p.cfg.failfast && has_non_pass(run, u)
            cancel!(run.queues) === false && print_failfast(run, first(p.units.span[u]))
            break
        end
    end
    return nothing
end

# Nothing here can be timed out — there is no second process to kill — so the two
# blocks run back to back and are merged the way a worker's two replies are.
function run_with_test_end(spec::ItemSpec, test_end::Expr)
    res = run_item(spec)
    (isempty(test_end.args) || res.state === SKIPPED) && return res
    return merge_test_end(res, YATFWorkers.run_test_end(spec, test_end))
end

function run_unit_in_process!(run::Run, slot::Slot, u::UnitIdx, attempt::Int8, max_attempts::Int)
    p = run.plan
    for i in p.units.span[u]
        is_cancelled(run.queues) && (record_cancelled!(run, i); continue)
        spec = item_spec(run, i, slot, attempt, max_attempts)
        res = try
            run_with_test_end(spec, p.profiles[1].test_end)
        catch e
            e isa InterruptException && rethrow()
            record_error!(
                run, i, slot, attempt, ERRORED,
                string(sprint(showerror, e), " · ",
                       retry_note(attempt, max_attempts, is_cancelled(run.queues)))
            )
            continue
        end
        record_result!(run, i, slot, attempt, res, max_attempts)
    end
    return nothing
end
