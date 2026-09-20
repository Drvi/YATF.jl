# Watching the machine while the tests run.
#
# The question is not "how much memory is free" but "how much are *we* using,
# where is it, and when was it worst". A run that dies at four in the morning has
# to leave behind enough to answer that, so the peaks are recorded as they happen
# rather than summarized at the end.
#
# Everything here is best-effort: the monitor never fails a run. If it throws, it
# switches itself off, says so once, and the tests carry on.

using .Platform: process_rss, process_tree, machine_memory, cpu_load, cpu_count,
    ensure_checked!, PER_PROCESS_OK

# The scan is over before the monitor exists, so the first stage a run reports is
# the one it is actually in. Resolving the environment and precompiling the setups
# are one stage and not two: the same single process does both, back to back, and
# which of them a given megabyte belongs to is not a question anyone asks.
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
    nprocs::Int16
    total_rss::Int64       # summed over our whole process tree
    largest_rss::Int64
    largest_pid::Int32
    machine_used::Int64
    machine_total::Int64
    load1::Float32     # one-minute load average
end

Sample() = Sample(0.0f0, PHASE_SETUP, 0, 0, 0, 0, 0, 0, -1.0f0)

"""
    PhaseStats

What one stage of a run cost.

Kept per stage because the stages are different machines: resolving an
environment runs one process, precompiling runs a handful of short-lived ones,
and testing runs as many workers as it was given. A single figure for the run
answers "was it close to the edge" and nothing else — these answer which stage
took it there.
"""
Base.@kwdef mutable struct PhaseStats
    entered::Float64 = 0.0    # when the run entered this stage, 0 if it never did
    peak_total::Int64 = 0      # summed resident size over our processes
    peak_single::Int64 = 0
    # How many processes were alive at the sample that set `peak_total`, not the
    # most that were ever alive at once. The line reports it next to that peak, and
    # three independent maxima taken at three different instants read as one moment
    # and contradict each other: a stage can report two processes beside a tree max
    # equal to its child max, which never happened.
    nprocs_at_peak::Int = 0
    # Processes started during this stage. A stage that replaces a worker per item
    # churns through many more than are ever alive together.
    starts::Int = 0
end

"""
    MemStats

The aggregates worth having after the fact, per stage of the run and over all of
it. Summing resident sizes over processes over-counts pages they share — the
Julia runtime and every package image are mapped into each worker — so a total is
an upper bound, and is reported as one.
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
end

phase_stats(st::MemStats, p::RunPhase) = st.phases[Int(p) + 1]

"""
    phase_peak(stats, phase) -> Int

The peak summed resident size while the run was in `phase`, or 0 if it never was.
"""
phase_peak(st::MemStats, p::RunPhase) = phase_stats(st, p).peak_total

"""
    phase_seconds(stats, phase, finish) -> Float64

How long the run spent in `phase`.

A stage ends when the next one begins, and the last one ends at `finish`. There is
no separate "left this stage" stamp because a run only ever moves forward through
them, and one stamp that cannot disagree with another is worth more than two that
can.
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

mutable struct Monitor
    # `Run` is defined after this, because a `Run` holds its `Monitor`. The field
    # therefore cannot name its type; `run_of` puts the type back. Without that,
    # every reach into the run's slots, plan and statuses from the sampling loop
    # and from the status line is a dynamic lookup that boxes what it returns.
    const run::Any
    const stats::MemStats
    const samples::Vector{Sample}
    ring_head::Int
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
    # Scratch for the status line's list of running items, refilled rather than
    # rebuilt: on a terminal the line is redrawn after every line the run prints.
    # Only ever touched under `run.printer`, which is held for every redraw.
    const running::Vector{String}
    # Where the status line is assembled, reused for the same reason. `lineio`
    # carries the colour setting into it: written to the buffer directly, every
    # `printstyled` in the line would come out plain.
    const linebuf::IOBuffer
    const lineio::IO
    const color::Bool
    # `strftime` builds a string per call and the clock moves once a second, while
    # this line is redrawn after every line the run prints.
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

function Monitor(run; interval = 0.2, print_interval = 30.0)
    # A line that rewrites itself needs a terminal that can rewrite it, and a
    # reader watching it happen. Anything else — a pipe, a log file, a CI job —
    # gets the same line printed periodically instead.
    tty = stdout isa Base.TTY && !haskey(ENV, "CI") && get(ENV, "TERM", "") != "dumb"
    color = get(stdout, :color, false)::Bool
    linebuf = IOBuffer()
    # The run is already in its first stage by the time it has a monitor — nothing
    # calls `set_phase!` to enter the one it starts in.
    stats = MemStats()
    phase_stats(stats, PHASE_SETUP).entered = time()
    return Monitor(
        run, stats, fill(Sample(), RING_SAMPLES), 0, nothing, false, false,
        PHASE_SETUP, true, interval, print_interval, tty,
        sizehint!(String[], nslots(run.plan)), linebuf,
        IOContext(linebuf, :color => color), color, 0, "", 0.0, 0.0, 0.0,
        zeros(Float64, length(MEMORY_MARKS)), PHASE_REPORT, 0.0, 0.0, 0.0
    )
end

# Stamped by the run's own task as it enters a stage, and read by the monitor when
# it reports. The run moves through the stages one at a time, so there is one
# writer per field and nothing to coordinate.
# Counted here rather than sampled: a sandbox worker can live and die between two
# samples, so the ring would miss it entirely.
function count_worker_start!(m::Union{Nothing, Monitor})
    m === nothing && return nothing
    phase_stats(m.stats, @atomic m.phase).starts += 1
    return nothing
end

function set_phase!(m::Union{Nothing, Monitor}, p::RunPhase)
    m === nothing && return nothing
    phase_stats(m.stats, p).entered = time()
    @atomic m.phase = p
    return nothing
end

function start_monitor!(m::Monitor)
    try
        ensure_checked!()
    catch e
        @warn "YATF: per-process memory accounting is unavailable here" exception = e maxlog = 1
    end
    m.task = Threads.@spawn begin
        try
            monitor_loop(m)
        catch e
            e isa InterruptException && rethrow()
            @atomic m.enabled = false
            @warn "YATF: the resource monitor stopped; the run continues without it" exception = e
        end
    end
    return m
end

function stop_monitor!(m::Union{Nothing, Monitor})
    m === nothing && return nothing
    @atomic m.stop = true
    m.task === nothing || (
        try
            wait(m.task)
        catch
        end
    )
    clear_status_line(m)
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

# Roots of our process tree: this process, plus every live worker. Their children
# — `Pkg`'s precompilation workers, anything a test item starts — are found from
# there, because they spend the same memory budget.
function tree_roots(m::Monitor)
    roots = Int32[Int32(getpid())]
    for slot in run_of(m).slots
        w = slot.worker
        w === nothing || push!(roots, Int32(w.pid))
    end
    return roots
end

function sample!(m::Monitor)
    t = Float32(time() - run_of(m).t0)
    phase = @atomic m.phase
    used, total = machine_memory()
    total_rss = Int64(0); largest = Int64(0); largest_pid = Int32(0); nprocs = 0
    if PER_PROCESS_OK[]
        for pid in process_tree(tree_roots(m))
            rss = process_rss(pid)
            rss <= 0 && continue
            nprocs += 1
            total_rss += rss
            rss > largest && ((largest, largest_pid) = (rss, Int32(pid)))
        end
    end
    load1 = Float32(cpu_load())
    s = Sample(t, phase, Int16(nprocs), total_rss, largest, largest_pid, used, total, load1)
    m.ring_head = mod1(m.ring_head + 1, RING_SAMPLES)
    m.samples[m.ring_head] = s
    update_stats!(m, s)
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
        write_memory!(run_of(m).runstate, st)
    end
    if s.largest_rss > st.peak_single_bytes
        st.peak_single_bytes = s.largest_rss
        st.peak_single_pid = s.largest_pid
        st.peak_single_item = item_on_pid(m, s.largest_pid)
        write_memory!(run_of(m).runstate, st)
    end
    # The stages are different memory regimes, and a figure for the whole run
    # hides which of them was the expensive one.
    ps = phase_stats(st, s.phase)
    if s.total_rss > ps.peak_total
        ps.peak_total = s.total_rss
        ps.nprocs_at_peak = Int(s.nprocs)
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
        i = slot.current
        i == 0 || push!(dest, run_of(m).plan.items.name[i])
    end
    return dest
end

function item_on_pid(m::Monitor, pid::Int32)
    for slot in run_of(m).slots
        w = slot.worker
        w === nothing && continue
        if Int32(w.pid) == pid && slot.current != 0
            return run_of(m).plan.items.name[slot.current]
        end
    end
    return ""
end

### Printing ###############################################################

"""
    print_bytes(io, b, width = 0)

Write `b` as one unit — gibibytes to a decimal, mebibytes and kibibytes whole —
right-aligned in `width` columns.

`K`, `M` and `G` are binary, as they are in `du -h` and as `GiB` is everywhere
else in a run: the divisors are 2^10, 2^20 and 2^30. Only the changeover is
decimal, at a thousand of the smaller unit, so that no figure is four digits wide.
A value between 1000 and 1023 mebibytes therefore reads `1.0G`, which is what
0.98 gibibytes rounds to at one decimal place.

Padding is done here rather than by `lpad` because the width follows from the
digits this is about to write, and asking for it separately is a second copy of
the same rule waiting to disagree with the first. Julia's integer and float
formatting each build a string per call; the status line writes three of these
every time the run prints a line.
"""
# See `print_bytes`: the unit changes over here, not at 1024, so that no figure is
# ever four digits wide. 1004M reads as a bigger number than 1.0G at a glance, and
# a column that is three digits except occasionally four is a column that moves.
const BYTES_PER_UNIT = 1000

function print_bytes(io::IO, b::Real, width::Integer = 0)
    if b <= 0
        pad_to(io, width, 1)
        write(io, UInt8('-'))
    elseif b >= BYTES_PER_UNIT * 2^20
        tenths = round(Int, b / 2^30 * 10)
        pad_to(io, width, ndigits(tenths ÷ 10) + 3)
        print_int(io, tenths ÷ 10)
        write(io, UInt8('.'), UInt8('0') + UInt8(tenths % 10), UInt8('G'))
    elseif b >= BYTES_PER_UNIT * 2^10
        n = round(Int, b / 2^20)
        pad_to(io, width, ndigits(n) + 1)
        print_int(io, n)
        write(io, UInt8('M'))
    else
        n = round(Int, b / 2^10)
        pad_to(io, width, ndigits(n) + 1)
        print_int(io, n)
        write(io, UInt8('K'))
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

# Every field is a fixed width and the one variable-length field comes last and is
# clipped, so the line keeps its shape for the whole run instead of jumping about
# as numbers gain and lose digits.
const PHASE_WIDTH = 9     # "reporting"

# How long the reporting stage has to take before it is worth a line of its own.
const REPORT_WORTH_SAYING = 1.0

procs_text(n::Integer) = string("over ", plural(n, "process", "processes"))
# Four holds every figure up to `9.9G`; a tree past that is one character wider and
# shifts the rest of the line, which is the price of not carrying a blank column
# on every redraw for the runs that never get there.
const TOTAL_WIDTH = 4     # "1.1G", "612M"
const BYTES_WIDTH = 5     # "12.3G"
const RUNNING_WIDTH = 28

"""
    print_status_line(io, m)

The progress line, written straight to `io`.

It is rebuilt after every line the run prints, so nothing here formats through a
temporary string: the numbers are written a digit at a time and the columns are
padded with spaces rather than with padded copies of their contents.
"""
function print_status_line(io::IO, m::Monitor)
    s = m.samples[m.ring_head == 0 ? 1 : m.ring_head]
    run = run_of(m)
    total = nitems(run.plan)
    done = @atomic run.ndone
    # The same shape as every other line in the log — glyph, who, when, what —
    # because this is the run saying something, not furniture. `w0` is the
    # coordinator: the process the others hang off.
    solo = single_process(run.plan)
    print_line_head(io, MARK_INFO, solo ? nothing : 0, clock_text(m))
    print_bold(io, "INFO")
    pad_to(io, WORKER_STATE_WIDTH, 4)
    print(io, FIELD)
    print_int(io, done, ndigits(total))
    write(io, UInt8('/'))
    print_int(io, total)
    print(io, FIELD)
    # What has gone wrong so far, counted from the states rather than tracked
    # alongside them: an item that fails and then passes on a retry is not a
    # failure, and only the states know that. Unpadded: on a healthy run this is
    # one character and the eye should not have to look for it.
    print_int(io, count(is_non_pass, run.statuses.state))
    print(io, " failed")
    if !solo
        print(io, FIELD)
        print_int(io, count(sl -> sl.worker !== nothing, run.slots))
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
            print_bytes(io, m.stats.peak_total_bytes)
            write(io, UInt8(')'))
        else
            # Both current figures come from the newest sample and the peak from the
            # run so far, so each says which it is. `total_rss` is the whole tree
            # summed, the coordinator among it — not the coordinator's own size —
            # and `largest_rss` is the biggest process in that same sample, which is
            # a reading and not a record.
            # One width for both readings: they are the same kind of number and a
            # column each keeps them under one another. The tree is the larger of
            # the two, so it is the one that sets the width.
            # The tree as it stands, with its peak alongside: the peak belongs to
            # the reading it qualifies rather than to a field of its own, and it is
            # unpadded because the brackets already say where it ends.
            print(io, " · tree mem ")
            print_bytes(io, s.total_rss, TOTAL_WIDTH)
            print(io, " (max ")
            print_bytes(io, m.stats.peak_total_bytes)
            write(io, UInt8(')'))
            # The largest any one process has been, not the largest right now: a
            # current reading fluctuates with whichever worker is mid-item, while
            # the peak is the number that says whether one of them got too big.
            print(io, " · child max ")
            print_bytes(io, m.stats.peak_single_bytes, TOTAL_WIDTH)
        end
    end
    if s.machine_total > 0
        print(io, " · mem ")
        print_int(io, round(Int, 100 * s.machine_used / s.machine_total), 2)
        write(io, UInt8('%'))
    end
    if s.load1 >= 0
        print(io, " · load ")
        # Four wide: a load average on a many-core machine reaches double digits
        # routinely, and this is the last field before the phase.
        print_1dp(io, s.load1, 4)
        write(io, UInt8('/'))
        print_int(io, cpu_count())
    end
    # What the run is doing, how long it has been doing it, and the first thing it
    # is doing it to. Last, because it is the only field that changes width. The
    # age qualifies the stage rather than taking a column of its own: this line is
    # busy enough.
    print(io, " · ", phase_name(s.phase), " ")
    print_age(io, run.t0 + Float64(s.t) - phase_stats(m.stats, s.phase).entered)
    running = running_items!(m)
    isempty(running) || (print(io, " · "); print_clipped(io, first(running), RUNNING_WIDTH))
    return nothing
end

"""
    print_age(io, seconds)

An elapsed time as `45s`, `1m12s` or `2h05m`, written a digit at a time.

The status line is redrawn after every line the run prints, so this formats into
the caller's buffer rather than building a string to throw away.
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

status_line(m::Monitor) =
    sprint(io -> print_status_line(IOContext(io, :color => m.color), m))

# The wall clock as this line writes it, formatted once a second.
function clock_text(m::Monitor)
    sec = unsafe_trunc(Int, time())
    if sec != m.clock_at
        m.clock_at = sec
        m.clock_text = Libc.strftime("%H:%M:%S", sec)
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

How close to out of memory is worth saying so, in percent of the machine's memory.

Crossing one of these upward earns a report of its own, whatever the schedule
says. Above ninety percent the interesting question stops being "how is the run
going" and becomes "how long until the kernel kills something", and the answer
changes faster than a thirty-second cadence can follow.
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
    # Not a terminal: poll often, report on a clock, and report as well when the
    # run changes what it is doing or the machine gets close to out of memory. The
    # clock is a cadence and not a delay since the last line, so an unscheduled
    # report says its piece without pushing the next scheduled one back.
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

What one printed line sends to a terminal: erase the pinned status line, the line
itself, then the status line again.

Assembled whole and written once. Sent as three writes the terminal paints each
of them, so a run that prints faster than the terminal refreshes spends its time
showing a status line that is half erased — this is the difference between a line
that updates and a line that flickers.
"""
function status_update!(m::Monitor, text::AbstractString)
    buf = m.linebuf
    truncate(buf, 0)
    print(m.lineio, "\r\e[2K", text)
    endswith(text, "\n") || print(m.lineio, "\n")
    print(m.lineio, "\r\e[2K")
    print_status_line(m.lineio, m)
    seekstart(buf)
    return buf
end

"""
    with_status_line_off(f, m)

Run `f` with the pinned status line withdrawn.

`Pkg` resolving an environment narrates it with a progress display of its own, and
it moves the cursor to do that. Two writers that both rewrite the last line
produce neither one. Sampling continues throughout — the stage's memory is still
measured — and only the drawing stops.
"""
function with_status_line_off(f, m::Union{Nothing, Monitor})
    m === nothing && return f()
    @atomic m.quiet = true
    clear_status_line(m)
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
    # Assembled in the monitor's own buffer and written once: this happens after
    # every line the run prints, and a line built out of temporary strings would
    # cost more than the line it draws. Safe to share — every caller holds the
    # printer lock.
    buf = m.linebuf
    truncate(buf, 0)
    print(m.lineio, "\r\e[2K")
    print_status_line(m.lineio, m)
    seekstart(buf)
    write(stdout, buf)
    flush(stdout)
    return nothing
end

# Written as part of the run's closing block, so the numbers arrive with the
# sentence that says the run is over rather than under a heading of their own.
"""
    print_memory_summary(io, m; indent)

What each stage of the run cost, a line each.

Per stage rather than per run because the stages are not comparable: one process
resolving an environment, a handful of short-lived ones precompiling, and as many
workers as the run was given testing. A single peak says the run came within so
much of the edge; these say which stage took it there, which is the one a reader
can act on.
"""
function print_memory_summary(io::IO, m::Monitor; indent::AbstractString = "  ")
    st = m.stats
    finish = time()
    solo = single_process(run_of(m).plan)
    if PER_PROCESS_OK[]
        # Two passes: the columns are as wide as the widest thing that will go in
        # them, so `5m57.7s` next to `12.0s` does not push a whole line right of
        # the one above it.
        shown(phase) = let ps = phase_stats(st, phase)
            ps.entered != 0 &&
                !(phase === PHASE_REPORT && phase_seconds(st, phase, finish) < REPORT_WORTH_SAYING)
        end
        time_width, procs_width = 0, 0
        for phase in instances(RunPhase)
            shown(phase) || continue
            ps = phase_stats(st, phase)
            time_width = max(time_width, length(fmt_seconds(phase_seconds(st, phase, finish))))
            (solo || ps.peak_total <= 0) && continue
            procs_width = max(procs_width, length(procs_text(ps.nprocs_at_peak)))
        end
        for phase in instances(RunPhase)
            ps = phase_stats(st, phase)
            # Every stage the run entered gets a line, whether or not a sample
            # landed in it: a stage that went by faster than the sampler is still
            # a stage the run went through, and a line that says so and nothing
            # else is more honest than no line.
            ps.entered == 0 && continue
            seconds = phase_seconds(st, phase, finish)
            # Except reporting, which is shutting the workers down and writing the
            # run state — a tenth of a second, whose memory is whatever was left
            # once the workers had gone. It earns a line only when it took long
            # enough to mean something went wrong on the way out.
            phase === PHASE_REPORT && seconds < REPORT_WORTH_SAYING && continue
            more_follows = ps.starts > nslots(run_of(m).plan) ||
                (phase === PHASE_TEST && sum(run_of(m).statuses.elapsed; init = 0.0f0) > 0)
            print(io, indent, rpad(phase_name(phase), PHASE_WIDTH), FIELD)
            print(io, lpad(fmt_seconds(seconds), time_width))
            if ps.peak_total > 0
                print(io, FIELD, solo ? "rss " : "tree max ")
                print_bytes(io, ps.peak_total, BYTES_WIDTH)
                if !solo
                    print(io, FIELD, "child max ")
                    print_bytes(io, ps.peak_single, BYTES_WIDTH)
                    text = procs_text(ps.nprocs_at_peak)
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
    st.guard_actions > 0 &&
        println(io, indent, "guard", FIELD, plural(st.guard_actions, "action"))
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
    if pressure < threshold
        if m.over_since != 0.0
            m.over_since = 0.0
            set_paused!(run.queues, false)
        end
        return nothing
    end
    if m.over_since == 0.0
        m.over_since = now
        set_paused!(run.queues, true)
        m.stats.guard_actions += 1
        @warn "YATF: memory pressure is at $(round(Int, 100 * pressure))%; " *
            "holding off on new test items"
        return nothing
    end
    over = now - m.over_since
    if over > GUARD_GC_SECONDS && now - m.last_restart > GUARD_RESTART_COOLDOWN
        m.last_restart = now
        m.stats.guard_actions += 1
        restart_biggest_worker!(m, s)
    elseif over > GUARD_BACKPRESSURE_SECONDS && now - m.last_gc > GUARD_GC_SECONDS
        m.last_gc = now
        m.stats.guard_actions += 1
        GC.gc(true)
        for slot in run.slots
            w = slot.worker
            (w === nothing || slot.current != 0) && continue   # do not disturb a running item
            try
                YATFWorkers.remote_eval(w, :(GC.gc(true)))
            catch
            end
        end
    end
    return nothing
end

function restart_biggest_worker!(m::Monitor, s::Sample)
    run = run_of(m)
    victim = nothing
    for slot in run.slots
        w = slot.worker
        w === nothing && continue
        (victim === nothing || Int32(w.pid) == s.largest_pid) && (victim = slot)
    end
    victim === nothing && return nothing
    w = victim.worker
    w === nothing && return nothing
    print_worker_line(
        run, victim.id, "KILL", string(
            "pid ", w.pid,
            " · memory guard: pressure above ", round(Int, 100 * run.plan.cfg.memory_threshold),
            "% · restarting to free memory",
            victim.current == 0 ? "" : string(" · was running ", repr(run.plan.items.name[victim.current]))
        )
    )
    # The slot task sees this as its worker dying, which it already knows how to
    # handle: the item is recorded, and retried if retries remain.
    try
        YATFWorkers.terminate!(w, :memory_guard)
    catch
    end
    return nothing
end
