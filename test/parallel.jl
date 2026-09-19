# Running the test files in parallel, one plain subprocess each.
#
# Plain subprocesses rather than YATF's own worker pool: a bug in the transport
# would stop the suite from running instead of telling you which test it broke.
# What crosses between parent and child is a stream of output and an exit status,
# which is the least a child can get wrong.

struct FileResult
    file::String
    ok::Bool
    status::String     # how it ended, when it did not end well
    seconds::Float64
    output::String
end

# The environment a child needs to be this process with one file in it: the same
# load path (YATF's own checkout is on it under `Pkg.test`), the same depot, and
# the same project.
function child_command(runner::AbstractString, file::AbstractString)
    pathsep = Sys.iswindows() ? ";" : ":"
    proj = Base.active_project()
    # `--project` rather than `JULIA_PROJECT`: the variable is inherited by every
    # process the child starts, and a test run builds environments of its own for
    # its workers to use.
    cmd = `$(Base.julia_cmd()) --startup-file=no --threads=$(Threads.nthreads())
           $(proj === nothing ? String[] : ["--project=$proj"])
           --color=$(get(stdout, :color, false) ? "yes" : "no") $runner $file`
    return addenv(
        cmd,
        "JULIA_LOAD_PATH" => join(LOAD_PATH, pathsep),
        "JULIA_DEPOT_PATH" => join(DEPOT_PATH, pathsep),
    )
end

# How a child ended, in the words the summary uses. A process killed by a signal
# reports an exit code of zero, so asking only for that would call a segfault or
# an `abort` a pass — which is the one answer a test runner may never give.
function exit_status(proc::Base.Process)
    proc.termsignal != 0 && return "killed by signal $(proc.termsignal)"
    proc.exitcode != 0 && return "exit code $(proc.exitcode)"
    return ""
end

function run_file_in_subprocess(runner::AbstractString, file::AbstractString)
    log = tempname()
    t0 = time()
    proc = try
        run(pipeline(ignorestatus(child_command(runner, file)); stdout = log, stderr = log))
    catch e
        # It could not be started at all; that is this file's failure too.
        return FileResult(file, false, "could not start", time() - t0, sprint(showerror, e))
    end
    seconds = time() - t0
    output = isfile(log) ? read(log, String) : ""
    rm(log; force = true)
    status = exit_status(proc)
    return FileResult(file, isempty(status), status, seconds, output)
end

function run_in_parallel(runner::AbstractString, files::Vector{String}, jobs::Int)
    println("[tests] running ", length(files), " files across ", jobs, " processes")
    results = Vector{Union{Nothing, FileResult}}(nothing, length(files))
    queue = Channel{Int}(length(files))
    foreach(i -> put!(queue, i), eachindex(files))
    close(queue)
    printer = ReentrantLock()
    @sync for _ in 1:jobs
        Threads.@spawn for i in queue
            r = run_file_in_subprocess(runner, files[i])
            results[i] = r
            # Printed whole, when the file finishes: a file's output is only
            # readable next to itself, and several of them arrive at once.
            @lock printer begin
                printstyled(
                    stdout, "\n", "="^78, "\n", rpad(r.file, 52),
                    r.ok ? "passed" : "FAILED " * r.status, "  ",
                    round(r.seconds; digits = 1), "s\n", "="^78, "\n";
                    bold = true, color = r.ok ? :green : :red
                )
                print(stdout, r.output)
                endswith(r.output, "\n") || println(stdout)
                flush(stdout)
            end
        end
    end
    return FileResult[r for r in results if r !== nothing]
end

function report_files(results::Vector{FileResult})
    failed = filter(r -> !r.ok, results)
    println("\n", "="^78)
    printstyled(stdout, "YATF test files\n"; bold = true)
    for r in sort(results; by = r -> -r.seconds)
        printstyled(
            stdout, "  ", rpad(r.file, 24), lpad(round(r.seconds; digits = 1), 7), "s  ",
            r.ok ? "passed" : "FAILED (" * r.status * ")", "\n";
            color = r.ok ? :green : :red
        )
    end
    println("="^78)
    isempty(failed) && return nothing
    # Each file's own detail is above, in its own block. What this adds is which
    # blocks to go and read, so a CI log's last line names them.
    error(
        "YATF: ", length(failed), " of ", length(results), " test files failed: ",
        join((string(r.file, " (", r.status, ")") for r in failed), ", ")
    )
end
