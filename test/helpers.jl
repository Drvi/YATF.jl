# Shared machinery for the tests that run a whole suite: building a throwaway
# package, running it, and reading back what happened and what was printed.

using YATF: prepare, execute, report, nitems
using YATFWorkers: YATFWorkers

# Fixture packages are written to a tempdir rather than checked in when their
# content is the thing under test: a profile, a broken layout, an item that has to
# crash in a particular place. Each needs a UUID of its own, because they are all
# resolved into environments in the same session.
const PKG_SERIAL = Ref(200)

function next_uuid()
    PKG_SERIAL[] += 1
    return string("1a2b3c4d-0000-4000-8000-", lpad(PKG_SERIAL[], 12, '0'))
end

"""
    make_pkg(name, "test/a_test.jl" => content, ...) -> dir

A package directory holding `name`, plus the given files written relative to it.
"""
function make_pkg(name::AbstractString, files::Pair{<:AbstractString,<:AbstractString}...)
    dir = mktempdir()
    write(joinpath(dir, "Project.toml"),
          "name = $(repr(name))\nuuid = $(repr(next_uuid()))\nversion = \"0.1.0\"\n")
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "src", name * ".jl"), "module $name\nend\n")
    mkpath(joinpath(dir, "test"))
    for (rel, content) in files
        path = joinpath(dir, rel)
        mkpath(dirname(path))
        write(path, content)
    end
    return dir
end

# Run a suite and hand back the per-item states by name. Never throws for a
# failing test item: the point is to assert on what was recorded.
function run_states(pkg; kwargs...)
    p, target = prepare((pkg,); kwargs...)
    run = execute(p, target)
    try
        states = Dict(p.items.name[i] => run.statuses.state[i] for i in 1:nitems(p))
        return states, run, p
    finally
        rm(run.logdir; force=true, recursive=true)
    end
end

"""
    capture_run(f) -> (value, output)

Everything the run printed, captured whole. A run writes through one stream,
relayed worker lines included, so redirecting it here catches all of it — which
is the only way to assert on output that a worker process produced.
"""
function capture_run(f)
    path, io = mktemp()
    value = try
        redirect_stdout(io) do
            f()
        end
    finally
        close(io)
    end
    output = read(path, String)
    rm(path; force=true)
    return value, output
end

# Fixtures that have to know whether they have run before write marker files; keep
# them out of a shared tempdir so a test can tell "this ran" from "this ran in
# some earlier test".
function with_marker_dir(f)
    dir = mktempdir()
    try
        withenv("YATF_FAULTY_DIR" => dir) do
            f(dir)
        end
    finally
        rm(dir; force=true, recursive=true)
    end
end

marker_dir() = ENV["YATF_FAULTY_DIR"]

# How many times a fixture has reached a marker, and one more.
function bump_marker(dir::AbstractString, name::AbstractString)
    path = joinpath(dir, name)
    n = isfile(path) ? parse(Int, read(path, String)) : 0
    write(path, string(n + 1))
    return n
end

live_worker_processes() = @lock YATFWorkers.LIVE_LOCK count(Base.process_running, YATFWorkers.LIVE_PROCESSES)
live_worker_pids() = @lock YATFWorkers.LIVE_LOCK Set(Base.getpid(p) for p in YATFWorkers.LIVE_PROCESSES
                                                     if Base.process_running(p))

# Run states live under the depot by default, keyed by project. A test that reads
# one back, or that must not see an earlier run's history, gets a directory of
# its own.
function with_runstate_dir(f)
    dir = mktempdir()
    try
        withenv("YATF_RUNSTATE_DIR" => dir) do
            f(dir)
        end
    finally
        rm(dir; force=true, recursive=true)
    end
end

# An item that records that it ran, in which process and when, so a test can
# assert what ran, in what order, where, and how many times.
#
# One file per *run* of the item rather than one shared file: items run at the
# same time in different processes, and two of them appending to one file is a
# race that shows up as a line quietly missing. The name is a timestamp and a pid,
# so a retry of the same item leaves a record of its own.
function journal_item(name::AbstractString; opts::AbstractString="", body::AbstractString="@test true")
    return """
    @testitem $(repr(name)) $opts begin
        let dir = ENV["YATF_JOURNAL"], now = time()
            open(joinpath(dir, string(time_ns(), "-", getpid())), "w") do io
                println(io, $(repr(name)), "\\t", getpid(), "\\t", now)
            end
        end
        $body
    end
    """
end

"""
    journal(dir) -> Vector{@NamedTuple{name::String, pid::Int}}

What the journalled items recorded, in the order they ran, one entry per run.

Ordered by the time each item wrote its record. Items in one process run one
after another, so that order is real; between processes there is no order to
have, and no test asserts one.
"""
function journal(dir::AbstractString)
    isdir(dir) || return NamedTuple{(:name, :pid), Tuple{String, Int}}[]
    rows = NamedTuple{(:name, :pid, :t), Tuple{String, Int, Float64}}[]
    for file in readdir(dir; join=true)
        parts = split(strip(read(file, String)), '\t')
        length(parts) == 3 || continue
        push!(rows, (name=String(parts[1]), pid=parse(Int, parts[2]), t=parse(Float64, parts[3])))
    end
    sort!(rows; by=r -> r.t)
    return [(name=r.name, pid=r.pid) for r in rows]
end

function with_journal(f)
    dir = mktempdir()
    try
        withenv("YATF_JOURNAL" => dir) do
            f(dir)
        end
    finally
        rm(dir; force=true, recursive=true)
    end
end

"""
    plain_julia(args...) -> Cmd

A julia command whose output carries no colour.

`Base.julia_cmd()` reproduces this process's flags, `--color` among them, so a
child of a suite run in a terminal writes SGR codes into the log it is spawned to
produce. A test that reads a child's output as text builds the child with this;
the trailing `--color=no` is what decides, because julia takes the last `--color`
on the line.
"""
plain_julia(args...) = `$(Base.julia_cmd()) --startup-file=no --color=no $args`
