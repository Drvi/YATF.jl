# Human-facing output for a plan. `--dry-run` prints this and stops.

function print_plan(io::IO, p::Plan; show_excluded::Vector{String} = String[])
    cfg = p.cfg
    n = nitems(p)
    println(
        io, "YATF plan: ", plural(n, "test item"), " in ", plural(length(p.units), "unit"),
        " on ", plural(nslots(p), "worker")
    )
    println(io)
    println(io, "configuration")
    for (k, v) in (
            ("workers", cfg.workers == 0 ? "0 (single process)" : string(cfg.workers)),
            ("threads", cfg.threads), ("timeout", "$(cfg.timeout_s)s"),
            ("retries", string(cfg.retries)), ("logs", string(cfg.logs)),
            ("failfast", string(cfg.failfast)),
            ("memory_threshold", string(cfg.memory_threshold)),
        )
        println(io, "  ", rpad(k, 17), v)
    end
    if !isempty(p.setups)
        println(io, "  ", rpad("setups", 17), join(p.setups, ", "))
    end
    println(io)
    for s in 1:nslots(p)
        pool = p.pools[p.slot_pool[s]]
        prof = p.profiles[pool.profile]
        units = p.slot_units[s]
        est = sum(u -> p.units.est_s[u], units; init = 0.0)
        print(io, "worker ", s, "  profile=", prof.name)
        pool.exclusive && print(io, " exclusive")
        isempty(prof.julia_args) || print(io, " ", join(prof.julia_args, " "))
        print(io, "  ", plural(length(units), "unit"))
        est > 0 && print(io, ", est ", fmt_seconds(est))
        println(io)
        for u in units
            print_unit(io, p, u, "    ")
        end
    end
    for k in p.pending
        pool = p.pools[k]
        prof = p.profiles[pool.profile]
        println(
            io, "waiting for a free worker  profile=", prof.name,
            pool.exclusive ? " exclusive" : "", "  ", plural(length(pool.units), "unit")
        )
    end
    if !isempty(show_excluded)
        println(io)
        println(io, "excluded: ", length(show_excluded), " items")
        for line in show_excluded
            println(io, "  ", line)
        end
    end
    return nothing
end

function print_unit(io::IO, p::Plan, u::UnitIdx, indent::AbstractString)
    span = p.units.span[u]
    chain = p.units.chain[u]
    return if chain !== NO_CHAIN
        println(io, indent, "chain :", chain, " (", length(span), " items, sequential)")
        for i in span
            print_item(io, p, i, indent * "  ")
        end
    else
        for i in span
            print_item(io, p, i, indent)
        end
    end
end

function print_item(io::IO, p::Plan, i::ItemIdx, indent::AbstractString)
    it = p.items
    est = p.units.est_s[it.unit[i]]
    print(
        io, indent, rpad(repr(it.name[i]), 34), " ",
        p.relfiles[it.fileidx[i]], ":", it.line[i]
    )
    tags = tags_of(it, i)
    isempty(tags) || print(io, "  [", join(tags, ","), "]")
    it.timeout_s[i] == USE_RUN_DEFAULT || print(io, "  timeout=", it.timeout_s[i], "s")
    setups = setups_of(it, i)
    isempty(setups) || print(io, "  setups=", join(setups, ","))
    println(io)
    return nothing
end

# The plural is spelled out when adding an `s` does not make one: "2 processs" is
# the kind of thing a reader notices instead of the number in front of it.
plural(n::Integer, one::AbstractString, many::AbstractString = one * "s") =
    string(n, " ", n == 1 ? one : many)

# The same shape `Test` uses for its own Time column, so every duration a run
# prints reads the same way.
function fmt_seconds(s::Real)
    s < 60 && return string(round(s; digits = 1), "s")
    m, rest = divrem(s, 60)
    return string(round(Int, m), "m", lpad(string(round(rest; digits = 1)), 4, "0"), "s")
end

### Run output #############################################################

"""
    yatf_prefix(io=stdout) -> String

The one prefix the framework speaks under. Everything YATF says about a run — the
scan, the header, the progress line, the closing summary — starts with it, so a
reader can tell the framework's voice from the tests' at a glance.

Indented by [`GUTTER`](@ref): the things YATF says that take more than one line are
drawn in a bracket, and the two columns the bracket's gutter occupies are the two
this leaves blank, so every `[YATF]` in a run starts in the same column.
"""
function yatf_prefix(io::IO = stdout)
    buf = IOBuffer()
    print(buf, GUTTER)
    printstyled(IOContext(buf, :color => get(io, :color, false)::Bool), "[YATF] "; bold = true)
    return String(take!(buf))
end

"""
    GUTTER

What a bracket's `┌ `, `│ ` and `└ ` occupy, as blanks. A line YATF prints that
needs no bracket leaves that room so it lines up with the ones that do.
"""
const GUTTER = "  "

# Worker lifecycle, test items and the run's own report share one line shape, so
# they line up in a log and a reader can skim by glyph before reading:
#     ⚫ w1 · 16:30:28 · UP   · pid 48123 · threads 2,1
#     🔵 w1 · 16:30:28 · RUN  ·  1/11 · "passes" · at test/basics_test.jl:1
#     🟢 w1 · 16:30:29 · DONE ·  1/11 · "passes" · PASS ·   0.2s ( 3% compile) · maxrss 0.4 GiB
#     ⚪ w0 · 16:30:29 · INFO ·  3/11 · 0 failed · 2/2 workers · tree mem 1.1G (max 1.2G) · …
#
# A circle is the framework speaking, and its colour is the news: blue in flight,
# green passed, red not, yellow set aside, black the worker itself, white the run
# reporting on itself. The one glyph that is not a circle is the one line that is
# not the framework — `MARK_ITEM`, for what a test item printed for itself.
#
# Every glyph here is two columns wide in Unicode's width tables and carries no
# variation selector, which is what keeps the `w1 |` column in the same place on
# every line. The obvious picks — 🛠️ and ℹ️ — are width 1 in those tables and
# width 2 in most terminals, and a log comes out ragged wherever the two disagree.
const MARK_WORKER = "⚫"   # a worker's own lifecycle
const MARK_ITEM = "🧪"   # whatever a test item printed for itself
const MARK_INFO = "⚪"   # the run reporting on itself
const MARK_INDENT = "   "

# A test item's own lines come in already carrying the glyph for how the item went
# (`YATFWorkers.ITEM_MARKS`): blue while it runs, then the colour of its outcome.
# Anything else is unlabelled output from the worker's stdout, and which of the
# last two it gets depends on whether an item was running when it arrived: a print
# from a test is the item talking, a signal backtrace from a process being taken
# down is not.
const LINE_MARKS = (YATFWorkers.ITEM_MARKS..., MARK_ITEM, MARK_WORKER)
const MARK_IDX_ITEM = length(YATFWorkers.ITEM_MARKS) + 1
const MARK_IDX_WORKER = length(YATFWorkers.ITEM_MARKS) + 2

"""
    mark_index(line) -> (index, at)

Which of [`LINE_MARKS`](@ref) a relayed line calls for, and the byte its text
starts at.

A line the worker's own `log_item` wrote begins with its glyph and a space; a line
a test item printed begins with whatever the item printed. Splitting them here is
what lets the worker choose the colour and the coordinator choose the layout.
"""
function mark_index(line::AbstractString)
    for (i, mark) in pairs(YATFWorkers.ITEM_MARKS)
        startswith(line, mark) && return i, ncodeunits(mark) + 2
    end
    return MARK_IDX_ITEM, 1
end

# `MARK_INDENT`, a glyph and a trailing space: what a line with no worker to name
# is drawn with, one per glyph so the common path is a single concatenation.
const SOLO_PREFIXES = ntuple(i -> string(MARK_INDENT, LINE_MARKS[i], " "), length(LINE_MARKS))

# The lead-in every one of those lines shares: the glyph, the worker it is about,
# and the time. The clock is passed in rather than read here, because the line
# that is redrawn after everything else the run prints has a cheaper way to get it
# than formatting one per draw.
function print_line_head(io::IO, mark::AbstractString, slot_id::Integer, clock::AbstractString)
    print(io, MARK_INDENT, mark, " w")
    print_int(io, slot_id)
    print(io, FIELD, clock, FIELD)
    return nothing
end

# A run with no workers has nothing to number. The column is dropped rather than
# filled with a zero that stands for a process nobody asked for.
function print_line_head(io::IO, mark::AbstractString, ::Nothing, clock::AbstractString)
    print(io, MARK_INDENT, mark, " ", clock, FIELD)
    return nothing
end

# Everything a test item says when it is running here rather than on a worker.


clock_now() = Libc.strftime("%H:%M:%S", time())

# `printstyled` builds a closure and a padded string per call, and the status line
# is redrawn after every line the run prints.
function print_bold(io::IO, text::AbstractString)
    bold = get(io, :color, false)::Bool
    bold && print(io, "\e[1m")
    print(io, text)
    bold && print(io, "\e[22m")
    return nothing
end

function print_worker_line(run, slot_id, state::AbstractString, text::AbstractString)
    buf = IOBuffer()
    io = IOContext(buf, :color => get(stdout, :color, false)::Bool)
    print_line_head(io, MARK_WORKER, slot_id, clock_now())
    printstyled(io, rpad(state, WORKER_STATE_WIDTH); bold = true)
    print(io, FIELD, text)
    printline(run, String(take!(buf)))
    return nothing
end

"""
    print_run_header(run)

The handful of facts about a run that are not visible from the call: which YATF
and which Julia, how much work, how many processes with what given to them, and
the environment it all resolved to. Printed once.
"""
# Where the time before the first test item went. On a large suite this is the
# part people wait through, and without a line for it the wait looks like nothing
# happening.
function print_startup(io::IO, s::Startup)
    parts = String[]
    s.files > 0      && push!(parts, string("files ", fmt_seconds(s.files)))
    s.env > 0.005    && push!(parts, string("environment ", fmt_seconds(s.env)))
    s.plan > 0.005   && push!(parts, string("plan ", fmt_seconds(s.plan)))
    s.precompile > 0.005 && push!(parts, string("precompile ", fmt_seconds(s.precompile)))
    isempty(parts) || println(io, "startup: ", join(parts, " · "))
    return nothing
end

function print_run_header(run)
    p = run.plan
    head = IOBuffer()
    print(
        head, pkgversion(@__MODULE__), " · julia ", VERSION, " · ", plural(nitems(p), "test item"),
        " in ", plural(length(p.files), "file")
    )
    # The commit, so a CI log says what to check out to reproduce this run.
    rev = project_revision(p.root)
    isempty(rev) || print(head, " · rev ", first(rev, 10))
    p.cfg.workers == 0 ? print(head, " · in this process") :
        print(
            head, " · ", plural(length(run.slots), "worker"), " · threads ",
            p.profiles[1].threads
        )
    body = IOBuffer()
    println(body, "env ", something(Base.active_project(), "none"))
    print_startup(body, p.startup)
    # Only profiles that actually change something are worth a line.
    for prof in p.profiles
        parts = String[]
        isempty(prof.julia_args) || push!(parts, join(prof.julia_args, " "))
        prof.threads == p.profiles[1].threads || push!(parts, string("threads ", prof.threads))
        isempty(prof.env) || push!(parts, join(("\$k=\$v" for (k, v) in prof.env), " "))
        isempty(prof.init.args) || push!(parts, "init expression")
        isempty(parts) && continue
        println(body, "profile ", prof.name, ": ", join(parts, " · "))
    end
    print_yatf_block(run, String(take!(head)), String(take!(body)))
    return nothing
end

"""
    print_yatf_block(run, head, body)

Something YATF has to say that runs to more than one line, drawn in a bracket.

The bracket is what makes a block one thing rather than a first line and some
stray indented text underneath it, which matters most when several workers are
printing at once. A block with nothing under its first line is not a block, and
is printed as the plain line it is.
"""
function print_yatf_block(run, head::AbstractString, body::AbstractString)
    isempty(strip(body)) && return printline(run, string(yatf_prefix(), head))
    return printline(run, bracket(body, "[YATF]", head, "", :white))
end

"""
    printline(run, text)

The one way anything reaches the terminal during a run. Erases the pinned status
line, writes `text` whole, and puts the status line back, all while holding the
printer lock — so a log record, a worker's relayed output and the status line can
never end up on the same line.
"""
function printline(run, text::AbstractString)
    @lock run.printer begin
        m = run.monitor
        if m === nothing || !drawing(m)
            print(stdout, text)
            endswith(text, "\n") || println(stdout)
            flush(stdout)
        else
            write(stdout, status_update!(m, text))
            flush(stdout)
        end
    end
    return nothing
end
"""
    RunLogger

Routes every log record produced during a run through [`printline`](@ref). Log
records are formatted whole and then written once: a `ConsoleLogger` writing
straight to `stdout` emits a record in several writes, which is how a warning ends
up spliced into the status line.
"""
struct RunLogger{L <: Logging.AbstractLogger} <: Logging.AbstractLogger
    parent::L
    run::Any
end

Logging.min_enabled_level(l::RunLogger) = Logging.min_enabled_level(l.parent)
Logging.shouldlog(l::RunLogger, args...) = Logging.shouldlog(l.parent, args...)
Logging.catch_exceptions(l::RunLogger) = Logging.catch_exceptions(l.parent)

function Logging.handle_message(
        l::RunLogger, level, message, _module, group, id,
        file, line; kwargs...
    )
    buf = IOBuffer()
    io = IOContext(buf, :color => get(stdout, :color, false)::Bool)
    formatter = Logging.ConsoleLogger(io, Logging.BelowMinLevel)
    Logging.handle_message(formatter, level, message, _module, group, id, file, line; kwargs...)
    printline(l.run, String(take!(buf)))
    return nothing
end


print_failfast(run, i::ItemIdx) = printline(
    run, string(
        yatf_prefix(), "stopping after ", repr(run.plan.items.name[i]), " failed (failfast)"
    )
)

"""
    print_conclusion(run)

The block that closes a run. On a terminal it lands where the progress line was,
so the last thing on screen says how the run went rather than which items
happened to finish last.
"""
function print_conclusion(run)
    p = run.plan
    st = run.statuses
    head = IOBuffer()
    print(
        head, "ran ", plural(nitems(p), "test item"), " in ", fmt_seconds(time() - run.t0),
        single_process(p) ? " in this process" : string(" on ", plural(length(run.slots), "worker"))
    )
    tally = state_tally(st, nitems(p))
    print(head, isempty(tally) ? ", all passed" : string(", ", join(tally, ", ")))
    body = IOBuffer()
    run.monitor === nothing || print_memory_summary(body, run.monitor; indent = "")
    run.runstate === nothing || println(body, "run state: ", run.runstate.path)
    print_yatf_block(run, String(take!(head)), String(take!(body)))
    return nothing
end

# Everything that is not a plain pass, in the order a reader cares about.
function state_tally(st, n::Integer)
    out = String[]
    for (state, label) in (
            (FAILED, "failed"), (ERRORED, "errored"), (TIMEDOUT, "timed out"),
            (BROKEN_CHAIN, "broken by a dead worker"), (SKIPPED, "skipped"),
            (CANCELLED, "cancelled"), (UNSEEN, "did not run"),
        )
        c = count(==(state), st.state)
        c > 0 && push!(out, string(c, " ", label))
    end
    return out
end

# A file's wall time: from the first of its items being dispatched to the last of
# them finishing. With several workers those spans overlap between files, so they
# do not sum to the run's wall time — the root row is that.
function file_testset(run, fid::Int32)
    p = run.plan
    st = run.statuses
    first_start, last_end = Inf32, -Inf32
    for i in 1:nitems(p)
        (p.items.fileidx[i] == fid && st.state[i] !== UNSEEN) || continue
        first_start = min(first_start, st.start[i])
        last_end = max(last_end, st.start[i] + st.elapsed[i])
    end
    name = p.relfiles[fid]
    isfinite(first_start) || return Test.DefaultTestSet(name; verbose = p.cfg.verbose)
    ts = Test.DefaultTestSet(name; verbose = p.cfg.verbose, time_start = run.t0 + first_start)
    @atomic ts.time_end = run.t0 + last_end
    return ts
end

"""
    report(run) -> Test.AbstractTestSet

Fold every item's testset into one tree, print the summary, and throw if anything
did not pass so that a test run fails the way `Pkg.test` does.
"""
function report(run)
    p = run.plan
    st = run.statuses
    # `Test` prints `time_end - time_start` in its own Time column, so the run's
    # times are put where it already looks rather than into a column of our own.
    # The root's clock starts when the run did, so its row is the run's wall time.
    root = Test.DefaultTestSet("YATF"; verbose = true, time_start = run.t0)
    byfile = Dict{Int32, Test.DefaultTestSet}()
    for fid in sort!(unique(p.items.fileidx))
        byfile[fid] = file_testset(run, fid)
    end
    for i in 1:nitems(p)
        ts = st.testsets[i]
        ts === nothing && continue
        Test.record(byfile[p.items.fileidx[i]], ts)
    end
    for fid in sort!(collect(keys(byfile)))
        Test.record(root, byfile[fid])
    end
    record_unrun!(root, run)
    print_conclusion(run)
    Test.finish(root)
    return root
end

# An item that never ran is not an item that passed. A run cut short — by a
# profile whose `init` expression will not start, by a slot that fell over, by
# failfast — leaves items with no testset to fold in, and folding nothing would
# make the emptiest possible run the greenest. So what is missing is recorded.
function record_unrun!(root::Test.AbstractTestSet, run)
    p = run.plan
    st = run.statuses
    idxs = [i for i in 1:nitems(p) if st.state[i] === UNSEEN || st.state[i] === CANCELLED]
    isempty(idxs) && return nothing
    shown = join((repr(p.items.name[i]) for i in Iterators.take(idxs, 5)), ", ")
    msg = string(
        length(idxs), " of ", plural(nitems(p), "test item"), " did not run because the run ",
        "stopped early: ", shown, length(idxs) > 5 ? ", …" : ""
    )
    # The conclusion block above says the same thing in the run's own words; this
    # record exists so the verdict is wrong when the run was.
    with_testset_printing(false) do
        Test.record(
            root, Test.Error(
                :nontest_error, Expr(:tuple), ErrorException(msg), exception_stack(msg),
                LineNumberNode(Int(p.items.line[first(idxs)]), p.files[p.items.fileidx[first(idxs)]])
            )
        )
    end
    return nothing
end

# `Test` prints a failure where it is recorded, which for us is on a worker with
# printing switched off. So the coordinator prints them itself: a summary table
# that says "2 errors" without saying what they were is not a test report.
"""
    report_item!(run, i, state)

Everything an item has to say, said when the item finishes rather than at the end
of the run, and written in one piece so another worker's output cannot land in the
middle of it: the failures first, then the captured logs — a failure is read
together with the output that led to it.
"""
function report_item!(run, i::ItemIdx, state::ItemState, n::Integer, msg::AbstractString)
    p = run.plan
    # Having nothing to say is the common case — a passing item in `:issues` mode —
    # and everything below this line allocates to find that out.
    (is_non_pass(state) || wants_log(p.cfg.logs, state) || p.cfg.verbose) || return nothing
    body = IOBuffer()
    io = IOContext(body, :color => get(stdout, :color, false)::Bool)
    # A coordinator-written outcome — a timeout, a dead worker — is already stated
    # in this block's first line; showing the record it synthesized would say it
    # again, word for word.
    is_non_pass(state) && !run.statuses.synthetic[i] && print_failures(io, run, i)
    print_item_log(io, run, i, state)
    body.size == 0 && return nothing
    total = nitems(p)
    label = string("[", lpad(n, ndigits(total)), "/", total, "] ", YATFWorkers.short_state(state))
    rest = string(repr(p.items.name[i]), isempty(msg) ? "" : string(" · ", msg))
    footer = string(
        "@ ", itemfile(p, i), ":", p.items.line[i], on_worker(run, i)
    )
    printline(
        run, bracket(
            strip_root(String(take!(body)), p.root), label, rest, footer,
            YATFWorkers.state_color(state)
        )
    )
    return nothing
end

"""
    bracket(body, header, footer, color) -> String

Everything one item has to say, drawn as a single block in the shape `Logging`
uses for a multi-line record: `┌` on the first line, `│` down the side, `└` on the
last. Test failures, captured logs and the odd crash dump then read as one thing
rather than as unrelated paragraphs from whichever worker got there first.
"""
function bracket(
        body::AbstractString, label::AbstractString, rest::AbstractString,
        footer::AbstractString, color
    )
    buf = IOBuffer()
    io = IOContext(buf, :color => get(stdout, :color, false)::Bool)
    # Coloured like a log record: the gutter and the label carry the colour, what
    # follows is ordinary text, and the location at the bottom is dimmed.
    printstyled(io, "┌ "; color, bold = true)
    printstyled(io, label; color, bold = true)
    isempty(rest) || print(io, " ", rest)
    println(io)
    lines = collect(eachsplit(chomp(body), '\n'))
    # `└` carries the last thing there is, as a log record's does: the location
    # when there is one, and otherwise the final line of the body.
    tail = isempty(footer) && !isempty(lines) ? pop!(lines) : nothing
    for line in lines
        printstyled(io, "│ "; color, bold = true)
        println(io, line)
    end
    printstyled(io, isempty(footer) && tail === nothing ? "└" : "└ "; color, bold = true)
    if tail !== nothing
        println(io, tail)
    elseif isempty(footer)
        println(io)
    else
        printstyled(io, footer; color = :light_black)
        println(io)
    end
    return String(take!(buf))
end

"""
    strip_root(text, root)

`text` with the project's own directory taken off the front of every path in it.

`Test` and the stacktrace printer name a file by the path the parser was given,
and that path is absolute on purpose: it is also what `@__FILE__` expands to, and
what `@__DIR__` is derived from, so a test item that loads a fixture next to
itself depends on it. The shortening therefore happens here, on the way out,
where it is presentation and cannot change what the item's code means.
"""
function strip_root(text::AbstractString, root::AbstractString)
    isempty(root) && return text
    out = replace(text, root * "/" => "")
    # The stacktrace printer contracts the home directory, so the same path
    # arrives spelled two ways.
    home = Base.contractuser(root)
    return home == root ? out : replace(out, home * "/" => "")
end

function print_failures(io::IO, run, i::ItemIdx)
    ts = run.statuses.testsets[i]
    ts === nothing && return nothing
    for r in collect_failures(ts)
        show(io, r)
        println(io)
    end
    return nothing
end

# `:eager` output was relayed as it happened; `:batched` prints every item's
# output, `:issues` only that of items with something wrong.
wants_log(logs::Symbol, state::ItemState) =
    logs === :batched || (logs === :issues && is_non_pass(state))

function print_item_log(io::IO, run, i::ItemIdx, state::ItemState)
    p = run.plan
    wants_log(p.cfg.logs, state) || return nothing
    path = item_logpath(run, i)
    has_logs = isfile(path) && filesize(path) > 0
    # An item that failed and said nothing is worth saying so about: silence there
    # is a fact about the failure, not a reason to print nothing.
    (has_logs || is_non_pass(state) || p.cfg.verbose) || return nothing
    if !has_logs
        printstyled(io, "No captured logs"; bold = true, color = Base.info_color())
        println(io)
        return nothing
    end
    # A bracket of its own, nested inside the item's: what the item printed is one
    # thing, and its own `@info`/`@warn` records keep their brackets inside this
    # one. Written through rather than indented, so the item's formatting and
    # colours are the ones its author meant to see.
    logs = trim_blank_lines(open(io -> read(io, String), path, "r"))
    print(io, bracket(logs, "Captured logs", "", "", Base.info_color()))
    return nothing
end

# A crash dump or a triggered profile tends to start and end with blank lines,
# which inside a bracket become empty gutter rows.
trim_blank_lines(text::AbstractString) =
    replace(replace(text, r"\A(?:[ \t]*\n)+" => ""), r"(?:\n[ \t]*)+\z" => "")

# With no workers there is no worker to name: the slot exists so the scheduler has
# something to talk about, and saying "on worker 1" about this process is telling
# the reader about a process that was never started.
on_worker(run, i::ItemIdx) =
    (single_process(run.plan) || run.statuses.slot[i] == 0) ? "" :
    string(" on worker ", run.statuses.slot[i])

item_logpath(run, i::ItemIdx) =
    item_log_path(run.logprefix, i, max(run.statuses.attempt[i], 1))

"""
    item_log_path(prefix, index, attempt) -> String

Where one attempt at one item writes what it prints.

Built a byte at a time rather than with `string`, which boxes each number and runs
the whole `print` pipeline: seven allocations for a prefix, two integers and a
suffix, once for every dispatch in the run.
"""
function item_log_path(prefix::String, index::Integer, attempt::Integer)
    n = ncodeunits(prefix)
    buf = Vector{UInt8}(undef, n + ndigits(index) + ndigits(attempt) + 5)
    copyto!(buf, 1, codeunits(prefix), 1, n)
    k = write_digits!(buf, n, index)
    buf[k += 1] = UInt8('_')
    k = write_digits!(buf, k, attempt)
    for c in codeunits(".log")
        buf[k += 1] = c
    end
    return String(buf)
end

function write_digits!(buf::Vector{UInt8}, k::Int, n::Integer)
    for p in (ndigits(n) - 1):-1:0
        buf[k += 1] = UInt8('0') + UInt8((n ÷ 10^p) % 10)
    end
    return k
end

function collect_failures(ts::Test.AbstractTestSet, out = Any[])
    for r in ts.results
        if r isa Test.Fail || r isa Test.Error
            push!(out, r)
        elseif r isa Test.AbstractTestSet
            collect_failures(r, out)
        end
    end
    return out
end
