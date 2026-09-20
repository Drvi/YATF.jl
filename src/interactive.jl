# Test items outside a run: `YATF.activate`, and a `@testitem` pasted into a REPL.
#
# A test item is written to run on a worker, in a fresh module, against the
# package's test environment with the setups on LOAD_PATH. None of that is true of
# a REPL by default, and the difference is the reason a pasted item behaves
# differently from the same item under `runtests`. What is here closes the gap:
# the same parser reads the item, the same evaluator runs it, and the same
# environment surrounds it.

"""
    ACTIVATION

What `activate` changed, so that `deactivate` can change it back. `nothing` when
YATF has not touched the session.
"""
const ACTIVATION = Ref{Any}(nothing)   # (; project, setups, target), or nothing

"""
    activate([paths...]) -> String

Make this session look the way a test item's worker does: the package's test
environment active, and `test/testsetups/` on `LOAD_PATH`.

`using MySetup` and the package's test-only dependencies then work at the REPL the
way they do inside a test item. Returns the environment's path.

[`deactivate`](@ref) puts both back.
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
    # The target is kept because it cannot be found again afterwards: with the
    # generated environment active, "the project of this session" resolves to the
    # environment rather than to the package it was built for.
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

# What a run decides for an item that a single interactive evaluation cannot.
# Named here so the warning can say exactly what it ignored rather than "some
# keywords".
const REPL_IGNORED = (
    :timeout => "there is no second process to stop",
    :retries => "a failure you are looking at is not one to paper over",
    :chain => "there is nothing for it to run in sequence with",
)

# `sandbox` puts the item in a process of its own, and the first two of those
# reasons stop being true once there is one: a timeout has something to stop and a
# retry has something to start. `chain` still has nothing to be sequenced with.
repl_ignored(sandboxed::Bool) = sandboxed ? REPL_IGNORED[3:3] : REPL_IGNORED

"""
    run_interactive(ex, source) -> Test.AbstractTestSet

Run one `@testitem` that was evaluated rather than scanned, and return its
testset.

The item is read by the scanner's own parser, so a keyword that would be an error
in a file is an error here, and it is evaluated by the same code a worker uses —
fresh module, soft scope, `Test` and the package in scope. `sandbox` is honoured
by starting a worker, because that is the only way to honour it; the keywords that
only mean something to a scheduler are ignored, once, out loud.
"""
function run_interactive(ex::Expr, source::LineNumberNode)
    path = source.file === nothing ? "REPL" : String(source.file)
    target = interactive_target()
    setups = target === nothing ? Dict{Symbol, String}() : setup_modules(target.testdir)
    errors = ScanError[]
    item = parse_testitem(ex, path, Int32(source.line), errors, setups)
    isempty(errors) || throw(ScanFailure(errors))
    warn_ignored(item, item.exclusive || item.profile !== DEFAULT_PROFILE)
    return with_interactive_env(target) do
        # The item's own lines carry the glyph for how it went; here there is no
        # coordinator relaying them, so the sink does what the relay would.
        previous = YATFWorkers.LOG_SINK[]
        YATFWorkers.LOG_SINK[] = function (line)
            mark, at = mark_index(line)
            print(stdout, SOLO_PREFIXES[mark], SubString(line, at))
            flush(stdout)
        end
        try
            result = item.exclusive || item.profile !== DEFAULT_PROFILE ?
                run_sandboxed(item, target) :
                run_item(interactive_spec(item, target); printing = true)
            return result.testset
        finally
            YATFWorkers.LOG_SINK[] = previous
        end
    end
end

# Where the REPL is: the project the session is in, when it has test items at all.
# A pasted item does not have to come from a package — `nothing` means run it with
# nothing arranged, which is still better than refusing.
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

# The environment of a run, for the length of one item. A session that called
# `activate` is already in it, and `with_test_env` says so and leaves it alone.
function with_interactive_env(f, target)
    target === nothing && return f()
    return with_test_env(target) do
        with_load_path(joinpath(target.testdir, TESTSETUPS_DIR)) do
            f()
        end
    end
end

function interactive_spec(item::RawItem, target)
    project = target === nothing ? "" : something(project_name_of(target.project), "")
    # A pasted item's "file" is whatever the REPL called the expression — `REPL[3]`,
    # `none`, a notebook cell — and making a path relative to the project out of
    # that produces nonsense. Only a real path is shortened.
    where = isabspath(item.file) && target !== nothing ?
        relpath_or_path(item.file, target.root) : item.file
    location = string(where, ":", item.line)
    return ItemSpec(
        Int32(1), Int32(0), item.name, item.file, item.line, location,
        item.code, item.skip, item.failfast == 1, project, item.profile,
        Int8(1), Int8(1), false, "",
        # One item, so the column is exactly as wide as its own name.
        Int32(YATFWorkers.quoted_width(item.name))
    )
end

# `sandbox` asks for a process of its own, and a REPL cannot become one. The item
# gets a worker configured the way the run would have configured it, and the
# worker is gone by the time this returns.
sandbox_worker(prof, target) = YATFWorkers.Worker(;
        julia_args = prof.julia_args, threads = prof.threads,
        extra_env = ["YATF_RUN_ID" => "repl", "YATF_WORKER" => "1",
            "JULIA_LOAD_PATH" => join(LOAD_PATH, Sys.iswindows() ? ";" : ":"),
            "JULIA_PROJECT" => something(Base.active_project(), "")],
        dir = target === nothing ? pwd() : target.root,
        project = Base.active_project(), redirect_io = stdout
    )

function run_sandboxed(item::RawItem, target)
    prof = interactive_profile(item, target)
    # There is a second process now, so `timeout` and `retries` mean here what they
    # mean in a run.
    timeout = item.timeout_s == USE_RUN_DEFAULT ? nothing : Int(item.timeout_s)
    attempts = item.retries == USE_RUN_DEFAULT ? 1 : Int(item.retries) + 1
    local result::ItemResult
    for attempt in 1:attempts
        w = sandbox_worker(prof, target)
        try
            isempty(prof.init.args) ||
                fetch(YATFWorkers.remote_eval(w, Expr(:block, prof.init.args...)))
            spec = interactive_spec(item, target)
            fut = YATFWorkers.remote_run(w, spec)
            result = (
                timeout === nothing ? fetch(fut) :
                fetch_within(fut, timeout, TimeoutException(timeout, "test item", item.name))
            )::ItemResult
            isempty(prof.test_end.args) ||
                fetch(YATFWorkers.remote_end(w, spec, prof.test_end))
            # A retry is for a result nobody wants to keep; the last attempt is
            # kept whatever it says.
            (result.state === YATFWorkers.PASSED || attempt == attempts) && break
        catch e
            e isa TimeoutException || rethrow()
            # The process it was told to stop is stopped; out of attempts, the
            # timeout is the answer.
            YATFWorkers.terminate!(w, :timeout)
            attempt == attempts && rethrow()
        finally
            close(w)
        end
    end
    # Printed here: the worker was told not to, because in a run the coordinator
    # does the printing, and here that is this process.
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
        println(stdout, yatf_prefix(), YATFWorkers.short_state(result.state))
    end
    return nothing
end
