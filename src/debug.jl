# Stepping into one test item under Debugger.jl, in this process.

"""
    debug([name]; seed) -> Test.AbstractTestSet

Step into one test item with Debugger.jl: `using Debugger` first. Without `name` it
is the last recorded run's most recent failure, the item among those that failed,
errored or timed out that finished last, with that run's seed, so it draws the
random numbers it failed with. When no run of the project is recorded, or the last
one had no failures, there is nothing to step into, and it says so.

The item runs here, in this process, as a run would run it: its module and imports,
the test environment and the setups, and its profile's `env`, `init` and
`test_end`. Its body is a function the debugger enters at the body's first call.
What cannot be part of a function, `using` and `struct` among it, has run by then.
Only this item runs: the items before it in a chain do not.

What this process cannot give the item is listed before it starts: a profile's
`julia_args`, `threads` and `preferences`, a process of its own, and the keywords
only a scheduler honours. `seed` is a run's, as `runtests` takes and prints it, so
the item draws the random numbers it drew in that run.

Returns the item's testset. Leaving the debugger before the item has finished
records an error, since the rest of it did not run.
"""
function debug(name::Union{Nothing, AbstractString} = nothing; seed::Union{Nothing, Integer} = nothing)
    return debug_item(debugger_entry(), name === nothing ? nothing : String(name), seed)
end

# The extension's entry point. Debugger.jl is a weak dependency, loaded by a session
# that wants to step through an item and by nothing else.
function debugger_entry()
    ext = Base.get_extension(Base.moduleroot(@__MODULE__), :YATFDebuggerExt)
    ext === nothing && throw(
        ConfigError(
            "YATF.debug steps through the item with Debugger.jl, which is not loaded: " *
                "`using Debugger` first, after `] add Debugger` if it is not installed"
        )
    )
    return ext.enter
end

# `enter(body)` calls the item's body, a function of no arguments, under a debugger.
# Without a name, the item is the last run's most recent failure.
function debug_item(enter, name::Union{Nothing, String}, seed::Union{Nothing, Integer})
    target = interactive_target()
    target === nothing &&
        throw(ConfigError("YATF.debug looks for test items in a package, and there is no package here"))
    failure = name === nothing ? last_failure(target) : nothing
    item = find_item(target, failure === nothing ? name : failure.name)
    prof = debug_profile(item, target)
    # A failure is stepped into with the seed of the run it happened in.
    runs = failure === nothing ? nothing : failure.seed
    run_seed = UInt64(something(seed, runs, rand(RandomDevice(), UInt64)))
    print_debug_header(item, prof, run_seed, failure, seed === nothing && runs !== nothing)
    return with_interactive_env(target) do
        withenv(prof.env...) do
            isempty(prof.init.args) || Core.eval(Main, Expr(:block, prof.init.args...))
            spec = interactive_spec(item, target, item_seed(run_seed, item.name))
            say(item, target, 1, nothing)
            # The item's testset prints its own summary as it finishes; a `test_end`
            # that then fails is nested under it, and said here.
            result = run_item(spec; printing = true, enter)
            n = length(result.testset.results)
            result = with_test_end(result, spec, prof.test_end)
            for ts in result.testset.results[(n + 1):end], r in collect_failures(ts)
                show(stdout, r)
                println(stdout)
            end
            say(item, target, 1, outcome(result))
            return result.testset
        end
    end
end

# What a run records as a failure that can be stepped into again: an item that ran.
# One that never got to run, because its chain broke or the run was stopped, has
# nothing of its own to show.
const STEPPABLE = (FAILED, ERRORED, TIMEDOUT)

"""
    last_failure(target) -> (; name, others, seed)

The project's last recorded run, and of the items in it that failed, errored or
timed out, the one that finished last; `others` are the rest, most recent first.
`seed` is the run's, or `nothing` if it did not record one. Throws when no run is
recorded or the last one had no failures.
"""
function last_failure(target)
    here = project_id(target.root)
    for path in Iterators.reverse(runstate_files(target.root))
        rs = read_run_state(path)
        # A dry run ran nothing, and a directory shared by several projects holds
        # other projects' runs.
        (rs === nothing || rs.dry_run || get(rs.meta, "project_id", "") != here) && continue
        failed = filter(i -> rs.statuses[i].state in STEPPABLE, eachindex(rs.statuses))
        isempty(failed) && throw(
            NoTestsError(
                "the last recorded run of this project had no failures to step into; " *
                    "name an item instead: `YATF.debug(\"name\")`"
            )
        )
        sort!(failed; by = i -> rs.statuses[i].start_off + rs.statuses[i].elapsed, rev = true)
        names = [rs.items[i].name for i in failed]
        return (; name = first(names), others = names[2:end], seed = tryparse(UInt64, get(rs.meta, "seed", "")))
    end
    throw(
        NoTestsError(
            "no run of this project is recorded, so there is no failure to step into; " *
                "run its tests first, or name an item: `YATF.debug(\"name\")`"
        )
    )
end

# The item called `name`, from the whole suite read the way a run reads it.
function find_item(target, name::String)
    files, strays = walk_test_dir(target.testdir)
    items = scan(files, Filter(), setup_modules(target.testdir); strays)
    i = findfirst(it -> it.name == name, items)
    i === nothing || return items[i]
    near = [it.name for it in items if occursin(lowercase(name), lowercase(it.name))]
    throw(
        NoTestsError(
            string(
                "no test item is called ", repr(name),
                isempty(near) ? "" : string("; did you mean ", join(repr.(first(near, 5)), ", ", " or "), "?")
            )
        )
    )
end

# The profile a run would give the item, `[profiles.default]` included.
debug_profile(item::RawItem, target) =
    item.profile === DEFAULT_PROFILE ? read_config(target.testdir).profiles[DEFAULT_PROFILE] :
    interactive_profile(item, target)

# Said before the debugger takes the terminal: which item and why, whose seed, the
# failures there are to step into instead, and what the item gets here that it
# would not get in a run.
function print_debug_header(item::RawItem, prof::Profile, seed::UInt64, failure, runs_seed::Bool)
    head = string(
        "debugging ", repr(item.name), " in this process",
        failure === nothing ? "" : " · the last run's most recent failure",
        runs_seed ? " · the run's seed " : " · seed ", seed_text(seed)
    )
    body = String[]
    if failure !== nothing && !isempty(failure.others)
        shown = first(failure.others, 5)
        push!(
            body, string(
                "the run's other failures: ", join(repr.(shown), ", "),
                length(failure.others) > length(shown) ? string(" and ", length(failure.others) - length(shown), " more") : ""
            )
        )
    end
    ignored = debug_ignored(item, prof)
    isempty(ignored) || push!(body, string("ignored here: ", join(ignored, " · ")))
    if isempty(body)
        println(stdout, yatf_prefix(), head)
    else
        print(stdout, bracket(join(body, "\n"), "[YATF]", head, "", :white))
    end
    flush(stdout)
    return nothing
end

function debug_ignored(item::RawItem, prof::Profile)
    out = String[]
    of = prof.name === DEFAULT_PROFILE ? "" : string(" of profile `", prof.name, "`")
    isempty(prof.julia_args) || push!(out, string("`", join(prof.julia_args, " "), "`", of))
    here = string(Threads.nthreads(:default), ",", Threads.nthreads(:interactive))
    prof.threads == here || push!(out, string("threads ", prof.threads, of))
    isempty(prof.preferences) || push!(out, string("preferences", of))
    item.exclusive && push!(out, "sandbox=true")
    item.timeout_s == USE_RUN_DEFAULT || push!(out, string("timeout=", item.timeout_s))
    item.retries == USE_RUN_DEFAULT || push!(out, string("retries=", item.retries))
    item.chain === NO_CHAIN || push!(out, string("chain=:", item.chain))
    return out
end
