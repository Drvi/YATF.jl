# Coverage. Each worker counts the lines of the package it runs and writes them to an
# LCOV tracefile of its own when it exits; the run merges them into one `lcov.info`
# at the package's root. Julia writes a tracefile whenever its exit hooks run, an
# empty one when nothing counted ran: on a normal exit, and on the SIGTERM a timed-out
# worker is stopped with (on Windows it is terminated outright, which runs nothing). A
# worker that ran items and left none died without them, and what it counted is lost.

# What the run's closing block says about coverage.
struct CoverageSummary
    path::String   # the merged tracefile
    files::Int     # files of `src/` and `ext/` it covers
    lines::Int     # lines of those it counts
    hit::Int       # of those, the lines that ran
    lost::Int      # workers that ran items and wrote no tracefile
    error::String  # why the merged tracefile could not be written, or empty
end

# Where a run's workers write their tracefiles, one per process.
coverage_dir(logdir::AbstractString) = joinpath(logdir, "coverage")

# Julia matches `@path` against the path a file was loaded from, which is resolved:
# the root as given can be a symlink, as a temporary directory on macOS is.
coverage_flags(root::AbstractString, dir::AbstractString) =
    ["--code-coverage=@" * realpath(root), "--code-coverage=" * joinpath(dir, "%p.info")]

"""
    merge_coverage(tracedir, root, out) -> (files, lines, hit)

Sum the LCOV tracefiles in `tracedir` over the package's `src/` and `ext/`, and
write them to `out` as one, with paths relative to `root`. A tracefile has the lines
of the functions that were compiled and no others, so every other line of a function
body in those directories goes in as not run: a function nothing called, in a file
nothing loaded, counts against the package.
"""
function merge_coverage(tracedir::AbstractString, root::AbstractString, out::AbstractString)
    roots = unique([abspath(root), realpath(root)])
    counts = Dict{String, Dict{Int, Int}}()
    for f in readdir(tracedir; join = true)
        endswith(f, ".info") || continue
        file = nothing
        for line in eachline(f)
            if startswith(line, "SF:")
                file = package_source(line[4:end], roots)
            elseif startswith(line, "DA:") && file !== nothing
                fields = split(line[4:end], ',')
                length(fields) >= 2 || continue
                l, n = tryparse(Int, fields[1]), tryparse(Int, fields[2])
                (l === nothing || n === nothing) && continue
                lines = get!(Dict{Int, Int}, counts, file)
                lines[l] = get(lines, l, 0) + n
            elseif line == "end_of_record"
                file = nothing
            end
        end
    end
    for dir in ("src", "ext")
        isdir(joinpath(root, dir)) || continue
        for (d, _, names) in walkdir(joinpath(root, dir)), name in names
            endswith(name, ".jl") || continue
            path = joinpath(d, name)
            lines = get!(Dict{Int, Int}, counts, join(splitpath(relpath(path, root)), '/'))
            for l in function_body_lines(path)
                haskey(lines, l) || (lines[l] = 0)
            end
        end
    end
    filter!(((_, lines),) -> !isempty(lines), counts)
    open(out, "w") do io
        for file in sort!(collect(keys(counts)))
            lines = counts[file]
            println(io, "SF:", file)
            for l in sort!(collect(keys(lines)))
                println(io, "DA:", l, ",", lines[l])
            end
            println(io, "LH:", count(>(0), values(lines)))
            println(io, "LF:", length(lines))
            println(io, "end_of_record")
        end
    end
    return (length(counts), sum(length, values(counts); init = 0),
            sum(lines -> count(>(0), values(lines)), values(counts); init = 0))
end

# A tracefile's source path as the report names it, `src/…` or `ext/…` relative to
# the package's root, or `nothing` for a file outside those.
function package_source(path::AbstractString, roots)
    for r in roots
        rel = try
            relpath(path, r)
        catch
            continue   # another drive, on Windows
        end
        parts = splitpath(rel)
        !isempty(parts) && first(parts) in ("src", "ext") && return join(parts, '/')
    end
    return nothing
end

"""
    function_body_lines(path) -> Vector{Int}

The lines of `path` inside the body of a function: `function`, the `f(x) = …` form
and `x -> …`, wherever they are written, in a module, a macro call or a quoted
block. Empty for a file that does not parse, which the package would not load.
"""
function function_body_lines(path::AbstractString)
    ex = try
        Meta.parseall(read(path, String); filename = path)
    catch
        return Int[]
    end
    lines = Int[]
    body_lines!(lines, ex, false)
    return unique!(sort!(lines))
end

function body_lines!(lines::Vector{Int}, ex, inside::Bool)
    if ex isa LineNumberNode
        inside && push!(lines, ex.line)
    elseif ex isa Expr
        if is_function_definition(ex)
            # The body, not the signature.
            foreach(a -> body_lines!(lines, a, true), ex.args[2:end])
        else
            foreach(a -> body_lines!(lines, a, inside), ex.args)
        end
    end
    return lines
end

is_function_definition(ex::Expr) =
    (ex.head === :function && length(ex.args) >= 2) || ex.head === :-> ||
    (ex.head === :(=) && is_call_signature(ex.args[1]))

is_call_signature(s) =
    s isa Expr && (s.head === :call || (s.head in (:where, :(::)) && is_call_signature(s.args[1])))

# Whether the run counts coverage and what decided it, when something did.
function print_coverage_setting(io::IO, cfg)
    isempty(cfg.coverage_source) && return nothing
    println(io, "coverage: ", cfg.coverage ? "src/ and ext/, merged into lcov.info" : "off",
            " · set by ", cfg.coverage_source)
    return nothing
end

# The line the closing block gives coverage: how much ran, and where it was written.
function print_coverage(io::IO, cov::CoverageSummary, root::AbstractString)
    print(io, "coverage: ")
    if !isempty(cov.error)
        print(io, "not written, the run's result stands: ", cov.error)
    elseif cov.lines == 0
        print(io, "no lines counted in src/ or ext/")
    else
        print(io, round(100 * cov.hit / cov.lines; digits = 1), "% of ", cov.lines, " lines in ",
              plural(cov.files, "file"))
    end
    if isempty(cov.error)
        print(io, " · ")
        printstyled(io, relpath_or_path(cov.path, root); color = :light_black)
    end
    println(io)
    cov.lost > 0 && println(io, "coverage: none from ", plural(cov.lost, "worker"),
                            " that ran items and did not exit normally (killed or crashed)")
    return nothing
end

"""
    collect_coverage(run) -> CoverageSummary

The run's tracefiles merged into `lcov.info` at the package's root, once every worker
has exited, and how many workers that ran items left none. Never throws: a report
that cannot be written is said in the closing block, and the run's verdict stands.
"""
function collect_coverage(run)
    root = run.plan.root
    dir = coverage_dir(run.logdir)
    out = joinpath(root, "lcov.info")
    written = Set{Int32}()
    for f in (isdir(dir) ? readdir(dir) : String[])
        endswith(f, ".info") || continue
        pid = tryparse(Int32, chop(f; tail = 5))
        pid === nothing || push!(written, pid)
    end
    lost = count(!in(written), @lock run.lock collect(run.item_pids))
    try
        files, lines, hit = merge_coverage(dir, root, out)
        return CoverageSummary(out, files, lines, hit, lost, "")
    catch e
        is_interrupt(e) && rethrow()
        return CoverageSummary(out, 0, 0, 0, lost, sprint(showerror, e))
    end
end
