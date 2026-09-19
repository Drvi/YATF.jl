# Run configuration: `runtests` keywords over `test/TestItems.toml` over defaults.
#
# The TOML is declarative on purpose. Everything the planner and the dry run need
# is readable without evaluating anything, and `init`/`test_end` are parsed here
# so a syntax error surfaces before any worker starts, not after.

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
end

Profile(
    name::Symbol; julia_args = String[], threads = "2,1", env = Pair{String, String}[],
    init = Expr(:block), test_end = Expr(:block)
) =
    Profile(name, julia_args, threads, env, init, test_end)

Base.@kwdef struct RunConfig
    workers::Int
    threads::String = "2,1"
    timeout_s::Int = 30 * 60
    # A profile's `init` and `test_end` expressions are the suite's own code, not
    # the item's, so they are timed against limits of their own: an item's budget
    # is for the item.
    init_timeout_s::Int = 30 * 60
    test_end_timeout_s::Int = 30 * 60
    retries::Int = 0
    failfast::Bool = false
    item_failfast::Bool = false
    logs::Symbol = :issues
    report::Bool = false
    verbose::Bool = false
    memory_threshold::Float64 = 0.9
    full_stacktraces::Bool = false
    monitor::Bool = true
    monitor_interval::Int = 30
    profiles::Dict{Symbol, Profile} = Dict(DEFAULT_PROFILE => Profile(DEFAULT_PROFILE))
    order_first::Vector{String} = String[]
    order_last::Vector{String} = String[]
end

const RUN_KEYS = (
    :workers, :threads, :timeout, :init_timeout, :test_end_timeout, :retries,
    :failfast, :item_failfast, :logs, :report, :verbose, :memory_threshold,
    :monitor, :monitor_interval, :full_stacktraces,
)
const ORDER_KEYS = (:first, :last)
const PROFILE_KEYS = (:julia_args, :threads, :env, :init, :test_end)
const TOP_KEYS = (:run, :order, :profiles)
const LOG_MODES = (:eager, :batched, :issues)

"""
    read_config(testdir; kwargs...) -> RunConfig

Merge `test/TestItems.toml` with explicit keyword arguments. An unknown key is an
error rather than a no-op: silently ignoring a misspelled option is how a suite
ends up not running the way its author believes it does.
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

function build_config(
        path, toml;
        workers = nothing,
        threads = nothing,
        timeout = nothing,
        init_timeout = nothing,
        test_end_timeout = nothing,
        retries = nothing,
        failfast = nothing,
        item_failfast = nothing,
        logs = nothing,
        report = nothing,
        verbose = nothing,
        memory_threshold = nothing,
        full_stacktraces = nothing,
        monitor = nothing,
        monitor_interval = nothing,
        nunits = 0,
    )
    run = get(toml, "run", Dict{String, Any}())
    run isa AbstractDict || throw(ConfigError("[run] of $(relpath_or_path(path)) must be a table"))
    check_keys(path, run, RUN_KEYS, "run")

    pick(kw, key, default) = kw !== nothing ? kw : get(run, string(key), default)

    threads′ = string(pick(threads, :threads, "2,1"))
    w = pick(workers, :workers, "auto")
    workers′ = w isa AbstractString ?
        (
            w == "auto" ? auto_workers(threads′, nunits) :
            throw(ConfigError("`workers` must be an integer or \"auto\", got $(repr(w))"))
        ) :
        Int(w)
    workers′ >= 0 || throw(ConfigError("`workers` must be >= 0, got $workers′"))

    logs′ = Symbol(pick(logs, :logs, default_logs(workers′)))
    logs′ in LOG_MODES || throw(ConfigError("`logs` must be one of $(LOG_MODES), got $(repr(logs′))"))
    timeout′ = Int(ceil(pick(timeout, :timeout, 30 * 60)))
    timeout′ > 0 || throw(ConfigError("`timeout` must be positive, got $timeout′"))
    init_timeout′ = Int(ceil(pick(init_timeout, :init_timeout, timeout′)))
    init_timeout′ > 0 || throw(ConfigError("`init_timeout` must be positive, got $init_timeout′"))
    end_timeout′ = Int(ceil(pick(test_end_timeout, :test_end_timeout, timeout′)))
    end_timeout′ > 0 || throw(ConfigError("`test_end_timeout` must be positive, got $end_timeout′"))
    retries′ = Int(pick(retries, :retries, 0))
    retries′ >= 0 || throw(ConfigError("`retries` must be >= 0, got $retries′"))
    mt = Float64(pick(memory_threshold, :memory_threshold, 0.9))
    0 < mt <= 1 || throw(ConfigError("`memory_threshold` must be in (0, 1], got $mt"))
    ff = Bool(pick(failfast, :failfast, false))

    order = get(toml, "order", Dict{String, Any}())
    order isa AbstractDict || throw(ConfigError("[order] of $(relpath_or_path(path)) must be a table"))
    check_keys(path, order, ORDER_KEYS, "order")
    first_ = String[string(x) for x in get(order, "first", String[])]
    last_ = String[string(x) for x in get(order, "last", String[])]

    profiles = read_profiles(path, toml, threads′)

    return RunConfig(;
        workers = workers′, threads = threads′, timeout_s = timeout′,
        init_timeout_s = init_timeout′, test_end_timeout_s = end_timeout′, retries = retries′,
        failfast = ff, item_failfast = Bool(pick(item_failfast, :item_failfast, ff)),
        logs = logs′, report = Bool(pick(report, :report, false)),
        verbose = Bool(pick(verbose, :verbose, false)),
        memory_threshold = mt, monitor = Bool(pick(monitor, :monitor, true)),
        full_stacktraces = Bool(pick(full_stacktraces, :full_stacktraces, false)),
        monitor_interval = Int(pick(monitor_interval, :monitor_interval, 30)),
        profiles, order_first = first_, order_last = last_
    )
end

# Interactively with one worker there is nothing to interleave, so logs go
# straight out; with several they are batched per item to stay readable. A
# non-interactive run prints them only for items that had something to say.
default_logs(workers::Integer) =
    isinteractive() ? (workers <= 1 ? :eager : :batched) : :issues

function read_profiles(path, toml, default_threads::String)
    profiles = Dict{Symbol, Profile}()
    tbl = get(toml, "profiles", Dict{String, Any}())
    tbl isa AbstractDict || throw(ConfigError("[profiles] of $(relpath_or_path(path)) must be a table"))
    for (name, p) in tbl
        p isa AbstractDict || throw(ConfigError("[profiles.$name] of $(relpath_or_path(path)) must be a table"))
        check_keys(path, p, PROFILE_KEYS, "profiles.$name")
        args = String[string(a) for a in get(p, "julia_args", String[])]
        env = Pair{String, String}[string(k) => string(v) for (k, v) in get(p, "env", Dict{String, Any}())]
        sort!(env; by = first)
        profiles[Symbol(name)] = Profile(
            Symbol(name), args,
            string(get(p, "threads", default_threads)), env,
            parse_expr(path, name, "init", get(p, "init", "")),
            parse_expr(path, name, "test_end", get(p, "test_end", ""))
        )
    end
    haskey(profiles, DEFAULT_PROFILE) ||
        (profiles[DEFAULT_PROFILE] = Profile(DEFAULT_PROFILE; threads = default_threads))
    return profiles
end

# Parsed here, never evaluated here: a syntax error in an init expression is a
# configuration error, and it must surface before any process is started.
function parse_expr(path, profile, key, str::AbstractString)
    isempty(strip(str)) && return Expr(:block)
    ex = try
        Meta.parseall(str; filename = "$(relpath_or_path(path)):[profiles.$profile].$key")
    catch e
        throw(
            ConfigError(
                "could not parse `$key` of [profiles.$profile] in " *
                    "$(relpath_or_path(path)): $(sprint(showerror, e))"
            )
        )
    end
    # `parseall` reports a bad parse as an `:error`/`:incomplete` node rather than
    # by throwing, so an unchecked result would defer the failure to the worker.
    for a in ex.args
        if a isa Expr && (a.head === :error || a.head === :incomplete)
            throw(
                ConfigError(
                    "could not parse `$key` of [profiles.$profile] in " *
                        "$(relpath_or_path(path)): $(a.args[1])"
                )
            )
        end
    end
    return Expr(:block, ex.args...)
end

# Deliberately conservative: too few workers is slow, too many is an OOM kill, and
# on a compilation-heavy suite every extra worker recompiles the same code again.
# The 4 GiB figure is a guess until a run state supplies a measured peak RSS.
const ASSUMED_WORKER_RSS = 4 * 2^30

function auto_workers(threads::String, nunits::Int)
    per_worker = something(tryparse(Int, first(split(threads, ','))), 2)
    by_cpu = max(1, Sys.CPU_THREADS ÷ max(1, per_worker))
    by_mem = max(1, Int(Sys.total_memory() ÷ ASSUMED_WORKER_RSS))
    n = clamp(min(by_cpu, by_mem), 1, 8)
    return nunits > 0 ? min(n, nunits) : n
end
