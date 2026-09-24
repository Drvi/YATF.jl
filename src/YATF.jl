"""
    YATF

Run a package's tests as independent test items across worker processes.

    YATF.runtests()                      # every test item under test/
    YATF.runtests("test/solver_test.jl") # one file
    YATF.runtests(name="adds numbers")   # one item
    YATF.runtests(dry_run=true)          # print the plan, run nothing

Test files live under `test/` and are named `*_test.jl` or `*_tests.jl`. They
contain `@testitem` declarations and nothing else. Shared setup code goes in
`test/testsetups/` as ordinary modules, which test items load with `using`.
"""
module YATF

using Base.ScopedValues: ScopedValue, with
using Logging: Logging, with_logger, current_logger
using Pkg: Pkg
using Random: RandomDevice
using Test
using Test: Test
using TestEnv: TestEnv
using TOML: TOML

# The worker side is a package of its own, so a worker loads the protocol and the
# item runner and nothing else.
using YATFWorkers: YATFWorkers, ItemState, UNSEEN, RUNNING, PASSED, FAILED, ERRORED, TIMEDOUT,
    SKIPPED, BROKEN_CHAIN, CANCELLED, is_non_pass, ItemSpec, ItemResult,
    current_testitem, in_testitem, in_yatf_run, run_item,
    with_testset_printing, without_enclosing_testset, PATHSEP

export @testitem

# Re-exported, so `using YATF` alone gives a script or the REPL `@test` and the
# rest. A test item's body does not need it: it is handed `Test` directly.
export Test, runtests
for name in names(Test)
    name === :Test && continue
    @eval export $name
end

public retry_failed, current_testitem, in_testitem, in_yatf_run,
    activate, deactivate, is_activated, debug

include("types.jl")
include("macros.jl")
include("scan.jl")
include("config.jl")
include("plan.jl")
include("runstate.jl")
include("report.jl")
include("platform.jl")
include("monitor.jl")
include("execute.jl")
include("interactive.jl")
include("debug.jl")

"""
    runtests([paths...]; kwargs...)

Run the test items under `test/`. With no arguments, the project of the active
environment is used.

`paths` narrow what is read: a directory, a test file, or `file.jl:42` to select
the item that line is inside.

# Keywords

Selection: `name` (`String` for an exact match, `Regex` for a partial one, or a
set of exact names) and `tags` (a symbol or vector of symbols an item must carry
all of, or a string expression such as `"!slow"` or `"juliac || serializer"`).

Execution: `workers` (a count, or `0` to run in this process), `threads`,
`timeout`, `init_timeout` and `test_end_timeout` (a profile's `init` and `test_end`
expressions are timed separately from the items, and default to `timeout`),
`retries`, `failfast`, `memory_threshold`, `full_stacktraces` (keep the
framework's own frames in a failing item's stacktrace; trimmed by default), `seed`
(every item draws its random numbers from this and its own name; random unless
given, and printed at the start of the run).

Output: `logs` (`:issues`, `:batched`, `:eager`), `report`, `verbose`,
`monitor`, `monitor_interval`.

State: `dry_run` prints the plan and runs nothing. `replay` names a run state (one
downloaded from CI, say) and runs it again: the same items, settings, profiles
and seed, with any keyword given here winning, and a warning naming each package
whose version differs from the one recorded.

Every keyword can also be set in `test/TestItems.toml`, which additionally
declares sandbox profiles and forced ordering; an explicit keyword wins.
"""
function runtests(args...; name = nothing, tags = nothing, dry_run::Bool = false, kwargs...)
    # A dry run says what it found in its own block, with the plan.
    p, target = prepare(args; name, tags, announce = !dry_run, kwargs...)
    if dry_run
        print_plan(stdout, p)
        return p
    end
    run = execute(p, target)
    try
        return report(run)
    finally
        rm(run.logdir; force = true, recursive = true)
    end
end

# Everything up to starting a process, so a plan can be inspected, printed or run.
# `announce` prints what is being read and what was found, as it happens.
function prepare(args; name = nothing, tags = nothing, replay = nothing, announce::Bool = true, kwargs...)
    target = resolve_target(args)
    PROJECT_ROOT[] = target.root
    rs = replay === nothing ? nothing : read_replay(String(replay), target)
    if rs !== nothing
        # The items and settings it recorded, under whatever the call says itself.
        selected = name !== nothing || tags !== nothing || !isempty(target.paths) || target.line != 0
        selected || (name = Set(it.name for it in rs.items))
        kwargs = merge(recorded_settings(rs), kwargs)
    end
    filter = Filter(; name, tags, paths = target.paths, line = target.line)
    setups = setup_modules(target.testdir)
    # Printed directly: there is no printer yet, and nothing else writes this early.
    announce && println(
        stdout, yatf_prefix(), "reading test files under ",
        relpath_or_path(target.testdir, target.root),
        is_full_run(filter, target) ? "" : string(" matching ", describe(filter, target))
    )
    t_files = time()
    files, strays = walk_test_dir(target.testdir)
    if isempty(files)
        # A stray file is the likeliest reason there is nothing to run, so it is
        # what the run says rather than "no test files found".
        isempty(strays) || throw(ScanFailure(map(stray_error, strays)))
        throw(
            NoTestsError(
                "no test files found under $(relpath_or_path(target.testdir)); test files are " *
                    "named `*_test.jl` or `*_tests.jl` and live under `test/`"
            )
        )
    end
    # Every file, whatever the selection: a broken suite is broken, not smaller.
    suite_names = String[]
    items = scan(files, filter, setups; strays, suite_names)
    isempty(items) && throw(NoTestsError("no test items matched " * describe(filter, target)))
    announce && println(
        stdout, yatf_prefix(), "found ", plural(length(items), "test item"), " in ",
        plural(length(unique(i -> i.file, items)), "file"),
        length(files) == length(unique(i -> i.file, items)) ? "" :
            string(" of ", length(files), " searched"),
        " in ", fmt_seconds(time() - t_files)
    )
    files_seconds = time() - t_files
    t_plan = time()
    cfg = read_config(target.testdir; nunits = length(items), kwargs...)
    rs === nothing || (cfg = replayed_config(cfg, rs))
    p = plan(
        items, cfg; history = history(target.root), root = target.root,
        strict_order = is_full_run(filter, target),
        selection = is_full_run(filter, target) ? "" : describe(filter, target), suite_names
    )
    p.startup.files = files_seconds
    p.startup.plan = time() - t_plan
    return p, target
end

# `replay`: a run state (one downloaded from CI, say) to run again. Only when asked:
# a run state lying next to the project is not a request to run differently.
function read_replay(path::String, target)
    rs = read_run_state(path)
    rs === nothing && throw(ConfigError(
        "could not read a run state from $path: it is missing, damaged, or written by another version of YATF"
    ))
    id, here = get(rs.meta, "project_id", ""), project_id(target.root)
    id == here || throw(ConfigError("$path records a run of project $(repr(id)), not of this one ($(repr(here)))"))
    m(k) = get(rs.meta, k, "")
    println(
        stdout, yatf_prefix(), "replaying ", basename(path), ": ", plural(length(rs.items), "test item"),
        " · seed ", m("seed"), " · recorded with julia ", m("julia"), " on ", m("machine"),
        isempty(m("revision")) ? "" : string(" at rev ", first(m("revision"), 10))
    )
    return rs
end

# The settings a run state recorded, as `runtests` keywords.
function recorded_settings(rs::RunStateRecord)
    out = Pair{Symbol, Any}[]
    for (key, parse_) in REPLAYED_SETTINGS
        text = get(rs.meta, string(key), "")
        isempty(text) && continue
        value = try
            parse_(text)
        catch
            throw(ConfigError("the run state's `$key` setting is unreadable: $(repr(text))"))
        end
        push!(out, key => value)
    end
    return NamedTuple(out)
end

# The recorded profiles in place of this checkout's, each preferences file written
# back out from what was recorded, and the recorded manifest kept for comparison.
function replayed_config(cfg::RunConfig, rs::RunStateRecord)
    profiles = copy(cfg.profiles)
    for (name, prof) in rs.profiles
        prefs = get(rs.preferences, name, "")
        path = isempty(prefs) ? "" : (f = tempname() * ".toml"; write(f, prefs); f)
        profiles[name] = Profile(prof.name, prof.julia_args, prof.threads, prof.env, prof.init, prof.test_end, path)
    end
    fields = NamedTuple{fieldnames(RunConfig)}(ntuple(i -> getfield(cfg, i), fieldcount(RunConfig)))
    return RunConfig(; merge(fields, (; profiles, replayed_manifest = get(rs.meta, "environment_manifest", ""),
                                        replayed_from = rs.path))...)
end

"""
    retry_failed(paths...; kwargs...)

Re-run exactly the items the last run recorded as not passing.
"""
function retry_failed(args...; kwargs...)
    target = resolve_target(args)
    h = history(target.root; nruns = 1)
    isempty(h.failed) && throw(
        NoTestsError(
            "the last recorded run has no failures to retry" *
                (isempty(runstate_files(target.root)) ? " (no run state found for this project)" : "")
        )
    )
    names = Set(keys(h.failed))
    println(
        stdout, yatf_prefix(), "re-running ", plural(length(names), "item"),
        " that did not pass"
    )
    return runtests(args...; name = names, kwargs...)
end

"""
    Target

Where a run reads from: the project, its `test/` directory, and any narrowing
the caller asked for.
"""
struct Target
    root::String
    project::String
    testdir::String
    paths::Vector{String}   # absolute; empty means "all of testdir"
    line::Int32
end

function resolve_target(args)
    isempty(args) && return target_from_dir(default_search_dir())
    length(args) == 1 && args[1] isa Module && return target_from_dir(_pkgdir(args[1]))
    paths = String[]; line = Int32(0)
    for a in args
        a isa AbstractString || throw(ArgumentError("YATF.runtests takes paths or a module, got $(repr(a))"))
        path, ln = split_line_suffix(String(a))
        ln == 0 || (line == 0 || throw(ArgumentError("only one `file.jl:line` target is allowed")); line = ln)
        push!(paths, abspath(path))
    end
    for path in paths
        ispath(path) || throw(ArgumentError("no such file or directory: $path"))
    end
    t = target_from_dir(isdir(first(paths)) ? first(paths) : dirname(first(paths)))
    # Naming the project or its test directory means "everything", not a narrowing.
    narrowing = String[]
    for path in paths
        rstrip_path(path) in (rstrip_path(t.root), rstrip_path(t.testdir)) && continue
        startswith(path, t.testdir) || throw(
            ArgumentError(
                "$(path) is not under $(t.testdir); YATF only reads test files from `test/`"
            )
        )
        isdir(path) || is_test_file(path) || throw(
            ArgumentError(
                "$(path) is not a test file; test files are named `*_test.jl` or `*_tests.jl`"
            )
        )
        push!(narrowing, path)
    end
    return Target(t.root, t.project, t.testdir, narrowing, line)
end

rstrip_path(p::AbstractString) = rstrip(p, PATH_SEPARATORS)

_pkgdir(m::Module) = something(pkgdir(m), throw(ArgumentError("could not find a directory for module $m")))

function split_line_suffix(path::AbstractString)
    m = match(r"^(.*\.jl):(\d+)$", path)
    m === nothing && return String(path), Int32(0)
    return String(m.captures[1]), parse(Int32, m.captures[2])
end

# Not the active project: under `Pkg.test` that is a temporary environment, and the
# package is where the `runtests.jl` being evaluated is.
function default_search_dir()
    source = get(task_local_storage(), :SOURCE_PATH, nothing)
    if source !== nothing && basename(String(source)) == "runtests.jl"
        return dirname(abspath(String(source)))
    end
    proj = Base.active_project()
    return proj === nothing ? pwd() : dirname(proj)
end

function target_from_dir(dir::AbstractString)
    project = find_project(abspath(dir))
    project === nothing && throw(
        ArgumentError(
            "could not find a Project.toml at or above $(abspath(dir))"
        )
    )
    root = dirname(project)
    return Target(root, project, joinpath(root, "test"), String[], Int32(0))
end

const PROJECT_NAMES = ("Project.toml", "JuliaProject.toml")

function find_project(dir::AbstractString)
    # `test/` has its own Project.toml, which is an environment and not a project
    # root, so a path inside it must keep walking up.
    while true
        if basename(dir) != "test"
            for n in PROJECT_NAMES
                p = joinpath(dir, n)
                isfile(p) && return p
            end
        end
        parent = dirname(dir)
        parent == dir && return nothing
        dir = parent
    end
    return
end

is_full_run(f::Filter, t::Target) =
    f.name === nothing && f.tags === nothing && f.line == 0 && isempty(t.paths)

function describe(f::Filter, t::Target)
    parts = String[]
    f.name === nothing || push!(parts, f.name isa Set ? plural(length(f.name), "named item") : "name = $(repr(f.name))")
    f.tags === nothing || push!(parts, "tags = $(f.tags)")
    f.line == 0 || push!(parts, "line $(f.line)")
    isempty(t.paths) || push!(parts, "paths " * join(map(p -> relpath_or_path(p, t.root), t.paths), ", "))
    return isempty(parts) ? "the filter" : join(parts, " and ")
end

using PrecompileTools: @setup_workload, @compile_workload

# The paths a run takes that the workload below cannot take for it: starting a
# worker starts a process during the build, and running an item evaluates code
# into `Main`, which makes Julia warn that incremental compilation may be broken.
# `with_test_env` takes a closure and has no concrete signature to name.
const PRECOMPILE_SIGNATURES = (
    (test_env, (Target,)),
    (resolve_target, (Tuple{String},)),
    (prepare, (Tuple{String},)),
    (execute, (Plan, Target)),
    (report, (Run,)),
    (run_on_workers, (Run, Target)),
    (run_slot, (Run, Slot, Target)),
)

# Everything between `runtests()` and the first test item: reading, configuring,
# planning and the shapes the run prints. On a 2,000-item suite this takes 2.3 s
# uncompiled and 0.04 s compiled, paid before anything appears on screen.
@setup_workload begin
    source = """
    @testitem "precompile one" tags=[:a] timeout=60 begin
        using Test
        @test true
    end
    @testitem "precompile two" chain=:c retries=1 begin
        @test true
    end
    """
    # A real directory, because the run reads real directories: the walk, the
    # parallel scan and the TOML are each their own pile of code.
    dir = mktempdir()
    mkpath(joinpath(dir, "test"))
    write(joinpath(dir, "Project.toml"), "name = \"Precompile\"\nuuid = \"1a2b3c4d-0000-4000-8000-00000000000f\"\n")
    write(joinpath(dir, "test", "precompile_test.jl"), source)
    write(joinpath(dir, "test", "TestItems.toml"), "[run]\nworkers = 2\n")
    testdir = joinpath(dir, "test")
    @compile_workload begin
        files = discover(testdir)
        setups = setup_modules(testdir)
        items = scan(files, Filter(), setups; ntasks = 2)
        scan(files, Filter(name = "precompile one"), setups; ntasks = 1)
        cfg = read_config(testdir; nunits = length(items), monitor = false)
        p = plan(items, cfg; history = history(dir), root = dir)
        print_plan(devnull, p)
        Queues(p); Statuses(nitems(p))

        # The run state, written before the first item starts and read by the run
        # after this one.
        statepath = joinpath(dir, "precompile.yatf")
        rsf = init_run_state(statepath, p)
        write_status!(rsf, 1, RUNNING, 1, 1)
        write_status!(rsf, 1, PASSED, 1, 1; elapsed = 0.1, compile = 0.05)
        append_event!(rsf, EVENT_ATTEMPT, UInt8(PASSED), 1, 1, 0.1, 0.2; item = 1, attempt = 1)
        write_memory!(rsf, MemStats())
        finish_run_state!(rsf)
        read_run_state(statepath)
        withenv("YATF_RUNSTATE_DIR" => dir) do
            history(dir)
        end

        # The shapes a run prints. The first three run once per field of the
        # progress line, which is redrawn after every line the run writes.
        buf = IOBuffer()
        print_bytes(buf, 3.5 * 2^30, BYTES_WIDTH)
        print_bytes(buf, 512 * 2^20, TOTAL_WIDTH)
        print_1dp(buf, 2.5, 4)
        print_int(buf, 42, 4)
        print_quoted(buf, "an item")
        item_line(1, 1, 2, "an item", 12, 1, 1, "a_test.jl:1")
        item_line(1, 1, 2, "an item", 12, 2, 2, (; state = PASSED, elapsed_ns = 1, compile_ns = 0, maxrss = 1))
        parse_record(string(YATFWorkers.RECORD_MARK, "DONE 1 1 2 3 4 5"))
        item_log_path("/precompile/item_", 1, 1)
        bracket("a line\nanother", "[1/2] FAIL", "\"an item\"", "@ a_test.jl:1", :red)
        fmt_seconds(0.5); plural(2, "worker"); plural(1, "process", "processes")
    end
    rm(dir; force = true, recursive = true)
    for (f, types) in PRECOMPILE_SIGNATURES
        YATFWorkers.precompile_or_throw(f, types)
    end
end

end # module YATF
