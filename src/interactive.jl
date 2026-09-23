# Test items outside a run: `YATF.activate`, and a `@testitem` pasted into a REPL.
#
# A pasted item is read by the scanner's parser, run by the worker's evaluator and
# surrounded by the run's environment, so it behaves as it does under `runtests`.

# What `activate` changed, for `deactivate` to undo: `(; project, setups, target)`,
# or `nothing` when YATF has not touched the session.
const ACTIVATION = Ref{Any}(nothing)

"""
    activate([paths...]) -> String

Make this session look the way a test item's worker does: the package's test
environment active and `test/testsetups/` on `LOAD_PATH`, so `using MySetup` and
test-only dependencies work at the REPL. Returns the environment's path;
[`deactivate`](@ref) undoes it.
"""
function activate(args...)
    ACTIVATION[] === nothing || throw(
        ConfigError(
            "YATF is already active in this session (" *
                something(Base.active_project(), "no project") *
                "); call `YATF.deactivate()` first"
        )
    )
    target = resolve_target(args)
    PROJECT_ROOT[] = target.root
    previous = Base.active_project()
    env = test_env_for(target)
    env === nothing || Base.set_active_project(env)
    setups = joinpath(target.testdir, TESTSETUPS_DIR)
    pushed = isdir(setups) && !(setups in LOAD_PATH)
    pushed && push!(LOAD_PATH, setups)
    # Kept because it cannot be found again: with the generated environment active,
    # the session's project is the environment, not the package.
    ACTIVATION[] = (project = previous, setups = pushed ? setups : nothing, target = target)
    active = something(Base.active_project(), "")
    println(
        stdout, yatf_prefix(), "activated ", relpath_or_path(active, target.root),
        pushed ? string(" · setups from ", relpath_or_path(setups, target.root)) : ""
    )
    return active
end

"""
    deactivate()

Undo [`activate`](@ref): restore the environment that was active and take the
setups back off `LOAD_PATH`. Does nothing if YATF is not active.
"""
function deactivate()
    state = ACTIVATION[]
    state === nothing && return nothing
    ACTIVATION[] = nothing
    if state.setups !== nothing
        i = findlast(==(state.setups), LOAD_PATH)
        i === nothing || deleteat!(LOAD_PATH, i)
    end
    Base.set_active_project(state.project)
    println(stdout, yatf_prefix(), "deactivated")
    return nothing
end

"""
    is_activated() -> Bool

Whether [`activate`](@ref) is in force.
"""
is_activated() = ACTIVATION[] !== nothing

### A pasted test item ######################################################

# Keywords only a run can honour, with the reason the warning gives for each.
const REPL_IGNORED = (
    :timeout => "there is no second process to stop",
    :retries => "a failure you are looking at is not one to paper over",
    :chain => "there is nothing for it to run in sequence with",
)

# A sandboxed item has a process of its own, so a timeout has something to stop and
# a retry something to start; `chain` still has nothing to run in sequence with.
repl_ignored(sandboxed::Bool) = sandboxed ? REPL_IGNORED[3:3] : REPL_IGNORED

"""
    run_interactive(ex, source) -> Test.AbstractTestSet

Run one `@testitem` that was evaluated rather than scanned, and return its
testset. It is read by the scanner's parser and evaluated by the worker's code;
`sandbox` and profiles start a worker, and the keywords only a scheduler can
honour are ignored with a warning.
"""
function run_interactive(ex::Expr, source::LineNumberNode)
    path = source.file === nothing ? "REPL" : String(source.file)
    target = interactive_target()
    setups = target === nothing ? Dict{Symbol, String}() : setup_modules(target.testdir)
    errors = ScanError[]
    item = parse_testitem(ex, path, Int32(source.line), errors, setups)
    isempty(errors) || throw(ScanFailure(errors))
    sandboxed = item.exclusive || item.profile !== DEFAULT_PROFILE
    warn_ignored(item, sandboxed)
    return with_interactive_env(target) do
        sandboxed && return run_sandboxed(item, target).testset
        say(item, target, 1, nothing)
        result = run_item(interactive_spec(item, target); printing = true)
        say(item, target, 1, outcome(result))
        return result.testset
    end
end

# The session's project, or `nothing`: a pasted item need not come from a package,
# and then it runs with nothing arranged.
function interactive_target()
    state = ACTIVATION[]
    state === nothing || return state.target
    return try
        resolve_target(())
    catch
        nothing
    end
end

function warn_ignored(item::RawItem, sandboxed::Bool)
    given = String[]
    for (key, why) in repl_ignored(sandboxed)
        set = key === :timeout ? item.timeout_s != USE_RUN_DEFAULT :
            key === :retries ? item.retries != USE_RUN_DEFAULT :
            item.chain !== NO_CHAIN
        set && push!(given, string("`", key, "` (", why, ")"))
    end
    isempty(given) && return nothing
    @warn "YATF: running `$(item.name)` here, so these are ignored: " * join(given, ", ") maxlog = 1
    return nothing
end

# The run's environment for the length of one item. After `activate` the session is
# already in it, and `with_test_env` leaves it alone.
function with_interactive_env(f, target)
    target === nothing && return f()
    return with_test_env(target) do
        with_load_path(joinpath(target.testdir, TESTSETUPS_DIR)) do
            f()
        end
    end
end

# An item's RUN or DONE line: one item, so no count, and a name column its own width.
say(item::RawItem, target, attempt, how) = (println(stdout, item_line(
    nothing, 1, 0, item.name, quoted_width(item.name), attempt, 1, something(how, item_location(item, target))
)); flush(stdout))

# A pasted item's file may be `REPL[3]`, `none` or a notebook cell; only a real path
# is made relative.
item_location(item::RawItem, target) = string(
    isabspath(item.file) && target !== nothing ? relpath_or_path(item.file, target.root) : item.file, ":", item.line
)

function interactive_spec(item::RawItem, target, seed::UInt64 = rand(RandomDevice(), UInt64))
    project = target === nothing ? "" : something(project_name_of(target.project), "")
    return ItemSpec(
        Int32(1), item.name, item.file, item.line, item.code, item.skip, item.failfast == 1,
        project, item.profile, Int8(1), false, "", seed
    )
end

# A worker configured as a run would configure it.
sandbox_worker(prof, target, redirect_fn) = YATFWorkers.Worker(;
        julia_args = prof.julia_args, threads = prof.threads,
        extra_env = worker_env("repl", 1, Base.active_project(), prof),
        dir = target === nothing ? pwd() : target.root,
        project = Base.active_project(), redirect_io = stdout, redirect_fn
    )

function run_sandboxed(item::RawItem, target)
    prof = interactive_profile(item, target)
    timeout = item.timeout_s == USE_RUN_DEFAULT ? nothing : Int(item.timeout_s)
    attempts = item.retries == USE_RUN_DEFAULT ? 1 : Int(item.retries) + 1
    local result::ItemResult
    relay(io, pid, line) = let rec = parse_record(line)
        rec === nothing ? println(io, "      worker ", pid, " | ", line) : say(item, target, rec.attempt, rec.how)
    end
    for attempt in 1:attempts
        w = sandbox_worker(prof, target, relay)
        try
            isempty(prof.init.args) ||
                fetch(YATFWorkers.remote_eval(w, Expr(:block, prof.init.args...)))
            spec = interactive_spec(item, target)
            fut = YATFWorkers.remote_run(w, spec)
            result = (
                timeout === nothing ? fetch(fut) :
                fetch_within(fut, timeout, TimeoutException(timeout, "test item", item.name, "its own timeout=$timeout"))
            )::ItemResult
            isempty(prof.test_end.args) ||
                fetch(YATFWorkers.remote_end(w, spec, prof.test_end))
            (result.state === YATFWorkers.PASSED || attempt == attempts) && break
        catch e
            e isa TimeoutException || rethrow()
            YATFWorkers.terminate!(w, :timeout)
            attempt == attempts && rethrow()
        finally
            close(w)
        end
    end
    # In a run the coordinator prints results; here this process is the coordinator.
    print_interactive_result(result)
    return result
end

function interactive_profile(item::RawItem, target)
    item.profile === DEFAULT_PROFILE && return Profile(DEFAULT_PROFILE)
    target === nothing &&
        throw(ConfigError("`sandbox=:$(item.profile)` needs a TestItems.toml, and there is no project here"))
    cfg = read_config(target.testdir)
    haskey(cfg.profiles, item.profile) || throw(
        ConfigError(
            "`sandbox=:$(item.profile)` has no [profiles.$(item.profile)] in " *
                relpath_or_path(joinpath(target.testdir, "TestItems.toml"), target.root)
        )
    )
    return cfg.profiles[item.profile]
end

function print_interactive_result(result::ItemResult)
    for r in collect_failures(result.testset)
        show(stdout, r)
        println(stdout)
    end
    try
        Test.print_test_results(result.testset)
    catch
        # A `Test` that prints its summary some other way is not worth failing over.
        println(stdout, yatf_prefix(), short_state(result.state))
    end
    return nothing
end
