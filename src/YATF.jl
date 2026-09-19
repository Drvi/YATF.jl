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

using Dates: Dates
using Logging: Logging, with_logger, current_logger
using Pkg: Pkg
using Test
using Test: Test
using TestEnv: TestEnv
using TOML: TOML

# The worker side lives in its own package (`lib/YATFWorkers`), so a worker
# process loads the protocol and the item runner and nothing else. The names a
# test item or the coordinator reaches for are imported here.
using YATFWorkers: YATFWorkers, ItemState, UNSEEN, RUNNING, PASSED, FAILED, ERRORED, TIMEDOUT,
    SKIPPED, BROKEN_CHAIN, CANCELLED, is_non_pass, ItemSpec, ItemResult,
    current_testitem, in_testitem, in_yatf_run, run_item,
    with_testset_printing, without_enclosing_testset, pad_to

export @testitem

# `Test` is re-exported, so `using YATF` is all a test file needs: a test item's
# body gets `@test`, `@testset` and the rest without the test environment having
# to declare `Test` itself. YATF already depends on it.
export Test, runtests
for name in names(Test)
    name === :Test && continue
    @eval export $name
end

public retry_failed, current_testitem, in_testitem, in_yatf_run,
    activate, deactivate, is_activated

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

"""
    runtests([paths...]; kwargs...)

Run the test items under `test/`. With no arguments, the project of the active
environment is used.

`paths` narrow what is read: a directory, a test file, or `file.jl:42` to select
the item that line is inside.

# Keywords

Selection: `name` (`String` for an exact match, `Regex` for a partial one) and
`tags` (a symbol or vector of symbols; an item must carry all of them).

Execution: `workers` (a count, or `0` to run in this process), `threads`,
`timeout`, `init_timeout` and `test_end_timeout` (a profile's `init` and `test_end`
expressions are timed separately from the items, and default to `timeout`),
`retries`, `failfast`, `memory_threshold`, `full_stacktraces` (keep the
framework's own frames in a failing item's stacktrace; trimmed by default).

Output: `logs` (`:issues`, `:batched`, `:eager`), `report`, `verbose`,
`monitor`, `monitor_interval`.

State: `dry_run` prints the plan and runs nothing.

Every keyword can also be set in `test/TestItems.toml`, which additionally
declares sandbox profiles and forced ordering; an explicit keyword wins.
"""
function runtests(args...; name = nothing, tags = nothing, dry_run::Bool = false, kwargs...)
    p, target = prepare(args; name, tags, kwargs...)
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

# Everything up to the point where a process would be started. Split out so that
# the plan can be inspected, printed, or executed without re-deriving it.
function prepare(args; name = nothing, tags = nothing, replay = nothing, kwargs...)
    target = resolve_target(args)
    PROJECT_ROOT[] = target.root
    filter = Filter(; name, tags, paths = target.paths, line = target.line)
    setups = setup_modules(target.testdir)
    # Reading the files is the first thing a run does and it can take a moment on a
    # large suite, so it says what it is doing and what it found. There is no
    # printer yet — nothing else is writing this early.
    println(
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
    # Every file, whatever the selection: a suite that does not parse, or that
    # declares one name twice, is broken rather than smaller, and finding that out
    # depends on reading all of it.
    items = scan(files, filter, setups; strays)
    isempty(items) && throw(NoTestsError("no test items matched " * describe(filter, target)))
    println(
        stdout, yatf_prefix(), "found ", plural(length(items), "test item"), " in ",
        plural(length(unique(i -> i.file, items)), "file"),
        length(files) == length(unique(i -> i.file, items)) ? "" :
            string(" of ", length(files), " searched"),
        " in ", fmt_seconds(time() - t_files)
    )
    files_seconds = time() - t_files
    t_plan = time()
    cfg = read_config(target.testdir; nunits = length(items), kwargs...)
    cfg = apply_runstate(cfg, items, target, replay)
    p = plan(
        items, cfg; history = history(target.root), root = target.root,
        strict_order = is_full_run(filter, target)
    )
    p.startup.files = files_seconds
    p.startup.plan = time() - t_plan
    return p, target
end

# Reproducing a run means running it with the same worker configuration, which is
# what `replay` is for: point it at a run state — one downloaded from CI, say —
# and the profiles it recorded are used in place of the ones this checkout
# declares. Only when asked. A run state found lying next to the project is not a
# request to run differently, and applying one would put a stale `init` expression
# ahead of an explicit `threads=` argument.
function apply_runstate(cfg::RunConfig, items::Vector{RawItem}, target, replay)
    replay === nothing && return cfg
    rs = read_run_state(String(replay))
    rs === nothing && throw(ConfigError("could not read a run state from $(replay)"))
    isempty(rs.profiles) && return cfg
    same = all(rs.profiles) do (name, prof)
        haskey(cfg.profiles, name) && profiles_match(cfg.profiles[name], prof)
    end
    same && return cfg
    println(
        stdout, yatf_prefix(), "applying the worker configuration recorded in ",
        basename(rs.path)
    )
    merged = merge(cfg.profiles, rs.profiles)
    return RunConfig(;
        cfg.workers, cfg.threads, cfg.timeout_s, cfg.init_timeout_s, cfg.test_end_timeout_s,
        cfg.retries, cfg.failfast, cfg.item_failfast, cfg.logs, cfg.report, cfg.verbose,
        cfg.memory_threshold, cfg.full_stacktraces, cfg.monitor, cfg.monitor_interval,
        profiles = merged, cfg.order_first, cfg.order_last
    )
end

profiles_match(a::Profile, b::Profile) =
    a.julia_args == b.julia_args && a.threads == b.threads && a.env == b.env &&
    expr_text(a.init) == expr_text(b.init) && expr_text(a.test_end) == expr_text(b.test_end)

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
    names = sort!(collect(h.failed))
    println(
        stdout, yatf_prefix(), "re-running ", plural(length(names), "item"),
        " that did not pass"
    )
    return runtests(args...; name = Regex("^(" * join(map(escape_string_regex, names), "|") * ")\$"), kwargs...)
end

escape_string_regex(s::AbstractString) = replace(s, r"([\\^\$.|?*+()\[\]{}])" => s"\\\1")

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

rstrip_path(p::AbstractString) = rstrip(p, '/')

_pkgdir(m::Module) = something(pkgdir(m), throw(ArgumentError("could not find a directory for module $m")))

function split_line_suffix(path::AbstractString)
    m = match(r"^(.*\.jl):(\d+)$", path)
    m === nothing && return String(path), Int32(0)
    return String(m.captures[1]), parse(Int32, m.captures[2])
end

# With no arguments, where do we look for tests? Not at the active project:
# `Pkg.test` builds its environment in a temporary directory, so under the most
# common entry point of all the active project is not the package being tested.
# The file being evaluated is.
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
    f.name === nothing || push!(parts, "name = $(repr(f.name))")
    f.tags === nothing || push!(parts, "tags = $(f.tags)")
    f.line == 0 || push!(parts, "line $(f.line)")
    isempty(t.paths) || push!(parts, "paths " * join(map(p -> relpath_or_path(p, t.root), t.paths), ", "))
    return isempty(parts) ? "the filter" : join(parts, " and ")
end

using PrecompileTools: @setup_workload, @compile_workload

# Everything between `runtests()` being called and the first test item starting:
# reading the files, resolving the configuration, planning, and the shapes the run
# prints. Measured on a 2000-item suite, this path takes 2.3s the first time it
# runs in a process and 0.04s afterwards — all of that difference is compilation,
# and it is paid before anything appears on screen.
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
    bytes = Vector{UInt8}(codeunits(source))
    # A real directory, because the run reads real directories: the walk, the
    # parallel scan and the TOML are each their own pile of code.
    dir = mktempdir()
    mkpath(joinpath(dir, "test"))
    write(joinpath(dir, "Project.toml"), "name = \"Precompile\"\nuuid = \"1a2b3c4d-0000-4000-8000-00000000000f\"\n")
    write(joinpath(dir, "test", "precompile_test.jl"), source)
    write(joinpath(dir, "test", "TestItems.toml"), "[run]\nworkers = 2\n")
    testdir = joinpath(dir, "test")
    @compile_workload begin
        for mode in (:stream, :parseall)
            items, errors, names = RawItem[], ScanError[], ItemName[]
            if mode === :stream
                scan_stream!(items, errors, names, bytes, "precompile_test.jl", Filter(), Dict{Symbol, String}())
            else
                scan_parseall!(items, errors, names, bytes, "precompile_test.jl", Filter(), Dict{Symbol, String}())
            end
        end
        files = discover(testdir)
        setups = setup_modules(testdir)
        items = scan(files, Filter(), setups; ntasks = 2)
        scan(files, Filter(name = "precompile one"), setups; ntasks = 1)
        cfg = read_config(testdir; nunits = length(items), monitor = false)
        h = history(dir)
        p = plan(items, cfg; history = h, root = dir)
        print_plan(devnull, p)
        Queues(p); Statuses(nitems(p))
        bracket("a line\nanother", "[1/2] FAIL", "\"an item\"", "@ a_test.jl:1", :red)
        fmt_seconds(0.5); plural(2, "worker")
    end
    rm(dir; force = true, recursive = true)
    # The environment path cannot be run here — it resolves a real project, which
    # a build sandbox may not be able to do — so it is precompiled by signature.
    precompile(test_env, (Target,))
    precompile(with_test_env, (Function, Target))
    precompile(resolve_target, (Tuple{String},))
    precompile(prepare, (Tuple{String},))
    precompile(execute, (Plan, Target))
    precompile(report, (Run,))
    precompile(run_on_workers, (Run, Target))
    precompile(run_slot, (Run, Slot, Target))
end

end # module YATF
