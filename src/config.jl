# Run configuration: `runtests` keywords over `test/TestItems.toml` over defaults.
#
# Nothing here is evaluated: `init` and `test_end` are only parsed, so a syntax
# error surfaces before any worker starts.

using TOML: TOML

"""
    Profile

Everything that makes two worker processes non-interchangeable. Items with the
same profile can share a worker; items with different profiles cannot.
"""
struct Profile
    name::Symbol
    julia_args::Vector{String}
    threads::String
    env::Vector{Pair{String, String}}
    init::Expr
    test_end::Expr
    # An absolute path to a preferences file, or empty. Preferences reach a package
    # from the environment that owns it, so this becomes the worker's own project
    # rather than anything layered on the test environment.
    preferences::String
end

Profile(
    name::Symbol; julia_args = String[], threads = "2,1", env = Pair{String, String}[],
    init = Expr(:block), test_end = Expr(:block), preferences = ""
) =
    Profile(name, julia_args, threads, env, init, test_end, preferences)

Base.@kwdef struct RunConfig
    workers::Int
    threads::String = "2,1"
    timeout_s::Int = 30 * 60
    # The suite's code, not the item's, so limits of their own.
    init_timeout_s::Int = 30 * 60
    test_end_timeout_s::Int = 30 * 60
    retries::Int = 0
    failfast::Bool = false
    item_failfast::Bool = false
    logs::Symbol = :issues
    verbose::Bool = false
    memory_threshold::Float64 = 0.9
    full_stacktraces::Bool = false
    # Every name printed whole in the name column, rather than one too long for it
    # shortened to a prefix no other item has.
    full_names::Bool = false
    # What the run's testset is called in the summary; runs of several calls under
    # one `@testset` are told apart by it.
    testset_name::String = "YATF"
    # Workers count which lines of the package's `src/` and `ext/` run, and the run
    # merges what they counted into `lcov.info` at the package's root.
    coverage::Bool = false
    # What set `coverage`, for the run to say, or empty for the default.
    coverage_source::String = ""
    monitor::Bool = true
    monitor_interval::Int = 30
    profiles::Dict{Symbol, Profile} = Dict(DEFAULT_PROFILE => Profile(DEFAULT_PROFILE))
    order_first::Vector{String} = String[]
    order_last::Vector{String} = String[]
    # Every item's random numbers start from this and its name, so a run with the
    # same seed draws the same numbers in each item, whatever ran before it.
    seed::UInt64 = 0
    # The manifest a replayed run state was recorded against, or empty: the run
    # says how its own environment differs.
    replayed_manifest::String = ""
    # The run state a replay runs, or empty for a run that is not one.
    replayed_from::String = ""
end

const RUN_KEYS = (
    :workers, :threads, :timeout, :init_timeout, :test_end_timeout, :retries,
    :failfast, :item_failfast, :logs, :verbose, :memory_threshold,
    :monitor, :monitor_interval, :full_stacktraces, :full_names, :testset_name, :coverage, :seed,
)
const ORDER_KEYS = (:first, :last)
const PROFILE_KEYS = (:julia_args, :threads, :env, :init, :test_end, :preferences)
const TOP_KEYS = (:run, :order, :profiles)
const LOG_MODES = (:eager, :batched, :issues)

"""
    read_config(testdir; kwargs...) -> RunConfig

Merge `test/TestItems.toml` with explicit keyword arguments. An unknown key is an
error, not a no-op: a misspelled option would otherwise be ignored in silence.
"""
function read_config(testdir::AbstractString; kwargs...)
    path = joinpath(testdir, "TestItems.toml")
    toml = Dict{String, Any}()
    if isfile(path)
        toml = try
            TOML.parsefile(path)
        catch e
            throw(ConfigError("could not parse $(relpath_or_path(path)): $(sprint(showerror, e))"))
        end
        check_keys(path, toml, TOP_KEYS, "")
    end
    return build_config(path, toml; kwargs...)
end

function check_keys(path, tbl::AbstractDict, allowed::Tuple, where_)
    for k in sort!(collect(keys(tbl)))
        Symbol(k) in allowed && continue
        loc = isempty(where_) ? "" : " in [$where_]"
        throw(
            ConfigError(
                "unknown key `$k`$loc of $(relpath_or_path(path)); " *
                    "allowed here: $(join(allowed, ", "))"
            )
        )
    end
    return
end

# A table of the configuration, holding only the keys it may hold. `label` is how
# a message names it.
function section(path, parent::AbstractDict, key::AbstractString, allowed::Tuple, label = key)
    t = get(parent, key, Dict{String, Any}())
    t isa AbstractDict || throw(ConfigError("[$label] of $(relpath_or_path(path)) must be a table"))
    check_keys(path, t, allowed, label)
    return t
end

# `true` or `false` from an environment variable, or `nothing` when it is unset or empty.
function env_flag(name::AbstractString)
    v = lowercase(strip(get(ENV, name, "")))
    isempty(v) && return nothing
    v in ("1", "true", "yes") && return true
    v in ("0", "false", "no") && return false
    throw(ConfigError("`$name` must be true or false (or 1, 0, yes, no), got $(repr(ENV[name]))"))
end

function build_config(path, toml; nunits = 0, kwargs...)
    for k in keys(kwargs)
        k in RUN_KEYS || throw(ConfigError("unknown keyword `$k`; the run settings are $(join(RUN_KEYS, ", "))"))
    end
    run = section(path, toml, "run", RUN_KEYS)
    # A keyword wins over the file, and the file over the default.
    pick(key, default) = something(get(kwargs, key, nothing), get(run, string(key), default))
    seconds(key, x) = (x isa Real && 0 < x <= MAX_TIMEOUT_S) ? Int(ceil(x)) :
        throw(ConfigError("`$key` must be a positive number of seconds, at most $MAX_TIMEOUT_S, got $(repr(x))"))
    # 0 prints at every sample, five times a second: a test's way to make the
    # monitor print as often as it can.
    interval(x) = (x isa Real && 0 <= x <= MAX_TIMEOUT_S) ? Int(ceil(x)) :
        throw(ConfigError("`monitor_interval` must be a number of seconds from 0 to $MAX_TIMEOUT_S, got $(repr(x))"))
    flag(key, default) = (v = pick(key, default); v isa Bool ? v :
        throw(ConfigError("`$key` must be true or false, got $(repr(v))")))

    threads = threads_spec("threads", pick(:threads, "2,1"))
    w = pick(:workers, "auto")
    # A worker is a slot, and slots are numbered in a `SlotIdx`.
    ((w isa Integer && 0 <= w <= typemax(SlotIdx)) || w == "auto") || throw(ConfigError(
        "`workers` must be \"auto\" or an integer from 0 to $(typemax(SlotIdx)), got $(repr(w))"
    ))
    workers = w isa Integer ? Int(w) : auto_workers(threads, nunits)
    logs = Symbol(pick(:logs, default_logs(workers)))
    logs in LOG_MODES || throw(ConfigError("`logs` must be one of $(LOG_MODES), got $(repr(logs))"))
    timeout = seconds(:timeout, pick(:timeout, 30 * 60))
    retries = pick(:retries, 0)
    (retries isa Integer && 0 <= retries <= MAX_RETRIES) ||
        throw(ConfigError("`retries` must be an integer from 0 to $MAX_RETRIES, got $(repr(retries))"))
    mt = pick(:memory_threshold, 0.9)
    (mt isa Real && 0 < mt <= 1) || throw(ConfigError("`memory_threshold` must be in (0, 1], got $(repr(mt))"))
    failfast = flag(:failfast, false)
    seed = pick(:seed, 0)
    (seed isa Integer && 0 <= seed <= typemax(UInt64)) ||
        throw(ConfigError("`seed` must be an integer from 0 to $(typemax(UInt64)), got $(repr(seed))"))
    order = section(path, toml, "order", ORDER_KEYS)
    # A keyword, then the environment, then the file: CI switches coverage on for a
    # job without editing the project. The environment is read only when the keyword
    # does not decide, so a bad value there fails only a run it would have set.
    coverage, coverage_source = if get(kwargs, :coverage, nothing) !== nothing
        (kwargs[:coverage], "the `coverage` keyword")
    else
        env_coverage = env_flag("YATF_COVERAGE")
        env_coverage !== nothing ? (env_coverage, "`YATF_COVERAGE`") :
            haskey(run, "coverage") ? (run["coverage"], relpath_or_path(path)) : (false, "")
    end
    coverage isa Bool || throw(ConfigError("`coverage` must be true or false, got $(repr(coverage))"))
    coverage && workers == 0 && throw(ConfigError(
        "`coverage` is counted by worker processes, and `workers = 0` runs the items in this one, " *
            "whose coverage was fixed when it started; use one worker or more"
    ))
    testset_name = pick(:testset_name, "YATF")
    (testset_name isa AbstractString && !isempty(testset_name)) ||
        throw(ConfigError("`testset_name` must be a non-empty string, got $(repr(testset_name))"))

    return RunConfig(;
        workers, threads, timeout_s = timeout,
        init_timeout_s = seconds(:init_timeout, pick(:init_timeout, timeout)),
        test_end_timeout_s = seconds(:test_end_timeout, pick(:test_end_timeout, timeout)),
        retries = Int(retries), failfast, item_failfast = flag(:item_failfast, failfast), logs,
        verbose = flag(:verbose, false),
        memory_threshold = Float64(mt), monitor = flag(:monitor, true),
        full_stacktraces = flag(:full_stacktraces, false),
        full_names = flag(:full_names, false),
        testset_name = String(testset_name), coverage, coverage_source,
        monitor_interval = interval(pick(:monitor_interval, 30)),
        profiles = read_profiles(path, toml, threads),
        order_first = String[string(x) for x in get(order, "first", String[])],
        order_last = String[string(x) for x in get(order, "last", String[])],
        seed = seed == 0 ? rand(RandomDevice(), UInt64) : UInt64(seed)
    )
end

# What `--threads` takes: default threads, `auto` or at least one, then optionally
# interactive ones, `auto` or any number. Checked here, or the first worker dies of it.
function threads_spec(what, x)
    s = x isa Integer ? string(x) : x
    (s isa AbstractString && occursin(r"^(auto|[1-9][0-9]*)(,(auto|[0-9]+))?$", s)) || throw(ConfigError(
        "`$what` must be what `--threads` takes (\"4\", \"4,1\", \"auto\"), got $(repr(x))"
    ))
    return String(s)
end

# One interactive worker streams its logs; several would interleave unreadably, so
# only items with problems print, as in a non-interactive run. `interactive` is a
# parameter so that a test suite, which is never interactive, can check both.
default_logs(workers::Integer, interactive::Bool = isinteractive()) =
    interactive && workers <= 1 ? :eager : :issues

function read_profiles(path, toml, default_threads::String)
    profiles = Dict{Symbol, Profile}()
    tbl = get(toml, "profiles", Dict{String, Any}())
    tbl isa AbstractDict || throw(ConfigError("[profiles] of $(relpath_or_path(path)) must be a table"))
    # Numbered in a `ProfileIdx`, `default` among them.
    length(tbl) < typemax(ProfileIdx) ||
        throw(ConfigError("$(relpath_or_path(path)) declares $(length(tbl)) profiles; at most $(typemax(ProfileIdx) - 1) fit"))
    for name in keys(tbl)
        p = section(path, tbl, name, PROFILE_KEYS, "profiles.$name")
        args = String[string(a) for a in get(p, "julia_args", String[])]
        env = Pair{String, String}[string(k) => string(v) for (k, v) in get(p, "env", Dict{String, Any}())]
        sort!(env; by = first)
        profiles[Symbol(name)] = Profile(
            Symbol(name), args,
            threads_spec("threads of [profiles.$name]", get(p, "threads", default_threads)), env,
            parse_expr(path, name, "init", get(p, "init", "")),
            parse_expr(path, name, "test_end", get(p, "test_end", "")),
            profile_preferences(path, name, get(p, "preferences", ""))
        )
    end
    haskey(profiles, DEFAULT_PROFILE) ||
        (profiles[DEFAULT_PROFILE] = Profile(DEFAULT_PROFILE; threads = default_threads))
    return profiles
end

"""
    profile_preferences(config_path, name, value) -> String

The absolute path to a profile's preferences file, or `""` when it declares none.
Parsed here, so a missing or malformed file fails before any worker starts.
"""
function profile_preferences(config_path, name, value)
    bad(what) = ConfigError("`preferences` of [profiles.$name]" * what)
    value isa AbstractString || throw(bad(" must be a path to a TOML file"))
    isempty(value) && return ""
    path = isabspath(value) ? value : normpath(joinpath(dirname(config_path), value))
    isfile(path) || throw(bad(" points at $(relpath_or_path(path)), which does not exist"))
    try
        TOML.parsefile(path)
    catch e
        throw(bad(": could not parse $(relpath_or_path(path)): $(sprint(showerror, e))"))
    end
    return path
end

function parse_expr(path, profile, key, str::AbstractString)
    isempty(strip(str)) && return Expr(:block)
    bad(what) = ConfigError("could not parse `$key` of [profiles.$profile] in $(relpath_or_path(path)): $what")
    ex = try
        Meta.parseall(str; filename = "$(relpath_or_path(path)):[profiles.$profile].$key")
    catch e
        throw(bad(sprint(showerror, e)))
    end
    # `parseall` reports a bad parse as an `:error`/`:incomplete` node rather than
    # by throwing, so an unchecked result would defer the failure to the worker.
    for a in ex.args
        a isa Expr && a.head in (:error, :incomplete) && throw(bad(a.args[1]))
    end
    return Expr(:block, ex.args...)
end

# A guess, not a measurement: too many workers is an OOM kill, and each extra one
# compiles the same code again.
const ASSUMED_WORKER_RSS = 4 * 2^30

function auto_workers(threads::String, nunits::Int)
    per_worker = something(tryparse(Int, first(split(threads, ','))), 2)
    # The CPUs this process may use: fewer than the machine's under a container
    # quota, and oversubscribing them turns timeouts flaky. 1.12 has only the
    # machine's count.
    cpus = @static isdefined(Sys, :EFFECTIVE_CPU_THREADS) ? Sys.EFFECTIVE_CPU_THREADS : Sys.CPU_THREADS
    by_cpu = max(1, cpus ÷ max(1, per_worker))
    by_mem = max(1, Int(Sys.total_memory() ÷ ASSUMED_WORKER_RSS))
    n = clamp(min(by_cpu, by_mem), 1, 8)
    return nunits > 0 ? min(n, nunits) : n
end
