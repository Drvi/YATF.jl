using YATF.Private: prepare, execute, report, Monitor, MemStats, start_monitor!, stop_monitor!,
            set_phase!, PHASE_SETUP, PHASE_TEST, PHASE_REPORT,
            phase_stats, phase_peak, phase_seconds, MemStats, RunPhase,
            status_line, print_status_line,
            status_update!, print_memory_summary, fmt_bytes, print_bytes, print_1dp,
            print_int, nitems
using Base.ScopedValues: with
using YATF.Private: printline, with_status_line_off
using YATF.Private.Platform: process_rss, child_pids, process_tree, machine_memory,
                     platform_selfcheck!, ensure_checked!, PER_PROCESS_OK

@testset "platform bindings" begin
    @testset "self-check" begin
        # Either the vendored accessors agree with an independent source, or they
        # are switched off. What must never happen is trusting a wrong one.
        ok = ensure_checked!()
        @test ok == PER_PROCESS_OK[]
        @test ok isa Bool
        # The Windows bindings pass their own check, the child listing included: no
        # other platform's run exercises them.
        Sys.iswindows() && @test ok
    end

    @testset "resident size agrees with Sys.maxrss" begin
        if PER_PROCESS_OK[]
            rss = process_rss(getpid())
            @test rss > 0
            @test rss < 100 * Sys.maxrss()
            @test rss > Sys.maxrss() ÷ 100
            @test process_rss(999999) <= 0          # a pid that is not ours
            # The bounds above only catch a binding that is wildly wrong; `ps`
            # reads the same figure through an interface of its own, in KiB.
            if !Sys.iswindows()
                ps = 1024 * parse(Int, strip(read(`ps -o rss= -p $(getpid())`, String)))
                @test isapprox(process_rss(getpid()), ps; rtol = 0.1)
            end
        end
    end

    @testset "children of this process are found" begin
        # On Windows whatever the self-check decided: the listing is the part of
        # the Windows bindings no other platform's run exercises.
        if PER_PROCESS_OK[] || Sys.iswindows()
            proc = run(`$(Base.julia_cmd()[1]) -e "sleep(30)"`; wait=false)
            try
                pid = Int32(Libc.getpid(proc))
                found = false
                for _ in 1:100
                    pid in child_pids(getpid()) && (found = true; break)
                    sleep(0.05)
                end
                @test found
                @test pid in process_tree([getpid()])
                @test getpid() in process_tree([getpid()])
            finally
                kill(proc, Base.SIGKILL)
            end
        end
    end

    @testset "a process tree is walked from its roots, however the children are listed" begin
        P = YATF.Private.Platform
        # `pid => parent`, as a Windows snapshot lists them: 1 has a line of
        # descendants six deep, 8 is 1's other child, 20 and 21 name each other (a
        # parent's pid reused by its own child's child), 0 names itself, as the
        # System Idle Process does, and 30 is no one's.
        parents = Pair{Int32, Int32}[2 => 1, 3 => 2, 4 => 3, 5 => 4, 6 => 5, 7 => 6, 8 => 1,
                                     20 => 21, 21 => 20, 0 => 0, 30 => 99]
        children = P.children_in(parents)
        @test sort(children(1)) == [2, 8]
        @test children(0) == Int32[]
        @test children(42) == Int32[]
        # Four generations below a root and no further, each process once.
        @test sort(P.process_tree([1]; children)) == [1, 2, 3, 4, 5, 8]
        @test sort(P.process_tree([1]; maxdepth = 1, children)) == [1, 2, 8]
        @test sort(P.process_tree([20]; children)) == [20, 21]
        @test sort(P.process_tree([0]; children)) == [0]
        @test sort(P.process_tree([3, 30]; children)) == [3, 4, 5, 6, 7, 30]
    end

    @testset "the Windows structures have the layout Windows gives them" begin
        # The C layout rules for these fields are the same on every 64-bit
        # platform, so a field moved or resized fails here, and not only where
        # Windows would read the wrong bytes.
        if Sys.WORD_SIZE == 64
            offset(T, f) = fieldoffset(T, findfirst(==(f), fieldnames(T)))
            E = YATF.Private.Platform.ProcessEntry32W
            @test sizeof(E) == 568
            @test offset(E, :pid) == 8
            @test offset(E, :parent_pid) == 32
            @test offset(E, :exe_file) == 44
            B, J = YATFWorkers.JobBasicLimits, YATFWorkers.JobExtendedLimits
            @test sizeof(B) == 64
            @test offset(B, :limit_flags) == 16
            @test offset(B, :scheduling_class) == 60
            @test sizeof(J) == 144
            @test offset(J, :io) == 64
            @test offset(J, :peak_job_memory) == 136
        end
    end

    Sys.iswindows() && @testset "every process is listed with its parent" begin
        ps = YATF.Private.Platform.process_parents_windows()
        @test any(p -> first(p) == getpid(), ps)
        proc = run(`$(Base.julia_cmd()[1]) -e "sleep(30)"`; wait=false)
        try
            child = Int32(Libc.getpid(proc))
            @test (child => Int32(getpid())) in YATF.Private.Platform.process_parents_windows()
        finally
            kill(proc, Base.SIGKILL)
        end
    end

    @testset "machine memory is cgroup-aware and sane" begin
        used, total = machine_memory()
        @test total > 0
        @test 0 <= used <= total
        @test total == Int64(Sys.total_memory())   # already respects cgroup limits
    end

    if Sys.isapple()
        @testset "the machine's memory figure is the one the machine reports" begin
            # `vm_stat` reads the same counters through a different interface, so
            # it is an independent answer. What macOS itself calls memory in use is
            # what is wired, what the compressor holds, and what processes have
            # anonymous; the rest — free, purgeable, file cache — is available.
            function sample()
                pages = Dict{String, Int64}()
                for line in eachline(`vm_stat`)
                    m = match(r"^(.+?):\s+(\d+)\.$", line)
                    m === nothing || (pages[m.captures[1]] = parse(Int64, m.captures[2]))
                end
                in_use = (pages["Pages wired down"] + pages["Pages occupied by compressor"] +
                          pages["Anonymous pages"]) * Int64(ccall(:getpagesize, Cint, ()))
                used, total = machine_memory()
                return used / total, in_use / total
            end
            # Wide enough for the pages that belong to neither side of the split,
            # narrow enough to catch a figure that is answering a different question.
            # The two are read a moment apart while other processes come and go, and
            # on a 7 GiB CI runner two workers exiting in between are more than the
            # margin, so a disagreement counts only if it holds on three tries.
            ours, theirs = sample()
            for _ in 2:3
                isapprox(ours, theirs; atol = 0.05) && break
                ours, theirs = sample()
            end
            @test isapprox(ours, theirs; atol = 0.05)
        end
    end

    @testset "byte formatting" begin
        @test fmt_bytes(0) == "-"
        @test endswith(fmt_bytes(5 * 2^10), "K")
        @test endswith(fmt_bytes(5 * 2^20), "M")
        @test endswith(fmt_bytes(5 * 2^30), "G")
    end
end

@testset "monitor" begin
    @testset "a run records its memory peaks" begin
        p, target = prepare((fixture("Basic.jl"),); workers=2, logs=:issues, monitor=true,
                            monitor_interval=1)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        @test run.monitor !== nothing
        st = run.monitor.stats
        @test st.machine_total > 0
        @test st.machine_peak_used > 0
        if PER_PROCESS_OK[]
            # the whole process tree, so more than this process alone
            @test st.peak_total_bytes >= st.peak_single_bytes > 0
            @test st.nprocs_peak >= 1
            @test phase_peak(st, PHASE_TEST) > 0
        end
        out = sprint(print_memory_summary, run.monitor)
        @test occursin("machine", out)
        if PER_PROCESS_OK[]
            @test occursin("testing", out)
            @test occursin("over-count", out)   # the caveat is stated, not hidden
        end
    end

    @testset "no stage claims more than the run as a whole" begin
        p, target = prepare((fixture("Basic.jl"),); workers=1, logs=:issues, monitor=true)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        st = run.monitor.stats
        # The run-wide peak is still the largest of the stages, and each stage's
        # largest single process is within its own total.
        for phase in instances(RunPhase)
            ps = phase_stats(st, phase)
            @test ps.peak_total <= st.peak_total_bytes
            @test ps.peak_single <= max(ps.peak_total, 0)
        end
        @test st.peak_total_bytes ==
            maximum(ps -> ps.peak_total, st.phases)
    end

    @testset "the status line says what is happening" begin
        p, target = prepare((fixture("Basic.jl"),); workers=1, logs=:issues, monitor=true)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        line = status_line(run.monitor)
        @test startswith(line, YATF.Private.MARK_INFO * " w0" * YATF.Private.FIELD)
        @test occursin("INFO", line)
        @test occursin("/", line)             # done/total
        @test occursin("failed", line)
        @test occursin("workers", line)
        @test occursin("mem ", line)

        # Each memory field says which number it is, and is that number. `w0` was
        # none of the three: it labelled the whole tree summed with the name of one
        # process in it, and `child max` labelled a reading from the newest sample
        # as a record.
        m = run.monitor
        s = m.samples[m.ring_head == 0 ? 1 : m.ring_head]
        if YATF.Private.Platform.PER_PROCESS_OK[] && s.total_rss > 0
            @test occursin(
                "tree mem " * sprint(io -> print_bytes(io, s.total_rss, YATF.Private.TOTAL_WIDTH)), line
            )
            @test occursin(
                "(max " * sprint(io -> print_bytes(io, m.stats.peak_total_bytes)) * ")",
                line
            )
            @test occursin(
                "child max " * sprint(io -> print_bytes(io, m.stats.peak_single_bytes, YATF.Private.TOTAL_WIDTH)),
                line
            )
            # A sum is at least its largest term, so the same holds of the peaks,
            # and a peak is at least the reading it was taken from.
            @test s.total_rss >= s.largest_rss
            @test m.stats.peak_total_bytes >= m.stats.peak_single_bytes
            @test m.stats.peak_total_bytes >= s.total_rss
        end
        @test count("w0", line) == 1        # the speaker, and no longer a field label

        # It is redrawn after every line the run prints, so it must not allocate to
        # do it: this is the one place in the run where formatting is on the hot path.
        # The steady-state cost. The clock is reformatted when the second turns,
        # which is one allocation a second however often the line is drawn, so the
        # measurement is over several draws.
        buf = IOBuffer()
        print_status_line(buf, run.monitor)
        draws = map(1:8) do _
            truncate(buf, 0)
            @allocated print_status_line(buf, run.monitor)
        end
        @test minimum(draws) == 0

        # The list of running items is refilled in place rather than rebuilt.
        before = run.monitor.running
        YATF.Private.running_items!(run.monitor)
        @test run.monitor.running === before
    end

    @testset "a printed line and the status line are one update" begin
        p, target = prepare((fixture("Basic.jl"),); workers=1, logs=:issues, monitor=true)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        m = run.monitor
        out = String(take!(copy(status_update!(m, "a line of output"))))
        # Erase, the line, then the status line again — assembled whole, because
        # three separate writes are what makes a busy run flicker.
        @test startswith(out, "\r\e[2K" * "a line of output" * "\n")
        @test occursin("\r\e[2K" * YATF.Private.MARK_INFO, out)
        @test endswith(out, status_line(m))
        # A line that already ends in a newline does not get a second one.
        out2 = String(take!(copy(status_update!(m, "ends in a newline\n"))))
        @test occursin("ends in a newline\n\r\e[2K" * YATF.Private.MARK_INFO, out2)
        @test !occursin("\n\n", out2)
    end

    @testset "numbers are written without formatting a string first" begin
        for n in (0, 7, 99, 1234, -42)
            @test sprint(io -> print_int(io, n)) == string(n)
            @test sprint(io -> print_int(io, n, 8)) == lpad(string(n), 8)
        end
        for b in (0, 1, 5 * 2^10, 2^20, 5 * 2^20, 2^30, 3 * 2^30 + 2^29, 123 * 2^30)
            plain = fmt_bytes(b)
            @test sprint(io -> print_bytes(io, b)) == plain
            # The padding is computed from the digits it is about to write, so the
            # two can never disagree about the width.
            @test sprint(io -> print_bytes(io, b, 7)) == lpad(plain, 7)
        end

        # No figure is ever four digits wide: a column that is three digits except
        # occasionally four is a column that moves.
        for b in vcat(
                [k * 2^10 for k in (1, 500, 999, 1000, 1023)],
                [k * 2^20 for k in (1, 500, 999, 1000, 1004, 1023)],
                [k * 2^30 for k in (1, 9, 12, 99)],
                [7 * 2^30 + 2^29, 64 * 2^30 + 2^28],
            )
            text = fmt_bytes(b)
            @test !occursin(r"[0-9]{4}", text)
            @test last(text) in ('K', 'M', 'G')
        end
        @test fmt_bytes(1004 * 2^20) == "1.0G"     # not "1004M"
        @test fmt_bytes(999 * 2^20) == "999M"
        # Binary, as the `GiB` spelled out elsewhere in a run is: 2^30 to the G.
        @test fmt_bytes(2^30) == "1.0G"
        @test fmt_bytes(2 * 2^30) == "2.0G"
        for x in (0.0, 1.0, 2.75, 17.25, -3.5)
            @test parse(Float64, sprint(io -> print_1dp(io, x))) == round(10x) / 10
            @test length(sprint(io -> print_1dp(io, x, 7))) == 7
        end
        # None of them builds a string on the way: the status line writes three of
        # these on every line a run prints.
        io = IOBuffer()
        gib() = print_bytes(io, 3.5 * 2^30, 5)
        dec() = print_1dp(io, 2.75, 5)
        int() = print_int(io, 1234, 6)
        for f in (gib, dec, int)
            f()
            truncate(io, 0)
            @test @allocated(f()) == 0
            truncate(io, 0)
        end
    end

    @testset "monitor=false runs without one" begin
        p, target = prepare((fixture("Basic.jl"),); workers=1, logs=:issues, monitor=false)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        @test run.monitor === nothing
        @test all(==(YATF.Private.PASSED), run.statuses.state)
        @test stop_monitor!(nothing) === nothing     # stopping a monitor there isn't is fine
    end

    @testset "a report fires on a clock, on a phase change, and near OOM" begin
        p, target = prepare((fixture("Basic.jl"),); workers=1, logs=:issues, monitor=true)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        m = run.monitor

        # Upward through a mark is worth saying; sitting above it is not, and
        # neither is drifting back down.
        @test YATF.Private.crossed_memory_mark!(m, 50.0, 1000.0) == 0
        @test YATF.Private.crossed_memory_mark!(m, 91.0, 1000.0) == 90
        @test YATF.Private.crossed_memory_mark!(m, 93.0, 1000.0) == 0     # still between marks
        @test YATF.Private.crossed_memory_mark!(m, 97.5, 1000.0) == 97    # the highest of 95, 96, 97
        @test YATF.Private.crossed_memory_mark!(m, 99.5, 1000.0) == 99
        @test YATF.Private.crossed_memory_mark!(m, 80.0, 1000.0) == 0

        # Crossing the same mark again says nothing until it has been quiet a
        # while, so a machine breathing across a boundary does not narrate.
        @test YATF.Private.crossed_memory_mark!(m, 96.5, 1010.0) == 0
        @test YATF.Private.crossed_memory_mark!(m, 80.0, 1010.0) == 0
        @test YATF.Private.crossed_memory_mark!(m, 96.5, 1000.0 + YATF.Private.MEMORY_MARK_QUIET + 1) == 96

        # Every mark the run is told to watch is one it can report.
        @test YATF.Private.MEMORY_MARKS == (90, 95, 96, 97, 98, 99)
        @test length(m.mark_said) == length(YATF.Private.MEMORY_MARKS)
    end

    @testset "the memory guard holds work back, then collects, then restarts, then lets go" begin
        # Fed readings rather than a machine short of memory: what it does depends
        # only on what the readings say and for how long they have said it.
        p, target = prepare((fixture("Basic.jl"),); workers=0, logs=:issues, monitor=false)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        m = Monitor(run)
        limit = p.cfg.memory_threshold
        function reading(pressure)
            m.samples[1] = YATF.Private.Sample(
                1.0f0, PHASE_TEST, Int16(1), Int16(0), 0, 0, Int32(0),
                round(Int64, pressure * 2^30), Int64(2^30), 0.0f0
            )
            m.ring_head = 1
        end
        reading(limit / 2)
        YATF.Private.guard!(m)
        @test !YATF.Private.is_paused(run.queues)
        reading(min(1.0, limit + 0.02))
        release = round(Int, 100 * (limit - YATF.Private.GUARD_HYSTERESIS))
        @test_logs (:warn, Regex("holding off on new test items until it is below $release%")) YATF.Private.guard!(m)
        @test YATF.Private.is_paused(run.queues)
        # Dipping under the threshold is not enough to let go: a machine hovering on
        # it would take and release the hold at every sample.
        reading(limit - YATF.Private.GUARD_HYSTERESIS / 2)
        @test_logs YATF.Private.guard!(m)
        @test YATF.Private.is_paused(run.queues)
        @test m.stats.guard_actions == 1
        reading(min(1.0, limit + 0.02))
        # Still over once holding back has had its chance: collect.
        m.over_since = time() - YATF.Private.GUARD_BACKPRESSURE_SECONDS - 1
        YATF.Private.guard!(m)
        @test m.stats.guard_actions == 2
        # Still over after that: restart a worker, and not again within the minute.
        m.over_since = time() - YATF.Private.GUARD_GC_SECONDS - 1
        YATF.Private.guard!(m)
        @test m.stats.guard_actions == 3
        YATF.Private.guard!(m)
        @test m.stats.guard_actions == 3
        # Well below it, the hold ends, and the run says so.
        reading(limit / 2)
        _, out = capture_run(() -> YATF.Private.guard!(m))
        @test !YATF.Private.is_paused(run.queues)
        @test occursin("memory is down to $(round(Int, 50 * limit))%; no longer holding off on new test items", out)
    end

    @testset "the memory guard restarts a worker between items, and stops no item" begin
        # Asked while the worker is running an item: the item finishes and passes,
        # and the next one gets a fresh process.
        ready = joinpath(mktempdir(), "ready")
        dir = make_pkg("GuardRecycle", "test/t_test.jl" => """
            @testitem "holds the worker" begin
                touch($(repr(ready)))
                sleep(2)
                @test true
            end
            @testitem "runs after" begin
                @test true
            end
            """)
        (states, run, p), out = capture_run() do
            task = @async run_states(dir; workers=1, logs=:issues, monitor=false)
            deadline = time() + 300
            while !isfile(ready) && !istaskdone(task) && time() < deadline
                sleep(0.05)
            end
            YATF.Private.recycle_biggest_worker!(Monitor(YATF.Private.LIVE_RUN[]))
            fetch(task)
        end
        @test states["holds the worker"] === YATF.Private.PASSED
        @test states["runs after"] === YATF.Private.PASSED
        pid(name) = run.statuses.pid[findfirst(==(name), p.items.name)]
        @test pid("holds the worker") != pid("runs after")
        @test occursin("restarting w1 (pid $(pid("holds the worker"))", out)
        @test occursin("once its item is done", out)
        @test occursin(Regex("EXIT · pid $(pid("holds the worker")) · 1 item · .* · restarted by the memory guard"), out)
    end

    @testset "a run with no workers does not talk about workers" begin
        (_, run, _), out = capture_run() do
            run_states(fixture("Basic.jl"); workers=0, logs=:issues, monitor=true,
                       monitor_interval=1)
        end
        item_lines = filter(l -> occursin("· START", l) || occursin("· DONE", l),
                            collect(eachsplit(out, '\n')))
        @test !isempty(item_lines)
        # The glyph is still there — it is how a line is read at a glance — but
        # there is no worker to number.
        @test all(item_lines) do l
            any(m -> startswith(l, m * " "), (YATF.Private.MARK_RUNNING, YATF.Private.MARK_PASSED, YATF.Private.MARK_FAILED, YATF.Private.MARK_SET_ASIDE, YATF.Private.MARK_ITEM, YATF.Private.MARK_WORKER))
        end
        @test !any(l -> occursin(r" w\d+ · ", l), item_lines)

        # Asked for directly rather than waited for: whether a periodic report
        # lands inside a two-second run depends on how busy the machine is, and
        # what is being checked here is the shape of one, not its timing.
        info = status_line(run.monitor)
        @test startswith(info, YATF.Private.MARK_INFO * " ")
        @test !occursin("w0", info)
        @test !occursin("workers", info)
        # One process, so one memory figure and its peak, not three names for it.
        @test occursin("rss ", info)
        @test occursin("max ", info)
        @test !occursin("tree", info)
        @test !occursin("child", info)

        # ...and the same in the summary.
        summary = sprint(io -> print_memory_summary(io, run.monitor))
        @test occursin("testing", summary)
        @test !occursin("across all YATF processes", summary)
        @test !occursin("largest single process", summary)
    end

    @testset "a count is pluralised correctly even when adding an s would not" begin
        @test YATF.Private.plural(1, "worker") == "1 worker"
        @test YATF.Private.plural(2, "worker") == "2 workers"
        @test YATF.Private.plural(1, "process", "processes") == "1 process"
        @test YATF.Private.plural(2, "process", "processes") == "2 processes"
    end

    @testset "a dead worker's memory is its own" begin
        p, target = prepare((fixture("Basic.jl"),); workers=1, logs=:issues, monitor=true)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        m = run.monitor
        r = @atomic m.reading
        @atomic m.reading = YATF.Private.Reading(r.sample, r.peak_total, r.peak_single, r.phase_entered,
                                                 [Int64(3) << 30], Int32[4242])
        note(pid) = YATF.Private.memory_note(m, 1, pid)
        @test occursin("peak rss $(fmt_bytes(Int64(3) << 30))", note(4242))
        # A worker that died before a sample saw it is not given the peak of the
        # one before it in the slot.
        @test !occursin("peak rss", note(4243))
    end

    @testset "a stage lasts until the next one starts" begin
        st = MemStats()
        # Nothing entered: nothing to report, and no negative durations.
        for phase in instances(RunPhase)
            @test phase_seconds(st, phase, 100.0) == 0.0
            @test phase_peak(st, phase) == 0
        end
        @atomic phase_stats(st, PHASE_SETUP).entered = 10.0
        @atomic phase_stats(st, PHASE_TEST).entered = 20.0
        @test phase_seconds(st, PHASE_SETUP, 100.0) == 10.0
        # The last stage entered runs until the run ends.
        @test phase_seconds(st, PHASE_TEST, 100.0) == 80.0
        # One never entered stays at nothing even with others around it.
        @test phase_seconds(st, PHASE_REPORT, 100.0) == 0.0
        # A finish before the stage began is a duration of zero, not a negative.
        @test phase_seconds(st, PHASE_TEST, 5.0) == 0.0
    end

    @testset "a sample counts against the stage it was taken in" begin
        p, target = prepare((fixture("Basic.jl"),); workers=1, logs=:issues, monitor=true)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        m = run.monitor
        st = m.stats
        for ps in st.phases
            ps.peak_total = 0; ps.peak_single = 0; ps.nprocs_at_peak = 0; ps.starts = 0
        end
        sample(phase, total, largest, n, workers = 0) =
            YATF.Private.Sample(1.0f0, phase, Int16(n), Int16(workers), Int64(total), Int64(largest),
                        Int32(1), Int64(0), Int64(0), 1.0f0)
        YATF.Private.update_stats!(m, sample(PHASE_SETUP, 800, 500, 2))
        YATF.Private.update_stats!(m, sample(PHASE_TEST, 3000, 700, 9, 8))
        YATF.Private.update_stats!(m, sample(PHASE_TEST, 2000, 900, 5, 4))
        @test phase_peak(st, PHASE_SETUP) == 800
        @test phase_peak(st, PHASE_TEST) == 3000        # the larger of the two
        @test phase_stats(st, PHASE_TEST).peak_single == 900
        # The count belongs to the sample that set the peak, so that the two read
        # together. A later sample with more processes and a smaller total is a
        # different moment and does not contribute its count to this one.
        @test phase_stats(st, PHASE_TEST).nprocs_at_peak == 9
        @test phase_stats(st, PHASE_TEST).workers_at_peak == 8
        YATF.Private.update_stats!(m, sample(PHASE_TEST, 2500, 400, 40, 8))
        @test phase_stats(st, PHASE_TEST).nprocs_at_peak == 9
        # ...and a larger total brings its own counts with it.
        YATF.Private.update_stats!(m, sample(PHASE_TEST, 4000, 400, 3, 2))
        @test phase_stats(st, PHASE_TEST).nprocs_at_peak == 3
        @test phase_stats(st, PHASE_TEST).workers_at_peak == 2
        # A stage that saw no sample keeps nothing from the others.
        @test phase_peak(st, PHASE_REPORT) == 0
    end

    @testset "a stage's processes are the coordinator, its workers and what they spawned" begin
        text(n, workers) = YATF.Private.procs_text(YATF.Private.PhaseStats(; nprocs_at_peak = n, workers_at_peak = workers))
        @test text(12, 8) == "coordinator + 8 workers + 3 spawned"
        @test text(9, 8) == "coordinator + 8 workers"
        @test text(2, 1) == "coordinator + 1 worker"
        # Setup has no workers; what it spawns is the precompiling.
        @test text(1, 0) == "coordinator"
        @test text(2, 0) == "coordinator + 1 spawned"
    end

    @testset "the summary reports each stage the run went through" begin
        p, target = prepare((fixture("Basic.jl"),); workers=2, logs=:issues, monitor=true)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        st = run.monitor.stats
        summary = sprint(io -> print_memory_summary(io, run.monitor))

        # Every stage the run entered is stamped, and the ones it went through
        # have a line of their own.
        @test phase_stats(st, PHASE_SETUP).entered > 0
        @test phase_stats(st, PHASE_TEST).entered >
            phase_stats(st, PHASE_SETUP).entered
        @test occursin("setup", summary)
        @test occursin("testing", summary)
        @test occursin("tree max", summary)
        @test occursin("child max", summary)
        @test occursin("% compile", summary)
        # Testing starts the workers, so it is the expensive stage.
        @test phase_peak(st, PHASE_TEST) >= phase_peak(st, PHASE_SETUP)
        @test phase_stats(st, PHASE_TEST).nprocs_at_peak >=
            phase_stats(st, PHASE_SETUP).nprocs_at_peak
        # The workers are counted as workers, in the stage that ran them.
        testing = only(filter(l -> occursin("testing", l), collect(eachsplit(summary, '\n'))))
        @test occursin("coordinator + 2 workers", testing)
        @test !occursin(r"over \d+ process", summary)

        # The single run-wide peak it used to lead with is gone: the stages say it.
        @test !occursin("largest single process", summary)
        @test !occursin("across all YATF processes", summary)
        @test !occursin("by phase", summary)
        # The caveat about shared pages survives, once.
        @test count("over-count", summary) == 1
        @test occursin("machine", summary)

        # Only the stage that runs items can have a compile share.
        compile_lines = filter(l -> occursin("% compile", l), collect(eachsplit(summary, '\n')))
        @test length(compile_lines) == 1
        @test occursin("testing", only(compile_lines))
    end

    @testset "replacing workers is reported, reusing them is not" begin
        # Peak concurrency cannot show process churn: a sandbox worker replaces a
        # pool worker in the same slot, so a run that starts a process per item
        # never has more alive at once than one that starts none.
        dir = make_pkg("ChurnSummary", "test/t_test.jl" => string(
            ("""
            @testitem "solo $i" sandbox=true begin
                @test true
            end
            """ for i in 1:4)...
        ))
        p, target = prepare((dir,); workers=1, logs=:issues, monitor=true)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        st = run.monitor.stats
        @test phase_stats(st, PHASE_TEST).starts == 4
        @test phase_stats(st, PHASE_TEST).nprocs_at_peak <= 2   # the run and one worker
        summary = sprint(io -> print_memory_summary(io, run.monitor))
        @test occursin("4 worker starts", summary)

        # A suite that reuses its worker says nothing about starts: that number
        # would be the worker count again, under another name.
        p2, target2 = prepare((fixture("Basic.jl"),); workers=1, logs=:issues, monitor=true)
        run2 = execute(p2, target2)
        rm(run2.logdir; force=true, recursive=true)
        @test phase_stats(run2.monitor.stats, PHASE_TEST).starts == 1
        @test !occursin("worker start", sprint(io -> print_memory_summary(io, run2.monitor)))
    end

    @testset "a run with no workers reports stages without process counts" begin
        p, target = prepare((fixture("Basic.jl"),); workers=0, logs=:issues, monitor=true)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        # A sample of its own: a short run on a busy machine can finish between
        # two of the monitor's, and what is under test here is the shape of the
        # line, not whether one happened to land.
        YATF.Private.update_stats!(run.monitor,
            YATF.Private.Sample(1.0f0, PHASE_TEST, Int16(1), Int16(0), Int64(500_000_000), Int64(500_000_000),
                        Int32(getpid()), Int64(0), Int64(0), 1.0f0))
        summary = sprint(io -> print_memory_summary(io, run.monitor))
        @test occursin("testing", summary)
        @test occursin("rss ", summary)
        # One process, so nothing to total and nothing to compare against.
        @test !occursin("tree max", summary)
        @test !occursin("child max", summary)
        @test !occursin("processes", summary)
        @test !occursin("coordinator", summary)
        @test !occursin("over-count", summary)
    end

    @testset "precompiling a setup is measured as its own stage" begin
        # A module nothing has compiled before, so the stage actually runs and
        # spawns the process that does the compiling. Its top level runs while it
        # compiles, and the pause there keeps that process alive for several of the
        # monitor's samples: compiling it alone can take less than one interval.
        dir = make_pkg("ColdStage")
        setup = string("Cold", string(hash(dir); base=16))
        mkpath(joinpath(dir, "test", "testsetups"))
        write(joinpath(dir, "test", "testsetups", setup * ".jl"),
              "module $setup
" * join(["f$i(x) = x + $i" for i in 1:200], "
") * "
sleep(1)
end
")
        write(joinpath(dir, "test", "a_test.jl"), """
        @testitem "uses it" begin
            using $setup
            @test $setup.f1(1) == 2
        end
        """)
        p, target = prepare((dir,); workers=1, logs=:issues, monitor=true)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        st = run.monitor.stats
        # The process doing the compiling is in the tree and counted there, in
        # the setup stage that spawned it: some sample of that stage has it, though
        # not necessarily the one that set the stage's peak, which can come after it
        # has gone. Windows lists no child processes.
        Sys.iswindows() || @test any(s -> s.phase === PHASE_SETUP && s.nprocs >= 2, run.monitor.samples)
        @test phase_peak(st, PHASE_SETUP) > 0
        summary = sprint(io -> print_memory_summary(io, run.monitor))
        @test occursin("setup", summary)
    end

    @testset "the memory summary reports totals, not what was running" begin
        p, target = prepare((fixture("Basic.jl"),); workers=1, logs=:issues, monitor=true)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        summary = sprint(io -> print_memory_summary(io, run.monitor))
        @test occursin("testing", summary)
        @test occursin("tree max", summary)
        # What was running at the peak was never the useful part; which stage the
        # peak fell in is, and each stage has its own line now.
        @test !occursin("running ", summary)
    end

    @testset "the run state records the memory summary" begin
        dir = mktempdir()
        withenv("YATF_RUNSTATE_DIR" => dir) do
            p, target = prepare((fixture("Basic.jl"),); workers=1, logs=:issues, monitor=true)
            run = execute(p, target)
            rm(run.logdir; force=true, recursive=true)
            @test !isempty(YATF.Private.runstate_files(p.root))
            @test YATF.Private.read_run_state(last(YATF.Private.runstate_files(p.root))) !== nothing
        end
    end
end

@testset "the status line and a second writer" begin
    @testset "withdrawing the line is restored even when the body throws" begin
        p, target = prepare((fixture("Basic.jl"),); workers=0, logs=:issues, monitor=true)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        m = run.monitor
        @test YATF.Private.with_status_line_off(m) do
            m.quiet
        end
        @test !m.quiet
        @test_throws ErrorException YATF.Private.with_status_line_off(m) do
            error("boom")
        end
        @test !m.quiet
        # No monitor at all is the common case in these tests, and the body still
        # runs and still returns what it returned.
        @test YATF.Private.with_status_line_off(nothing) do
            :ran
        end === :ran
    end

    @testset "the status line never outgrows one row" begin
        # `\r\e[2K` erases the row the cursor is on. A line wider than the terminal
        # wraps onto several, so the next redraw would leave all but its last row
        # behind.
        p, target = prepare((fixture("Basic.jl"),); workers=2, logs=:issues, monitor=false)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        plain(s) = replace(s, r"\e\[[0-9;?]*[a-zA-Z]" => "")
        drawn(cols) = withenv("COLUMNS" => string(cols)) do
            with(YATF.Private.TTY_OVERRIDE => true) do
                run.monitor = Monitor(run)
                @test run.monitor.columns == cols
                out = String(take!(copy(status_update!(run.monitor, "x"))))
                out[findlast("\r\e[2K", out).stop + 1:end]
            end
        end
        for cols in (200, 100, 60, 30, 12)
            line = drawn(cols)
            @test textwidth(plain(line)) <= cols
            # Cut between characters, not through one: a half-written glyph is
            # what a byte-count truncation would leave.
            @test isvalid(line)
        end
        # Wide enough for the whole line, and it is not cut at all.
        @test textwidth(plain(drawn(400))) == textwidth(plain(drawn(0)))

        # In colour: the escape codes take no columns and are kept or cut whole, and
        # a line cut inside a colour still ends by resetting it.
        fits(s, cols) = YATF.Private.bytes_within(codeunits(s), 1, ncodeunits(s), cols)
        @test fits("abcdef", 4) == 4
        @test fits("\e[32mabcdef\e[0m", 4) == ncodeunits("\e[32mabcd")
        @test fits("\e[1;32mab\e[0mcdef", 4) == ncodeunits("\e[1;32mab\e[0mcd")
        @test fits("ab\e[32m", 4) == ncodeunits("ab\e[32m")
        m = withenv(() -> with(() -> Monitor(run), YATF.Private.TTY_OVERRIDE => true), "COLUMNS" => "4")
        truncate(m.linebuf, 0)
        print(m.linebuf, "\e[32mabcdef\e[0m")
        YATF.Private.clip_status!(m, 0)
        @test String(take!(m.linebuf)) == "\e[32mabcd\e[0m"
    end

    @testset "a run that throws before its first item takes the line down" begin
        # `stop_monitor!` used to be reached only on the way out of the test phase,
        # so a run that fell over before that — a setup that will not compile, an
        # environment that will not resolve — left the line pinned, and whatever
        # printed the error wrote on top of it.
        dir = make_pkg("SetupThrows")
        setup = string("Boom", string(hash(dir); base=16))
        mkpath(joinpath(dir, "test", "testsetups"))
        write(joinpath(dir, "test", "testsetups", setup * ".jl"),
              "module $setup\nerror(\"this setup refuses to compile\")\nend\n")
        write(joinpath(dir, "test", "a_test.jl"), """
        @testitem "uses it" begin
            using $setup
            @test true
        end
        """)
        thrown, out = capture_run() do
            with(YATF.Private.TTY_OVERRIDE => true) do
                try
                    p, target = prepare((dir,); workers=1, logs=:issues, monitor=true)
                    execute(p, target)
                    nothing
                catch e
                    e
                end
            end
        end
        @test thrown isa YATF.ConfigError
        @test occursin("failed to precompile", sprint(showerror, thrown))
        # Taking the monitor down erases what it had drawn, so the last thing on
        # the terminal is the erase and not half a status line.
        @test endswith(out, "\r\e[2K")
    end

    @testset "a warning from the monitor's own task gets a line of its own" begin
        # The monitor's task warns when memory runs short, and the run starts it
        # before its own logger is in place. Written as the process's logger writes,
        # the warning went to stderr and continued the status line just drawn.
        p, target = prepare((fixture("Basic.jl"),); workers=0, logs=:issues, monitor=false,
                            memory_threshold=0.001)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        _, out = capture_run() do
            with(YATF.Private.TTY_OVERRIDE => true) do
                m = run.monitor = Monitor(run)
                # Every machine has more than a thousandth of its memory in use, so
                # the first sample warns.
                start_monitor!(m)
                timedwait(() -> m.stats.guard_actions > 0, 30.0)
                stop_monitor!(m)
            end
        end
        at = findfirst("Warning: YATF: memory is at", out)
        @test at !== nothing
        if at !== nothing
            # What is on the warning's row before it: the status line was drawn
            # there, and it must have been erased, leaving nothing visible.
            row = out[something(findprev(==('\n'), out, at.start), 0) + 1:prevind(out, at.start)]
            left = last(split(row, "\r\e[2K"))
            @test isempty(replace(left, r"\e\[[0-9;]*m" => "", "┌ " => "", r"\s" => ""))
        end
    end

    @testset "what is written once the monitor stops starts its own row" begin
        # A stopped monitor draws nothing, so `printline` no longer erases before it
        # writes: stopping has to take the line down in the same step. A writer that
        # goes the moment it sees the stop is what a slow machine's warning did.
        p, target = prepare((fixture("Basic.jl"),); workers=0, logs=:issues, monitor=false)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        _, out = capture_run() do
            with(YATF.Private.TTY_OVERRIDE => true) do
                m = run.monitor = Monitor(run)
                start_monitor!(m)
                timedwait(() -> m.last_print > 0, 30.0)   # the line is up
                writer = Threads.@spawn begin
                    while !(@atomic m.stop)
                        yield()
                    end
                    printline(run, "WRITTEN")
                end
                stop_monitor!(m)
                wait(writer)
            end
        end
        at = findfirst("WRITTEN", out)
        @test at !== nothing
        if at !== nothing
            row = out[something(findprev(==('\n'), out, at.start), 0) + 1:prevind(out, at.start)]
            @test isempty(replace(last(split(row, "\r\e[2K")), r"\e\[[0-9;]*m" => "", r"\s" => ""))
        end
    end

    @testset "nothing is drawn while the line is withdrawn" begin
        # The drawing path exists only on a terminal, and a test suite's output is
        # a pipe; `TTY_OVERRIDE` is how it is reached without arranging one.
        p, target = prepare((fixture("Basic.jl"),); workers=0, logs=:issues, monitor=false)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        _, out = capture_run() do
            with(YATF.Private.TTY_OVERRIDE => true) do
                # Not started: the sampling task would draw on its own clock, and
                # what is under test is what the printing path does.
                run.monitor = Monitor(run)
                run.monitor.tty || error("the override did not reach the monitor")
                printline(run, "OUTSIDE")
                with_status_line_off(run.monitor) do
                    printline(run, "INSIDE")
                end
            end
        end
        @test occursin("OUTSIDE", out)
        @test occursin("INSIDE", out)
        # A line printed with the status line up carries it along; the same call
        # inside the withdrawal writes the line and stops there.
        after_outside = out[findfirst("OUTSIDE", out).stop:findfirst("INSIDE", out).start]
        after_inside = out[findfirst("INSIDE", out).stop:end]
        @test occursin(YATF.Private.MARK_INFO, after_outside)
        @test !occursin(YATF.Private.MARK_INFO, after_inside)
    end
end
