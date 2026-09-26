# Watching the machine while the tests run: how much memory *we* use, where, and
# when it was worst. Peaks are recorded as they happen, so a run that dies still
# leaves the answer behind. Best effort: if the monitor throws, it switches itself
# off, says so once, and the tests carry on.

using .Platform: process_rss, process_tree, machine_memory, cpu_load, cpu_count,
    cpu_ticks, process_cpu_seconds, ensure_checked!, PER_PROCESS_OK

# The scan is over before the monitor exists. Resolving the environment and
# precompiling are one stage: the same process does both, back to back.
@enum RunPhase::UInt8 begin
    PHASE_SETUP = 0
    PHASE_TEST = 1
    PHASE_REPORT = 2
end

phase_name(p::RunPhase) =
    p === PHASE_SETUP ? "setup" : p === PHASE_TEST ? "testing" : "reporting"

struct Sample
    t::Float32     # seconds since the run started
    phase::RunPhase
    nprocs::Int16    # the whole tree: this process, its workers, and what they started
    nworkers::Int16  # of those, the live workers
    total_rss::Int64       # summed over our whole process tree
    largest_rss::Int64
    largest_pid::Int32
    machine_used::Int64
    machine_total::Int64
    load1::Float32     # one-minute load average
end

Sample() = Sample(0.0f0, PHASE_SETUP, 0, 0, 0, 0, 0, 0, 0, -1.0f0)

# What one stage of a run cost. Per stage because the stages are different
# machines: one process resolving, a few short-lived ones precompiling, and the
# workers testing. `entered` and `starts` are written on the run's thread, the rest
# by the monitor's task; the monitor reads `entered`, so it is atomic, and `starts`
# is read only once the monitor has stopped.
mutable struct PhaseStats
    @atomic entered::Float64   # when the run entered this stage, 0 if it never did
    peak_total::Int64          # summed resident size over our processes
    peak_single::Int64
    # Processes alive at the sample that set `peak_total`, not the most ever alive:
    # maxima from different instants, printed side by side, contradict each other.
    nprocs_at_peak::Int
    workers_at_peak::Int       # of those, the live workers
    # Processes started during this stage. A stage that replaces a worker per item
    # churns through many more than are ever alive together.
    starts::Int
end

PhaseStats(; entered = 0.0, peak_total = 0, peak_single = 0, nprocs_at_peak = 0, workers_at_peak = 0, starts = 0) =
    PhaseStats(entered, peak_total, peak_single, nprocs_at_peak, workers_at_peak, starts)

"""
    CpuReading

The machine's CPU time at one moment: milliseconds its threads have spent busy and
in all since boot, how many threads, this process's and its reaped children's CPU
seconds (-1 where the platform keeps no total for children), and when it was taken.
Two readings give how busy the run kept the machine, and how busy the machine was.
"""
struct CpuReading
    busy_ms::UInt64
    total_ms::UInt64
    threads::Int
    run_s::Float64
    at::Float64
end
CpuReading() = CpuReading(0, 0, 0, -1.0, 0.0)
cpu_reading() = CpuReading(cpu_ticks()..., process_cpu_seconds(), time())

"""
    MemStats

The aggregates worth having after the fact, per stage and for the whole run.
Summed resident sizes over-count the pages processes share (the runtime and every
package image), so a total is an upper bound, and is reported as one.
"""
Base.@kwdef mutable struct MemStats
    # One per `RunPhase`, indexed by `Int(phase) + 1`.
    phases::Vector{PhaseStats} = [PhaseStats() for _ in instances(RunPhase)]
    peak_total_bytes::Int64 = 0
    peak_total_at::Float64 = 0.0
    peak_total_phase::RunPhase = PHASE_SETUP
    peak_single_bytes::Int64 = 0
    peak_single_pid::Int32 = 0
    peak_single_item::String = ""
    nprocs_peak::Int = 0
    machine_peak_used::Int64 = 0
    machine_total::Int64 = 0
    guard_actions::Int = 0
    # Taken on the run's thread: the first before the monitor's task starts, the
    # second once it has stopped and the workers have exited and been reaped.
    cpu_start::CpuReading = CpuReading()
    cpu_end::CpuReading = CpuReading()
end

phase_stats(st::MemStats, p::RunPhase) = st.phases[Int(p) + 1]

"""
    phase_peak(stats, phase) -> Int

The peak summed resident size while the run was in `phase`, or 0 if it never was.
"""
phase_peak(st::MemStats, p::RunPhase) = phase_stats(st, p).peak_total

"""
    phase_seconds(stats, phase, finish) -> Float64

How long the run spent in `phase`: a stage ends when the next one begins, and the
last at `finish`. A run only moves forward, so one stamp per stage cannot disagree
with another.
"""
function phase_seconds(st::MemStats, p::RunPhase, finish::Float64)
    entered = phase_stats(st, p).entered
    entered == 0 && return 0.0
    ends = finish
    for other in st.phases
        other.entered > entered && other.entered < ends && (ends = other.entered)
    end
    return max(0.0, ends - entered)
end

const RING_SAMPLES = 300      # 60 s of history at 5 Hz, allocated once

"""
    Reading

What the monitor has measured, as of its newest sample, for readers on other
threads: the status line, which whoever prints redraws, and the report of a worker
that died. Built whole by the monitor's task and published through one atomic
field, so a reader sees one sample's figures together; the ring, the statistics and
the peaks it is built from stay the monitor's own.
"""
struct Reading
    sample::Sample
    peak_total::Int64            # the run's peak, summed over its processes
    peak_single::Int64           # the largest any one of them has been
    phase_entered::Float64       # when the sample's stage began
    worker_peak::Vector{Int64}   # per slot, the largest its worker was sampled at; a copy
    worker_pid::Vector{Int32}    # and whose peak that is; a copy
end

mutable struct Monitor
    # `Run` is defined after this, so the field cannot name its type; `run_of`
    # restores it, or every access from the sampling loop is a dynamic lookup.
    const run::Any
    const stats::MemStats
    const samples::Vector{Sample}
    ring_head::Int
    # See `Reading`: the only way into what the monitor measures from another thread.
    @atomic reading::Reading
    task::Union{Nothing, Task}
    @atomic stop::Bool
    # Something else owns the terminal for a moment; sampling carries on, drawing
    # does not.
    @atomic quiet::Bool
    @atomic phase::RunPhase
    @atomic enabled::Bool
    const interval::Float64
    const print_interval::Float64
    const tty::Bool
    # The terminal's width, or 0 when nothing is drawn. Erasing a line that wrapped
    # leaves all but its last row behind, so the status line is clipped to this.
    # Refreshed with the clock.
    columns::Int
    # Scratch for the status line's list of running items, refilled rather than
    # rebuilt: on a terminal the line is redrawn after every line the run prints.
    # There it is only touched under `run.printer`, which every redraw holds; off a
    # terminal only the monitor's task builds the line.
    const running::Vector{String}
    # Per slot, the largest resident size sampled for its current process, and that
    # process's pid: a new pid starts a new peak. The monitor's task alone writes
    # both; others read the peaks through `reading`.
    const worker_peak::Vector{Int64}
    const worker_pid::Vector{Int32}
    # Where the status line is assembled, reused for the same reason. `lineio`
    # carries the colour setting into it: written to the buffer directly, every
    # `printstyled` in the line would come out plain.
    const linebuf::IOBuffer
    const lineio::IO
    const color::Bool
    # `strftime` builds a string per call and the clock moves once a second, while
    # this line is redrawn after every line the run prints. Touched as `running` is.
    clock_at::Int
    clock_text::String
    last_print::Float64
    next_print::Float64      # when the next scheduled report is due
    last_mem_pct::Float64    # the machine's memory at the previous check
    const mark_said::Vector{Float64}   # when each of MEMORY_MARKS last reported
    last_phase_printed::RunPhase
    over_since::Float64      # when machine pressure first crossed the threshold
    last_gc::Float64
    last_restart::Float64
end

"""
    TTY_OVERRIDE

What [`is_tty`](@ref) answers when a test has decided: the drawing path exists
only on a terminal, and a test suite's output is a pipe.
"""
const TTY_OVERRIDE = ScopedValue{Union{Nothing, Bool}}(nothing)

# `displaysize` falls back to `COLUMNS` when the stream is not a terminal, which is
# how a test says how wide to pretend the screen is.
terminal_columns(tty::Bool) = tty ? displaysize(stdout)[2] : 0

"""
    is_tty() -> Bool

Whether the run should draw a line that rewrites itself: that needs a terminal to
rewrite it and a reader watching. A pipe, a log file or a CI job gets the line
printed periodically instead.
"""
function is_tty()
    forced = TTY_OVERRIDE[]
    forced === nothing || return forced
    return stdout isa Base.TTY && !haskey(ENV, "CI") && get(ENV, "TERM", "") != "dumb"
end

function Monitor(run; interval = 0.2, print_interval = 30.0)
    tty = is_tty()
    color = get(stdout, :color, false)::Bool
    linebuf = IOBuffer()
    # The run is already in its first stage by the time it has a monitor — nothing
    # calls `set_phase!` to enter the one it starts in.
    stats = MemStats(; cpu_start = cpu_reading())
    entered = time()
    @atomic phase_stats(stats, PHASE_SETUP).entered = entered
    n = nslots(run.plan)
    return Monitor(
        run, stats, fill(Sample(), RING_SAMPLES), 0, Reading(Sample(), 0, 0, entered, zeros(Int64, n), zeros(Int32, n)),
        nothing, false, false,
        PHASE_SETUP, true, interval, print_interval, tty, terminal_columns(tty),
        sizehint!(String[], n), zeros(Int64, n), zeros(Int32, n), linebuf,
        IOContext(linebuf, :color => color), color, 0, "", 0.0, 0.0, 0.0,
        zeros(Float64, length(MEMORY_MARKS)), PHASE_REPORT, 0.0, 0.0, 0.0
    )
end

# Counted rather than sampled: a sandbox worker can live and die between samples.
function count_worker_start!(m::Union{Nothing, Monitor})
    m === nothing && return nothing
    phase_stats(m.stats, @atomic m.phase).starts += 1
    return nothing
end

# What memory looked like when the worker `pid` in a slot was last seen: the largest
# it was sampled at, and the machine at the newest sample. Empty when nothing was
# measured; no peak when that worker died before a sample saw it.
function memory_note(m::Union{Nothing, Monitor}, slot::Integer, pid::Integer)
    m === nothing && return ""
    r = @atomic m.reading
    s = r.sample
    peak = r.worker_pid[slot] == pid ? r.worker_peak[slot] : 0
    return string(
        peak > 0 ? string(" · peak rss ", fmt_bytes(peak)) : "",
        s.machine_total > 0 ? string(" · machine ", round(Int, 100 * s.machine_used / s.machine_total), "% in use") : ""
    )
end

# Stamped by the run's own task as it enters a stage: one writer per field.
function set_phase!(m::Union{Nothing, Monitor}, p::RunPhase)
    m === nothing && return nothing
    @atomic phase_stats(m.stats, p).entered = time()
    @atomic m.phase = p
    return nothing
end

function start_monitor!(m::Monitor)
    try
        ensure_checked!()
    catch e
        is_interrupt(e) && rethrow()
        @warn "YATF: per-process memory accounting is unavailable here" exception = e maxlog = 1
    end
    # A task keeps the logger of the scope that started it, and the monitor starts
    # before the run's own is in place: its warnings go through `printline` whoever
    # starts it, or they land on the status line it draws.
    logger = RunLogger(current_logger(), run_of(m))
    # Shielded: the run stops it, and it watches the run's teardown too.
    m.task = shielded() do
        Threads.@spawn with_logger(logger) do
            try
                monitor_loop(m)
            catch e
                # Ctrl-C, when this was the task its thread last ran: the run is
                # stopping, and needs no monitor to do it.
                is_interrupt(e) && return YATFWorkers.forward_interrupt(e)
                @atomic m.enabled = false
                @warn "YATF: the resource monitor stopped; the run continues without it" exception = e
            end
        end
    end
    return m
end

function stop_monitor!(m::Union{Nothing, Monitor})
    m === nothing && return nothing
    # Stopped and erased in one step under the lock every writer takes. A stopped
    # monitor is not drawing, so `printline` writes without erasing; with the line
    # still up, what the monitor's own task says on its way out would continue it.
    @lock run_of(m).printer begin
        @atomic m.stop = true
        clear_status_line(m)
    end
    m.task === nothing || (
        try
            wait(m.task)
        catch
        end
    )
    return nothing
end

function monitor_loop(m::Monitor)
    while !m.stop
        sample!(m)
        maybe_print(m)
        guard!(m)
        sleep(m.interval)
    end
    sample!(m)
    return nothing
end

# Roots of our process tree: this process, plus every worker it has started and
# not seen end, including one still connecting or shutting down, which no slot holds.
# Their children — `Pkg`'s precompilation workers, anything a test item starts — are
# found from there, because they spend the same memory budget.
function tree_roots(::Monitor)
    roots = Int32[Int32(getpid())]
    append!(roots, YATFWorkers.live_worker_pids())
    return roots
end

function sample!(m::Monitor)
    t = Float32(time() - run_of(m).t0)
    phase = @atomic m.phase
    used, total = machine_memory()
    total_rss = Int64(0); largest = Int64(0); largest_pid = Int32(0); nprocs = 0; nworkers = 0
    if PER_PROCESS_OK[]
        roots = tree_roots(m)
        for pid in process_tree(roots)
            rss = process_rss(pid)
            rss <= 0 && continue
            nprocs += 1
            # Every root but this process is a worker.
            pid != first(roots) && pid in roots && (nworkers += 1)
            total_rss += rss
            rss > largest && ((largest, largest_pid) = (rss, Int32(pid)))
        end
        for slot in run_of(m).slots
            w = @atomic slot.worker
            w === nothing && continue
            pid = Int32(w.pid)
            if m.worker_pid[slot.id] != pid
                m.worker_pid[slot.id] = pid
                m.worker_peak[slot.id] = 0
            end
            rss = process_rss(pid)
            rss > m.worker_peak[slot.id] && (m.worker_peak[slot.id] = rss)
        end
    end
    load1 = Float32(cpu_load())
    s = Sample(t, phase, Int16(nprocs), Int16(nworkers), total_rss, largest, largest_pid, used, total, load1)
    # The sample before the head that points at it: a reader between the two would
    # get the slot's previous contents, a sample from minutes ago.
    head = mod1(m.ring_head + 1, RING_SAMPLES)
    m.samples[head] = s
    m.ring_head = head
    update_stats!(m, s)
    st = m.stats
    @atomic m.reading = Reading(s, st.peak_total_bytes, st.peak_single_bytes,
                                (@atomic phase_stats(st, phase).entered), copy(m.worker_peak), copy(m.worker_pid))
    return s
end

function update_stats!(m::Monitor, s::Sample)
    st = m.stats
    st.machine_total = s.machine_total
    s.machine_used > st.machine_peak_used && (st.machine_peak_used = s.machine_used)
    s.nprocs > st.nprocs_peak && (st.nprocs_peak = Int(s.nprocs))
    if s.total_rss > st.peak_total_bytes
        st.peak_total_bytes = s.total_rss
        st.peak_total_at = Float64(s.t)
        st.peak_total_phase = s.phase
        write_memory!((@atomic run_of(m).runstate), st)
    end
    if s.largest_rss > st.peak_single_bytes
        st.peak_single_bytes = s.largest_rss
        st.peak_single_pid = s.largest_pid
        st.peak_single_item = item_on_pid(m, s.largest_pid)
        write_memory!((@atomic run_of(m).runstate), st)
    end
    # The stages are different memory regimes, and a figure for the whole run
    # hides which of them was the expensive one.
    ps = phase_stats(st, s.phase)
    if s.total_rss > ps.peak_total
        ps.peak_total = s.total_rss
        ps.nprocs_at_peak = Int(s.nprocs)
        ps.workers_at_peak = Int(s.nworkers)
    end
    s.largest_rss > ps.peak_single && (ps.peak_single = s.largest_rss)
    return nothing
end

# The run this monitor watches, with its type restored. See the note on the field.
run_of(m::Monitor) = m.run::Run

# Refilled rather than rebuilt. The only caller is the status line, which reads it
# at once and under the printer lock, so one buffer for the monitor is enough.
function running_items!(m::Monitor)
    dest = m.running
    empty!(dest)
    for slot in run_of(m).slots
        i = @atomic slot.current
        i == 0 || push!(dest, run_of(m).plan.items.name[i])
    end
    return dest
end

function item_on_pid(m::Monitor, pid::Int32)
    for slot in run_of(m).slots
        # Read once each: the slot's own task changes both while this runs.
        w, i = (@atomic slot.worker), (@atomic slot.current)
        (w === nothing || i == 0) && continue
        Int32(w.pid) == pid && return run_of(m).plan.items.name[i]
    end
    return ""
end

### Printing ###############################################################

# The unit changes over at a thousand of the smaller one, not at 1024, so that no
# figure is four digits wide.
const BYTES_PER_UNIT = 1000

"""
    print_bytes(io, b, width = 0)

Write `b` in one binary unit (`K`, `M` and `G` are 2^10, 2^20 and 2^30, as in
`du -h`), gibibytes to a decimal and the others whole, right-aligned in `width`
columns; 1000 to 1023 MiB reads `1.0G`. Padded here from the digits about to be
written, and without building strings: the status line writes three of these on
every redraw.
"""
function print_bytes(io::IO, b::Real, width::Integer = 0)
    if b <= 0
        pad_to(io, width, 1)
        write(io, UInt8('-'))
    elseif b >= BYTES_PER_UNIT * 2^20
        print_1dp(io, b / 2^30, width - 1)
        write(io, UInt8('G'))
    else
        mib = b >= BYTES_PER_UNIT * 2^10
        print_int(io, round(Int, b / (mib ? 2^20 : 2^10)), width - 1)
        write(io, UInt8(mib ? 'M' : 'K'))
    end
    return nothing
end

fmt_bytes(b::Real) = sprint(print_bytes, b)

# `x` to one decimal, right-aligned in `width`. Rounded on the scaled integer, so
# a tie lands on the even tenth.
function print_1dp(io::IO, x::Real, width::Integer = 0)
    isfinite(x) || (print(io, x); return nothing)
    tenths = round(Int, 10 * x)
    neg = tenths < 0
    neg && (tenths = -tenths)
    pad_to(io, width, ndigits(tenths ÷ 10) + 2 + neg)
    neg && write(io, UInt8('-'))
    print_int(io, tenths ÷ 10)
    write(io, UInt8('.'), UInt8('0') + UInt8(tenths % 10))
    return nothing
end

# Decimal digits straight to the stream; `print(io, n)` builds a string first.
function print_int(io::IO, n::Integer, width::Integer = 0)
    neg = n < 0
    neg && (n = -n)
    pad_to(io, width, ndigits(n) + neg)
    neg && write(io, UInt8('-'))
    for k in (ndigits(n) - 1):-1:0
        write(io, UInt8('0') + UInt8((n ÷ 10^k) % 10))
    end
    return nothing
end

# How long the reporting stage has to take before it is worth a line of its own.
const REPORT_WORTH_SAYING = 1.0

# Who a stage's peak was summed over: this process, its workers, and whatever they
# started (the processes precompiling, or anything a test ran), each counted apart.
function procs_text(ps::PhaseStats)
    spawned = ps.nprocs_at_peak - 1 - ps.workers_at_peak
    return string(
        "coordinator",
        ps.workers_at_peak > 0 ? string(" + ", plural(ps.workers_at_peak, "worker")) : "",
        spawned > 0 ? string(" + ", spawned, " spawned") : ""
    )
end
# Four holds every figure up to `9.9G`; a bigger tree shifts the line by a column
# rather than every redraw carrying a blank one.
const TOTAL_WIDTH = 4     # "1.1G", "612M"
const BYTES_WIDTH = 5     # "12.3G"
const RUNNING_WIDTH = 28

"""
    print_status_line(io, m)

The progress line, written straight to `io`. Every field is a fixed width and the
one variable-length field comes last and is clipped, so the line keeps its shape.
It is rebuilt after every line the run prints, so nothing formats through a
temporary string.
"""
function print_status_line(io::IO, m::Monitor)
    # Drawn by whichever task prints, on any thread: what the monitor measured
    # comes from its published reading, and the run's own counts are atomic.
    r = @atomic m.reading
    s = r.sample
    run = run_of(m)
    total = nitems(run.plan)
    done = @atomic run.ndone
    # The same shape as every other line in the log; `w0` is the coordinator.
    solo = single_process(run.plan)
    print_line_head(io, MARK_INFO, solo ? nothing : 0, clock_text(m))
    print_word(io, "INFO")
    print_int(io, done, ndigits(total))
    write(io, UInt8('/'))
    print_int(io, total)
    print(io, FIELD)
    # Unpadded: on a healthy run it is one digit.
    print_int(io, @atomic run.nonpass)
    print(io, " failed")
    if !solo
        print(io, FIELD)
        print_int(io, count(sl -> (@atomic sl.worker) !== nothing, run.slots))
        write(io, UInt8('/'))
        print_int(io, length(run.slots))
        print(io, " workers")
    end
    if PER_PROCESS_OK[] && s.total_rss > 0
        if solo
            # One process: its total, its peak, and nothing to compare them to.
            print(io, " · rss ")
            print_bytes(io, s.total_rss, TOTAL_WIDTH)
            print(io, " (max ")
            print_bytes(io, r.peak_total)
            write(io, UInt8(')'))
        else
            # The newest sample's whole tree, the coordinator among it, with the
            # run's peak alongside.
            print(io, " · tree mem ")
            print_bytes(io, s.total_rss, TOTAL_WIDTH)
            print(io, " (max ")
            print_bytes(io, r.peak_total)
            write(io, UInt8(')'))
            # The largest any one process has been, not the largest now: a current
            # reading moves with whichever worker is mid-item.
            print(io, " · child max ")
            print_bytes(io, r.peak_single, TOTAL_WIDTH)
        end
    end
    if s.machine_total > 0
        print(io, " · mem ")
        print_int(io, round(Int, 100 * s.machine_used / s.machine_total), 2)
        write(io, UInt8('%'))
    end
    if s.load1 >= 0
        print(io, " · cpu ")
        # Four wide: a load average on a many-core machine reaches double digits
        # routinely, and this is the last field before the phase.
        print_1dp(io, s.load1, 4)
        write(io, UInt8('/'))
        print_int(io, cpu_count())
    end
    # The stage and its age, then the first running item: last, because it is the
    # only field that changes width.
    print(io, " · ", phase_name(s.phase), " ")
    print_age(io, run.t0 + Float64(s.t) - r.phase_entered)
    running = running_items!(m)
    isempty(running) || (print(io, " · "); print_clipped(io, first(running), RUNNING_WIDTH))
    return nothing
end

"""
    print_age(io, seconds)

An elapsed time as `45s`, `1m12s` or `2h05m`, written a digit at a time into the
caller's buffer.
"""
function print_age(io::IO, seconds::Real)
    s = seconds > 0 ? unsafe_trunc(Int, seconds) : 0
    if s < 60
        print_int(io, s)
        write(io, UInt8('s'))
    elseif s < 3600
        print_int(io, s ÷ 60)
        write(io, UInt8('m'))
        print_int2(io, s % 60)
        write(io, UInt8('s'))
    else
        print_int(io, s ÷ 3600)
        write(io, UInt8('h'))
        print_int2(io, (s % 3600) ÷ 60)
        write(io, UInt8('m'))
    end
    return nothing
end

# Zero-padded to two digits: `1m05s` reads as one duration, `1m5s` as two numbers.
function print_int2(io::IO, n::Integer)
    n < 10 && write(io, UInt8('0'))
    print_int(io, n)
    return nothing
end

"""
    clip_status!(m, from)

Cut the status line the buffer holds from `from` onward to what fits on one row.

A line wider than the terminal wraps, and `\\r\\e[2K` erases the row the cursor is
on and no other — so the next redraw leaves every row but the last of the old line
sitting on the screen. Cutting it is what keeps one line one row.
"""
function clip_status!(m::Monitor, from::Integer)
    m.columns > 0 || return nothing
    buf = m.linebuf
    to = position(buf)
    fits = from + bytes_within(buf.data, from + 1, to, m.columns)
    if fits < to
        # A colour the kept part turns on may have had its reset cut off.
        colored = any(==(0x1b), view(buf.data, (from + 1):fits))
        truncate(buf, fits)
        colored && print(buf, "\e[0m")
    end
    return nothing
end

"""
    bytes_within(data, from, to, columns) -> Int

How many of the bytes `data[from:to]` fit in `columns` columns of screen.

Escape sequences change the colour, not the cursor's position, so they cost
nothing, and one is kept or cut whole. Decoded a byte at a time: a `String` would
allocate on every redraw.
"""
function bytes_within(data::AbstractVector{UInt8}, from::Int, to::Int, columns::Int)
    col = 0
    i = from
    while i <= to
        b = data[i]
        if b == 0x1b
            # `ESC [`, then parameter and intermediate bytes, then a final byte in
            # 0x40:0x7e; any other escape is `ESC` and one byte.
            if i + 1 <= to && data[i + 1] == UInt8('[')
                j = i + 2
                while j <= to && !(0x40 <= data[j] <= 0x7e)
                    j += 1
                end
                i = j + 1
            else
                i += 2
            end
            continue
        end
        n = b < 0x80 ? 1 : b < 0xe0 ? 2 : b < 0xf0 ? 3 : 4
        i + n - 1 > to && break
        cp = if n == 1
            UInt32(b)
        elseif n == 2
            (UInt32(b & 0x1f) << 6) | UInt32(data[i + 1] & 0x3f)
        elseif n == 3
            (UInt32(b & 0x0f) << 12) | (UInt32(data[i + 1] & 0x3f) << 6) |
                UInt32(data[i + 2] & 0x3f)
        else
            (UInt32(b & 0x07) << 18) | (UInt32(data[i + 1] & 0x3f) << 12) |
                (UInt32(data[i + 2] & 0x3f) << 6) | UInt32(data[i + 3] & 0x3f)
        end
        w = textwidth(Char(cp))
        col + w > columns && return i - from
        col += w
        i += n
    end
    return i - from
end

status_line(m::Monitor) =
    sprint(io -> print_status_line(IOContext(io, :color => m.color), m))

# The wall clock as this line writes it, formatted once a second.
function clock_text(m::Monitor)
    sec = unsafe_trunc(Int, time())
    if sec != m.clock_at
        m.clock_at = sec
        m.clock_text = Libc.strftime("%H:%M:%S", sec)
        m.columns = terminal_columns(m.tty)
    end
    return m.clock_text
end

# Clipped but not padded: the pinned line is erased before it is redrawn, so
# trailing spaces would only litter a log file.
function print_clipped(io::IO, s::AbstractString, width::Int)
    if length(s) <= width
        print(io, s)
    else
        print(io, SubString(s, 1, nextind(s, 0, width - 1)), '…')
    end
    return nothing
end

"""
    MEMORY_MARKS

Percentages of the machine's memory whose upward crossing earns a report of its
own, off schedule: past ninety percent, things change faster than a thirty-second
cadence can follow.
"""
const MEMORY_MARKS = (90, 95, 96, 97, 98, 99)

# A mark sits still while the machine breathes across it, so a run hovering on one
# would narrate every sample. Each mark says its piece at most this often.
const MEMORY_MARK_QUIET = 30.0

# The highest mark the machine has just crossed upward, or 0 for none.
function crossed_memory_mark!(m::Monitor, pct::Float64, now::Float64)
    prev = m.last_mem_pct
    m.last_mem_pct = pct
    crossed = 0
    for (i, mark) in pairs(MEMORY_MARKS)
        prev < mark <= pct || continue
        # Marked as said even when it is not reported, so that a machine drifting
        # over the same mark again in a moment stays quiet.
        now - m.mark_said[i] < MEMORY_MARK_QUIET && continue
        m.mark_said[i] = now
        crossed = mark
    end
    return crossed
end

function maybe_print(m::Monitor)
    now = time()
    s = m.samples[m.ring_head == 0 ? 1 : m.ring_head]
    if m.tty
        now - m.last_print < 0.5 && return nothing
        m.last_print = now
        @lock run_of(m).printer redraw_status(m)
        return nothing
    end
    # Not a terminal: poll often and report on a clock, and also when the stage
    # changes or memory nears the edge. The clock is a cadence, so an unscheduled
    # report does not push the next scheduled one back.
    phase_changed = s.phase !== m.last_phase_printed
    pressure = s.machine_total > 0 ? 100 * s.machine_used / s.machine_total : 0.0
    near_oom = crossed_memory_mark!(m, pressure, now) != 0
    due = now >= m.next_print
    (due || phase_changed || near_oom) || return nothing
    due && (m.next_print = max(now, m.next_print) + m.print_interval)
    m.last_print = now
    m.last_phase_printed = s.phase
    printline(run_of(m), status_line(m))
    return nothing
end

# The pinned line is erased before anything else writes, and redrawn after. Both
# happen under the printer lock, so no other output can land in between.
clear_status_line(m::Union{Nothing, Monitor}) =
    (m !== nothing && m.tty && (print(stdout, "\r\e[2K"); flush(stdout)); nothing)

"""
    status_update!(m, text) -> IOBuffer

What one printed line sends to a terminal: erase the status line, the line, the
status line again, assembled whole and written once. Written as three pieces, a
run that prints fast mostly shows a half-erased status line.
"""
function status_update!(m::Monitor, text::AbstractString)
    buf = m.linebuf
    truncate(buf, 0)
    print(m.lineio, "\r\e[2K", text)
    endswith(text, "\n") || print(m.lineio, "\n")
    print(m.lineio, "\r\e[2K")
    at = position(buf)
    print_status_line(m.lineio, m)
    clip_status!(m, at)
    seekstart(buf)
    return buf
end

"""
    with_status_line_off(f, m)

Run `f` with the pinned status line withdrawn: `Pkg` draws its own progress by
moving the cursor, and two writers rewriting the last line produce neither.
Sampling continues; only the drawing stops.
"""
function with_status_line_off(f, m::Union{Nothing, Monitor})
    m === nothing && return f()
    # Under the printer lock, as `stop_monitor!` does: a redraw already under way
    # would otherwise land after the erase.
    @lock run_of(m).printer begin
        @atomic m.quiet = true
        clear_status_line(m)
    end
    try
        return f()
    finally
        @atomic m.quiet = false
    end
end

# Whether the status line may be drawn at all right now.
drawing(m::Monitor) = m.tty && !m.stop && !(@atomic m.quiet)

function redraw_status(m::Union{Nothing, Monitor})
    (m === nothing || !drawing(m)) && return nothing
    # Assembled in the monitor's buffer and written once. Safe to share: every
    # caller holds the printer lock.
    buf = m.linebuf
    truncate(buf, 0)
    print(m.lineio, "\r\e[2K")
    at = position(buf)
    print_status_line(m.lineio, m)
    clip_status!(m, at)
    seekstart(buf)
    write(stdout, buf)
    flush(stdout)
    return nothing
end

"""
    print_memory_summary(io, m; indent)

What each stage of the run cost, a line each, for the run's closing block. Per
stage because the stages are not comparable, and the stage that came closest to
the edge is the one a reader can act on.
"""
function print_memory_summary(io::IO, m::Monitor; indent::AbstractString = "  ")
    st = m.stats
    finish = time()
    solo = single_process(run_of(m).plan)
    if PER_PROCESS_OK[]
        # Every stage the run entered gets a line, whether or not a sample landed in
        # it: a stage that went by faster than the sampler is still a stage the run
        # went through. Except reporting, which is shutting the workers down and
        # writing the run state — a tenth of a second, whose memory is whatever was
        # left once the workers had gone. It earns a line only when it took long
        # enough to mean something went wrong on the way out.
        shown(phase) = let ps = phase_stats(st, phase)
            ps.entered != 0 &&
                !(phase === PHASE_REPORT && phase_seconds(st, phase, finish) < REPORT_WORTH_SAYING)
        end
        # Two passes: the columns are as wide as the widest thing that will go in
        # them, so `5m57.7s` next to `12.0s` does not push a whole line right of
        # the one above it.
        name_width, time_width, procs_width = 0, 0, 0
        for phase in instances(RunPhase)
            shown(phase) || continue
            ps = phase_stats(st, phase)
            name_width = max(name_width, length(phase_name(phase)))
            time_width = max(time_width, length(fmt_seconds(phase_seconds(st, phase, finish))))
            (solo || ps.peak_total <= 0) && continue
            procs_width = max(procs_width, length(procs_text(ps)))
        end
        for phase in instances(RunPhase)
            shown(phase) || continue
            ps = phase_stats(st, phase)
            seconds = phase_seconds(st, phase, finish)
            more_follows = ps.starts > nslots(run_of(m).plan) ||
                (phase === PHASE_TEST && sum(run_of(m).statuses.elapsed; init = 0.0f0) > 0)
            print(io, indent, rpad(phase_name(phase), name_width), FIELD)
            print(io, lpad(fmt_seconds(seconds), time_width))
            if ps.peak_total > 0
                print(io, FIELD, solo ? "rss " : "tree max ")
                print_bytes(io, ps.peak_total, BYTES_WIDTH)
                if !solo
                    print(io, FIELD, "child max ")
                    print_bytes(io, ps.peak_single, BYTES_WIDTH)
                    text = procs_text(ps)
                    print(io, FIELD, text)
                    # Padded only to line up a field that follows; a line that ends
                    # here ends at its last character.
                    more_follows && pad_to(io, procs_width, length(text))
                end
            end
            # Only when workers were replaced rather than reused: otherwise this is
            # the worker count again, said twice.
            ps.starts > nslots(run_of(m).plan) &&
                print(io, FIELD, plural(ps.starts, "worker start"))
            phase === PHASE_TEST && print_compile_share(io, run_of(m))
            println(io)
        end
        solo || println(
            io, indent, "(summed resident sizes over-count pages the processes share)"
        )
    end
    st.machine_total > 0 && println(
        io, indent, "machine", FIELD, fmt_bytes(st.machine_peak_used), " of ",
        fmt_bytes(st.machine_total), " in use at peak"
    )
    print_cpu(io, st.cpu_start, st.cpu_end; indent)
    st.guard_actions > 0 &&
        println(io, indent, "guard", FIELD, plural(st.guard_actions, "action"))
    return nothing
end

# Once every worker has exited and been reaped: before that, what a worker has used
# is not in its parent's count.
record_cpu_end!(m::Union{Nothing, Monitor}) = (m === nothing || (m.stats.cpu_end = cpu_reading()); nothing)

# How busy the run kept the machine's CPU threads, and how busy the machine was:
# the two differ by whatever else was running. Where the run's own time is unknown,
# or comes out beyond what the machine could give, only the machine's is said.
function print_cpu(io::IO, a::CpuReading, b::CpuReading; indent::AbstractString = "  ")
    (b.at > a.at && b.total_ms > a.total_ms && b.threads > 0) || return nothing
    machine = round(Int, 100 * (b.busy_ms - a.busy_ms) / (b.total_ms - a.total_ms))
    run = a.run_s >= 0 && b.run_s >= a.run_s ? (b.run_s - a.run_s) / ((b.at - a.at) * b.threads) : -1.0
    print(io, indent, "cpu", FIELD)
    if 0 <= run <= 1.05
        println(io, round(Int, 100 * min(run, 1.0)), "% of ", b.threads, " threads for this run's processes, ",
                machine, "% for the whole machine (averages over the run)")
    else
        println(io, machine, "% of ", b.threads, " threads for the whole machine (average over the run)")
    end
    return nothing
end

# How much of the time the items spent was spent compiling. Summed over the items
# rather than measured against the stage's wall time, which several workers share
# and which would make the share depend on how many there were.
function print_compile_share(io::IO, run)
    elapsed = sum(run.statuses.elapsed; init = 0.0f0)
    elapsed > 0 || return nothing
    share = round(Int, 100 * sum(run.statuses.compile; init = 0.0f0) / elapsed)
    print(io, FIELD, share, "% compile")
    return nothing
end

### The memory guard #######################################################

const GUARD_BACKPRESSURE_SECONDS = 10.0
const GUARD_GC_SECONDS = 20.0
const GUARD_RESTART_COOLDOWN = 60.0
# A hold ends this far below the threshold, not at it. The machine's reading drifts
# by about this much with nothing happening (1.8 points over 30s, measured on an idle
# 64 GiB Mac), and a hold released on the first dip is taken again on the next rise.
const GUARD_HYSTERESIS = 0.02

# Escalates slowly on purpose: restarting a worker throws away everything it has
# compiled, which on a compilation-heavy suite is the most expensive thing the
# framework can do to itself.
function guard!(m::Monitor)
    run = run_of(m)
    threshold = run.plan.cfg.memory_threshold
    s = m.samples[m.ring_head == 0 ? 1 : m.ring_head]
    s.machine_total > 0 || return nothing
    pressure = s.machine_used / s.machine_total
    now = time()
    release = max(threshold - GUARD_HYSTERESIS, threshold / 2)
    if m.over_since != 0.0 && pressure < release
        m.over_since = 0.0
        # Said only when the hold was still on: `wait_while_paused` lets go by itself
        # after `MAX_BACKPRESSURE_SECONDS`, and says so.
        if is_paused(run.queues)
            set_paused!(run.queues, false)
            say(run, "memory is down to ", round(Int, 100 * pressure), "%; no longer holding off on new test items")
        end
        return nothing
    end
    pressure < threshold && return nothing   # below it, or on the way down from a hold
    if m.over_since == 0.0
        m.over_since = now
        set_paused!(run.queues, true)
        m.stats.guard_actions += 1
        @warn "YATF: memory is at $(round(Int, 100 * pressure))% of the machine; holding off on new " *
            "test items until it is below $(round(Int, 100 * release))%, for " *
            "$(round(Int, MAX_BACKPRESSURE_SECONDS))s at most"
        return nothing
    end
    over = now - m.over_since
    if over > GUARD_GC_SECONDS && now - m.last_restart > GUARD_RESTART_COOLDOWN
        m.last_restart = now
        m.stats.guard_actions += 1
        recycle_biggest_worker!(m)
    elseif over > GUARD_BACKPRESSURE_SECONDS && now - m.last_gc > GUARD_GC_SECONDS
        m.last_gc = now
        m.stats.guard_actions += 1
        GC.gc(true)
        for slot in run.slots
            w = @atomic slot.worker
            (w === nothing || (@atomic slot.current) != 0) && continue   # do not disturb a running item
            try
                YATFWorkers.remote_eval(w, :(GC.gc(true)))
            catch e
                is_interrupt(e) && rethrow()
            end
        end
    end
    return nothing
end

# The largest worker, measured now, is replaced once its slot is between units.
function recycle_biggest_worker!(m::Monitor)
    run = run_of(m)
    victim, most = nothing, Int64(-1)
    for slot in run.slots
        w = @atomic slot.worker
        (w === nothing || (@atomic slot.recycle)) && continue
        rss = process_rss(w.pid)
        rss > most && ((victim, most) = (slot, rss))
    end
    victim === nothing && return nothing
    w = @atomic victim.worker
    w === nothing && return nothing
    @atomic victim.recycle = true
    say(run, "memory is above ", round(Int, 100 * run.plan.cfg.memory_threshold), "%; restarting w",
        victim.id, " (pid ", w.pid, most > 0 ? string(", ", fmt_bytes(most)) : "", ")",
        (@atomic victim.current) == 0 ? "" : " once its item is done")
    return nothing
end

