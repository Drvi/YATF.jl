# Human-facing output for a plan. `--dry-run` prints this and stops.

function print_plan(io::IO, p::Plan; show_excluded::Vector{String} = String[])
    order = run_order(p)
    print(io, plan_block(p, order))
    print_plan_table(io, p, order)
    if !isempty(show_excluded)
        println(io)
        println(io, "excluded: ", length(show_excluded), " items")
        for line in show_excluded
            println(io, "  ", line)
        end
    end
    return nothing
end

# What the plan is for and what it was made from, in the bracket a run's header is
# drawn in: the table below it is the plan.
function plan_block(p::Plan, order)
    cfg = p.cfg
    head = sprint() do io
        print(io, "dry run · ")
        print_work(io, p, single_process(p) ? 0 : nslots(p))
    end
    body = sprint() do io
        print_startup(io, p.startup)
        isempty(p.setups) || println(io, "setups: ", join(("`$s`" for s in p.setups), ", "))
        println(io, "timeout: ", cfg.timeout_s, "s · retries: ", cfg.retries, " · failfast: ", cfg.failfast,
                " · logs: ", cfg.logs, " · memory_threshold: ", cfg.memory_threshold)
        print_profiles(io, p)
        estimated = any(>(0), p.units.est_s)
        if !single_process(p)
            estimated && println(io, "estimated work: ",
                                 join(("w$s $(est_text(w))" for (s, w) in enumerate(order.work)), " · "))
            println(io, "order and workers: predicted ",
                    estimated ? "from the recorded durations, an item without one counting as a typical one" :
                        "as if every item took as long, since no durations are recorded yet")
        end
    end
    return bracket(body, "[YATF]", head, "", :white)
end

# The opening words of a run's header and of a dry run's: which YATF and Julia, how
# much work, and on how many processes.
function print_work(io::IO, p::Plan, nworkers::Integer; seed::Union{Nothing, UInt64} = nothing)
    print(io, "v", pkgversion(@__MODULE__), " · julia ", VERSION, " · ", plural(nitems(p), "test item"),
          " in ", plural(length(p.files), "file"))
    isempty(p.selection) || print(io, " matching ", p.selection)
    # The commit, so a CI log says what to check out to reproduce this run.
    rev = project_revision(p.root)
    isempty(rev) || print(io, " · rev ", first(rev, 10))
    seed === nothing || print(io, " · seed ", seed_text(seed))
    p.cfg.workers == 0 ? print(io, " · in this process") :
        print(io, " · ", plural(nworkers, "worker"), " · threads ", p.profiles[1].threads)
    return nothing
end

# Only profiles that actually change something are worth a line.
function print_profiles(io::IO, p::Plan)
    for prof in p.profiles
        parts = String[]
        isempty(prof.julia_args) || push!(parts, join(prof.julia_args, " "))
        prof.threads == p.profiles[1].threads || push!(parts, string("threads ", prof.threads))
        isempty(prof.env) || push!(parts, join(("$k=$v" for (k, v) in prof.env), " "))
        isempty(prof.init.args) || push!(parts, "init expression")
        isempty(prof.test_end.args) || push!(parts, "test end expression")
        isempty(parts) || println(io, "profile `", prof.name, "`: ", join(parts, " · "))
    end
    return nothing
end

"""
    run_order(p) -> (; items, work)

The order the run is expected to start the items in, and where: its own dispatch
(`claim!`) played out with each unit taking as long as the recorded runs say, and a
unit nothing is recorded for counting as a typical one. `items` holds `(start,
worker, item)` in that order, a chain's members spread over its time; `work` is each
worker's estimated seconds. A run without workers takes the units in plan order.
"""
function run_order(p::Plan)
    est = [e > 0 ? e : typical_estimate(p.units.est_s) for e in p.units.est_s]
    items = Tuple{Float64, Int, ItemIdx}[]
    function started!(t, s, u)
        span = p.units.span[u]
        for (k, i) in enumerate(span)
            push!(items, (t + (k - 1) * est[u] / length(span), s, i))
        end
    end
    if single_process(p)
        t = 0.0
        for u in UnitIdx(1):UnitIdx(length(p.units))
            started!(t, 1, u)
            t += est[u]
        end
        return (; items, work = [t])
    end
    q = Queues(p)
    free = zeros(nslots(p))
    done = falses(nslots(p))
    while !all(done)
        # The next worker to ask is the first free, and the lowest numbered of those.
        s = argmin(k -> (done[k], free[k], k), 1:nslots(p))
        claim = claim!(q, s)
        claim.kind === :done && (done[s] = true; continue)
        claim.kind === :rebind && continue
        started!(free[s], s, claim.unit)
        free[s] += est[claim.unit]
    end
    return (; items = sort!(items; by = x -> (x[1], x[2])), work = free)
end

# An estimate as the dry run gives it: to a tenth of a second like every other
# duration, but a sub-second one to two figures, which a tenth would round to 0.0s.
est_text(s::Real) = s < 1 ? string(round(s; sigdigits = 2), "s") : fmt_seconds(s)

"""
    why_text(p, u) -> String

Why unit `u` is handed out where it is, for the dry run: empty for a unit in its
worker's stretch, where file order put it.
"""
function why_text(p::Plan, u::UnitIdx)
    why = p.units.why[u]
    why === PINNED_FIRST && return "[order] first"
    why === PINNED_LAST && return "[order] last"
    why === SANDBOXED && return "sandbox"
    why === LONG && return string("long, est ", est_text(p.units.est_s[u]))
    why === RECENT || return ""
    ago = p.units.failed_ago[u]
    failed = ago < 0 ? "" : ago == 0 ? "failed in the last run" : string("failed ", ago + 1, " runs ago")
    changed = p.units.changed[u] ? "file changed since the last run" : ""
    return join(filter(!isempty, [failed, changed]), ", ")
end

# What an item row says about the item itself: the keywords it was declared with,
# the chain it belongs to, and the setups it loads.
function details_text(p::Plan, i::Integer)
    it = p.items
    u = it.unit[i]
    parts = String[]
    chain = p.units.chain[u]
    if chain !== NO_CHAIN
        span = p.units.span[u]
        push!(parts, string("chain `", chain, "` ", i - first(span) + 1, "/", length(span)))
    end
    # A sandbox is the reason it goes early, unless something else put it there.
    p.units.exclusive[u] && p.units.why[u] !== SANDBOXED && push!(parts, "sandbox")
    prof = p.profiles[p.units.profile[u]]
    prof.name === DEFAULT_PROFILE || push!(parts, string("profile `", prof.name, "`"))
    it.timeout_s[i] == USE_RUN_DEFAULT || push!(parts, string("timeout ", it.timeout_s[i], "s"))
    it.retries[i] == USE_RUN_DEFAULT || push!(parts, string("retries ", it.retries[i]))
    setups = setups_of(it, i)
    isempty(setups) || push!(parts, string(length(setups) == 1 ? "setup " : "setups ",
                                           join(("`$s`" for s in setups), ", ")))
    return join(parts, ", ")
end

"""
    shown_names(names, width; among = names) -> Vector{String}

Each of `names` as a column `width` wide shows it. A name that fits is quoted as it
is. One that does not becomes `r"^…"`: a prefix of it as long as fits, and never
shorter than the shortest prefix no other name in `among` starts with, so that
passed to `name=` it picks out that item and no other. `among` is every name in the
suite, since a filter can leave out the item whose name a prefix would also match. When even that prefix does
not fit, the name overruns the column with it; when no prefix is its own (the name
begins another), it overruns the column whole. With any name shortened, every name
gets a column in front of its opening quote, `r` or a space, so the quotes line up.
"""
function shown_names(names::Vector{String}, width::Integer; among::Vector{String} = names)
    quoted = [repr(n) for n in names]
    all(q -> textwidth(q) <= width, quoted) && return quoted
    # In sorted order, a name shares its longest prefix with one of its neighbours.
    pool = sort!(unique!(vcat(among, names)))
    common(a, b) = (k = 0; for (x, y) in zip(a, b); x == y || break; k += 1; end; k)
    need = map(names) do n
        j = searchsortedfirst(pool, n)
        before = j > 1 ? common(n, pool[j - 1]) : 0
        after = j < length(pool) ? common(n, pool[j + 1]) : 0
        max(before, after) + 1
    end
    shortened = map(eachindex(names)) do i
        n = names[i]
        textwidth(quoted[i]) <= width && return nothing
        need[i] >= length(n) && return nothing   # no prefix of its own, or none shorter
        # The longest prefix whose `"^…"` fits, but no shorter than `need`.
        k = need[i]
        while k + 1 < length(n) && textwidth(regex_prefix(n, k + 1)) - 1 <= width
            k += 1
        end
        return regex_prefix(n, k)
    end
    any(!isnothing, shortened) || return quoted
    return [s === nothing ? " " * q : s for (s, q) in zip(shortened, quoted)]
end

"""
    item_names(p, width) -> (names, column)

Every item's name as the run writes it in the name column, and the column's width:
one too long for `width` is shortened as [`shown_names`](@ref) does, unless the run
asked for `full_names`.
"""
function item_names(p::Plan, width::Integer)
    p.cfg.full_names && return [repr(n) for n in p.items.name], width
    names = shown_names(p.items.name, width; among = p.suite_names)
    # With any name shortened, every name has a column in front of its opening quote.
    return names, width + any(n -> !startswith(n, '"'), names)
end

# `r"^…"` for the first `k` characters of `name`, written as Julia source for a
# regular expression that matches those characters literally.
function regex_prefix(name::AbstractString, k::Integer)
    io = IOBuffer()
    print(io, "r\"^")
    for c in first(name, k)
        if c in "\\^\$.|?*+()[]{}"
            print(io, '\\', c)
        elseif c == '"'
            print(io, "\\\"")
        elseif !isprint(c)
            print(io, escape_string(string(c)))   # `\n`, `\x01`: escapes the regex reads too
        else
            print(io, c)
        end
    end
    print(io, '"')
    return String(take!(io))
end

"""
    print_plan_table(io, p, order)

Every test item, a row each, in the order the run is expected to start them (see
[`run_order`](@ref)): the worker expected to run it, where it is, its tags, why it
goes where it does when that is not file order, and what it was declared with.
Columns are separated as the fields of the run's lines are, and each is as wide as
the widest thing in it; a column nothing fills is left out. The names are written
as the run's lines write them (see [`item_names`](@ref)).
"""
function print_plan_table(io::IO, p::Plan, order)
    it = p.items
    n = nitems(p)
    solo = single_process(p)
    rows = [i for (_, _, i) in order.items]
    workers = [string("w", s) for (_, s, _) in order.items]
    shown, column = item_names(p, name_width(it.name))
    names = [shown[i] for i in rows]
    locations = [string(p.relfiles[it.fileidx[i]], ":", it.line[i]) for i in rows]
    tags = [join(tags_of(it, i), ", ") for i in rows]
    # A chain's reason is its first item's: the unit is placed, not each member.
    whys = [i == first(p.units.span[it.unit[i]]) ? why_text(p, it.unit[i]) : "" for i in rows]
    details = [details_text(p, i) for i in rows]
    columns = Tuple{String, Vector{String}}[]
    push!(columns, ("#", [string(i) for i in 1:n]))
    solo || push!(columns, ("worker", workers))
    push!(columns, ("test item", names))
    push!(columns, ("at", locations))
    any(!isempty, tags) && push!(columns, ("tags", tags))
    any(!isempty, whys) && push!(columns, ("why here", whys))
    any(!isempty, details) && push!(columns, ("details", details))
    # A name wider than the column overruns it rather than widening it for all.
    widths = map(columns) do (title, cells)
        title == "test item" ? max(length(title), column) :
            max(length(title), maximum(textwidth, cells; init = 0))
    end
    println(io)
    for r in 0:n
        print(io, GUTTER)
        # A row ends at its last filled column: the empty ones after it are left
        # off, separators and all, while an empty one before it keeps its place.
        cells = [r == 0 ? title : col[r] for (title, col) in columns]
        last_ = something(findlast(!isempty, cells), 1)
        for c in 1:last_
            c == 1 || print(io, FIELD)
            # The number and the worker are right-aligned, the rest left, and the
            # last column is not padded.
            text = columns[c][1] in ("#", "worker") ? lpad(cells[c], widths[c]) :
                c == last_ ? cells[c] : rpad(cells[c], widths[c])
            r == 0 ? print_bold(io, text) : print(io, text)
        end
        println(io)
    end
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

The prefix everything YATF says about a run starts with, indented by
[`GUTTER`](@ref) so that it lines up with the text inside a bracket.
"""
yatf_prefix(io::IO = stdout) =
    GUTTER * sprint(x -> printstyled(x, "[YATF] "; bold = true); context = :color => get(io, :color, false)::Bool)

# What a bracket's `┌ `, `│ ` and `└ ` occupy, as blanks.
const GUTTER = "  "

# Worker lifecycle, test items and the run's own report share one line shape:
#     ⚫ w1 · 16:30:28 · UP   · pid 48123 · threads 2,1
#     🔵 w1 · 16:30:28 · RUN  ·  1/11 · "passes" · at test/basics_test.jl:1
#     🟢 w1 · 16:30:29 · DONE ·  1/11 · "passes" · PASS ·   0.2s ( 3% compile) · maxrss 0.4 GiB
#     ⚪ w0 · 16:30:29 · INFO ·  3/11 · 0 failed · 2/2 workers · tree mem 1.1G (max 1.2G) · …
#        w1 · whatever a test item printed for itself
#
# A circle is the framework speaking, and its colour is the news: blue in flight,
# green passed, red not, yellow set aside, black the worker, white the run itself.
# What an item prints has no circle, since it is not the framework speaking.
# Every glyph is two columns wide in Unicode's tables and has no variation
# selector, which keeps the `w1` column in place; 🛠️ and ℹ️ are width 1 in the
# tables and width 2 in most terminals.
const MARK_RUNNING = "🔵"
const MARK_PASSED = "🟢"
const MARK_FAILED = "🔴"
const MARK_SET_ASIDE = "🟡"
const MARK_WORKER = "⚫"
const MARK_ITEM = "  "   # as wide as a glyph, and blank
const MARK_INFO = "⚪"

const FIELD = " · "
const WORKER_STATE_WIDTH = 4   # "DONE", "EXIT", "KILL", "LOST", "INFO"; "RUN" and "UP" are shorter
const STATE_WIDTH = 4          # "PASS"; the rarer outcomes are longer and may push the line
const TIME_WIDTH = 5           # "99.9s"

# One unit each, always: a column that switches between ms and s, or MiB and GiB,
# cannot be compared down the page at a glance.
fmt_secs(s::Real) = string(round(s; digits = 1), "s")
fmt_gib(b::Real) = string(round(b / 2^30; digits = 1), " GiB")

# Four columns for the common outcomes; the rare ones are spelled out and may push
# the line.
short_state(state::ItemState) =
    state === PASSED ? "PASS" : state === FAILED ? "FAIL" : state === ERRORED ? "ERR" :
    state === SKIPPED ? "SKIP" : state === TIMEDOUT ? "TIMEOUT" :
    state === BROKEN_CHAIN ? "BROKEN" : state === CANCELLED ? "CANCELLED" : string(state)

# `Test`'s palette, so an outcome looks the same here as in `Test`'s summary.
state_color(state::ItemState) =
    state === PASSED ? :green : state === SKIPPED || state === CANCELLED ? Base.warn_color() :
    is_non_pass(state) ? Base.error_color() : :default
state_mark(state::ItemState) =
    state === PASSED ? MARK_PASSED : state === SKIPPED || state === CANCELLED ? MARK_SET_ASIDE :
    is_non_pass(state) ? MARK_FAILED : MARK_RUNNING

# The width of a name as `repr` writes it, without building the copy when there is
# nothing to escape, which is almost every name.
needs_escaping(s::AbstractString) = any(c -> c == '"' || c == '\\' || c == '$' || !isprint(c), s)
quoted_width(name::AbstractString) = needs_escaping(name) ? textwidth(repr(name)) : textwidth(name) + 2

# Written a byte at a time: the status line pads several numbers on every redraw.
function pad_to(io::IO, width::Integer, used::Integer)
    for _ in 1:(width - used)
        write(io, UInt8(' '))
    end
    return nothing
end

# Bounds on the name column: narrower is not worth aligning, wider is a column of
# blanks on a line nobody can read anyway.
const MIN_NAME_WIDTH = 12
const MAX_NAME_WIDTH = 60
# The column may leave this share of the names to overflow, and always at least
# this many: one wild name among five should not set the width for the other four.
const NAME_OUTLIER_SHARE = 10
const NAME_OUTLIER_ALLOWANCE = 2
# ...but covers a tail that is this close, rather than leave it to overflow.
const NAME_TAIL_SLACK = 8
# What the rest of a DONE line takes at its widest.
const LINE_RESERVED = 82

"""
    name_width(names; columns = 0) -> Int

One width for the name column for the whole run, so the columns after it stay put:
the widest name once the allowed outliers are set aside, extended through the
names above it while each is within `NAME_TAIL_SLACK`. Two thousand ten-character
names and two of sixty get a ten-wide column and two long lines. `columns` is the
terminal's width, or `0` when there is none.
"""
function name_width(names; columns::Integer = 0)
    isempty(names) && return MIN_NAME_WIDTH
    widths = sort!([quoted_width(n) for n in names])
    n = length(widths)
    allowed = max(NAME_OUTLIER_ALLOWANCE, n ÷ NAME_OUTLIER_SHARE)
    wanted = widths[max(1, n - allowed)]
    for j in (max(1, n - allowed) + 1):n
        widths[j] - wanted <= NAME_TAIL_SLACK || break
        wanted = widths[j]
    end
    # The floor is on the budget, not the answer: names all eight wide want an
    # eight-wide column, not a floor's worth of blanks after each.
    budget = columns > 0 ? clamp(columns - LINE_RESERVED, MIN_NAME_WIDTH, MAX_NAME_WIDTH) : MAX_NAME_WIDTH
    return min(wanted, budget)
end

clock_now() = Libc.strftime("%H:%M:%S", time())

# The start every line shares: glyph, the worker it is about (none in a run
# without workers), and the time. The clock is passed in because the status line,
# redrawn after everything the run prints, has a cheaper way to get it.
function print_line_head(io::IO, mark::AbstractString, slot_id, clock::AbstractString)
    print(io, mark, " ")
    slot_id === nothing || (print(io, "w"); print_int(io, slot_id); print(io, FIELD))
    print(io, clock, FIELD)
    return nothing
end

print_word(io::IO, word::AbstractString) = (print_bold(io, rpad(word, WORKER_STATE_WIDTH)); print(io, FIELD))

# `printstyled` builds a closure and a padded string per call, and the status line
# is redrawn after every line the run prints.
function print_bold(io::IO, text::AbstractString)
    bold = get(io, :color, false)::Bool
    bold && print(io, "\e[1m")
    print(io, text)
    bold && print(io, "\e[22m")
    return nothing
end

# Text built for printing, in colour when the run's own output is.
styled(f) = sprint(f; context = :color => get(stdout, :color, false)::Bool)

# A line the run says about itself.
say(run, parts...) = printline(run, string(yatf_prefix(), parts...))

print_worker_line(run, slot_id, state::AbstractString, text::AbstractString) = printline(run, styled() do io
    print_line_head(io, MARK_WORKER, slot_id, clock_now())
    print_word(io, state)
    print(io, text)
end)

"""
    item_line(slot_id, i, total, shown, width, attempt, attempts, how) -> String

An item's RUN line when `how` is where it is, and its DONE line when `how` is how
it went: `(; state, elapsed_ns, compile_ns, maxrss)`. `shown` is its name as the
line writes it, quoted or shortened (see [`item_names`](@ref)), in a column `width`
wide. A retry is the same item again, so it gets the same line with a field of its
own; `total` is 0 when there is no count to give.
"""
item_line(slot_id, i, total, shown, width, attempt, attempts, how) = styled() do io
    done = !(how isa AbstractString)
    print_line_head(io, done ? state_mark(how.state) : MARK_RUNNING, slot_id, clock_now())
    print_word(io, done ? "DONE" : "RUN")
    total > 0 && print(io, lpad(i, ndigits(total)), "/", total, FIELD)
    # A name longer than the column pushes the rest out rather than being cut: the
    # name is what identifies the item, and a shortened one still does.
    print(io, shown)
    pad_to(io, width, textwidth(shown))
    attempt > 1 && print(io, FIELD, "retry ", attempt - 1, " of ", max(attempts - 1, 1))
    print(io, FIELD)
    if done
        pct = how.elapsed_ns > 0 ? round(Int, 100 * how.compile_ns / how.elapsed_ns) : 0
        printstyled(io, rpad(short_state(how.state), STATE_WIDTH); color = state_color(how.state))
        print(io, FIELD, lpad(fmt_secs(how.elapsed_ns / 1.0e9), TIME_WIDTH), " (", lpad(pct, 2), "% compile)")
        print(io, FIELD, "maxrss ", fmt_gib(how.maxrss))
    else
        print(io, "at ")
        print_bold(io, how)
    end
end

outcome(r::ItemResult) = (; r.state, r.stats.elapsed_ns, r.stats.compile_ns, r.stats.maxrss)

"""
    parse_record(line) -> Union{Nothing, NamedTuple}

A worker's record of an item starting or finishing (`YATFWorkers.record_run`,
`record_done`) as `(; i, attempt, how)`, with `how === nothing` for a start; or
`nothing` for any other line.
"""
function parse_record(line::AbstractString)
    startswith(line, YATFWorkers.RECORD_MARK) || return nothing
    word, rest... = split(SubString(line, ncodeunits(YATFWorkers.RECORD_MARK) + 1), ' ')
    n = map(x -> tryparse(Int, x), rest)
    any(isnothing, n) && return nothing
    word == "RUN" && length(n) == 2 && return (; i = n[1], attempt = n[2], how = nothing)
    (word == "DONE" && length(n) == 6 && 0 <= n[3] <= Int(CANCELLED)) || return nothing
    return (; i = n[1], attempt = n[2], how = (; state = ItemState(n[3]), elapsed_ns = n[4], compile_ns = n[5], maxrss = n[6]))
end

# Where the time before the first test item went: on a large suite, the wait.
function print_startup(io::IO, s::Startup)
    parts = String[]
    s.files > 0      && push!(parts, string("files ", fmt_seconds(s.files)))
    s.plan > 0.005   && push!(parts, string("plan ", fmt_seconds(s.plan)))
    s.setup > 0.005  && push!(parts, string("setup ", fmt_seconds(s.setup)))
    isempty(parts) || println(io, "startup: ", join(parts, " · "))
    return nothing
end

"""
    print_run_header(run)

What the call does not show: which YATF and Julia, how much work, how many
processes with what given to them, and the environment it resolved to.
"""
function print_run_header(run)
    p = run.plan
    head = sprint(io -> print_work(io, p, length(run.slots); seed = p.cfg.seed))
    body = sprint() do io
        println(io, "env: ", something(Base.active_project(), "none"))
        print_startup(io, p.startup)
        print_profiles(io, p)
    end
    print_yatf_block(run, head, body)
    return nothing
end

"""
    print_yatf_block(run, head, body)

Something YATF says that runs to more than one line, drawn in a bracket so that it
reads as one block among the workers' output. With nothing under its first line it
is printed as the plain line it is.
"""
function print_yatf_block(run, head::AbstractString, body::AbstractString)
    isempty(strip(body)) && return say(run, head)
    return printline(run, bracket(body, "[YATF]", head, "", :white))
end

"""
    printline(run, text)

The one way anything reaches the terminal during a run: erase the pinned status
line, write `text` whole, and put the status line back, all under the printer lock,
so a log record, a worker's output and the status line never share a line.
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

Routes every log record of a run through [`printline`](@ref), formatted whole and
written once: a `ConsoleLogger` on `stdout` writes a record in several pieces, and
a warning ends up spliced into the status line.
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
    printline(l.run, styled() do io
        Logging.handle_message(Logging.ConsoleLogger(io, Logging.BelowMinLevel), level, message, _module, group, id, file, line; kwargs...)
    end)
    return nothing
end

print_failfast(run, i::ItemIdx) = say(run, "stopping after ", repr(run.plan.items.name[i]), " failed (failfast)")

"""
    print_conclusion(run, ended = :finished)

The block that closes a run. On a terminal it lands where the progress line was,
so the last thing on screen says how the run went rather than which items
happened to finish last. `ended` is `:interrupted` or `:stalled` for a run that was
stopped, which then says how far it got.
"""
function print_conclusion(run, ended::Symbol = :finished)
    p = run.plan
    st = run.statuses
    elapsed = fmt_seconds(time() - run.t0)
    tally = state_tally(st.state)
    # A run that was stopped got through some of its items, and how many is the news.
    head = string(
        ended !== :finished ?
            string(ended === :stalled ? "stopped as hung after " : "interrupted after ",
                   count(s -> s !== UNSEEN && s !== CANCELLED, st.state), " of ",
                   plural(nitems(p), "test item"), " in ", elapsed) :
            string("ran ", plural(nitems(p), "test item"), " in ", elapsed,
                   single_process(p) ? " in this process" : string(" on ", plural(length(run.slots), "worker"))),
        isempty(tally) ? ", all passed" : string(", ", join(tally, ", "))
    )
    body = styled() do io
        run.monitor === nothing || print_memory_summary(io, run.monitor; indent = "")
        if run.runstate !== nothing
            print(io, "run state: ")
            printstyled(io, run.runstate.path; color = :light_black)
            println(io)
        end
    end
    print_yatf_block(run, head, body)
    return nothing
end

# Everything that is not a plain pass, in the order a reader cares about.
function state_tally(states)
    out = String[]
    for (state, label) in STATE_LABELS
        state === PASSED && continue
        c = count(==(state), states)
        c > 0 && push!(out, string(c, " ", label))
    end
    return out
end

const STATE_LABELS = (
    PASSED => "passed", FAILED => "failed", ERRORED => "errored", TIMEDOUT => "timed out",
    BROKEN_CHAIN => "broken by a dead worker", SKIPPED => "skipped", CANCELLED => "cancelled",
    UNSEEN => "did not run", RUNNING => "still running",
)

# Why a worker ended, as a person says it.
worker_end_text(by::Symbol) =
    by === :close ? "closed by the run" : by === :timeout ? "killed for a timeout" :
    by === :connection_lost || by === :process_exit ? "died" : by === :memory_guard ? "killed by the memory guard" :
    by === :interrupt ? "killed by an interrupt" : by === :init_failed ? "its init expression failed" :
    replace(String(by), '_' => ' ')

# A run's testsets are built after the items finish, so both ends are set from what
# the run recorded. 1.13 takes the start as a keyword and holds `time_end`
# atomically; 1.12 has neither.
@static if VERSION >= v"1.13"
    started_testset(name::AbstractString; verbose::Bool, at::Float64) =
        Test.DefaultTestSet(name; verbose, time_start = at)
    finished_at!(ts::Test.DefaultTestSet, at::Float64) = (@atomic ts.time_end = at)
else
    function started_testset(name::AbstractString; verbose::Bool, at::Float64)
        ts = Test.DefaultTestSet(name; verbose)
        ts.time_start = at
        return ts
    end
    finished_at!(ts::Test.DefaultTestSet, at::Float64) = (ts.time_end = at)
end

# A file's wall time: from its first item's dispatch to its last item's end. With
# several workers these overlap, so they do not sum to the run's time.
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
    ts = started_testset(name; verbose = p.cfg.verbose, at = run.t0 + first_start)
    finished_at!(ts, run.t0 + last_end)
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
    root = started_testset(p.cfg.testset_name; verbose = true, at = run.t0)
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

"""
    RunTestSet

What [`runtests`](@ref) returns: a testset that prints as one line. Everything else
it hands to the `Test.DefaultTestSet` it holds, `ts.testset`, whose fields also
read through it, so it records, finishes, counts and summarizes as that testset
does. Recorded into a parent or finished inside one, it is the `DefaultTestSet`
that goes into the parent, so no testset tree ever holds anything else.
"""
struct RunTestSet <: Test.AbstractTestSet
    testset::Test.DefaultTestSet
end

# `@testset RunTestSet "name" begin … end`, which names the type to make.
RunTestSet(description::AbstractString; kwargs...) = RunTestSet(Test.DefaultTestSet(description; kwargs...))

Base.getproperty(ts::RunTestSet, f::Symbol) =
    f === :testset ? getfield(ts, :testset) : getproperty(getfield(ts, :testset), f)
Base.propertynames(ts::RunTestSet, private::Bool = false) =
    (:testset, propertynames(getfield(ts, :testset), private)...)

Test.record(ts::RunTestSet, res; kwargs...) = Test.record(ts.testset, res; kwargs...)
Test.record(parent::Test.DefaultTestSet, ts::RunTestSet) = Test.record(parent, ts.testset)
function Test.finish(ts::RunTestSet; kwargs...)
    Test.finish(ts.testset; kwargs...)
    return ts
end
Test.results(ts::RunTestSet) = Test.results(ts.testset)
Test.print_verbose(ts::RunTestSet) = Test.print_verbose(ts.testset)
Test.get_test_counts(ts::RunTestSet) = Test.get_test_counts(ts.testset)
Test.get_alignment(ts::RunTestSet, depth::Int) = Test.get_alignment(ts.testset, depth)
Test.format_duration(ts::RunTestSet) = Test.format_duration(ts.testset)
Test.filter_errors(ts::RunTestSet) = Test.filter_errors(ts.testset)
Test.get_rng(ts::RunTestSet) = Test.get_rng(ts.testset)
Test.set_rng!(ts::RunTestSet, rng::Random.AbstractRNG) = Test.set_rng!(ts.testset, rng)
Test.print_test_results(ts::RunTestSet, depth_pad = 0) = Test.print_test_results(ts.testset, depth_pad)
@static if isdefined(Test, :anynonpass)
    Test.anynonpass(ts::RunTestSet) = Test.anynonpass(ts.testset)
end

# One line: the testset's name and what it counted, inside other output too.
function Base.show(io::IO, ts::RunTestSet)
    tc = Test.get_test_counts(ts.testset)
    counts = (tc.passes + tc.cumulative_passes => "passed", tc.fails + tc.cumulative_fails => "failed",
              tc.errors + tc.cumulative_errors => "errored", tc.broken + tc.cumulative_broken => "broken")
    shown = [string(n, " ", what) for (n, what) in counts if n > 0]
    print(io, repr(ts.testset.description), " testset: ", isempty(shown) ? "no tests" : join(shown, ", "))
    ts.testset.time_end > 0 && print(io, " · ", Test.format_duration(ts.testset))
    return nothing
end

# An item that never ran is not an item that passed. A run cut short (an `init`
# that will not start, a dead slot, failfast) records what is missing, or the
# emptiest run would be the greenest.
function record_unrun!(root::Test.AbstractTestSet, run)
    p = run.plan
    st = run.statuses
    idxs = [i for i in 1:nitems(p) if st.state[i] === UNSEEN || st.state[i] === CANCELLED]
    isempty(idxs) && return nothing
    shown = join((repr(p.items.name[i]) for i in Iterators.take(idxs, 5)), ", ")
    why = is_cancelled(run.queues) ? "did not run because the run stopped early" :
        "have no outcome, though the run was not stopped (a YATF bug, logged above)"
    msg = string(length(idxs), " of ", plural(nitems(p), "test item"), " ", why, ": ", shown, length(idxs) > 5 ? ", …" : "")
    # The conclusion block above says the same thing in the run's own words; this
    # record exists so the verdict is wrong when the run was.
    add_error!(root, msg, source_of(p, first(idxs)))
    return nothing
end

# Where an item is, as a stack frame would say it.
source_of(p::Plan, i::Integer) = LineNumberNode(Int(p.items.line[i]), p.files[p.items.fileidx[i]])

# An error the run synthesized, recorded into `ts` without `Test` printing it: the
# run prints what it records itself. `Test.Error` renders its message from the
# exception stack, so the stack carries it.
function add_error!(ts::Test.AbstractTestSet, msg::AbstractString, source::LineNumberNode)
    stack = Base.ExceptionStack([(exception = ErrorException(msg), backtrace = Ptr{Nothing}[])])
    with_testset_printing(false) do
        Test.record(ts, Test.Error(:nontest_error, Expr(:tuple), ErrorException(msg), stack, source))
    end
    return ts
end

"""
    report_item!(run, i, state, n, msg)

Everything an item has to say, written when it finishes and in one piece so that
no other worker's output lands inside it: its failures, then its captured logs.
`Test` would print failures where they are recorded, on a worker with printing
switched off, so the coordinator prints them.
"""
function report_item!(run, i::ItemIdx, state::ItemState, n::Integer, msg::AbstractString)
    p = run.plan
    # A cancelled item has nothing of its own to show; the conclusion counts them.
    state === CANCELLED && return nothing
    # Having nothing to say is the common case — a passing item in `:issues` mode —
    # and everything below this line allocates to find that out.
    (is_non_pass(state) || wants_log(p.cfg.logs, state) || p.cfg.verbose) || return nothing
    body = styled() do io
        # A coordinator-written outcome — a timeout, a dead worker — is already
        # stated in this block's first line; showing the record it synthesized
        # would say it again, word for word.
        is_non_pass(state) && !run.statuses.synthetic[i] && print_failures(io, run, i)
        print_item_log(io, run, i, state)
    end
    isempty(body) && return nothing
    total = nitems(p)
    label = string("[", lpad(n, ndigits(total)), "/", total, "] ", short_state(state))
    rest = string(repr(p.items.name[i]), isempty(msg) ? "" : string(" · ", msg))
    footer = string(
        "@ ", itemfile(p, i), ":", p.items.line[i], on_worker(run, i)
    )
    printline(run, bracket(strip_root(body, p.root), label, rest, footer, state_color(state)))
    return nothing
end

"""
    bracket(body, label, rest, footer, color) -> String

`body` drawn in the shape `Logging` gives a multi-line record: `┌`, the coloured
`label` and `rest` on the first line, `│` down the side, and `└` on the last, with
`footer` dimmed.
"""
function bracket(
        body::AbstractString, label::AbstractString, rest::AbstractString,
        footer::AbstractString, color
    )
    # Coloured like a log record: the gutter and the label carry the colour, what
    # follows is ordinary text, and the location at the bottom is dimmed.
    return styled() do io
        printstyled(io, "┌ ", label; color, bold = true)
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
        tail === nothing ? (isempty(footer) || printstyled(io, footer; color = :light_black)) : print(io, tail)
        println(io)
    end
end

"""
    strip_root(text, root)

`text` with the project's directory taken off every path in it. Paths stay absolute
while an item runs, because `@__FILE__` and `@__DIR__` depend on them; shortening
them on the way out cannot change what the item's code means.
"""
function strip_root(text::AbstractString, root::AbstractString)
    isempty(root) && return text
    out = text
    # The stacktrace printer contracts the home directory, so the same path can
    # arrive spelled two ways; and on Windows with either separator, since Julia
    # writes `\` and much else writes `/`.
    for r in unique((root, Base.contractuser(root))), sep in PATH_SEPARATORS
        out = replace(out, r * sep => "")
    end
    return out
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
    # A bracket of its own inside the item's, written through rather than indented,
    # so the item's own log records and colours come out as its author meant.
    logs = trim_blank_lines(open(io -> read(io, String), path, "r"))
    print(io, bracket(logs, "Captured logs", "", "", Base.info_color()))
    return nothing
end

# A crash dump or a triggered profile tends to start and end with blank lines,
# which inside a bracket become empty gutter rows.
trim_blank_lines(text::AbstractString) =
    replace(replace(text, r"\A(?:[ \t]*\n)+" => ""), r"(?:\n[ \t]*)+\z" => "")

# With no workers there is no worker to name.
on_worker(run, i::ItemIdx) =
    (single_process(run.plan) || run.statuses.slot[i] == 0) ? "" :
    string(" on worker ", run.statuses.slot[i])

item_logpath(run, i::ItemIdx) =
    item_log_path(run.logprefix, i, max(run.statuses.attempt[i], 1))

"""
    item_log_path(prefix, index, attempt) -> String

Where one attempt at one item writes what it prints. Built a byte at a time:
`string` boxes each number, and this runs for every dispatch.
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
