using YATF: prepare, execute, report, Monitor, MemStats, start_monitor!, stop_monitor!,
            set_phase!, PHASE_PRECOMPILE, PHASE_TEST, status_line, print_status_line,
            status_update!, print_memory_summary, fmt_bytes, print_bytes, print_1dp,
            print_int, nitems
using YATF.Platform: process_rss, child_pids, process_tree, machine_memory,
                     platform_selfcheck!, ensure_checked!, PER_PROCESS_OK

@testset "platform bindings" begin
    @testset "self-check" begin
        # Either the vendored accessors agree with an independent source, or they
        # are switched off. What must never happen is trusting a wrong one.
        ok = ensure_checked!()
        @test ok == PER_PROCESS_OK[]
        @test ok isa Bool
    end

    @testset "resident size agrees with Sys.maxrss" begin
        if PER_PROCESS_OK[]
            rss = process_rss(getpid())
            @test rss > 0
            @test rss < 100 * Sys.maxrss()
            @test rss > Sys.maxrss() ÷ 100
            @test process_rss(999999) <= 0          # a pid that is not ours
        end
    end

    @testset "children of this process are found" begin
        if PER_PROCESS_OK[] && !Sys.iswindows()
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

    @testset "machine memory is cgroup-aware and sane" begin
        used, total = machine_memory()
        @test total > 0
        @test 0 <= used <= total
        @test total == Int64(Sys.total_memory())   # already respects cgroup limits
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
            @test st.peak_test_bytes > 0
        end
        out = sprint(print_memory_summary, run.monitor)
        @test occursin("memory", out)
        @test occursin("machine", out)
        if PER_PROCESS_OK[]
            @test occursin("across all YATF processes", out)
            @test occursin("largest single process", out)
            @test occursin("over-count", out)   # the caveat is stated, not hidden
        end
    end

    @testset "precompilation is accounted separately from testing" begin
        p, target = prepare((fixture("Basic.jl"),); workers=1, logs=:issues, monitor=true)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        st = run.monitor.stats
        # Whichever phase the peak fell in, the two are tracked apart.
        @test st.peak_precompile_bytes >= 0
        @test st.peak_test_bytes >= 0
        @test st.peak_total_bytes >= max(st.peak_precompile_bytes, st.peak_test_bytes)
    end

    @testset "the status line says what is happening" begin
        p, target = prepare((fixture("Basic.jl"),); workers=1, logs=:issues, monitor=true)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        line = status_line(run.monitor)
        @test startswith(line, YATF.MARK_INDENT * YATF.MARK_INFO * " w0 | ")
        @test occursin("INFO", line)
        @test occursin("/", line)             # done/total
        @test occursin("failed", line)
        @test occursin("workers", line)
        @test occursin("mem ", line)
        @test occursin("tree max", line)

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
        YATF.running_items!(run.monitor)
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
        @test occursin("\r\e[2K" * YATF.MARK_INDENT * YATF.MARK_INFO, out)
        @test endswith(out, status_line(m))
        # A line that already ends in a newline does not get a second one.
        out2 = String(take!(copy(status_update!(m, "ends in a newline\n"))))
        @test occursin("ends in a newline\n\r\e[2K" * YATF.MARK_INDENT * YATF.MARK_INFO, out2)
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
        @test all(==(YATF.PASSED), run.statuses.state)
        @test stop_monitor!(nothing) === nothing     # stopping a monitor there isn't is fine
    end

    @testset "a report fires on a clock, on a phase change, and near OOM" begin
        p, target = prepare((fixture("Basic.jl"),); workers=1, logs=:issues, monitor=true)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        m = run.monitor

        # Upward through a mark is worth saying; sitting above it is not, and
        # neither is drifting back down.
        @test YATF.crossed_memory_mark!(m, 50.0, 1000.0) == 0
        @test YATF.crossed_memory_mark!(m, 91.0, 1000.0) == 90
        @test YATF.crossed_memory_mark!(m, 93.0, 1000.0) == 0     # still between marks
        @test YATF.crossed_memory_mark!(m, 97.5, 1000.0) == 97    # the highest of 95, 96, 97
        @test YATF.crossed_memory_mark!(m, 99.5, 1000.0) == 99
        @test YATF.crossed_memory_mark!(m, 80.0, 1000.0) == 0

        # Crossing the same mark again says nothing until it has been quiet a
        # while, so a machine breathing across a boundary does not narrate.
        @test YATF.crossed_memory_mark!(m, 96.5, 1010.0) == 0
        @test YATF.crossed_memory_mark!(m, 80.0, 1010.0) == 0
        @test YATF.crossed_memory_mark!(m, 96.5, 1000.0 + YATF.MEMORY_MARK_QUIET + 1) == 96

        # Every mark the run is told to watch is one it can report.
        @test YATF.MEMORY_MARKS == (90, 95, 96, 97, 98, 99)
        @test length(m.mark_said) == length(YATF.MEMORY_MARKS)
    end

    @testset "the memory summary reports totals, not what was running" begin
        p, target = prepare((fixture("Basic.jl"),); workers=1, logs=:issues, monitor=true)
        run = execute(p, target)
        rm(run.logdir; force=true, recursive=true)
        summary = sprint(io -> print_memory_summary(io, run.monitor))
        @test occursin("memory: peak", summary)
        @test occursin("largest single process", summary)
        @test !occursin("running ", summary)
    end

    @testset "the run state records the memory summary" begin
        dir = mktempdir()
        withenv("YATF_RUNSTATE_DIR" => dir) do
            p, target = prepare((fixture("Basic.jl"),); workers=1, logs=:issues, monitor=true)
            run = execute(p, target)
            rm(run.logdir; force=true, recursive=true)
            @test !isempty(YATF.runstate_files(p.root))
            @test YATF.read_run_state(last(YATF.runstate_files(p.root))) !== nothing
        end
    end
end
