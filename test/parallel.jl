# Running the test files in parallel, one plain subprocess each.
#
# Plain subprocesses rather than YATF's own worker pool: a bug in the transport
# would stop the suite from running instead of telling you which test it broke.
# What crosses between parent and child is a stream of output and an exit status,
# which is the least a child can get wrong.
#
# Each child writes to a log of its own, and only a file that failed has its log
# printed: a green run is twenty lines, and a red one is the output of the file
# that went red.

struct FileResult
    file::String
    ok::Bool
    status::String     # how it ended, when it did not end well
    seconds::Float64
    output::String
end

# Memory while the files run, sampled twice a second: each file's process tree (its
# process and every worker it starts) at its largest, and the suite's and the
# machine's at theirs. With how busy the CPUs were over the run, the other limit,
# it is what it takes to choose how many files run at once.
mutable struct MemoryLog
    const lock::ReentrantLock
    const pids::Dict{Int32, String}   # a running file's process -> the file
    const peak::Dict{String, Int64}   # file -> its tree's largest summed resident size
    const machine_while::Dict{String, Int64}   # file -> the machine's memory in use, at its largest while the file ran
    suite::Int64                      # every running file's tree together, at the largest
    suite_files::Int                  # how many files were running then
    machine::Int64                    # the machine's memory in use, at the largest
    total::Int64
    cpus::Int                         # the machine's CPU threads; 0 until the run has ended
    cpu_busy::Float64                 # the share of their time they spent busy over the run
    @atomic done::Bool
end
MemoryLog() = MemoryLog(ReentrantLock(), Dict{Int32, String}(), Dict{String, Int64}(), Dict{String, Int64}(), 0, 0, 0, 0, 0, 0.0, false)

# Busy and total milliseconds since boot, summed over every CPU thread: two readings
# give the share of the time in between that the machine spent busy.
function cpu_times()
    busy = total = UInt64(0)
    for c in Sys.cpu_info()
        b = c.var"cpu_times!user" + c.var"cpu_times!nice" + c.var"cpu_times!sys" + c.var"cpu_times!irq"
        busy += b
        total += b + c.var"cpu_times!idle"
    end
    return busy, total
end

function sample!(log::MemoryLog)
    used, total = YATF.Private.Platform.machine_memory()
    @lock log.lock begin
        log.total = total
        log.machine = max(log.machine, used)
        for file in values(log.pids)
            used > get(log.machine_while, file, 0) && (log.machine_while[file] = used)
        end
        # Without per-process figures there is only the machine to go by.
        YATF.Private.Platform.PER_PROCESS_OK[] || return nothing
        suite = Int64(0)
        for (pid, file) in log.pids
            tree = sum((max(YATF.Private.Platform.process_rss(p), 0) for p in YATF.Private.Platform.process_tree([pid])); init = Int64(0))
            suite += tree
            tree > get(log.peak, file, 0) && (log.peak[file] = tree)
        end
        suite > log.suite && ((log.suite, log.suite_files) = (suite, length(log.pids)))
    end
    return nothing
end

peak_of(log::MemoryLog, file) = @lock log.lock get(log.peak, file, 0)

# A share of the machine's memory, as a percentage.
percent(used, total) = total > 0 ? string(round(Int, 100 * used / total), "%") : "-"

# What a file's line says about memory: its own peak, and how full the machine got
# while it ran.
memory_text(log::MemoryLog, file) = @lock log.lock string(
    "peak ", YATF.Private.fmt_bytes(get(log.peak, file, 0)),
    " · machine ", percent(get(log.machine_while, file, 0), log.total)
)

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
        # A child's output is shown only when its file fails, so it can afford to
        # print everything it captured along the way.
        "YATF_TEST_ECHO" => "1",
    )
end

# How long one file may take before it counts as hung. The slowest takes about a
# minute here and a few on a CI runner. A hung one would otherwise hold the job
# until the job's own timeout and show nothing, its output still in a log file.
const FILE_LIMIT_SECONDS = something(tryparse(Int, get(ENV, "YATF_TEST_FILE_TIMEOUT", "")), 15 * 60)

# A hung file is asked where its tasks are before it is killed: the child installed
# YATF's inspection hook, so the signal prints every task's backtrace into its log,
# and SIGTERM then prints every thread's. Windows has neither and is just killed.
function stop_hung(proc::Base.Process)
    exited(seconds) = timedwait(() -> process_exited(proc), seconds; pollint = 0.2) === :ok
    signal(sig) = try
        kill(proc, sig)
    catch
    end
    sig = YATFWorkers.INSPECT_SIGNAL
    # The report is a backtrace per task and a one-second profile: printed well within this.
    sig === nothing || (signal(sig); exited(3.0))
    process_exited(proc) || (signal(Base.SIGTERM); exited(5.0))
    process_exited(proc) || signal(Base.SIGKILL)
    return nothing
end

# How a child ended, in the words the summary uses. A process killed by a signal
# reports an exit code of zero, so asking only for that would call a segfault or
# an `abort` a pass — which is the one answer a test runner may never give.
function exit_status(proc::Base.Process)
    proc.termsignal != 0 && return "killed by signal $(proc.termsignal)"
    proc.exitcode != 0 && return "exit code $(proc.exitcode)"
    return ""
end

function run_file_in_subprocess(
        runner::AbstractString, file::AbstractString;
        limit::Real = FILE_LIMIT_SECONDS, memory::Union{Nothing, MemoryLog} = nothing
    )
    log = tempname()
    t0 = time()
    # One open file for both streams. Given the path twice, the child would get two
    # descriptors with offsets of their own, and each stream would write over the other.
    io = open(log, "w")
    proc = try
        run(pipeline(ignorestatus(child_command(runner, file)); stdout = io, stderr = io); wait = false)
    catch e
        close(io)
        # It could not be started at all; that is this file's failure too.
        return FileResult(file, false, "could not start", time() - t0, sprint(showerror, e))
    end
    pid = try
        Int32(getpid(proc))
    catch
        Int32(0)   # it has already exited
    end
    memory === nothing || pid == 0 || @lock memory.lock (memory.pids[pid] = file)
    hung = timedwait(() -> process_exited(proc), limit; pollint = 1.0) === :timed_out
    hung && stop_hung(proc)
    wait(proc)
    memory === nothing || @lock memory.lock delete!(memory.pids, pid)
    close(io)
    seconds = time() - t0
    output = isfile(log) ? read(log, String) : ""
    rm(log; force = true)
    status = hung ? string("hung: still running after the ", round(Int, limit), "s limit (YATF_TEST_FILE_TIMEOUT)") : exit_status(proc)
    return FileResult(file, isempty(status), status, seconds, output)
end

function run_in_parallel(runner::AbstractString, files::Vector{String}, jobs::Int)
    println("[tests] running ", length(files), " files across ", jobs, " processes")
    results = Vector{Union{Nothing, FileResult}}(nothing, length(files))
    queue = Channel{Int}(length(files))
    foreach(i -> put!(queue, i), eachindex(files))
    close(queue)
    printer = ReentrantLock()
    memory = MemoryLog()
    YATF.Private.Platform.ensure_checked!()
    sampler = Threads.@spawn while !(@atomic memory.done)
        sample!(memory)
        sleep(0.5)
    end
    busy0, total0 = cpu_times()
    @sync for _ in 1:jobs
        Threads.@spawn for i in queue
            # Said when a file starts, so a run that stalls shows what is in flight.
            @lock printer begin
                println(stdout, rpad(files[i], 52), "running")
                flush(stdout)
            end
            r = run_file_in_subprocess(runner, files[i]; memory)
            results[i] = r
            # A file that passed says so in one line: twenty files' worth of
            # passing output is what buries the few lines that matter. A file that
            # failed prints everything it said, whole and when it finishes, since
            # its output is only readable next to itself and several of them
            # arrive at once.
            @lock printer begin
                if r.ok
                    printstyled(
                        stdout, rpad(r.file, 52), "passed  ",
                        lpad(string(round(r.seconds; digits = 1), "s"), 6), "  ",
                        memory_text(memory, r.file), "\n"; color = :green
                    )
                else
                    printstyled(
                        stdout, "\n", "="^78, "\n", rpad(r.file, 52),
                        "FAILED ", r.status, "  ", round(r.seconds; digits = 1), "s\n",
                        "="^78, "\n"; bold = true, color = :red
                    )
                    print(stdout, r.output)
                    endswith(r.output, "\n") || println(stdout)
                end
                flush(stdout)
            end
        end
    end
    busy1, total1 = cpu_times()
    total1 > total0 && ((memory.cpus, memory.cpu_busy) = (length(Sys.cpu_info()), (busy1 - busy0) / (total1 - total0)))
    @atomic memory.done = true
    wait(sampler)
    return FileResult[r for r in results if r !== nothing], memory
end

function report_files(results::Vector{FileResult}; memory::Union{Nothing, MemoryLog} = nothing, jobs::Int = 0)
    failed = filter(r -> !r.ok, results)
    println("\n", "="^78)
    printstyled(stdout, "YATF test files\n"; bold = true)
    for r in sort(results; by = r -> -r.seconds)
        printstyled(
            stdout, "  ", rpad(r.file, 24), lpad(round(r.seconds; digits = 1), 7), "s  ",
            memory === nothing ? "" : string(lpad(YATF.Private.fmt_bytes(peak_of(memory, r.file)), 6), "  "),
            r.ok ? "passed" : "FAILED (" * r.status * ")", "\n";
            color = r.ok ? :green : :red
        )
    end
    memory === nothing || print_memory(memory, jobs)
    println("="^78)
    isempty(failed) && return nothing
    # Each file's own detail is above, in its own block. What this adds is which
    # blocks to go and read, so a CI log's last line names them.
    error(
        "YATF: ", length(failed), " of ", length(results), " test files failed: ",
        join((string(r.file, " (", r.status, ")") for r in failed), ", ")
    )
end

# What the files needed, to choose `YATF_TEST_JOBS` from: the largest one, and all
# that were running at once at the suite's peak, against what the machine had; and
# how busy its CPUs were, since memory to spare is no use to a machine without time.
function print_memory(memory::MemoryLog, jobs::Int)
    largest = isempty(memory.peak) ? nothing : argmax(memory.peak)
    parts = String[]
    memory.suite > 0 && push!(parts, string(
        "the files peaked at ", YATF.Private.fmt_bytes(memory.suite), " together, with ",
        memory.suite_files, " of ", jobs, " running"))
    largest === nothing || push!(parts, string(
        "the largest alone at ", YATF.Private.fmt_bytes(memory.peak[largest]), " (", largest, ")"))
    memory.total > 0 && push!(parts, string(
        "the machine at ", YATF.Private.fmt_bytes(memory.machine), " of ", YATF.Private.fmt_bytes(memory.total),
        " (", percent(memory.machine, memory.total), ")"))
    isempty(parts) || println("  memory: ", join(parts, " · "))
    memory.suite > 0 && println("  (a file's figure is its process and its workers, summed: shared pages count twice)")
    memory.cpus > 0 && println("  cpu: the machine's ", memory.cpus, " threads were ",
        round(Int, 100 * memory.cpu_busy), "% busy over the run")
    return nothing
end
