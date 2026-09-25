# A suite's upkeep in one call: what a run would refuse to start on, setups whose
# packages have fallen behind what they import, and run states nothing reads.

# A run state of this machine's older than this is deleted by `chores(fix = true)`.
const STALE_RUN_DAYS = 7

"""
    chores([path]; fix = false) -> Bool

Check the upkeep a package's suite needs, and with `fix = true` do what can be done
without a person:

- test items and `test/TestItems.toml`: everything a run would refuse to start on,
  such as a syntax error, a name declared twice, a setting it does not accept, an
  `[order]` entry naming no item or an unknown profile. Reported, never changed.
- test setups: what [`setups_to_packages`](@ref) would do, making packages of the
  setups that are not and adding to their `[deps]` what they have come to import.
- run states: this machine's, modified more than $(STALE_RUN_DAYS) days ago, are
  deleted, except the newest $(HISTORY_RUNS), whose durations order the next run. One
  recorded elsewhere, a CI artifact say, is never deleted.

Returns whether nothing is left to do: `true` when the check finds nothing, or when
`fix = true` found nothing it could not do. `path` finds the package as it does for
[`runtests`](@ref).
"""
function chores(args...; fix::Bool = false)
    target = resolve_target(args)
    todo = problems = 0
    body = styled() do io
        problems += check_suite!(io, target)
        n, bad = chore_setups!(io, target, fix)
        todo += n
        problems += bad
        todo += chore_runstates!(io, target, fix)
        if problems > 0
            print(io, "to fix by hand: ", problems)
            todo > 0 && !fix && print(io, " · the rest `YATF.chores(fix = true)` does")
        elseif todo > 0
            print(io, fix ? "done: $todo" : "to do: $todo, which `YATF.chores(fix = true)` does")
        else
            print(io, "nothing to do")
        end
    end
    print(stdout, bracket(body, "[YATF]", fix ? "chores" : "chores, checking only", "", :white))
    return problems == 0 && (fix || todo == 0)
end

# The suite as a full run would read it: its items, then its settings and what they
# name. The number of problems a person has to fix.
function check_suite!(io::IO, target)
    config = joinpath(target.testdir, "TestItems.toml")
    try
        p, _ = prepare((target.root,); announce = false)
        println(io, "test items: ", nitems(p), " in ", plural(length(p.files), "file"), ", all valid")
        print(io, "config: ")
        if isfile(config)
            printstyled(io, relpath_or_path(config, target.root); color = :light_black)
            println(io, ", valid")
        else
            println(io, "none")
        end
        return 0
    catch e
        e isa ConfigError && return print_problem(io, "config", e.msg)
        e isa ScanFailure || e isa NoTestsError || rethrow()
        n = if e isa ScanFailure
            println(io, "test items: ", plural(length(e.errors), "problem"), ":")
            foreach(err -> println(io, "  ", err), e.errors)
            length(e.errors)
        else
            print_problem(io, "test items", e.msg)
        end
        # The settings on their own: which items they name waits on the items.
        try
            read_config(target.testdir)
        catch e2
            e2 isa ConfigError || rethrow()
            return n + print_problem(io, "config", e2.msg)
        end
        if isfile(config)
            print(io, "config: ")
            printstyled(io, relpath_or_path(config, target.root); color = :light_black)
            println(io, " reads; the items it names are checked once the test items read")
        end
        return n
    end
end

# `label: msg`, a message of several lines indented under its first. Counts as one.
function print_problem(io::IO, label::AbstractString, msg::AbstractString)
    lines = split(chomp(msg), '\n')
    println(io, label, ": ", first(lines))
    foreach(l -> println(io, "  ", l), lines[2:end])
    return 1
end

# What making the setups packages would change, done under `fix`: the number of
# setups to change, and of problems a person has to fix.
function chore_setups!(io::IO, target, fix::Bool)
    dir = joinpath(target.testdir, TESTSETUPS_DIR)
    modules = setup_modules(target.testdir)
    isempty(modules) && (println(io, "setups: none"); return (0, 0))
    plans = try
        plan_setup_packages(target, dir, modules)
    catch e
        e isa ConfigError || rethrow()
        return (0, print_problem(io, "setups", e.msg))
    end
    pending = filter(p -> moves(p) || p.changed, plans)
    if isempty(pending)
        println(io, "setups: ", length(plans), ", all up to date")
        return (0, 0)
    end
    fix && foreach(write_setup_package, pending)
    println(io, "setups: ", length(pending), " of ", length(plans), fix ? " changed:" : " to change:")
    print_setup_changes(io, pending, dir; done = fix, indent = "  ")
    return (length(pending), 0)
end

# Deletes, under `fix`, the run states `stale_runstates` names; their number.
function chore_runstates!(io::IO, target, fix::Bool)
    files = runstate_files(target.root)
    print(io, "run states: ")
    isempty(files) && (println(io, "none"); return 0)
    print(io, length(files), " in ")
    printstyled(io, relpath_or_path(runstate_dir(target.root), target.root); color = :light_black)
    stale = stale_runstates(target.root)
    if isempty(stale)
        println(io, ", none to delete")
        return 0
    end
    fix && foreach(f -> rm(f; force = true), stale)
    println(io, ", ", length(stale), " of this machine's older than ", STALE_RUN_DAYS, " days ",
            fix ? "deleted" : "to delete", " (the newest ", HISTORY_RUNS, " stay)")
    return length(stale)
end

"""
    stale_runstates(root) -> Vector{String}

The run states `chores(fix = true)` deletes: this machine's, modified more than
`STALE_RUN_DAYS` ago, and not among the newest `HISTORY_RUNS`, which `history`
reads. One recorded elsewhere, and one that cannot be read, are never among them:
nothing shows they are this machine's to delete.
"""
function stale_runstates(root::AbstractString)
    files = runstate_files(root)
    here = run_host()
    cutoff = time() - STALE_RUN_DAYS * 86400
    return filter(files[1:max(0, end - HISTORY_RUNS)]) do f
        mtime(f) < cutoff || return false
        rs = read_run_state(f)
        return rs !== nothing && get(rs.meta, "host", "") == here
    end
end
